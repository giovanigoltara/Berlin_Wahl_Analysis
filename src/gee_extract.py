"""Summer land surface temperature (LST) and NDVI per station district, from Google Earth Engine.

1. Composites over imagery.aoi_bbox, June to August of each year in imagery.years:
   - LST: Landsat 8 and 9 Collection 2 Level 2, scenes with CLOUD_COVER <= max_scene_cloud_cover,
     pixels masked with QA_PIXEL (dilated cloud, cirrus, cloud, shadow) and ST_B10 = 0 (no data),
     K = ST_B10 * st_scale + st_offset, minus 273.15 for degrees Celsius; per-pixel median.
   - NDVI: Sentinel-2 SR Harmonized, pixels with Cloud Score+ cs_cdf below clear_threshold
     masked, NDVI = (B8 - B4) / (B8 + B4); per-pixel median.
   Each composite carries the number of clear observations per pixel.
2. Scene counts (before and after the scene cloud filter) and the clear-observation spread are
   written to docs/provenance.md; low-resolution previews (computePixels, drawn locally) to
   figures/.
3. Zonal statistics per station district over two zones: residential land
   (analysis.district_population.residential_geom, sql/30_dasymetric.sql) and the whole district
   (clean.station_district). Mean and median are area-weighted; effective pixels are the zone's
   area with valid data, in pixels. Reduction runs in EPSG:25833 at each sensor's scale_m.
4. Results go to raw.ee_zonal and raw.ee_meta in PostGIS, and to data/processed/ (ee_zonal.csv,
   ee_meta.json), so later phases can be rerun without Earth Engine credentials (--from-csv).
   sql/35_satellite.sql picks the zone per district and runs the checks.

Usage: uv run python src/gee_extract.py             (full run, needs the PostGIS tables)
       uv run python src/gee_extract.py --no-zonal  (composites, counts and previews only)
       uv run python src/gee_extract.py --from-csv  (load committed results, no Earth Engine)
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import UTC, datetime
from pathlib import Path

import ee
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
import yaml  # noqa: E402
from pyproj import Transformer  # noqa: E402
from sqlalchemy import create_engine, text  # noqa: E402

import ee_auth  # noqa: E402
from run_sql import dsn  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
PROVENANCE = ROOT / "docs/provenance.md"
SECTION = "## Earth Engine imagery"
BATCH = 100  # features per reduceRegions request; keeps each request well under the size limit
WORKING_CRS = "EPSG:25833"


# Composites ------------------------------------------------------------------------------


def season_filter(img_params: dict) -> ee.Filter:
    """June to August (season_start inclusive, season_end exclusive) of every configured year."""
    windows = [
        ee.Filter.date(f"{y}-{img_params['season_start']}", f"{y}-{img_params['season_end']}")
        for y in img_params["years"]
    ]
    return ee.Filter.Or(*windows)


def landsat(img_params: dict, aoi: ee.Geometry) -> tuple[ee.ImageCollection, ee.ImageCollection]:
    """Return (all scenes in season, LST in degrees C of the scenes passing the cloud filter)."""
    p = img_params["landsat"]
    scenes = ee.ImageCollection(p["collections"][0])
    for name in p["collections"][1:]:
        scenes = scenes.merge(ee.ImageCollection(name))
    scenes = scenes.filterBounds(aoi).filter(season_filter(img_params))
    kept = scenes.filter(ee.Filter.lte("CLOUD_COVER", p["max_scene_cloud_cover"]))
    qa_bits = sum(1 << b for b in p["qa_mask_bits"])

    def to_lst(img: ee.Image) -> ee.Image:
        dn = img.select(p["band"])
        clear = img.select("QA_PIXEL").bitwiseAnd(qa_bits).eq(0).And(dn.gt(0))
        celsius = dn.multiply(p["st_scale"]).add(p["st_offset"]).subtract(273.15)
        return celsius.updateMask(clear).rename("lst").copyProperties(img, ["system:time_start"])

    return scenes, kept.map(to_lst)


def sentinel2(img_params: dict, aoi: ee.Geometry) -> tuple[ee.ImageCollection, ee.ImageCollection]:
    """Return (all images in season, NDVI with Cloud Score+ masking)."""
    p = img_params["sentinel2"]
    images = ee.ImageCollection(p["collection"]).filterBounds(aoi).filter(season_filter(img_params))
    linked = images.linkCollection(
        ee.ImageCollection(p["cloud_score_collection"]), [p["cloud_score_band"]]
    )

    def to_ndvi(img: ee.Image) -> ee.Image:
        clear = img.select(p["cloud_score_band"]).gte(p["clear_threshold"])
        ndvi = img.normalizedDifference([p["nir_band"], p["red_band"]]).rename("ndvi")
        return ndvi.updateMask(clear).copyProperties(img, ["system:time_start"])

    return images, linked.map(to_ndvi)


def composite(masked: ee.ImageCollection, band: str) -> ee.Image:
    """Per-pixel median and number of clear observations."""
    return masked.median().rename(band).addBands(masked.count().rename("n_obs"))


# Counts and previews ---------------------------------------------------------------------


def count_by_year(coll: ee.ImageCollection, years: list[int], prop: str) -> dict[str, dict]:
    """Images per year, split by the given property (collection or spacecraft)."""
    out = {}
    for y in years:
        c = coll.filter(ee.Filter.calendarRange(y, y, "year"))
        out[str(y)] = c.aggregate_histogram(prop).getInfo()
    return out


def obs_spread(img: ee.Image, aoi: ee.Geometry, scale: int) -> dict:
    stats = img.select("n_obs").reduceRegion(
        ee.Reducer.percentile([0, 5, 50, 95]), aoi, scale * 10, crs=WORKING_CRS, bestEffort=True
    )
    return {k.replace("n_obs_", ""): round(v) for k, v in stats.getInfo().items()}


def preview(
    img: ee.Image, band: str, bbox: list[float], res_m: int, vis: dict, label: str, out: Path
) -> None:
    """Fetch the composite on a coarse EPSG:25833 grid and save a PNG with a colour bar."""
    west, south, east, north = Transformer.from_crs(4326, 25833, always_xy=True).transform_bounds(
        *bbox
    )
    width, height = int((east - west) // res_m), int((north - south) // res_m)
    arr = ee.data.computePixels(
        {
            "expression": img.select(band).unmask(-9999),
            "fileFormat": "NUMPY_NDARRAY",
            "grid": {
                "dimensions": {"width": width, "height": height},
                "affineTransform": {
                    "scaleX": res_m,
                    "shearX": 0,
                    "translateX": west,
                    "shearY": 0,
                    "scaleY": -res_m,
                    "translateY": north,
                },
                "crsCode": WORKING_CRS,
            },
        }
    )[band]
    data = np.ma.masked_equal(arr.astype(float), -9999)
    fig, ax = plt.subplots(figsize=(7, 7 * height / width + 0.6), dpi=150)
    im = ax.imshow(
        data, cmap=vis["cmap"], vmin=vis["min"], vmax=vis["max"], extent=(west, east, south, north)
    )
    ax.set_axis_off()
    fig.colorbar(im, ax=ax, shrink=0.7, label=label)
    ax.set_title(f"{label}, preview at {res_m} m", fontsize=10)
    fig.savefig(out, bbox_inches="tight")
    plt.close(fig)


# Zonal statistics -------------------------------------------------------------------------


def zones(engine) -> pd.DataFrame:
    """Residential land and whole district per station district, as GeoJSON in EPSG:4326."""
    sql = text(
        """
        SELECT uwb, 'residential' AS zone, ST_AsGeoJSON(ST_Transform(residential_geom, 4326), 7)
               AS geojson
        FROM analysis.district_population WHERE residential_geom IS NOT NULL
        UNION ALL
        SELECT uwb, 'district', ST_AsGeoJSON(ST_Transform(geom, 4326), 7)
        FROM clean.station_district
        ORDER BY zone, uwb
        """
    )
    with engine.connect() as conn:
        return pd.read_sql(sql, conn)


def reduce_zones(img: ee.Image, band: str, scale: int, z: pd.DataFrame) -> pd.DataFrame:
    """Area-weighted mean and median, effective pixels and mean clear observations per zone.

    Effective pixels are the weighted sum of the valid-data mask: the zone's area with data,
    in pixels. An unweighted count would include every pixel the zone touches, which overstates
    fragmented residential masks.
    """
    img = img.addBands(img.select(band).mask().rename("valid"))
    reducer = (
        ee.Reducer.mean()
        .combine(ee.Reducer.median(), sharedInputs=True)
        .combine(ee.Reducer.sum(), sharedInputs=True)
    )
    rows = []
    for start in range(0, len(z), BATCH):
        part = z.iloc[start : start + BATCH]
        fc = ee.FeatureCollection(
            [
                ee.Feature(ee.Geometry(json.loads(g), opt_geodesic=False), {"uwb": u, "zone": zn})
                for u, zn, g in zip(part.uwb, part.zone, part.geojson, strict=True)
            ]
        )
        out = img.reduceRegions(fc, reducer, scale=scale, crs=WORKING_CRS, tileScale=4)
        for f in out.getInfo()["features"]:
            p = f["properties"]
            rows.append(
                {
                    "uwb": p["uwb"],
                    "zone": p["zone"],
                    "indicator": band,
                    "mean": p.get(f"{band}_mean"),
                    "median": p.get(f"{band}_median"),
                    "n_eff_pixels": p.get("valid_sum", 0),
                    "mean_obs": p.get("n_obs_mean"),
                }
            )
        print(f"zonal {band:<5} {min(start + BATCH, len(z)):>5} of {len(z)} zones")
    return pd.DataFrame(rows)


# Provenance -------------------------------------------------------------------------------


def write_provenance(meta: dict) -> None:
    """Replace (or append) the generated Earth Engine section of docs/provenance.md."""
    lt, s2 = meta["landsat"], meta["sentinel2"]
    lines = [
        SECTION,
        "",
        f"Generated by `src/gee_extract.py` on {meta['run_utc']} (earthengine-api "
        f"{meta['ee_version']}). Parameters are in `config/params.yaml` under `imagery`.",
        "",
        f"- Extent: {meta['aoi_bbox']} (EPSG:4326, west, south, east, north)",
        f"- Season: {meta['season']} of {', '.join(map(str, meta['years']))}, per-pixel median",
        f"- LST: `{'`, `'.join(lt['collections'])}`, band `{lt['band']}`, "
        f"K = DN x {lt['st_scale']} + {lt['st_offset']}, minus 273.15; scenes with "
        f"`CLOUD_COVER` <= {lt['max_scene_cloud_cover']}; `QA_PIXEL` bits {lt['qa_mask_bits']} "
        f"masked; {lt['scale_m']} m",
        f"- NDVI: `{s2['collection']}`, (`{s2['nir_band']}` - `{s2['red_band']}`) / "
        f"(`{s2['nir_band']}` + `{s2['red_band']}`); pixels with `{s2['cloud_score_band']}` < "
        f"{s2['clear_threshold']} masked using `{s2['cloud_score_collection']}`; {s2['scale_m']} m",
        *[
            f"- Terms of use, {name}: "
            + (f'"{t["licence_as_stated"]}"' if t["licence_as_stated"] else "not yet recorded")
            + f" ({t['catalogue']})"
            for name, t in meta["terms"].items()
        ],
        "",
        "| Year | Landsat scenes in season | after scene cloud filter | Sentinel-2 granules |",
        "| --- | --- | --- | --- |",
    ]
    for y in map(str, meta["years"]):
        total = sum(meta["landsat_scenes"][y].values())
        kept = sum(meta["landsat_kept"][y].values())
        by_sat = ", ".join(f"{k} {v}" for k, v in sorted(meta["landsat_kept"][y].items()))
        s2_total = sum(meta["s2_images"][y].values())
        lines.append(f"| {y} | {total} | {kept} ({by_sat}) | {s2_total} |")
    lo, so = meta["lst_obs"], meta["ndvi_obs"]
    lines += [
        "",
        "Clear observations per pixel over the extent (percentiles p0 / p5 / p50 / p95): "
        f"LST {lo['p0']} / {lo['p5']} / {lo['p50']} / {lo['p95']}, "
        f"NDVI {so['p0']} / {so['p5']} / {so['p50']} / {so['p95']}.",
        "",
        "Previews: `figures/preview_lst.png`, `figures/preview_ndvi.png` "
        f"(LST stretched {meta['lst_vis'][0]} to {meta['lst_vis'][1]} °C, NDVI 0 to 0.8).",
    ]
    section = "\n".join(lines) + "\n"
    text_ = PROVENANCE.read_text(encoding="utf-8")
    if SECTION in text_:
        before, after = text_.split(SECTION, 1)
        nxt = after.find("\n## ")
        text_ = before + section + ("\n" + after[nxt + 1 :] if nxt >= 0 else "")
    else:
        text_ = text_.rstrip() + "\n\n" + section
    PROVENANCE.write_text(text_, encoding="utf-8")


def to_postgis(result: pd.DataFrame, meta: dict, engine) -> None:
    result.to_sql("ee_zonal", engine, schema="raw", if_exists="replace", index=False)
    flat = {k: (json.dumps(v) if isinstance(v, (dict, list)) else v) for k, v in meta.items()}
    pd.DataFrame([flat]).to_sql("ee_meta", engine, schema="raw", if_exists="replace", index=False)
    print(f"raw   ee_zonal {len(result)} rows, ee_meta")


# Main -------------------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--no-zonal", action="store_true", help="skip zonal statistics")
    mode.add_argument(
        "--from-csv",
        action="store_true",
        help="load the committed data/processed results into PostGIS, without Earth Engine",
    )
    args = parser.parse_args()

    params = yaml.safe_load((ROOT / "config/params.yaml").read_text(encoding="utf-8"))
    img = params["imagery"]
    engine = create_engine(dsn().replace("postgresql://", "postgresql+psycopg://"))
    if args.from_csv:
        processed = ROOT / params["paths"]["processed"]
        result = pd.read_csv(processed / "ee_zonal.csv", dtype={"uwb": str})
        meta = json.loads((processed / "ee_meta.json").read_text(encoding="utf-8"))
        print(f"csv   {len(result)} rows from data/processed/ee_zonal.csv ({meta['run_utc']})")
        to_postgis(result, meta, engine)
        return 0

    print(f"ee    {ee_auth.init()}")
    aoi = ee.Geometry.Rectangle(img["aoi_bbox"], proj="EPSG:4326", geodesic=False)

    lt_scenes, lt_masked = landsat(img, aoi)
    s2_images, s2_masked = sentinel2(img, aoi)
    lst = composite(lt_masked, "lst")
    ndvi = composite(s2_masked, "ndvi")

    meta = {
        "run_utc": datetime.now(UTC).strftime("%Y-%m-%d %H:%M UTC"),
        "ee_version": ee.__version__,
        "aoi_bbox": img["aoi_bbox"],
        "years": img["years"],
        "season": f"{img['season_start']} to {img['season_end']} (end exclusive)",
        "landsat": img["landsat"],
        "sentinel2": img["sentinel2"],
        "terms": img["terms"],
        "landsat_scenes": count_by_year(lt_scenes, img["years"], "SPACECRAFT_ID"),
        "landsat_kept": count_by_year(
            lt_scenes.filter(ee.Filter.lte("CLOUD_COVER", img["landsat"]["max_scene_cloud_cover"])),
            img["years"],
            "SPACECRAFT_ID",
        ),
        "s2_images": count_by_year(s2_images, img["years"], "SPACECRAFT_NAME"),
        "lst_obs": obs_spread(lst, aoi, img["landsat"]["scale_m"]),
        "ndvi_obs": obs_spread(ndvi, aoi, img["sentinel2"]["scale_m"]),
    }
    for y in map(str, img["years"]):
        print(
            f"year  {y}: Landsat {meta['landsat_scenes'][y]} -> kept {meta['landsat_kept'][y]}; "
            f"Sentinel-2 {meta['s2_images'][y]}"
        )
    print(f"obs   LST {meta['lst_obs']}, NDVI {meta['ndvi_obs']}")

    # Preview stretch from the 2nd and 98th LST percentiles over the extent, rounded to 1 degree.
    pct = (
        lst.select("lst")
        .reduceRegion(ee.Reducer.percentile([2, 98]), aoi, 300, crs=WORKING_CRS, bestEffort=True)
        .getInfo()
    )
    meta["lst_vis"] = [round(pct["lst_p2"]), round(pct["lst_p98"])]
    figures = ROOT / params["paths"]["figures"]
    figures.mkdir(exist_ok=True)
    res = img["preview_res_m"]
    preview(
        lst,
        "lst",
        img["aoi_bbox"],
        res,
        {"min": meta["lst_vis"][0], "max": meta["lst_vis"][1], "cmap": "RdYlBu_r"},
        "Summer land surface temperature (°C)",
        figures / "preview_lst.png",
    )
    preview(
        ndvi,
        "ndvi",
        img["aoi_bbox"],
        res,
        {"min": 0, "max": 0.8, "cmap": "Greens"},
        "Summer NDVI",
        figures / "preview_ndvi.png",
    )
    print("png   figures/preview_lst.png, figures/preview_ndvi.png")
    write_provenance(meta)
    print(f"doc   {PROVENANCE.relative_to(ROOT)}: section '{SECTION[3:]}'")

    if args.no_zonal:
        return 0

    z = zones(engine)
    print(
        f"zones {len(z)} ({(z.zone == 'residential').sum()} residential, "
        f"{(z.zone == 'district').sum()} whole districts)"
    )
    result = pd.concat(
        [
            reduce_zones(lst, "lst", img["landsat"]["scale_m"], z),
            reduce_zones(ndvi, "ndvi", img["sentinel2"]["scale_m"], z),
        ],
        ignore_index=True,
    )
    processed = ROOT / params["paths"]["processed"]
    processed.mkdir(exist_ok=True)
    result.to_csv(processed / "ee_zonal.csv", index=False, float_format="%.6f")
    (processed / "ee_meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    print(f"csv   {len(result)} rows to data/processed/ee_zonal.csv, run metadata to ee_meta.json")
    to_postgis(result, meta, engine)
    return 0


if __name__ == "__main__":
    sys.exit(main())
