"""Unit tests for the helpers that pass parameters to SQL and download sources."""

import pytest
import requests

import download
from run_sql import flatten


def test_flatten_passes_scalars_lists_and_mapping_values():
    settings = {
        "alpha": 0.05,
        "years": [2023, 2024],
        "parties": {"linke": "P04", "cdu": "P01"},
        "contrast": {"left": ["P04", "P03"], "right": ["P01", "P05"]},
        "amenities": {"schools": {"amenity": ["school"]}},
    }
    out = dict(flatten(settings))
    assert out["alpha"] == 0.05
    assert out["years"] == [2023, 2024]
    assert out["parties"] == ["linke", "cdu"]
    assert out["parties_linke"] == "P04"
    assert out["contrast_left"] == ["P04", "P03"]
    # Nested mappings pass their keys only.
    assert out["amenities"] == ["schools"]
    assert "amenities_schools" not in out


class FakeResponse:
    def __init__(self, status: int, body: bytes = b"data"):
        self.status_code, self.body = status, body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def raise_for_status(self):
        if self.status_code >= 400:
            raise requests.HTTPError(response=self)

    def iter_content(self, size):
        yield self.body


@pytest.fixture
def no_sleep(monkeypatch):
    waits = []
    monkeypatch.setattr(download.time, "sleep", waits.append)
    return waits


def test_fetch_retries_connection_errors_then_succeeds(tmp_path, monkeypatch, no_sleep):
    outcomes = [requests.ConnectionError("reset"), FakeResponse(503), FakeResponse(200, b"ok")]

    def fake_get(*args, **kwargs):
        result = outcomes.pop(0)
        if isinstance(result, Exception):
            raise result
        return result

    monkeypatch.setattr(download.requests, "get", fake_get)
    dest = tmp_path / "file.csv"
    download.fetch("https://example.org/file.csv", dest)
    assert dest.read_bytes() == b"ok"
    assert no_sleep == [2, 4]  # exponential backoff
    assert not dest.with_suffix(".csv.part").exists()


def test_fetch_fails_at_once_on_client_errors(tmp_path, monkeypatch, no_sleep):
    monkeypatch.setattr(download.requests, "get", lambda *a, **k: FakeResponse(404))
    with pytest.raises(requests.HTTPError):
        download.fetch("https://example.org/missing.csv", tmp_path / "missing.csv")
    assert no_sleep == []


def test_fetch_gives_up_after_the_last_retry(tmp_path, monkeypatch, no_sleep):
    def always_reset(*args, **kwargs):
        raise requests.ConnectionError("reset")

    monkeypatch.setattr(download.requests, "get", always_reset)
    with pytest.raises(requests.ConnectionError):
        download.fetch("https://example.org/file.csv", tmp_path / "file.csv")
    assert no_sleep == [2, 4, 8, 16]
