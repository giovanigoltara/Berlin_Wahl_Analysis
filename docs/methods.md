# Methods

Each section names the SQL or Python file that implements it. Checks for every step are in `docs/validation_report.md`.

## Postal vote allocation (`sql/20_postal_allocation.sql`)

Berlin reports postal votes (Briefwahl) for postal districts (Briefwahlbezirke, key `BWB`), not for polling-station districts (Urnenwahlbezirke, key `UWB`). Every station district belongs to exactly one postal district, and a postal district covers 1 to 4 station districts (median 2). In 2026, 745,010 of 1,824,514 valid Zweitstimmen (40.8 %) were cast by post, so dropping them would leave out a large and socially selective part of the electorate.

Postal votes are split among the station districts of each postal district with a weight `w` that sums to 1 per postal district. The same weight applies to every party and to voters, valid and invalid votes.

| Method | Weight of a station district | Rationale |
| --- | --- | --- |
| A | its valid station votes | places postal voters where station voters are |
| B | its eligible voters (`WberIns`) | places postal voters where the electorate is |
| C | its eligible voters holding a Wahlschein (`WberA2`) | places postal voters where postal ballots were issued |
| S | none; postal votes are dropped | reference for the sensitivity check |

Method C is the most direct proxy. Postal ballots are requested through a Wahlschein, and no voter used a Wahlschein at a polling station (`Wahlsch` is 0 in every station row), so Wahlschein holders are almost exactly the postal electorate. Summed per postal district, Wahlschein holders correlate with actual postal voters at r = 0.997, against 0.685 for eligible voters and 0.674 for station valid votes; 81 % to 98 % of Wahlschein holders returned a ballot. The brief specified methods A and B; C was added after inspecting the data and is proposed as the primary method, with A, B and S reported as sensitivity checks.

Shared assumption: within a postal district, postal voters of every station district vote alike. Only the size of each station's share differs between methods. In 661 of 2,542 station districts the postal district contains only that station, so all methods agree there.

Outputs: `analysis.postal_weight`, `analysis.district_votes` (long, one row per station, method and party), `analysis.district_result` (eligible, voters, valid, invalid, turnout and postal share per station and method). Allocated values are fractional and unrounded, so every method reproduces the official Berlin totals exactly.

## Dasymetric population (`sql/30_dasymetric.sql`)

Station districts include water, forest, allotments and industry. To describe the places where people live, indicators are computed over residential land, taken from the Umweltatlas population blocks 2025.

1. Each block is intersected with the station districts. A block inside one district is kept whole; a block split by a district boundary is clipped, and its residents are divided by area share. 4,907 blocks holding 26 % of residents are split this way. Pieces smaller than `dasymetric.min_piece_m2` are boundary slivers and are dropped.
2. Area shares are normalised by the part of each block inside the district coverage. 124 populated blocks on Berlin's outer boundary overhang the district coverage by up to 207 m2 (1.2 % of a block), a digitisation mismatch between the two sources; normalising keeps their residents, so the district totals equal the block total of 3,913,505 exactly.
3. A block is residential if it has at least `dasymetric.min_block_residents` residents and its block type is not listed in `dasymetric.excluded_block_types`. The 19 excluded types are open land (forest, water, parks, cemeteries, allotments, weekend-house areas, sports grounds, wasteland) and transport or utility infrastructure, where registered residents are caretaker flats or register artefacts. Built types, including commercial, mixed and institutional blocks, stay residential when people live there. Residents of excluded blocks (28,593, 0.73 %) still count in district residents but not in residential density. Residential land per district is the union of its residential pieces (`analysis.district_population.residential_geom`), used later as the mask for satellite and accessibility indicators.
4. Per district: residents, residents of residential blocks, residential area, gross density (residents per ha of district) and residential density (residential residents per ha of residential land).

Blocks exclude street space, so residential land excludes streets.

### Population and register mismatch

Residents date from 2025 and eligible voters from the 2026 register. Across Berlin, eligible voters are 0.64 of residents (median district 0.66), as expected with minors and non-citizens excluded. In 15 districts (0.48 % of eligible voters) eligible voters exceed residents or there is no residential land; these carry `population_mismatch = true`, and Phase 4 reports results with and without them. The extreme case is a Spandau site that the 2025 blocks show as industrial land while the 2026 register lists 189 eligible voters in districts 05334 and 05335, consistent with housing occupied after the population snapshot. Districts allowed to lack residential land are listed in `dasymetric.known_no_residential_land`; any other such district fails the run.

Outputs: `analysis.block_piece`, `analysis.district_population`.

## OSM accessibility (`src/osm_extract.py`, `sql/40_accessibility.sql`)

Amenities come from the Geofabrik Berlin extract of 2026-10-03 (see `docs/provenance.md`). `src/osm_extract.py` reads nodes (GDAL layer `points`) and areas (closed ways and multipolygon relations, layer `multipolygons`), and assigns each feature to every category whose tags it matches, using the mapping in `config/params.yaml`:

| Category | OSM tags | Rows |
| --- | --- | --- |
| schools | `amenity=school` | 1,089 |
| kindergartens | `amenity=kindergarten` | 2,395 |
| health | `amenity=doctors, clinic, hospital, pharmacy`; `healthcare=doctor, clinic, hospital, pharmacy, centre` | 2,586 |
| supermarkets | `shop=supermarket` | 1,400 |
| public_transport_stops | `highway=bus_stop`; `railway=station, halt, tram_stop`; `public_transport=station` | 7,829 |
| parks | `leisure=park` | 2,714 |
| playgrounds | `leisure=playground` | 4,753 |

The mapping was fixed after counting candidate tags in the extract. Health covers general practice and pharmacies; dentists, therapists and alternative medicine are left out. Transit uses boarding points; `stop_position` and `platform` features would duplicate them. Convenience stores are not supermarkets. Features tagged `access=private` or `access=no` are dropped (928 rows, mostly playgrounds in residential courtyards). A feature mapped both as a node and as an area can appear twice; this does not affect the measures below, which depend on the nearest amenity only.

In PostGIS, amenities are transformed to EPSG:25833 and validated. Areas keep their shape, so distance is measured to their edge rather than their centroid. Two measures per district and category, both over residential land and weighted by residents:

1. **Share within reach**: buffers of `accessibility.buffer_m` (500 m, straight line) are dissolved per category and subdivided for indexing. Each residential block piece contributes its residents times the share of its area inside the catchment.
2. **Mean distance to the nearest amenity**: distance from a point on the surface of each residential block piece to the nearest amenity (index-assisted nearest-neighbour search), averaged with residents as weights.

The second measure was added after the first proved saturated: at 500 m the median district is fully covered in every category, and 84 % to 88 % of districts are fully covered for parks, playgrounds and transit. Mean nearest distance keeps the spread (for supermarkets, 126 m to 572 m from the 10th to the 90th percentile of districts) and is the better candidate for correlation analysis.

Limitations: straight-line distance underestimates walking distance, most where rail lines, water or motorways separate blocks from amenities. A point on a large block piece stands in for all its residents. OSM completeness varies by category and area. The extract reaches past the state border by a margin of varying width (amenities up to 1.9 km outside, median 265 m), so services in Brandenburg are only partly counted; 5.9 % of residential residents live within 500 m of the border.

Outputs: `analysis.amenity`, `analysis.amenity_catchment`, `analysis.piece_access`, `analysis.district_access` (residents, residents covered, share and mean nearest distance per district and category).

## Analysis plan (fixed 2026-10-05, before Phase 3)

This plan was committed before any surface temperature or NDVI value was computed, so the headline tests could not be chosen after seeing results. Parameters are in `config/params.yaml` under `analysis`. The analysis is ecological: every statement is about districts, never about voters.

### Variables

- **Outcomes**: Zweitstimme shares of the six parties above 4 % (Linke, CDU, AfD, Grüne, SPD, BSW), turnout, and a **left-right contrast**, (Linke + Grüne) minus (CDU + AfD) share per district. The contrast summarises the main ideological divide in one variable. It describes two camps, not a coalition or a government.
- **Indicators**: summer LST, summer NDVI, residential density, and mean nearest distance to each of the seven amenity categories. The **accessibility index** is the mean over the seven categories of the standardised (z-scored) logarithm of mean nearest distance; higher means worse access.

### Control for centrality

Heat, low NDVI, short distances, high density and left or green shares all rise toward the city centre, so raw correlations would largely measure that one gradient. Tier 1 therefore uses **partial Spearman correlation controlling for log residential density**. Density is taken from the project's own dasymetric step; distance to a chosen centre point was rejected as arbitrary. Raw correlations are reported alongside in Tier 2.

### Tiers

| Tier | Purpose | Tests | Settings |
| --- | --- | --- | --- |
| 1, confirmatory | Headline results | LST, NDVI and accessibility index x Linke, Grüne, CDU, AfD and the contrast (15), plus LST x turnout: 16 | Method C, partial on log density, Holm correction, alpha 0.05 |
| 2, robustness | Stability of Tier 1 | The 16 Tier 1 pairs under methods A, B and S, without the 15 `population_mismatch` districts, as raw correlations, and with the SPD added to the left side of the contrast | A Tier 1 result is called robust only if its sign holds in every variant and rho changes by less than 0.10 |
| 3, exploratory | Overview | 10 indicators x 7 outcomes, method C, shown as a heatmap | No p-values; labelled exploratory |

Global Moran's I (queen contiguity, 999 permutations, fixed seed) is reported for every indicator and outcome as a description of spatial clustering.

### Uncertainty

Neighbouring districts are similar (spatial autocorrelation), which violates the independence assumption behind standard correlation p-values. Results are therefore reported as effect sizes (rho with a confidence interval); p-values are labelled as not adjusted for spatial autocorrelation and serve only to rank evidence within Tier 1.

### Satellite indicators over small residential masks

Residential masks exclude street space, and a 30 m Landsat pixel often straddles a block and a street. Phase 3 records the number of whole pixels inside each district's residential mask. Districts below `analysis.min_lst_pixels` use the whole district instead and are flagged; the threshold is set from the observed distribution and documented with it.

### What LST measures

Landsat LST is the radiative temperature of surfaces (roofs, pavement, vegetation) at the satellite overpass, about 10:30 local time, under clear skies. It is a proxy for daytime heat exposure, not air temperature, and it says nothing about night-time heat. Imagery covers the summers of 2023 to 2025, while the election took place in September 2026. Both points will be stated in the README limitations.
