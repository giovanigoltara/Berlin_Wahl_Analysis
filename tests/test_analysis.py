"""Unit tests for the statistics in src/analysis.py, on inputs with known answers."""

import numpy as np
import pandas as pd
import pytest
from scipy import stats

from analysis import correlate, holm


def test_holm_matches_hand_computation():
    # Sorted: 0.005 x 4 = 0.02, 0.01 x 3 = 0.03, 0.03 x 2 = 0.06, 0.04 x 1 = 0.04,
    # then a running maximum, so the last becomes 0.06.
    p = pd.Series([0.01, 0.04, 0.03, 0.005], index=["a", "b", "c", "d"])
    expected = pd.Series([0.03, 0.06, 0.06, 0.02], index=["a", "b", "c", "d"])
    pd.testing.assert_series_equal(holm(p), expected)


def test_holm_caps_at_one_and_keeps_order():
    p = pd.Series([0.6, 0.5, 0.9])
    adj = holm(p)
    assert (adj <= 1).all()
    assert (adj >= p).all()


def test_raw_correlation_matches_scipy_spearman():
    rng = np.random.default_rng(1)
    x = pd.Series(rng.normal(size=200))
    y = pd.Series(0.5 * x + rng.normal(size=200))
    res = correlate(x, y)
    ref = stats.spearmanr(x, y)
    assert res["rho"] == pytest.approx(ref.statistic, abs=1e-12)
    assert res["p"] == pytest.approx(ref.pvalue, rel=1e-9)
    assert res["n"] == 200


def test_partial_correlation_matches_textbook_formula():
    # Partial correlation of ranks: (r_xy - r_xz r_yz) / sqrt((1 - r_xz^2)(1 - r_yz^2)).
    rng = np.random.default_rng(2)
    z = rng.normal(size=300)
    x = pd.Series(z + rng.normal(size=300))
    y = pd.Series(z + 0.3 * x + rng.normal(size=300))
    z = pd.Series(z)
    r = pd.concat([x, y, z], axis=1).rank().corr().to_numpy()
    rxy, rxz, ryz = r[0, 1], r[0, 2], r[1, 2]
    expected = (rxy - rxz * ryz) / np.sqrt((1 - rxz**2) * (1 - ryz**2))
    assert correlate(x, y, z)["rho"] == pytest.approx(expected, abs=1e-12)


def test_partial_correlation_removes_a_shared_driver():
    # x and y depend only on z: strongly correlated raw, unrelated once z is controlled.
    rng = np.random.default_rng(3)
    z = pd.Series(rng.normal(size=2000))
    x = z + pd.Series(rng.normal(scale=0.5, size=2000))
    y = z + pd.Series(rng.normal(scale=0.5, size=2000))
    assert correlate(x, y)["rho"] > 0.7
    assert abs(correlate(x, y, z)["rho"]) < 0.06


def test_missing_values_are_dropped_pairwise():
    x = pd.Series([1.0, 2.0, 3.0, 4.0, np.nan, 6.0])
    y = pd.Series([2.0, 1.0, 4.0, 3.0, 5.0, np.nan])
    assert correlate(x, y)["n"] == 4


def test_confidence_interval_contains_rho():
    rng = np.random.default_rng(4)
    x = pd.Series(rng.normal(size=100))
    y = pd.Series(x + rng.normal(size=100))
    res = correlate(x, y)
    assert -1 < res["ci_low"] < res["rho"] < res["ci_high"] < 1
