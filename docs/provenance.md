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
- Manual step: the `/opendata/...` URLs are routes of a JavaScript web app. Scripts receive an HTML page with status 200; browsers then fetch the file from `cdn0.scrvt.com`, which the build environment cannot reach. Both files were therefore downloaded in a browser on 2026-10-03 and placed in `data/raw/district_geometries/` by hand (manifest method `manual`). Their SHA-256 hashes are pinned in `config/params.yaml`, and `src/download.py` rejects any other content, including the HTML page.

### Population density 2025 (Umweltatlas)

- Provider: Amt für Statistik Berlin-Brandenburg, published via the Berlin Geodateninfrastruktur
- Catalogue entry: <https://daten.berlin.de/datensaetze/einwohnerdichte-2025-umweltatlas-wfs-b2654f6b>
- Service: WFS 2.0.0 <https://gdi.berlin.de/services/wfs/ua_einwohnerdichte_2025>, layer `ua_einwohnerdichte_2025:ua_einwohnerdichte_2025`, EPSG:25833, GML 3.2, 26,613 features, fetched in one GetFeature request
- Licence as stated: "Der Datenbestand wird unter der Lizenz CC-BY-3.0-Namensnennung veröffentlicht (vgl. https://creativecommons.org/licenses/by/3.0/de/). Der Quellenvermerk gemäß Abschnitt 3a der Lizenz lautet "Amt für Statistik Berlin-Brandenburg / Einwohnerdichte 2025 (Umweltatlas)"." (WFS GetCapabilities, `ows:AccessConstraints`)

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

The WFS response and its hash can change if the provider updates the service.

## Pending

- OpenStreetMap extract (Phase 2): source, extract date and licence
- Earth Engine assets, date ranges and parameters (Phase 3)
