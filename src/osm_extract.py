"""Extract amenities from the OSM PBF and load them into PostGIS as raw.osm_amenity.

The tag mapping lives in config/params.yaml (accessibility.amenities). GDAL's OSM driver reads
nodes as `points` and closed ways and multipolygon relations as `multipolygons`; tags without a
column of their own are in the hstore text `other_tags`. A feature gets one row per category it
matches; features with a non-public access tag are dropped. Geometries stay in EPSG:4326 as
delivered; sql/40_accessibility.sql transforms and validates them.

The extract date is read from the PBF header (osmosis_replication_timestamp) and stored in
raw.osm_meta, so it travels with the data.

Usage: uv run python src/osm_extract.py
"""

from __future__ import annotations

import re
import struct
import sys
import time
import zlib
from pathlib import Path

import geopandas as gpd
import pandas as pd
import pyogrio
import yaml
from sqlalchemy import create_engine

from run_sql import dsn

ROOT = Path(__file__).resolve().parents[1]
LAYERS = {"points": "node", "multipolygons": "area"}
HSTORE = re.compile(r'"((?:[^"\\]|\\.)*)"=>"((?:[^"\\]|\\.)*)"')


def _varint(b: bytes, i: int) -> tuple[int, int]:
    r = s = 0
    while True:
        c = b[i]
        i += 1
        r |= (c & 0x7F) << s
        s += 7
        if c < 0x80:
            return r, i


def _fields(b: bytes) -> list[tuple[int, int | bytes]]:
    """Minimal protobuf decoder: (field number, value) pairs."""
    i, out = 0, []
    while i < len(b):
        key, i = _varint(b, i)
        num, wire = key >> 3, key & 7
        if wire == 0:
            v, i = _varint(b, i)
        elif wire == 2:
            n, i = _varint(b, i)
            v, i = b[i : i + n], i + n
        elif wire == 1:
            v, i = b[i : i + 8], i + 8
        elif wire == 5:
            v, i = b[i : i + 4], i + 4
        else:
            raise ValueError(f"unsupported protobuf wire type {wire}")
        out.append((num, v))
    return out


def pbf_header(path: Path) -> dict[str, str]:
    """Read the OSM PBF HeaderBlock: writing program, replication timestamp and base URL."""
    with path.open("rb") as f:
        n = struct.unpack(">I", f.read(4))[0]
        blob_header = dict(_fields(f.read(n)))
        blob = dict(_fields(f.read(blob_header[3])))
    header = _fields(zlib.decompress(blob[3]))  # field 3: zlib_data
    out = {}
    for num, v in header:
        if num == 16:
            out["writingprogram"] = v.decode()
        elif num == 32:
            out["replication_timestamp"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(v))
        elif num == 34:
            out["replication_base_url"] = v.decode()
    return out


def read_layer(path: Path, layer: str, keys: set[str]) -> gpd.GeoDataFrame:
    """Read features carrying any of the mapped keys, with all tags as a dict."""
    columns = set(pyogrio.read_info(path, layer=layer)["fields"])
    # Coarse prefilter in OGR SQL; the exact tag match happens in classify().
    where = " OR ".join(
        f"{k} IS NOT NULL" if k in columns else f"other_tags LIKE '%\"{k}\"=>%'"
        for k in sorted(keys)
    )
    gdf = pyogrio.read_dataframe(path, layer=layer, where=where)
    tag_cols = [
        c for c in gdf.columns if c not in ("geometry", "other_tags", "osm_id", "osm_way_id")
    ]

    def tags(row) -> dict[str, str]:
        t = {c: row[c] for c in tag_cols if isinstance(row[c], str)}
        if isinstance(row.get("other_tags"), str):
            t.update(HSTORE.findall(row["other_tags"]))
        return t

    gdf["tags"] = gdf.apply(tags, axis=1)
    if layer == "points":
        gdf["osm_type"], gdf["osm_key"] = "node", gdf["osm_id"]
    else:
        # Areas come from closed ways (osm_way_id) or multipolygon relations (osm_id).
        is_way = gdf["osm_way_id"].notna()
        gdf["osm_type"] = is_way.map({True: "way", False: "relation"})
        gdf["osm_key"] = gdf["osm_way_id"].where(is_way, gdf["osm_id"])
    return gdf[["osm_type", "osm_key", "tags", "geometry"]]


def classify(
    gdf: gpd.GeoDataFrame, mapping: dict, exclude_access: set[str]
) -> tuple[pd.DataFrame, int]:
    """One row per (feature, matching category); also return rows dropped for access tags."""
    rows, dropped = [], 0
    for rec in gdf.itertuples(index=False):
        t = rec.tags
        for category, rule in mapping.items():
            if any(t.get(k) in vals for k, vals in rule.items()):
                if t.get("access") in exclude_access:
                    dropped += 1
                    continue
                rows.append(
                    {
                        "category": category,
                        "osm_type": rec.osm_type,
                        "osm_id": int(rec.osm_key),
                        "name": t.get("name"),
                        "tag": next(f"{k}={t[k]}" for k, v in rule.items() if t.get(k) in v),
                        "access": t.get("access"),
                        "geometry": rec.geometry,
                    }
                )
    return pd.DataFrame(rows), dropped


def main() -> int:
    params = yaml.safe_load((ROOT / "config/params.yaml").read_text(encoding="utf-8"))
    acc = params["accessibility"]
    mapping = {c: {k: set(v) for k, v in rule.items()} for c, rule in acc["amenities"].items()}
    keys = {k for rule in mapping.values() for k in rule} | {"access"}
    exclude_access = set(acc["exclude_access"])

    pbf = ROOT / params["paths"]["raw"] / "osm/berlin-261003.osm.pbf"
    meta = pbf_header(pbf)
    print(f"pbf   {pbf.relative_to(ROOT)}: {meta}")

    frames, dropped = [], 0
    for layer in LAYERS:
        gdf = read_layer(pbf, layer, keys - {"access"})
        out, n_dropped = classify(gdf, mapping, exclude_access)
        dropped += n_dropped
        print(f"read  {layer:<14} {len(gdf):>7} candidates, {len(out):>6} category rows")
        frames.append(out)

    amen = gpd.GeoDataFrame(pd.concat(frames, ignore_index=True), geometry="geometry", crs=4326)
    amen = amen.rename_geometry("geom")
    engine = create_engine(dsn().replace("postgresql://", "postgresql+psycopg://"))
    amen.to_postgis("osm_amenity", engine, schema="raw", if_exists="replace", index=False)
    pd.DataFrame([{**meta, "file": pbf.name, "dropped_access": dropped}]).to_sql(
        "osm_meta", engine, schema="raw", if_exists="replace", index=False
    )

    print(amen.groupby("category").size().to_string())
    print(f"raw   osm_amenity {len(amen)} rows; {dropped} category rows dropped for access tags")
    return 0


if __name__ == "__main__":
    sys.exit(main())
