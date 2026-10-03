# Project brief: "Heat, green and the vote" (Berlin 2026)

## 1. Why this project exists

I am Giovani Bonadiman Goltara, an architect and urban researcher. This repository is a public portfolio project supporting my application (deadline 19 October 2026) to a geospatial data position in the ERC project CAMPS at UPC Barcelona. The reviewers will score demonstrated experience in:

- PostgreSQL/PostGIS and spatial SQL
- Raster processing and remote sensing (Google Earth Engine)
- Python for reproducible spatial workflows
- Integration and validation of heterogeneous sources (institutional data, OpenStreetMap, satellite data)
- Git/GitHub and workflow documentation
- FAIR data principles, metadata and provenance
- Cartography and figures for publication
- Relating spatial analysis to social and political processes

Every design decision should make one of these skills visible and verifiable to a technical reviewer reading the repo. Clarity and reproducibility matter more than sophistication. Time budget is about 40 hours over two weeks, so prefer simple, correct and well documented over ambitious and fragile.

## 2. Research question

How do surface temperature, vegetation and access to everyday services vary across Berlin's electoral districts, and how do these urban conditions align with party-list (Zweitstimme) results of the Abgeordnetenhaus election of 20 September 2026?

This is an ecological, descriptive analysis at district level. It must never imply individual-level conclusions (no "people in hot areas vote X"). State this limitation in the README.

## 3. Data sources

Inspect every source before writing code that depends on it. Do NOT assume column names, keys, CRS or encodings. Print schemas, sample rows and row counts, and report them before building on them.

### Institutional (Berlin)

- Election results 2026: https://www.wahlen-berlin.de/wahlen/BE2026/Afspraes/AGH/downloads.html
- Electoral district geometries 2026: https://daten.berlin.de/datensaetze/geometrien-der-wahlbezirke-fur-die-wahl-zum-20-abgeordnetenhaus-von-berlin-und-bvv-2026
- Population density 2025 (Umweltatlas, WFS): https://daten.berlin.de/datensaetze/einwohnerdichte-2025-umweltatlas-wfs-b2654f6b

Expected (to be verified): results are reported separately for polling-station districts (Urnenwahlbezirke, key likely BEZ + UWB) and postal districts (Briefwahlbezirke, key likely BEZ + BWB), and one postal district covers several station districts.

### OpenStreetMap

- Berlin extract from Geofabrik (PBF), or osmnx for the street network. Amenities: schools, kindergartens, doctors/clinics/pharmacies, supermarkets, public transport stops, parks and playgrounds. Record the extract date.

### Satellite (Google Earth Engine, Python API)

- Landsat 8 and 9 Collection 2 Level 2 (`LANDSAT/LC08/C02/T1_L2`, `LANDSAT/LC09/C02/T1_L2`), band `ST_B10` for land surface temperature. Apply the official scale factor and offset, convert Kelvin to Celsius, mask clouds with `QA_PIXEL`.
- Sentinel-2 Surface Reflectance Harmonized (`COPERNICUS/S2_SR_HARMONIZED`) for NDVI, cloud-masked with Cloud Score+ (`GOOGLE/CLOUD_SCORE_PLUS/V1/S2_HARMONIZED`).
- Period: summer months (June to August) of 2023 to 2025, median composites. Parameters (dates, thresholds) live in a config file, not hardcoded.

### Prior work to credit in the README

Danila Morkovkin's dot-density map of the 2026 Berlin election (https://danilamorkovkin.blog/berlin-election-2026/). This project does not replicate it; it adds explanatory urban indicators and reconciles postal and station votes.

## 4. Technical stack

- PostGIS via Docker (`postgis/postgis` image) defined in `docker-compose.yml`
- Python 3.11+, environment managed with uv (`pyproject.toml` with pinned versions)
- geopandas, shapely, pandas, sqlalchemy, psycopg, earthengine-api, osmnx (or pyrosm), libpysal + esda, matplotlib, mapclassify
- GDAL/ogr2ogr for loading vector data into PostGIS where it is simpler than Python
- Working CRS: EPSG:25833 (ETRS89 / UTM 33N) for all metric operations. Store original CRS in metadata.
- A Makefile so the whole pipeline runs with `make all` after setup

## 5. Repository structure

The GitHub repository is `giovanigoltara/berlin_wahl_analysis`; its root corresponds to `heat-green-vote-berlin/` below.

```
heat-green-vote-berlin/
  README.md
  CLAUDE.md                 (this file)
  LICENSE                   (MIT for code)
  CITATION.cff
  datapackage.json          (Frictionless Data descriptor for outputs)
  docker-compose.yml
  pyproject.toml
  Makefile
  config/
    params.yaml             (dates, thresholds, buffer distances, CRS)
  data/
    raw/                    (gitignored, populated by scripts)
    interim/                (gitignored)
    processed/              (small final tables committed if under ~10 MB)
  sql/
    00_schema.sql
    10_load_checks.sql
    20_postal_allocation.sql
    30_dasymetric.sql
    40_accessibility.sql
    50_indicators.sql
  src/
    download.py
    load_postgis.py
    gee_extract.py
    osm_extract.py
    analysis.py
    maps.py
  docs/
    data_dictionary.md
    provenance.md
    methods.md
    validation_report.md
  figures/
  notebooks/                (optional, exploration only, not part of the pipeline)
```

## 6. Work plan with checkpoints

Work in phases. At the end of each phase: commit with a clear message, summarise what was done, list open questions, and STOP for review before continuing.

### Phase 0: Setup (target 2 h)

- Initialise the repo structure, `pyproject.toml`, `docker-compose.yml`, `Makefile`, `.gitignore`, `config/params.yaml`.
- Verify PostGIS runs and the extension is enabled.
- Document manual steps: Earth Engine authentication and Google Cloud project registration, GitHub remote creation.

### Phase 1: Acquire and inspect (target 4 h)

- `download.py` fetches all institutional sources into `data/raw/` with a manifest (URL, download timestamp, file hash, licence as stated by the source).
- Inspect and report: schemas, keys, row counts, CRS, encoding, totals of valid votes per party.
- Validation: station + postal valid votes should sum to the official Berlin-wide totals. Report any discrepancy.

### Phase 2: PostGIS core (target 10 h)

- `00_schema.sql`: schemas `raw`, `clean`, `analysis`. Primary keys, spatial indexes (GIST), constraints.
- Load geometries and results; geometry validity checks (`ST_IsValid`, `ST_MakeValid` if needed), report fixes.
- `20_postal_allocation.sql`: allocate each Briefwahlbezirk's party votes to its constituent Urnenwahlbezirke. Two methods:
  - A: proportional to station-district valid votes
  - B: proportional to eligible voters (or residential population if eligible voters are not available)
  Produce combined per-district results for both, plus a station-only version.
- `30_dasymetric.sql`: intersect electoral districts with Umweltatlas population blocks, compute residential population and residential area per district, so indicators can be computed over inhabited land rather than lakes, forests and industrial land.
- `40_accessibility.sql`: per district, population-weighted share of residents within walking distance (start with 500 m Euclidean buffers; network distance via pgRouting or osmnx only if time allows) of each amenity type.
- Write validation results to `docs/validation_report.md`.

### Phase 3: Earth Engine (target 12 h)

- `gee_extract.py`: build LST and NDVI summer composites, document scene counts and cloud filtering, reduce to mean and median per electoral district (ideally over residential area only, using the dasymetric mask), export tables, load into PostGIS.
- Save a low-resolution preview PNG of each composite for the README.
- Record all asset IDs, date ranges and parameters in `docs/provenance.md`.

### Phase 4: Indicators and analysis (target 6 h)

- `50_indicators.sql`: one analysis table, one row per electoral district, with: party shares (allocation A, B, station-only), turnout, LST, NDVI, accessibility indicators, residential density.
- `analysis.py`: Spearman correlations between urban indicators and party shares; global Moran's I for key variables; sensitivity check showing how results change across allocation A, B and station-only. Keep statistics simple and honest; no causal language.

### Phase 5: Maps, documentation, release (target 6 h)

- `maps.py`: 4 to 6 publication-quality static maps (consistent style, scale bar, north arrow where useful, source line on each map): LST, NDVI, accessibility, two party shares, one bivariate map (e.g. LST x party share). Export PNG (300 dpi) and SVG.
- README: question, data, method diagram (Mermaid), key figures, findings in a few sentences, limitations (ecological fallacy, postal allocation assumptions, temporal mismatch between imagery and election date, MAUP), how to reproduce, credits.
- `docs/data_dictionary.md` for every output column (name, type, unit, definition, source).
- `datapackage.json` and `CITATION.cff` completed.
- Final check: clone into a fresh folder and run the pipeline from scratch following only the README.

## 7. Rules for working on this repo

- Never invent column names, keys, dataset IDs or licences. If unsure, inspect or ask.
- Prefer SQL in `sql/` files for spatial operations, so PostGIS skills are visible. Python orchestrates, loads, calls GEE and plots.
- Every script is idempotent and runnable from the Makefile.
- Small, descriptive commits (e.g. "Add postal vote allocation, method A and B"), one logical change per commit.
- Commit author is always `giovanigoltara <giovani.goltara@gmail.com>`. No co-author trailers.
- Comments and docs in English, concise. Do not use em dashes in any prose or documentation.
- Licences: record each source's licence exactly as stated by the provider in `docs/provenance.md`; do not guess.
- Treat this as research data: provenance for every derived number must be traceable from README to script to raw source.
- If a phase is going to exceed its time budget, stop and propose a simplification rather than pushing on.

## 8. Definition of done

- `make all` reproduces every table and figure from raw downloads (except GEE auth, documented).
- README lets a reviewer understand the project in two minutes and reproduce it in under an hour.
- `docs/validation_report.md` shows that vote totals reconcile and geometries are valid.
- The repo demonstrates, in visible files, each skill listed in section 1.
