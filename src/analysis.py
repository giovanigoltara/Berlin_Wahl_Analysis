"""Correlations between urban indicators and vote outcomes, following the pre-registered plan.

Reads analysis.indicators and analysis.outcome (sql/50_indicators.sql) and the `analysis` section
of config/params.yaml (fixed 2026-10-05, before any satellite value existed; docs/methods.md,
"Analysis plan"):

  Tier 1  confirmatory: partial Spearman correlation controlling for log residential density,
          primary allocation method, Holm correction over the Tier 1 pairs.
  Tier 2  robustness of each Tier 1 pair: other allocation methods, without population_mismatch
          districts, raw (uncontrolled) correlation, and the contrast with the SPD on the left.
          Robust = same sign in every variant and rho changing by less than robust_max_rho_change.
  Tier 3  exploratory grid of raw Spearman correlations, no p-values.
  Moran   global Moran's I (queen contiguity, permutation inference) for every variable.

Partial Spearman: Pearson correlation of the residuals of the ranks of x and y after linear
regression on the ranks of the control. Confidence intervals use the Fisher transform with the
Bonett-Wright standard error sqrt((1 + rho^2 / 2) / (n - 3 - k)), k controls. p-values assume
independent districts, which spatial autocorrelation violates; they rank evidence within Tier 1.

Outputs: data/processed/tier1.csv, tier2.csv, tier3.csv, moran.csv; figures/tier3_correlations.png;
docs/results.md.

Usage: uv run python src/analysis.py
"""

from __future__ import annotations

import sys
from datetime import UTC, datetime
from pathlib import Path

import esda
import geopandas as gpd
import matplotlib
import numpy as np
import pandas as pd
import yaml
from libpysal.weights import Queen, w_subset
from scipy import stats
from sqlalchemy import create_engine, text

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.colors import LinearSegmentedColormap  # noqa: E402

from run_sql import dsn  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "docs/results.md"
RAW = "raw (no density control)"
# Names in params.yaml that differ from the indicator table's column names.
ALIASES = {
    "residential_density": "density_residential",
    "log_residential_density": "log_density_residential",
}
# Diverging blue (negative) to red (positive) through a neutral grey midpoint.
DIVERGING = LinearSegmentedColormap.from_list(
    "blue_grey_red", ["#1c4f8f", "#2a78d6", "#f0efec", "#d6452a", "#8f2a1c"]
)


# Statistics -------------------------------------------------------------------------------


def correlate(x: pd.Series, y: pd.Series, z: pd.Series | None = None) -> dict:
    """Spearman rho (partial on z if given), n, two-sided p and 95 % confidence interval."""
    cols = [x.rename("x"), y.rename("y")] + ([z.rename("z")] if z is not None else [])
    d = pd.concat(cols, axis=1).dropna()
    n, k = len(d), int(z is not None)
    r = d.rank()
    if k:
        design = np.column_stack([np.ones(n), r["z"]])

        def resid(v: pd.Series) -> np.ndarray:
            coef, *_ = np.linalg.lstsq(design, v.to_numpy(), rcond=None)
            return v.to_numpy() - design @ coef

        rho = float(np.corrcoef(resid(r["x"]), resid(r["y"]))[0, 1])
    else:
        rho = float(np.corrcoef(r["x"], r["y"])[0, 1])
    df = n - 2 - k
    t = rho * np.sqrt(df / max(1 - rho**2, 1e-15))
    p = float(2 * stats.t.sf(abs(t), df))
    se = np.sqrt((1 + rho**2 / 2) / (n - 3 - k))
    lo, hi = np.tanh(np.arctanh(rho) + np.array([-1, 1]) * 1.959964 * se)
    return {"n": n, "rho": rho, "ci_low": float(lo), "ci_high": float(hi), "p": p}


def holm(p: pd.Series) -> pd.Series:
    """Holm step-down adjusted p-values."""
    order = p.sort_values().index
    m = len(p)
    adj = (p[order] * (m - np.arange(m))).cummax().clip(upper=1)
    return adj.reindex(p.index)


# Data -------------------------------------------------------------------------------------


def load(engine) -> tuple[gpd.GeoDataFrame, pd.DataFrame]:
    with engine.connect() as conn:
        ind = gpd.read_postgis(
            text("SELECT * FROM analysis.indicators ORDER BY uwb"), conn, geom_col="geom"
        )
        out = pd.read_sql(text("SELECT uwb, method, outcome, value FROM analysis.outcome"), conn)
    wide = out.pivot_table(index="uwb", columns=["method", "outcome"], values="value")
    return ind.set_index("uwb", drop=False), wide


def col(name: str) -> str:
    return ALIASES.get(name, name)


# Tiers ------------------------------------------------------------------------------------


def tier1(ind: pd.DataFrame, a: dict) -> pd.DataFrame:
    t = a["tier1"]
    pairs = [(i, o) for i in t["indicators"] for o in t["outcomes"]] + [
        tuple(p) for p in t["extra_pairs"]
    ]
    z = ind[col(a["partial_control"])]
    rows = [{"indicator": i, "outcome": o, **correlate(ind[col(i)], ind[o], z)} for i, o in pairs]
    res = pd.DataFrame(rows)
    res["p_holm"] = holm(res["p"])
    res["significant"] = res["p_holm"] < a["alpha"]
    return res


def tier2(ind: pd.DataFrame, wide: pd.DataFrame, t1: pd.DataFrame, a: dict) -> pd.DataFrame:
    z = ind[col(a["partial_control"])]
    keep = ~ind["population_mismatch"]
    rows = []
    for r in t1.itertuples():
        x = ind[col(r.indicator)]
        variants = {}
        for m in a["robustness_methods"]:
            if (m, r.outcome) in wide.columns:  # turnout is not defined for method S
                variants[f"method {m}"] = correlate(x, wide[(m, r.outcome)], z)
        variants["without mismatch districts"] = correlate(x[keep], ind[r.outcome][keep], z[keep])
        variants[RAW] = correlate(x, ind[r.outcome])
        if r.outcome == "contrast":
            variants["contrast with SPD"] = correlate(x, ind["contrast_with_spd"], z)
        for name, v in variants.items():
            rows.append(
                {
                    "indicator": r.indicator,
                    "outcome": r.outcome,
                    "variant": name,
                    "tier1_rho": r.rho,
                    **v,
                }
            )
    res = pd.DataFrame(rows)
    res["same_sign"] = np.sign(res["rho"]) == np.sign(res["tier1_rho"])
    res["rho_change"] = (res["rho"] - res["tier1_rho"]).abs()
    return res


def robustness(t2: pd.DataFrame, a: dict) -> pd.DataFrame:
    g = t2.groupby(["indicator", "outcome"], sort=False)
    out = g.agg(
        variants=("variant", "size"),
        all_same_sign=("same_sign", "all"),
        max_rho_change=("rho_change", "max"),
    ).reset_index()
    out["robust"] = out["all_same_sign"] & (out["max_rho_change"] < a["robust_max_rho_change"])
    worst = t2.loc[g["rho_change"].idxmax(), ["indicator", "outcome", "variant"]]
    out = out.merge(
        worst.rename(columns={"variant": "largest_change_in"}), on=["indicator", "outcome"]
    )
    # Post-hoc correction (2026-10-07, docs/methods.md): the raw variant removes the density
    # control, which is the change the control exists to make, so it measures the control's
    # effect, not robustness. It is reported as its own column instead.
    s = t2[t2["variant"] != RAW].groupby(["indicator", "outcome"], sort=False)
    post = s.agg(
        same_sign_excl_raw=("same_sign", "all"), max_rho_change_excl_raw=("rho_change", "max")
    ).reset_index()
    post["robust_excl_raw"] = post["same_sign_excl_raw"] & (
        post["max_rho_change_excl_raw"] < a["robust_max_rho_change"]
    )
    raw = t2[t2["variant"] == RAW][["indicator", "outcome", "rho"]].rename(
        columns={"rho": "raw_rho"}
    )
    return out.merge(post, on=["indicator", "outcome"]).merge(raw, on=["indicator", "outcome"])


def tier3(ind: pd.DataFrame, a: dict) -> pd.DataFrame:
    t = a["tier3"]
    return pd.DataFrame(
        [[correlate(ind[col(i)], ind[o])["rho"] for o in t["outcomes"]] for i in t["indicators"]],
        index=t["indicators"],
        columns=t["outcomes"],
    )


def moran(ind: gpd.GeoDataFrame, variables: list[str], a: dict) -> pd.DataFrame:
    w_all = Queen.from_dataframe(ind, use_index=True, silence_warnings=True)
    rows = []
    for v in variables:
        y = ind[col(v)].dropna()
        w = w_subset(w_all, list(y.index), silence_warnings=True) if len(y) < len(ind) else w_all
        w.transform = "r"
        np.random.seed(a["random_seed"])
        mi = esda.Moran(y.to_numpy(), w, permutations=a["moran_permutations"])
        rows.append(
            {
                "variable": v,
                "n": len(y),
                "moran_i": mi.I,
                "expected_i": mi.EI,
                "p_sim": mi.p_sim,
                "islands": len(w.islands),
            }
        )
    return pd.DataFrame(rows)


# Outputs ----------------------------------------------------------------------------------


def heatmap(t3: pd.DataFrame, out: Path) -> None:
    fig, ax = plt.subplots(figsize=(8, 6.4), dpi=150)
    im = ax.imshow(t3.to_numpy(), cmap=DIVERGING, vmin=-0.8, vmax=0.8)
    ax.set_xticks(range(t3.shape[1]), t3.columns, rotation=30, ha="right")
    ax.set_yticks(range(t3.shape[0]), [s.replace("_", " ") for s in t3.index])
    for (i, j), v in np.ndenumerate(t3.to_numpy()):
        ax.text(
            j,
            i,
            f"{v:.2f}",
            ha="center",
            va="center",
            fontsize=7,
            color="white" if abs(v) > 0.35 else "#1a1a19",
        )
    ax.tick_params(length=0)
    for s in ax.spines.values():
        s.set_visible(False)
    fig.colorbar(im, ax=ax, shrink=0.8, label="Spearman rho (raw, method C)")
    ax.set_title(
        "Exploratory: urban indicators and vote outcomes by station district\n"
        "(2,542 districts; descriptive, no p-values)",
        fontsize=10,
    )
    fig.text(
        0.01,
        0.01,
        "Sources: Landeswahlleiter Berlin 2026, Amt für Statistik "
        "Berlin-Brandenburg, OpenStreetMap contributors, USGS Landsat, Copernicus Sentinel-2",
        fontsize=6,
        color="#5c5c58",
    )
    fig.savefig(out, bbox_inches="tight")
    plt.close(fig)


def fmt(v: float, d: int = 3) -> str:
    return f"{v:.{d}f}"


def write_results(t1, rob, t3, mor, a, n_districts) -> None:
    lines = [
        "# Results",
        "",
        f"Generated by `src/analysis.py` on {datetime.now(UTC):%Y-%m-%d %H:%M UTC} from "
        "`analysis.indicators`, following the analysis plan in `docs/methods.md` (fixed "
        "2026-10-05, before any satellite value existed). Parameters: `config/params.yaml`, "
        "section `analysis`.",
        "",
        f"All statements describe {n_districts:,} station districts, not voters. Correlation "
        "is not causation, and neighbouring districts are similar (Moran's I below), so "
        "p-values assume an independence the data does not have: they rank evidence within "
        "Tier 1 and should not be read as exact error rates.",
        "",
        "## Tier 1: confirmatory",
        "",
        f"Partial Spearman rho controlling for log residential density, allocation method "
        f"{a['primary_method']}, 95 % confidence interval, Holm-adjusted p over "
        f"{len(t1)} tests, alpha {a['alpha']}.",
        "",
        "| Indicator | Outcome | n | rho | 95 % CI | p (Holm) | Holm < alpha | Raw rho "
        "| Robust, pre-registered | Robust, post-hoc |",
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    t = t1.merge(rob, on=["indicator", "outcome"])
    yn = {True: "yes", False: "no"}
    for r in t.itertuples():
        lines.append(
            f"| {r.indicator} | {r.outcome} | {r.n} | {fmt(r.rho)} | "
            f"[{fmt(r.ci_low)}, {fmt(r.ci_high)}] | {r.p_holm:.1e} | {yn[r.significant]} | "
            f"{fmt(r.raw_rho)} | {yn[r.robust]} | {yn[r.robust_excl_raw]} |"
        )
    lines += [
        "",
        "**Robust, pre-registered** applies the rule fixed on 2026-10-05: same sign and rho "
        f"changing by less than {a['robust_max_rho_change']} in every Tier 2 variant, including "
        "the raw correlation. **Robust, post-hoc** applies the same rule without the raw "
        "variant. This is a correction made on 2026-10-07, after seeing the results: removing "
        "the density control is the change the control exists to make, so the raw variant "
        "measures the control's effect, not robustness. The raw rho is shown in its own column; "
        "the gap between raw and partial rho shows how much of each association is shared with "
        'density. See `docs/methods.md`, "Deviations from the analysis plan".',
        "",
        "## Tier 2: robustness",
        "",
        f"Each Tier 1 pair recomputed under other allocation methods "
        f"({', '.join(a['robustness_methods'])}; turnout is not defined for S), without the "
        "`population_mismatch` districts, without the density control, and for the contrast "
        "with the SPD on the left.",
        "",
        "| Indicator | Outcome | Variants | Max rho change (all) | Largest change in "
        "| Robust, pre-registered | Max rho change (excl. raw) | Robust, post-hoc |",
        "| --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for r in rob.itertuples():
        lines.append(
            f"| {r.indicator} | {r.outcome} | {r.variants} | {fmt(r.max_rho_change)} | "
            f"{r.largest_change_in} | {yn[r.robust]} | {fmt(r.max_rho_change_excl_raw)} | "
            f"{yn[r.robust_excl_raw]} |"
        )
    lines += [
        "",
        "Every variant's rho is in `data/processed/tier2.csv`.",
        "",
        "## Tier 3: exploratory",
        "",
        "Raw Spearman rho, method C, no density control, no p-values.",
        "",
        "![Tier 3 correlations](../figures/tier3_correlations.png)",
        "",
        "| Indicator | " + " | ".join(t3.columns) + " |",
        "| --- |" + " --- |" * len(t3.columns),
    ]
    for name, row in t3.iterrows():
        lines.append(f"| {name} | " + " | ".join(fmt(v, 2) for v in row) + " |")
    lines += [
        "",
        "## Spatial autocorrelation",
        "",
        f"Global Moran's I, queen contiguity, row-standardised, {a['moran_permutations']} "
        f"permutations (seed {a['random_seed']}). The expected value without clustering is "
        "about 0.",
        "",
        "| Variable | n | Moran's I | pseudo p | Islands |",
        "| --- | --- | --- | --- | --- |",
    ]
    for r in mor.itertuples():
        lines.append(f"| {r.variable} | {r.n} | {fmt(r.moran_i)} | {r.p_sim:.3f} | {r.islands} |")
    RESULTS.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    params = yaml.safe_load((ROOT / "config/params.yaml").read_text(encoding="utf-8"))
    a = params["analysis"]
    engine = create_engine(dsn().replace("postgresql://", "postgresql+psycopg://"))
    ind, wide = load(engine)
    print(f"data  {len(ind)} districts, {wide.shape[1]} method x outcome columns")

    t1 = tier1(ind, a)
    t2 = tier2(ind, wide, t1, a)
    rob = robustness(t2, a)
    t3 = tier3(ind, a)
    variables = list(
        dict.fromkeys(
            a["tier3"]["indicators"] + ["access_index"] + a["tier3"]["outcomes"] + ["contrast"]
        )
    )
    mor = moran(ind, variables, a)

    processed = ROOT / params["paths"]["processed"]
    t1.to_csv(processed / "tier1.csv", index=False, float_format="%.6g")
    t2.to_csv(processed / "tier2.csv", index=False, float_format="%.6g")
    t3.to_csv(processed / "tier3.csv", float_format="%.6g")
    mor.to_csv(processed / "moran.csv", index=False, float_format="%.6g")
    heatmap(t3, ROOT / params["paths"]["figures"] / "tier3_correlations.png")
    write_results(t1, rob, t3, mor, a, len(ind))

    for r in t1.merge(rob, on=["indicator", "outcome"]).itertuples():
        print(
            f"tier1 {r.indicator:<13} {r.outcome:<9} rho {r.rho:+.3f} "
            f"[{r.ci_low:+.3f}, {r.ci_high:+.3f}] p_holm {r.p_holm:.1e} "
            f"raw {r.raw_rho:+.3f} robust pre-registered {'yes' if r.robust else 'no '} "
            f"post-hoc {'yes' if r.robust_excl_raw else 'no '}"
        )
    print(f"moran {', '.join(f'{r.variable} {r.moran_i:.2f}' for r in mor.itertuples())}")
    print(
        f"wrote {RESULTS.relative_to(ROOT)}, data/processed/tier*.csv, moran.csv, "
        "figures/tier3_correlations.png"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
