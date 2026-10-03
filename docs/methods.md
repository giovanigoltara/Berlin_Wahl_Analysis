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

1. Each block is intersected with the station districts. A block inside one district is kept whole; a block split by a district boundary is clipped, and its residents are divided by area share. Pieces smaller than `dasymetric.min_piece_m2` are boundary slivers and are dropped.
2. A block is residential if it has at least `dasymetric.min_block_residents` residents. Residential land per district is the union of its residential pieces (`analysis.district_population.residential_geom`), used later as the mask for satellite and accessibility indicators.
3. Per district: residents, residential area, gross density (residents per ha of district) and residential density (residents per ha of residential land).

Blocks exclude street space, so residential land excludes streets. Residents date from 2025 and eligible voters from the 2026 register; their ratio per district is reported as a consistency check.

Outputs: `analysis.block_piece`, `analysis.district_population`.
