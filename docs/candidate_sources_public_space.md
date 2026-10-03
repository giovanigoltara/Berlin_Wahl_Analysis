# Candidate sources: quality of public space

Research note, 3 October 2026. Purpose: decide whether one indicator that *qualifies* public space (how good it is, not only where it is) should be added to the analysis later. Nothing here changes the pipeline.

## How this was checked

- Service discovery: CSW catalogue of the Berlin Geodateninfrastruktur, `https://gdi.berlin.de/geonetwork/srv/ger/csw`, full-text query `%wfs%` (1,144 records), filtered for WFS endpoints under `https://gdi.berlin.de/services/wfs/`.
- For every candidate: `GetCapabilities` (WFS 2.0.0) for layer names, CRS and licence; `GetFeature&resultType=hits` for feature counts; one sample feature (`count=1`, GeoJSON) for attribute names. Block-key overlaps and value distributions were computed from full attribute downloads (`propertyName=...`, no geometry).
- **Where the licence lives.** In these services `ows:AccessConstraints` only states access conditions (e.g. "Es gelten keine Zugriffsbeschränkungen."). The licence text is in **`ows:Fees`**. Both are quoted below.
- Hosts not reachable from this session (not verified): `www.berlin.de/umweltatlas` (proxy 403), `fbinter.stadt-berlin.de` (proxy 403), `daten.berlin.de` (bot challenge, 403), `download.geofabrik.de` and `overpass-api.de` (connection reset). Method descriptions and class definitions on the Umweltatlas pages could therefore not be read.

Legend: **V** = verified by fetching it in this session; **U** = unverified (inferred, from memory, or host unreachable).

### Licence strings (verbatim, from `ows:Fees` of each service's GetCapabilities, V)

- **DL-DE-Zero-2.0** (all candidates below unless noted): "Für die Nutzung der Daten ist die Datenlizenz Deutschland - Zero - Version 2.0 anzuwenden. Die Lizenz ist über https://www.govdata.de/dl-de/zero-2-0 abrufbar."
- `ows:AccessConstraints` reads either "Es gelten keine Zugriffsbeschränkungen." or "Es gelten keine Bedingungen" (given per row in the table).

**Side finding relevant to the existing pipeline (V).** `ua_einwohnerdichte_2025`, already used for the dasymetric step, is *not* DL-DE-Zero. Its `ows:Fees` reads: "Der Datenbestand wird unter der Lizenz CC-BY-3.0-Namensnennung veröffentlicht (vgl. https://creativecommons.org/licenses/by/3.0/de/). Der Quellenvermerk gemäß Abschnitt 3a der Lizenz lautet "Amt für Statistik Berlin-Brandenburg / Einwohnerdichte 2025 (Umweltatlas)"." This attribution must appear on maps and in `docs/provenance.md`.

## Candidate table

All WFS endpoints are `https://gdi.berlin.de/services/wfs/<service>`; provider for all is the Land Berlin geodata infrastructure (Senatsverwaltung data published via gdi.berlin.de; the responsible department per dataset was not checked, U). All layers report `DefaultCRS urn:ogc:def:crs:EPSG::25833` (V). "Block key" means the 16-digit Umweltatlas block/block-part key (`schluessel`, `schl5`, `styp_id`), the same key used by `ua_einwohnerdichte_2025` (26,613 blocks).

| # | Dimension | Name (service : layer) | Format, geometry | Spatial unit, n features (V) | Reference year | Access constraint (V) | Key attributes (V) | Aggregation to UWB |
|---|---|---|---|---|---|---|---|---|
| 1 | Green provision per resident | Versorgung mit öffentlichen, wohnungsnahen Grünanlagen 2020 (Umweltatlas). `ua_versorggruen_2020 : versorggruen_2020` (+ `versorggruen_oeff_2020`, `versorggruen_wald_2020`) | WFS, MultiPolygon | Residential blocks, 13,385 | 2020 (title) | Es gelten keine Bedingungen | `styp_id` (block key), `versorg_sst` (integer 1 to 12), `voeff_name` (versorgter / unterversorgter / schlecht versorgter / nicht versorgter Bereich), `vpriv_name` (private open space class) | Yes, easy: 13,117 of 13,385 keys (98 %) match `ua_einwohnerdichte_2025`; population-weighted via existing dasymetric blocks |
| 2 | Thermal comfort of street space | Klimaanalyse 2022 (Umweltatlas), PET at 14:00 on Verkehrsflächen. `ua_klimaanalyse_2022 : pb_ua_pet_str_2022` (also `pa_..._siedlg_2022` for settlement blocks, `rb_ua_utci_str_2022` UTCI) | WFS, MultiPolygon | Street-space polygons 33,887; settlement blocks 16,217 | 2022 (title) | Es gelten keine Zugriffsbeschränkungen. | `schl5`, `pet14h` (numeric, °C per layer title) | Yes: area-weighted mean of street polygons intersecting each UWB |
| 3 | Bioclimate, planning assessment | Klimabewertungskarten 2022 (Umweltatlas). `ua_klimabewertung_2022 : bj_ua_phk_biokl_siedl_2022`, `bi_ua_phk_biokl_str_2022`, `ca_ua_phk_aufenth_grfrei_tag_2022` | WFS, MultiPolygon | Blocks 16,795 / streets 33,887 / green spaces 7,119 | 2022 | Es gelten keine Zugriffsbeschränkungen. | `phk_gesamt` (günstig 937, weniger günstig 10,267, ungünstig 4,951, sehr ungünstig 640); `pet14h_tag_klar` for green spaces | Yes (ordinal, block key matches 16,655 of 16,795) |
| 4 | Street trees | Baumbestand Berlin. `baumbestand : strassenbaeume`, `anlagenbaeume` | WFS, Point | Trees: 434,765 street, 527,780 park | Metadata modified 2026-04-09 | Es gelten keine Zugriffsbeschränkungen. | `art_bot`, `pflanzjahr`, `standalter`, `kronedurch`, `stammumfg`, `baumhoehe`, `bezirk`. In a 20,000-row sample of street trees, `kronedurch` was missing/0 for 17 rows only | Yes: count or crown area per UWB, per km street or per ha street space. Abstract: park trees are only "ein Teil der Bäume in Grünanlagen" |
| 5 | Tree canopy / vegetation structure | Mittlere Vegetationshöhen 2020; Grünvolumen 2020 (Umweltatlas). `ua_vegetationshoehen_2020 : a_vegetationshoehe_2020`; `ua_gruenvolumen_2020 : a_gruenvol2020` | WFS, MultiPolygon | All blocks incl. streets, 34,498 each | 2020 | Keine Zugriffsbeschränkungen / Keine Bedingungen | `mean_vegh_bl2020`, `anteil_veg_2020`, `anteil_oeff_baum2020`, `vegvol2020` (m³/m²) | Yes (block key, 26,150 keys shared with EWD 2025). Meaning of `anteil_oeff_baum2020` not documented in the service (U) |
| 6 | Public green spaces and playgrounds | Grünanlagenbestand Berlin (einschließlich der öffentlichen Spielplätze). `gruenanlagen : gruenanlagen`, `spielplaetze` | WFS, MultiPolygon | 2,563 green spaces, 1,886 playgrounds | Metadata modified 2026-04-09 | Es gelten keine Bedingungen | `objartname`, `katasterfl`, `widmung`, `baujahr`, `sanierjahr`, `nettospfl` (playground net area) | Yes: area per resident within 500 m buffer, same logic as `40_accessibility.sql` |
| 7 | Noise | Strategische Lärmkarten 2022 (Umweltatlas). `ua_stratlaerm_2022 : aa_fp_gesamt2022` (facade points), `ab_wohngebaeude2022` | WFS, Point / MultiPolygon | 3,799,746 facade points; 305,574 residential buildings | 2022; metadata modified 2024-01-23 | Es gelten keine Zugriffsbeschränkungen. | `ges_den`, `ges_n` (all sources), `str_*`, `sch_*`, `flg_*` | Yes, but heavy: share of residential facade points above a threshold per UWB. 3.8 M points need paged download |
| 8 | Air quality (traffic) | Verkehrsbedingte Luftbelastung im Straßenraum 2020 und 2025. `ua_luftbelastung_verkehr_2020_2025` | WFS, MultiLineString | Main road segments, 12,370 | 2020, 2025 (modelled) | Es gelten keine Zugriffsbeschränkungen | `no2_2025`, `pm10_2025`, `pm25_2025`, `dtv_2025`, `n_betrof` | Partial: covers main road network only, no values for side streets |
| 9 | Composite (environmental justice) | Umweltgerechtigkeit 2023/2024 (Umweltatlas). `ua_umweltgerechtigkeit2023 : a_laerm2023, b_luft2023, c_gruen2023, d_bioklima2023, e_sozial2023, z_gesamt_umwelt2023`, ... | WFS, MultiPolygon | Planungsräume (LOR), 542 | 2023/2024; metadata modified 2024-10-01 | Es gelten keine Zugriffsbeschränkungen. | `plr_id`, `kategorie` (3 classes, e.g. green: gut 291, mittel 113, schlecht 136, null 2) | Coarser than UWB (about 4.7 UWB per PLR); only by area or population overlay. Better as a benchmark than as a variable |
| 10 | Street space allocation | Straßenbefahrung 2014. `strassenbefahrung : cm_fahrbahn, cl_gehweg, ch_radweg, ck_parkflaeche, ci_oeffentlicher_platz, bj_sitzbank, bn_baumscheibe, ...` (67 layers) | WFS, polygons and points | e.g. 63,175 carriageway polygons | Survey 2014 and 2015 (abstract) | Es gelten keine Zugriffsbeschränkungen. | `bezeichnun`, `flaeche`, `material` (carriageway sample) | Yes, technically ideal (carriageway vs footway vs cycleway area per UWB), but 11 years old and many layers |
| 11 | Parking in street space | Parken im Straßenraum. `parkplaetze : parkplaetze` (inside S-Bahn ring), `parkplaetze_aussen` | WFS, MultiPolygon | 45,917 inner, 214,173 outer | Inner ring "Stand Juli 2023" (abstract) | Es gelten keine Zugriffsbeschränkungen. | `errechnete_anzahl_parkplaetze` / `anzahl_parkplaetze`, `parkort`, `ausrichtung` | Yes, parking spaces per km street; inner and outer layers have different schemas and origins |
| 12 | Cycling infrastructure | Radverkehrsanlagen. `radverkehrsanlagen : b_radverkehrsanlagen` | WFS, MultiLineString | 18,641 segments | Not checked (U) | Es gelten keine Zugriffsbeschränkungen. | `rva_typ`, `sorvt_typ`, `laenge`, `b_pflicht` | Yes, km per km street |
| 13 | Street sealing | Versiegelung 2021, Straßenflächen. `ua_versiegelung_2021 : versieg2021_str` | WFS, MultiPolygon | 32,153 street blocks | 2021 | Es gelten keine Zugriffsbeschränkungen. | `vg` (% sealed), `kl1` to `kl7` | Yes (block key) |
| 14 | Toilets | Öffentliche Toiletten. `toiletten : toiletten` | WFS, Point | 520 | Metadata modified 2026-09-18; updated "mindestens einmal im Jahr" | Es gelten keine Zugriffsbeschränkungen. | `modelltyp`, `barrierefrei`, `nutzungsentgelt`, `oeffnungszeiten` | Counts too low for 2,542 districts; most UWB would score 0 |
| 15 | Drinking fountains | Trinkwasserbrunnen. `trinkwasserbrunnen : trinkwasserbrunnen` | WFS, Point | 242 | Metadata date 2026-03-09 | Es gelten keine Zugriffsbeschränkungen. | `trinkbrunnenart`, `baujahr`, `einschraenkungen` | Same sparsity problem |
| 16 | Cool rooms (heat protection) | Kühle Räume (Hitzeschutz). `kuehle_raeume : kuehle_raeume` | WFS, Point | 126 | Metadata modified 2026-07-31 | Es gelten keine Zugriffsbeschränkungen. | `bezirk`, `oeffnungszeiten`, `rollstuhlgerechter_zugang` | Too sparse; indoor, not public space |
| 17 | Benches, playgrounds, fountains, toilets, trees (crowd-sourced) | OpenStreetMap tags (U): `amenity=bench`, `leisure=playground`, `amenity=drinking_water`, `amenity=toilets`, `natural=tree`, `sidewalk=*`, `highway=footway` | PBF (Geofabrik) or Overpass | Points / lines | Extract date | ODbL (U, not read in this session) | Not inspected | Possible, but completeness of benches and trees in OSM varies strongly by neighbourhood (U), which would bias a district comparison |

Other services found in the catalogue but not inspected: `fussgaengernetz` (pedestrian network, may help network-distance accessibility later), `gruene_wege`, `ua_biotoptypen_2024`, `ua_klimawandel_2022`, `beleuchtung` (street lighting), `sozialer_zusammenhalt` (V for existence and licence only).

## Ranked shortlist

Criteria: fit to the research question (urban conditions vs vote), effort within the remaining budget, data quality. Main risk across the board: several layers measure what LST and NDVI already capture. A new indicator is only worth adding if it is not a near-duplicate of those.

### 1. Versorgung mit öffentlichen, wohnungsnahen Grünanlagen 2020

- **Fit (high).** The only official layer that expresses *quality of provision per resident* rather than presence of green; the abstract defines it as "Versorgungsgrad (m² / Einwohner) von Wohnblöcken mit öffentlichen, wohnungsnahen Grünanlagen unter Berücksichtigung vorhandener privater und halböffentlicher Freiräume" (V). That is conceptually distinct from NDVI, which also counts private gardens, railway verges and cemeteries.
- **Effort (low, about 3 to 4 h).** Block key matches the population blocks already used in `30_dasymetric.sql` for 98 % of features (V), so it is a key join plus population-weighted share per UWB (e.g. share of residents in "unterversorgt" or worse). No new geometry processing.
- **Quality and caveats.** Reference year 2020, five years before the population data. The service delivers ordinal classes (`versorg_sst` 1 to 12, `voeff_name`), not the m² per resident value (V); the exact class thresholds are on the Umweltatlas page, which was not reachable (U). Must be documented before use.

### 2. PET at 14:00 on street space, Klimaanalyse 2022

- **Fit (high for "public space").** It qualifies the street itself as a place to walk and stay: modelled felt temperature (PET, °C) per street-space polygon (V). Complements Landsat LST, which is a surface temperature of roofs and ground, not thermal comfort of people outdoors. It also offers a validation exercise: modelled PET vs observed LST.
- **Effort (low to medium, about 4 to 5 h).** 33,887 polygons, one numeric field, area-weighted mean per UWB in SQL.
- **Quality and caveats.** Model output for an assumed summer situation (model and scenario not verified, U). Likely strongly correlated with LST; check the correlation before treating it as independent evidence.

### 3. Street trees, Baumbestand Berlin

- **Fit (medium to high).** Street trees are the most direct public-space amenity for shade and walkability. Indicators such as trees per km of street or crown area per ha of street space are easy to explain.
- **Effort (medium, about 5 to 6 h).** 434,765 points need a paged WFS download (or ogr2ogr) and a street-length or street-area denominator (e.g. `pb_ua_pet_str_2022` polygons or `versieg2021_str`).
- **Quality and caveats.** Attributes are well populated in the sample (V). Park trees are only partly included according to the abstract, so restrict to street trees. Correlation with NDVI likely moderate, not as high as for canopy layers.

**Not shortlisted, and why.** Klimabewertung (3): ordinal re-expression of the same climate model as candidate 2. Vegetation height and green volume (5): near-duplicates of NDVI. Noise (7): strong and independent signal, but 3.8 M points make it the most expensive option; the best runner-up if the budget allows. Umweltgerechtigkeit (9): too coarse (542 PLR, 3 classes) for a 2,542-district analysis, but worth one sentence in the README as an external benchmark. Street survey (10) and parking (11): ideal concepts for street space allocation, but 2014/2015 data or split schemas. Toilets, fountains, cool rooms (14 to 16): too few points per district. OSM (17): uneven completeness, not verifiable from this session.

**Recommendation.** If only one indicator is added, take candidate 1. Add candidate 2 only if the LST correlation turns out below roughly 0.8, otherwise it adds little. The budget for either must come from Phase 5 slack, not from validation work.

## Decision (3 October 2026): adopt candidate 1

Green provision 2020 is adopted as the public-space quality indicator. Parameters are in `config/params.yaml` (`sources.green_provision`, `green_provision`).

**Class thresholds (V).** Read from the WMS legend, `https://gdi.berlin.de/services/wms/ua_versorggruen_2020?service=WMS&version=1.3.0&request=GetLegendGraphic&format=image/png&layer=versorggruen_2020&sld_version=1.1.0`. Unit: m² of public, near-home green space per inhabitant.

| `voeff_name` | m² per inhabitant | Blocks |
|---|---|---|
| versorgter Bereich | > 6.0 | 7,308 |
| unterversorgter Bereich | 3.0 to < 6.0 | 1,134 |
| schlecht versorgter Bereich | 0.1 to < 3.0 | 1,180 |
| nicht versorgter Bereich | ≤ 0.1 | 3,763 |

The legend crosses these four classes with the share of private or semi-public open space (gering, mittel, hoch), which gives the 12 `versorg_sst` codes. **Do not use `versorg_sst`** (V): code 1 holds 4,552 "hoch", 133 "mittel" and 22 "gering" blocks, and codes 3, 6, 9 and 12 also hold "kein: alle anderen Strukturtypen". Use `voeff_name` and `vpriv_name` as two separate fields.

**Indicators per UWB.**
- `green_undersupplied_share`: share of residents (`ew2025` from `ua_einwohnerdichte_2025`) living in blocks below 6 m² per inhabitant.
- `green_poorly_supplied_share`: same, below 3 m² per inhabitant.
- Weighting goes through the dasymetric block intersection of Phase 2. Blocks are joined on `styp_id` = `schluessel`. The 268 provision blocks without a key match in 2025 are reported in the validation report and assigned by spatial overlay.

**Known confound (U, to test).** 2,026 of the 3,763 "nicht versorgt" blocks have a high share of private open space ("hoch: aufgelockerte Siedlungsbebauung"), i.e. probably detached housing at the city edge. There, low public green provision may reflect garden ownership rather than deprivation, and it will correlate with building type and with vote. Report the indicator alongside `vpriv_name`, or restrict it to blocks with "gering" or "mittel" private open space, and check which choice changes the correlations.

**Overlap with existing plan.** `accessibility.amenities` already includes `parks` (500 m from OSM). Keep both only if they are not near-duplicates: compare them in Phase 4 and drop one if Spearman ρ > 0.8.
