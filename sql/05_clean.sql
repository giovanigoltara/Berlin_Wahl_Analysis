-- Build typed clean tables from raw. Raw column names are lowercased by src/load_postgis.py.
-- Geometries are repaired with ST_MakeValid only where ST_IsValid fails; every repair is counted
-- in sql/10_load_checks.sql (raw vs clean validity).

INSERT INTO clean.party (party_code, party_name)
SELECT party_code, party_name
FROM raw.parties;

INSERT INTO clean.postal_district (bwb, bez)
SELECT briefwahlbezirk, bezirk
FROM raw.results_w
WHERE wbezart = 'B';

INSERT INTO clean.station_district (uwb, bez, bwb, awk, bwk, geom)
SELECT uwb, bez, bwb, awk, bwk,
       ST_Multi(CASE WHEN ST_IsValid(geom) THEN geom
                     ELSE ST_CollectionExtract(ST_MakeValid(geom), 3) END)
FROM raw.uwb_geom;

INSERT INTO clean.station_result (uwb, eligible, wahlschein, voters, valid, invalid)
SELECT bezirk || wahlbezirk, wberins::int, wbera2::int, waehler::int, gueltig::int,
       unguelt::int
FROM raw.results_w
WHERE wbezart = 'W';

INSERT INTO clean.postal_result (bwb, voters, valid, invalid)
SELECT briefwahlbezirk, waehler::int, gueltig::int, unguelt::int
FROM raw.results_w
WHERE wbezart = 'B';

-- Wide party columns to long rows: one row per district and ballot party.
INSERT INTO clean.station_votes (uwb, party_code, votes)
SELECT r.bezirk || r.wahlbezirk, p.party_code, (to_jsonb(r) ->> lower(p.party_code))::int
FROM raw.results_w AS r
CROSS JOIN clean.party AS p
WHERE r.wbezart = 'W';

INSERT INTO clean.postal_votes (bwb, party_code, votes)
SELECT r.briefwahlbezirk, p.party_code, (to_jsonb(r) ->> lower(p.party_code))::int
FROM raw.results_w AS r
CROSS JOIN clean.party AS p
WHERE r.wbezart = 'B';

-- Berlin row of the A table, as item/value pairs.
INSERT INTO clean.berlin_total (item, value)
SELECT v.item, (to_jsonb(a) ->> v.col)::bigint
FROM raw.results_a AS a
CROSS JOIN LATERAL (
    VALUES ('eligible', 'wberins'), ('voters', 'waehler'), ('valid', 'gueltig'),
           ('invalid', 'unguelt')
) AS v (item, col)
WHERE a.gebietsart = 'Bundesland'
UNION ALL
SELECT p.party_code, (to_jsonb(a) ->> lower(p.party_code))::bigint
FROM raw.results_a AS a
CROSS JOIN clean.party AS p
WHERE a.gebietsart = 'Bundesland';

INSERT INTO clean.population_block (schluessel, residents, area_m2, block_type, geom)
SELECT schluessel, ew2025::int, flalle::double precision, typklar,
       ST_Multi(CASE WHEN ST_IsValid(geom) THEN geom
                     ELSE ST_CollectionExtract(ST_MakeValid(geom), 3) END)
FROM raw.population_blocks;

ANALYZE clean.station_district, clean.population_block, clean.station_votes, clean.postal_votes;
