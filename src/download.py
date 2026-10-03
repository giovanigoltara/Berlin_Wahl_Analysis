"""Fetch institutional sources into data/raw and record them in a manifest.

Every file listed under `sources` in config/params.yaml is downloaded once. A file that already
exists is kept and only re-hashed, so the script is idempotent; pass --force to re-download.
A file placed by hand (for hosts unreachable from the run environment) is accepted and recorded
with method "manual". The manifest stores URL, timestamp, SHA-256, size and the licence as stated.

Every file is checked before it is accepted: its leading bytes must match the expected format, so
an HTML page served with status 200 in place of a file is rejected. Files with a `sha256` in
params.yaml must also match that hash.

Usage: uv run python src/download.py [--force]
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import sys
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import urlparse

import requests
import yaml

ROOT = Path(__file__).resolve().parents[1]
TIMEOUT_S = 300
USER_AGENT = (
    "heat-green-vote-berlin/0.1 (research; +https://github.com/giovanigoltara/berlin_wahl_analysis)"
)
MANIFEST_FIELDS = [
    "source",
    "file_id",
    "url",
    "path",
    "method",
    "retrieved_utc",
    "sha256",
    "bytes",
    "licence_as_stated",
    "licence_where",
]

# WFS responses have no filename in the URL; give them stable names here.
FILENAMES = {
    "population_blocks": "ua_einwohnerdichte_2025.gml",
    "population_capabilities": "ua_einwohnerdichte_2025_capabilities.xml",
}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# Leading bytes expected per file extension. Anything starting like HTML is always rejected.
MAGIC = {".zip": b"PK\x03\x04", ".pdf": b"%PDF", ".gml": b"<?xml", ".xml": b"<?xml"}


def check_content(path: Path, expected_sha256: str | None) -> str | None:
    """Return a reason the file is not acceptable, or None if it is."""
    head = path.open("rb").read(512).lstrip(b"\xef\xbb\xbf").lstrip()
    if head[:15].lower().startswith((b"<!doctype html", b"<html")):
        return "received an HTML page instead of the file"
    magic = MAGIC.get(path.suffix.lower())
    if magic and not head.startswith(magic):
        return f"content does not start with {magic!r} as expected for {path.suffix}"
    if b"ExceptionReport" in head:
        return "server returned an OGC exception report"
    if expected_sha256 and sha256(path) != expected_sha256:
        return f"SHA-256 differs from the pinned value {expected_sha256[:12]}..."
    return None


def target_path(raw_dir: Path, source: str, file_id: str, url: str) -> Path:
    name = FILENAMES.get(file_id) or Path(urlparse(url).path).name
    return raw_dir / source / name


def fetch(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    with requests.get(url, stream=True, timeout=TIMEOUT_S, headers={"User-Agent": USER_AGENT}) as r:
        r.raise_for_status()
        with tmp.open("wb") as f:
            for chunk in r.iter_content(1 << 20):
                f.write(chunk)
    tmp.replace(dest)


def read_manifest(path: Path) -> dict[str, dict]:
    if not path.exists():
        return {}
    with path.open(newline="", encoding="utf-8") as f:
        return {row["file_id"]: row for row in csv.DictReader(f)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--force", action="store_true", help="re-download existing files")
    args = parser.parse_args()

    params = yaml.safe_load((ROOT / "config/params.yaml").read_text(encoding="utf-8"))
    raw_dir = ROOT / params["paths"]["raw"]
    manifest_path = ROOT / params["paths"]["manifest"]
    previous = read_manifest(manifest_path)

    rows, failures = [], []
    for source, spec in params["sources"].items():
        for file_id, entry in spec["files"].items():
            # An entry is a URL, or a mapping with `url` and a pinned `sha256`.
            url = entry["url"] if isinstance(entry, dict) else entry
            pinned = entry.get("sha256") if isinstance(entry, dict) else None
            dest = target_path(raw_dir, source, file_id, url)
            prev = previous.get(file_id, {})
            if dest.exists() and not args.force:
                digest = sha256(dest)
                unchanged = prev.get("sha256") == digest
                method = prev.get("method", "manual") if unchanged else "manual"
                retrieved = (
                    prev.get("retrieved_utc")
                    if unchanged
                    else datetime.fromtimestamp(dest.stat().st_mtime, UTC).isoformat(
                        timespec="seconds"
                    )
                )
                if problem := check_content(dest, pinned):
                    print(
                        f"FAIL  {file_id:<24} {dest.relative_to(ROOT)}: {problem}", file=sys.stderr
                    )
                    failures.append(file_id)
                    continue
                print(f"keep  {file_id:<24} {dest.relative_to(ROOT)} ({method})")
            else:
                try:
                    fetch(url, dest)
                except requests.RequestException as e:
                    print(f"FAIL  {file_id:<24} {url}\n      {e}", file=sys.stderr)
                    print(
                        f"      Place the file by hand at {dest.relative_to(ROOT)} and rerun.",
                        file=sys.stderr,
                    )
                    failures.append(file_id)
                    continue
                if problem := check_content(dest, pinned):
                    dest.unlink()
                    print(f"FAIL  {file_id:<24} {url}\n      {problem}", file=sys.stderr)
                    print(
                        f"      Place the file by hand at {dest.relative_to(ROOT)} and rerun.",
                        file=sys.stderr,
                    )
                    failures.append(file_id)
                    continue
                digest, method = sha256(dest), "download"
                retrieved = datetime.now(UTC).isoformat(timespec="seconds")
                print(f"get   {file_id:<24} {dest.relative_to(ROOT)}")
            rows.append(
                {
                    "source": source,
                    "file_id": file_id,
                    "url": url,
                    "path": dest.relative_to(ROOT).as_posix(),
                    "method": method,
                    "retrieved_utc": retrieved,
                    "sha256": digest,
                    "bytes": dest.stat().st_size,
                    "licence_as_stated": spec["licence_as_stated"],
                    "licence_where": spec["licence_where"],
                }
            )

    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    with manifest_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=MANIFEST_FIELDS)
        writer.writeheader()
        writer.writerows(rows)
    print(f"Manifest: {manifest_path.relative_to(ROOT)} ({len(rows)} files)")

    if failures:
        print(f"{len(failures)} file(s) missing: {', '.join(failures)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
