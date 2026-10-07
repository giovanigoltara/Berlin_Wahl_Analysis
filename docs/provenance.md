# Provenance

Every raw file is fetched by `src/download.py` from the URLs in `config/params.yaml`. Each run writes `data/raw/manifest.csv` with URL, retrieval time (UTC), method (`download` or `manual`), SHA-256, size and licence. The manifest is the authoritative record for a given run; the hashes below document the Phase 1 snapshot.

Licences are quoted exactly as stated by the provider.

## Institutional sources

### Election results, Abgeordnetenhaus 2026, Zweitstimme

- Provider: Der Landeswahlleiter für Berlin / Amt für Statistik Berlin-Brandenburg
- Landing page: <https://www.wahlen-berlin.de/wahlen/BE2026/Afspraes/AGH/downloads.html>
- Files: `Datenexport_AGH2026_Zweitstimme_W_BE.csv` (by Wahlbezirk), `Datenexport_AGH2026_Zweitstimme_A_BE.csv` (by Wahlkreis, Bezirk and Berlin), and their `DSB_` dataset descriptions
- Status: "Vorläufige Ergebnisse" (preliminary). Berlin row extracted 2026-09-21 03:34:26.
- Licence as stated: "CC BY 3.0 DE" (field `Lizenz` in the `DSB_` files)

### Polling district geometries 2026 (RBS)

- Provider: Amt für Statistik Berlin-Brandenburg, Regionales Bezugssystem
- Catalogue entry: <https://daten.berlin.de/datensaetze/geometrien-der-wahlbezirke-fur-die-wahl-zum-20-abgeordnetenhaus-von-berlin-und-bvv-2026> (published 2026-04-22, updated 2026-05-04)
- Files: `RBS_OD_UWB_AH26.zip` (ESRI Shapefile, EPSG:25833), `RBS_OD_Wahlgebiete_AH2026_Beschreibung.pdf`
- Validity: "Der Datenbestand entspricht dem abgestimmten Sachstand vom März 2026." (PDF)
- Licence as stated: "Der Datenbestand wird unter der Lizenz CC-BY-3.0-Namensnennung veröffentlicht (vgl. https://creativecommons.org/licenses/by/3.0/de/). Als Urheber ist dabei zu nennen: Amt für Statistik Berlin-Brandenburg 2026." (PDF; the catalogue page shows only "Creative Commons Attribution (cc-by)")
- Download: the published `/opendata/...` links are routes of a JavaScript web app; scripts receive an HTML page with status 200. In Phase 1 both files were therefore downloaded in a browser on 2026-10-03 and placed by hand. On 2026-10-07 the app's direct file URLs on `download.statistik-berlin-brandenburg.de` were resolved with a headless browser; they serve byte-identical files (same SHA-256), so `src/download.py` now fetches them directly. Both URLs and the pinned hashes are in `config/params.yaml`, and `src/download.py` rejects any other content, including the HTML page.

### Population density 2025 (Umweltatlas)

- Provider: Amt für Statistik Berlin-Brandenburg, published via the Berlin Geodateninfrastruktur
- Catalogue entry: <https://daten.berlin.de/datensaetze/einwohnerdichte-2025-umweltatlas-wfs-b2654f6b>
- Service: WFS 2.0.0 <https://gdi.berlin.de/services/wfs/ua_einwohnerdichte_2025>, layer `ua_einwohnerdichte_2025:ua_einwohnerdichte_2025`, EPSG:25833, GML 3.2, 26,613 features, fetched in one GetFeature request
- Licence as stated: "Der Datenbestand wird unter der Lizenz CC-BY-3.0-Namensnennung veröffentlicht (vgl. https://creativecommons.org/licenses/by/3.0/de/). Der Quellenvermerk gemäß Abschnitt 3a der Lizenz lautet "Amt für Statistik Berlin-Brandenburg / Einwohnerdichte 2025 (Umweltatlas)"." (WFS GetCapabilities, `ows:AccessConstraints`)

## OpenStreetMap

### Berlin extract (Geofabrik)

- Provider: Geofabrik GmbH, from OpenStreetMap
- Landing page: <https://download.geofabrik.de/europe/germany/berlin.html>
- Origin file: <https://download.geofabrik.de/europe/germany/berlin-261003.osm.pbf> (Geofabrik's dated copy of `berlin-latest.osm.pbf`)
- Extract time: replication timestamp 2026-10-03T20:20:50Z, read from the PBF header by `src/osm_extract.py` (written by osmium/1.16.0, replication base URL `https://download.geofabrik.de/europe/germany/berlin-updates`); the landing page showed the same timestamp
- Licence as stated: "License: ODbL 1.0" (page footer), with the attribution "Data processed by Geofabrik GmbH and created by OpenStreetMap Contributors"
- Mirror: Geofabrik keeps daily dated files only for a few days, and its host was unreachable from the build environment. The unmodified file is therefore mirrored as the asset `berlin-261003.osm.1.pbf` of this repository's release [`osm-berlin-2026-10-03`](https://github.com/giovanigoltara/Berlin_Wahl_Analysis/releases/tag/osm-berlin-2026-10-03), which `config/params.yaml` points to with its SHA-256 pinned. `src/download.py` stores it as `data/raw/osm/berlin-261003.osm.pbf`. Redistribution of the unmodified extract follows ODbL 1.0 with the attribution above.
- Derived data (`analysis.amenity` and the accessibility tables) is a Produced Work from the ODbL database; the tag mapping that selects it is in `config/params.yaml` under `accessibility.amenities`.

## Phase 1 snapshot (2026-10-03)

| File | Method | SHA-256 |
| --- | --- | --- |
| `election_results/Datenexport_AGH2026_Zweitstimme_W_BE.csv` | download | `e7666acb3275cd02e3d169efd7b3aa507aeffc7d9d30e265b42ac57b1e6e2f74` |
| `election_results/DSB_Datenexport_AGH2026_Zweitstimme_W_BE.csv` | download | `2f9b7b6dabbfaa4870fc05dbeddb30d69790b51000df5b02fec7438d20739fbe` |
| `election_results/Datenexport_AGH2026_Zweitstimme_A_BE.csv` | download | `4162984451f8e1c56fd32362336a8efd3ffe4eaad2796fc0b0af07002d33d8dd` |
| `election_results/DSB_Datenexport_AGH2026_Zweitstimme_A_BE.csv` | download | `831b5816b5f035fed805152373b8c324ccffe08159b402d882aaa57dc0bd7836` |
| `district_geometries/RBS_OD_UWB_AH26.zip` | manual | `d807a17fb634f8d382aec5996cade1ae510086814ed329865e6a6901cbd75371` |
| `district_geometries/RBS_OD_Wahlgebiete_AH2026_Beschreibung.pdf` | manual | `9e40a1fa8397d585b8bff2bee4275c969ebdcbef30c815052c750322c9bfad9d` |
| `population_density/ua_einwohnerdichte_2025.gml` | download | `8e49df147f0ebae8ab850e39f5e977ffdeeeccce60f3d8d93e884fb3608e2c54` |
| `population_density/ua_einwohnerdichte_2025_capabilities.xml` | download | `2faee4ab3ed28e274825fcb39fa17b4587c904651ac369f4f6fe0939cb5b958b` |
| `osm/berlin-261003.osm.pbf` (added 2026-10-05) | manual, from the release asset | `732546ad128dea41ebd68c26b9c52c845baa7f2b50cd9816dd193604bb3c20f0` |

The WFS response and its hash can change if the provider updates the service.

## Pending

- Earth Engine assets, date ranges and parameters (Phase 3)

## Earth Engine imagery

Generated by `src/gee_extract.py` on 2026-10-07 11:42 UTC (earthengine-api 1.7.46). Parameters are in `config/params.yaml` under `imagery`.

- Extent: [13.05, 52.31, 13.8, 52.7] (EPSG:4326, west, south, east, north)
- Season: 06-01 to 09-01 (end exclusive) of 2023, 2024, 2025, per-pixel median
- LST: `LANDSAT/LC08/C02/T1_L2`, `LANDSAT/LC09/C02/T1_L2`, band `ST_B10`, K = DN x 0.00341802 + 149.0, minus 273.15; scenes with `CLOUD_COVER` <= 30; `QA_PIXEL` bits [1, 2, 3, 4] masked; 30 m
- NDVI: `COPERNICUS/S2_SR_HARMONIZED`, (`B8` - `B4`) / (`B8` + `B4`); pixels with `cs_cdf` < 0.6 masked using `GOOGLE/CLOUD_SCORE_PLUS/V1/S2_HARMONIZED`; 10 m
- Terms of use, landsat: "Landsat datasets are federally created data and therefore reside in the public domain and may be used, transferred, or reproduced without copyright restriction. Acknowledgement or credit of the USGS as data source should be provided by including a line of text citation such as the example shown below. (Product, Image, Photograph, or Dataset Name) courtesy of the U.S. Geological Survey" (https://developers.google.com/earth-engine/datasets/catalog/LANDSAT_LC09_C02_T1_L2)
- Terms of use, sentinel2: "The use of Sentinel data is governed by the Copernicus Sentinel Data Terms and Conditions." (https://developers.google.com/earth-engine/datasets/catalog/COPERNICUS_S2_SR_HARMONIZED)
- Terms of use, cloud_score_plus: "CC-BY-4.0" (https://developers.google.com/earth-engine/datasets/catalog/GOOGLE_CLOUD_SCORE_PLUS_V1_S2_HARMONIZED)

| Year | Landsat scenes in season | after scene cloud filter | Sentinel-2 granules |
| --- | --- | --- | --- |
| 2023 | 54 | 18 (LANDSAT_8 9, LANDSAT_9 9) | 190 |
| 2024 | 46 | 16 (LANDSAT_8 7, LANDSAT_9 9) | 185 |
| 2025 | 45 | 15 (LANDSAT_8 8, LANDSAT_9 7) | 270 |

Clear observations per pixel over the extent (percentiles p0 / p5 / p50 / p95): LST 2 / 11 / 22 / 29, NDVI 32 / 44 / 92 / 146.

Previews: `figures/preview_lst.png`, `figures/preview_ndvi.png` (LST stretched 26 to 39 °C, NDVI 0 to 0.8).
