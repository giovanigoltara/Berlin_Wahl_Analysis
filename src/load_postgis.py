"""Load raw sources into PostGIS, build clean tables and run load checks.

Steps, each idempotent:
  1. sql/00_schema.sql   schemas and typed clean tables
  2. raw.*               sources as delivered (attributes as text, column names lowercased)
  3. sql/05_clean.sql    typed, keyed clean tables
  4. sql/10_load_checks.sql, results copied to docs/validation_report.md

Connection settings come from the environment (.env, see .env.example).

Usage: uv run python src/load_postgis.py
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import geopandas as gpd
import pandas as pd
import psycopg
import yaml
from sqlalchemy import create_engine

from inspect_raw import party_names
from run_sql import write_report

ROOT = Path(__file__).resolve().parents[1]
SQL = ROOT / "sql"
REPORT = ROOT / "docs/validation_report.md"
SECTION = "## Phase 2a: PostGIS load"


def dsn() -> str:
    e = os.environ.get
    return (
        f"postgresql://{e('POSTGRES_USER', 'hgv')}:{e('POSTGRES_PASSWORD', 'hgv')}"
        f"@{e('POSTGRES_HOST', 'localhost')}:{e('POSTGRES_PORT', '5432')}/{e('POSTGRES_DB', 'hgv')}"
    )


def run_sql(conn: psycopg.Connection, name: str) -> None:
    print(f"sql   {name}")
    conn.execute((SQL / name).read_text(encoding="utf-8"))
    conn.commit()


def lower_columns(df: pd.DataFrame) -> pd.DataFrame:
    return df.rename(columns=str.lower)


def load_raw(engine, raw: Path) -> None:
    er = raw / "election_results"
    tables = {
        "manifest": pd.read_csv(raw / "manifest.csv", dtype=str),
        "results_w": pd.read_csv(
            er / "Datenexport_AGH2026_Zweitstimme_W_BE.csv",
            sep=";",
            encoding="utf-8-sig",
            dtype=str,
        ),
        "results_a": pd.read_csv(
            er / "Datenexport_AGH2026_Zweitstimme_A_BE.csv",
            sep=";",
            encoding="utf-8-sig",
            dtype=str,
        ),
    }
    names = party_names(er / "DSB_Datenexport_AGH2026_Zweitstimme_W_BE.csv")
    tables["parties"] = pd.DataFrame(
        [(c, n) for c, n in names.items() if not n.startswith("nicht besetzt")],
        columns=["party_code", "party_name"],
    )
    for name, df in tables.items():
        lower_columns(df).to_sql(name, engine, schema="raw", if_exists="replace", index=False)
        print(f"raw   {name:<18} {len(df):>6} rows")

    layers = {
        "uwb_geom": gpd.read_file(f"zip://{raw / 'district_geometries/RBS_OD_UWB_AH26.zip'}"),
        "population_blocks": gpd.read_file(raw / "population_density/ua_einwohnerdichte_2025.gml"),
    }
    for name, gdf in layers.items():
        # Geometry types stay as delivered; 05_clean.sql casts to MultiPolygon.
        gdf = lower_columns(gdf).rename_geometry("geom")
        for col in gdf.columns.drop("geom"):
            gdf[col] = gdf[col].astype("string")
        gdf.to_postgis(name, engine, schema="raw", if_exists="replace", index=False)
        print(f"raw   {name:<18} {len(gdf):>6} rows, EPSG:{gdf.crs.to_epsg()}")


def main() -> int:
    params = yaml.safe_load((ROOT / "config/params.yaml").read_text(encoding="utf-8"))
    raw = ROOT / params["paths"]["raw"]
    engine = create_engine(dsn().replace("postgresql://", "postgresql+psycopg://"))

    with psycopg.connect(dsn()) as conn:
        run_sql(conn, "00_schema.sql")
        load_raw(engine, raw)
        run_sql(conn, "05_clean.sql")
        run_sql(conn, "10_load_checks.sql")
        rows = conn.execute(
            "SELECT name, passed, detail FROM clean.load_check ORDER BY check_id"
        ).fetchall()

    for name, passed, detail in rows:
        print(f"{'pass' if passed else 'FAIL'}  {name}: {detail}")
    source = "`src/load_postgis.py` from `clean.load_check` (`sql/10_load_checks.sql`)"
    ok = write_report(SECTION, source, rows)
    print(f"Wrote {REPORT.relative_to(ROOT)}: {'all checks pass' if ok else 'CHECKS FAILED'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
