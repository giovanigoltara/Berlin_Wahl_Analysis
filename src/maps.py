"""Publication maps of the district indicators, PNG (300 dpi) and SVG in figures/.

Each district's value is drawn on its residential land only (sql/30_dasymetric.sql), not over
the whole district polygon, so large peripheral districts made of forest, water and industry do
not dominate the picture. Bezirk boundaries are drawn for orientation. Geometries are simplified
by MAP_SIMPLIFY_M metres for drawing only; at the printed scale one 300 dpi pixel covers about
40 m.

Maps (data from analysis.indicators, primary allocation method C):
  map_lst          summer land surface temperature
  map_ndvi         summer NDVI
  map_access       accessibility index (higher = farther from everyday services)
  map_linke        Die Linke share of valid Zweitstimmen
  map_afd          AfD share of valid Zweitstimmen
  map_bivariate    LST terciles x left-right contrast terciles

Classes are quantiles (mapclassify), so each colour holds the same number of districts; the
legend shows the class limits. Districts without residential land are not drawn.

Usage: uv run python src/maps.py
"""

from __future__ import annotations

import sys
from pathlib import Path

import geopandas as gpd
import mapclassify
import matplotlib
import numpy as np
import pandas as pd
import yaml
from sqlalchemy import create_engine, text

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.colors import ListedColormap  # noqa: E402
from matplotlib.patches import Patch  # noqa: E402
from matplotlib_scalebar.scalebar import ScaleBar  # noqa: E402

from run_sql import dsn  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
MAP_SIMPLIFY_M = 10
INK, MUTED, BOUNDARY = "#1a1a19", "#5c5c58", "#3d3d3a"
ELECTION = "Landeswahlleiter für Berlin, Abgeordnetenhaus 2026 (preliminary), allocation C"
GEOMETRY = "Amt für Statistik Berlin-Brandenburg: Wahlbezirke 2026, Einwohnerdichte 2025"
SOURCES = {
    "lst": f"USGS Landsat 8/9 C2 L2, June to August 2023 to 2025. {GEOMETRY}",
    "ndvi": f"Copernicus Sentinel-2 SR, June to August 2023 to 2025. {GEOMETRY}",
    "access": f"© OpenStreetMap contributors (ODbL), extract 2026-10-03. {GEOMETRY}",
    "party": f"{ELECTION}. {GEOMETRY}",
    "bivariate": f"USGS Landsat 8/9; {ELECTION}. {GEOMETRY}",
}
# Sequential ramps, one hue each, light to dark (7 classes).
RAMPS = {
    "lst": ["#fdf1e6", "#fbd7b4", "#f7b77f", "#ee8f4f", "#d9672e", "#b2461c", "#7f2d10"],
    "ndvi": ["#f2f7ec", "#d6eac3", "#b3d897", "#89c169", "#5ea544", "#3a8130", "#1f5a20"],
    "linke": ["#f7ecf3", "#ebcbe0", "#dba5c8", "#c97dae", "#b35693", "#8e3574", "#621e50"],
    "afd": ["#ebf2fa", "#c9dcf1", "#a1c2e6", "#74a3d8", "#4a82c4", "#2c61a3", "#183f73"],
}
# Diverging: better access (blue) to worse access (red) through a neutral grey midpoint.
DIVERGING = ["#1c4f8f", "#4f86c6", "#a9c2df", "#e6e5e1", "#e7ac98", "#cf6748", "#8f2a1c"]
# Bivariate 3 x 3 (rows: LST low to high; columns: contrast right-leaning to left-leaning).
BIVARIATE = [
    ["#e8e8e8", "#ace4e4", "#5ac8c8"],
    ["#dfb0d6", "#a5add3", "#5698b9"],
    ["#be64ac", "#8c62aa", "#3b4994"],
]


def load(engine) -> tuple[gpd.GeoDataFrame, gpd.GeoDataFrame]:
    sql = text(
        f"""
        SELECT i.uwb, i.lst, i.ndvi, i.access_index, i.linke, i.afd, i.contrast,
               ST_SimplifyPreserveTopology(p.residential_geom, {MAP_SIMPLIFY_M}) AS geom
        FROM analysis.indicators AS i
        JOIN analysis.district_population AS p USING (uwb)
        WHERE p.residential_geom IS NOT NULL
        """
    )
    bez = text(
        f"""
        SELECT bez, ST_SimplifyPreserveTopology(ST_Union(geom), {MAP_SIMPLIFY_M}) AS geom
        FROM clean.station_district GROUP BY bez
        """
    )
    with engine.connect() as conn:
        res = gpd.read_postgis(sql, conn, geom_col="geom")
        bezirke = gpd.read_postgis(bez, conn, geom_col="geom")
    return res, bezirke


def frame(bezirke: gpd.GeoDataFrame, title: str, subtitle: str, source: str):
    fig, ax = plt.subplots(figsize=(7.2, 6.4), dpi=300)
    fig.patch.set_facecolor("white")
    ax.set_axis_off()
    ax.set_aspect("equal")
    fig.text(0.02, 0.97, title, fontsize=12, fontweight="bold", color=INK, va="top")
    fig.text(0.02, 0.925, subtitle, fontsize=8, color=MUTED, va="top")
    fig.text(
        0.02,
        0.045,
        "Blank: land without residents (parks, forest, water, industry, "
        "transport); values describe residential land only.",
        fontsize=5.5,
        color=MUTED,
        va="bottom",
    )
    fig.text(0.02, 0.015, f"Data: {source}", fontsize=5.5, color=MUTED, va="bottom", wrap=True)
    return fig, ax


def finish(fig, ax, bezirke: gpd.GeoDataFrame, out: Path) -> None:
    bezirke.boundary.plot(ax=ax, color=BOUNDARY, linewidth=0.5, zorder=3)
    ax.add_artist(
        ScaleBar(
            1,
            units="m",
            location="lower right",
            length_fraction=0.2,
            box_alpha=0,
            color=INK,
            font_properties={"size": 7},
        )
    )
    ax.annotate(
        "N",
        xy=(0.97, 0.95),
        xytext=(0.97, 0.87),
        xycoords="axes fraction",
        ha="center",
        va="center",
        fontsize=9,
        color=INK,
        arrowprops={"arrowstyle": "-|>", "color": INK, "lw": 1},
    )
    fig.subplots_adjust(left=0.01, right=0.99, top=0.9, bottom=0.08)
    for ext in ("png", "svg"):
        fig.savefig(out.with_suffix(f".{ext}"), dpi=300, facecolor="white")
    plt.close(fig)


def choropleth(res, bezirke, column, colors, title, subtitle, source, fmt, out) -> None:
    data = res.dropna(subset=[column])
    cls = mapclassify.Quantiles(data[column], k=len(colors))
    data = data.assign(cls=cls.yb)
    fig, ax = frame(bezirke, title, subtitle, source)
    cmap = ListedColormap(colors)
    data.plot(ax=ax, column="cls", cmap=cmap, vmin=0, vmax=len(colors) - 1, linewidth=0, zorder=2)
    lower = [data[column].min(), *cls.bins[:-1]]
    handles = [
        Patch(facecolor=c, edgecolor="none", label=f"{fmt(lo)} to {fmt(hi)}")
        for c, lo, hi in zip(colors, lower, cls.bins, strict=True)
    ]
    ax.legend(
        handles=handles,
        loc="upper left",
        frameon=False,
        fontsize=6.5,
        title="Quantile classes",
        title_fontsize=6.5,
        labelcolor=INK,
        handlelength=1.4,
        borderaxespad=0,
    )
    finish(fig, ax, bezirke, out)


def bivariate(res, bezirke, out) -> None:
    data = res.dropna(subset=["lst", "contrast"]).copy()
    data["r"] = pd.qcut(data["lst"], 3, labels=False)
    data["c"] = pd.qcut(data["contrast"], 3, labels=False)
    data["color"] = [BIVARIATE[r][c] for r, c in zip(data["r"], data["c"], strict=True)]
    fig, ax = frame(
        bezirke,
        "Surface heat and the left-right contrast",
        "Terciles of summer LST and of (Linke + Grüne) minus (CDU + AfD) share, by district",
        SOURCES["bivariate"],
    )
    data.plot(ax=ax, color=data["color"], linewidth=0, zorder=2)
    # 3 x 3 legend in the upper left.
    leg = fig.add_axes((0.07, 0.62, 0.13, 0.13))
    leg.imshow(
        np.array([[matplotlib.colors.to_rgb(c) for c in row] for row in BIVARIATE]), origin="lower"
    )
    leg.set_xticks([0, 2], ["right", "left"], fontsize=6, color=INK)
    leg.set_yticks([0, 2], ["cool", "hot"], fontsize=6, color=INK)
    leg.set_xlabel("contrast", fontsize=6, color=MUTED, labelpad=6)
    leg.set_ylabel("LST", fontsize=6, color=MUTED, labelpad=1)
    leg.tick_params(length=0, pad=1)
    for s in leg.spines.values():
        s.set_visible(False)
    finish(fig, ax, bezirke, out)


def main() -> int:
    params = yaml.safe_load((ROOT / "config/params.yaml").read_text(encoding="utf-8"))
    engine = create_engine(dsn().replace("postgresql://", "postgresql+psycopg://"))
    res, bezirke = load(engine)
    print(f"data  {len(res)} districts with residential land, {len(bezirke)} Bezirke")
    figs = ROOT / params["paths"]["figures"]
    pct = lambda v: f"{100 * v:.1f} %"  # noqa: E731

    choropleth(
        res,
        bezirke,
        "lst",
        RAMPS["lst"],
        "Summer land surface temperature",
        "Median of clear Landsat observations, June to August 2023 to 2025, on "
        "residential land (°C)",
        SOURCES["lst"],
        lambda v: f"{v:.1f}",
        figs / "map_lst",
    )
    choropleth(
        res,
        bezirke,
        "ndvi",
        RAMPS["ndvi"],
        "Summer vegetation (NDVI)",
        "Median of clear Sentinel-2 observations, June to August 2023 to 2025, on residential land",
        SOURCES["ndvi"],
        lambda v: f"{v:.2f}",
        figs / "map_ndvi",
    )
    choropleth(
        res,
        bezirke,
        "access_index",
        DIVERGING,
        "Distance to everyday services",
        "Accessibility index: mean of z-scored log distances to 7 amenity types "
        "(0 = Berlin average, higher = farther)",
        SOURCES["access"],
        lambda v: f"{0.0 if abs(v) < 0.005 else v:+.2f}",
        figs / "map_access",
    )
    choropleth(
        res,
        bezirke,
        "linke",
        RAMPS["linke"],
        "Die Linke",
        "Share of valid Zweitstimmen, postal votes allocated by Wahlschein holders",
        SOURCES["party"],
        pct,
        figs / "map_linke",
    )
    choropleth(
        res,
        bezirke,
        "afd",
        RAMPS["afd"],
        "AfD",
        "Share of valid Zweitstimmen, postal votes allocated by Wahlschein holders",
        SOURCES["party"],
        pct,
        figs / "map_afd",
    )
    bivariate(res, bezirke, figs / "map_bivariate")

    for f in sorted(figs.glob("map_*")):
        print(f"map   {f.relative_to(ROOT)} {f.stat().st_size / 1e6:.1f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
