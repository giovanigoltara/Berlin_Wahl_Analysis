-- Post-load checks. Results are written to clean.load_check; src/load_postgis.py copies them
-- into docs/validation_report.md and fails the run if any check fails.

DROP TABLE IF EXISTS clean.load_check;
CREATE TABLE clean.load_check (
    check_id  serial PRIMARY KEY,
    name      text NOT NULL,
    passed    boolean NOT NULL,
    detail    text NOT NULL
);

-- Row counts: nothing lost between raw and clean.
INSERT INTO clean.load_check (name, passed, detail)
SELECT 'Row counts raw = clean', bool_and(r = c),
       string_agg(format('%s %s/%s', t, c, r), ', ' ORDER BY t)
FROM (
    SELECT 'stations' AS t, (SELECT count(*) FROM raw.uwb_geom) AS r,
           (SELECT count(*) FROM clean.station_district) AS c
    UNION ALL SELECT 'station results',
           (SELECT count(*) FROM raw.results_w WHERE wbezart = 'W'),
           (SELECT count(*) FROM clean.station_result)
    UNION ALL SELECT 'postal districts',
           (SELECT count(*) FROM raw.results_w WHERE wbezart = 'B'),
           (SELECT count(*) FROM clean.postal_result)
    UNION ALL SELECT 'population blocks', (SELECT count(*) FROM raw.population_blocks),
           (SELECT count(*) FROM clean.population_block)
    UNION ALL SELECT 'parties', (SELECT count(*) FROM raw.parties),
           (SELECT count(*) FROM clean.party)
) AS counts;

-- Geometry validity as delivered, and repairs applied by 05_clean.sql.
INSERT INTO clean.load_check (name, passed, detail)
SELECT 'Raw geometries valid (no ST_MakeValid repairs)', sum(n_invalid) = 0,
       string_agg(format('%s: %s invalid of %s', t, n_invalid, n), ', ')
FROM (
    SELECT 'stations' AS t, count(*) FILTER (WHERE NOT ST_IsValid(geom)) AS n_invalid,
           count(*) AS n
    FROM raw.uwb_geom
    UNION ALL
    SELECT 'population blocks', count(*) FILTER (WHERE NOT ST_IsValid(geom)), count(*)
    FROM raw.population_blocks
) AS v;

INSERT INTO clean.load_check (name, passed, detail)
SELECT 'All clean geometries EPSG:25833',
       bool_and(srid = 25833), string_agg(DISTINCT srid::text, ', ')
FROM (
    SELECT ST_SRID(geom) AS srid FROM clean.station_district
    UNION ALL SELECT ST_SRID(geom) FROM clean.population_block
) AS s;

-- Keys: every station has results, every postal district has stations.
INSERT INTO clean.load_check (name, passed, detail)
SELECT 'Every station district has a result row and vice versa',
       count(*) FILTER (WHERE r.uwb IS NULL OR d.uwb IS NULL) = 0,
       format('%s unmatched', count(*) FILTER (WHERE r.uwb IS NULL OR d.uwb IS NULL))
FROM clean.station_district AS d
FULL JOIN clean.station_result AS r USING (uwb);

INSERT INTO clean.load_check (name, passed, detail)
SELECT 'Every postal district covers at least one station district', count(*) = 0,
       format('%s postal districts without stations', count(*))
FROM clean.postal_district AS p
WHERE NOT EXISTS (SELECT 1 FROM clean.station_district AS s WHERE s.bwb = p.bwb);

-- Votes: party votes add up to valid votes in every district.
INSERT INTO clean.load_check (name, passed, detail)
SELECT 'Party votes sum to valid votes (stations)', count(*) = 0,
       format('%s districts differ', count(*))
FROM clean.station_result AS r
JOIN (SELECT uwb, sum(votes) AS s FROM clean.station_votes GROUP BY uwb) AS v USING (uwb)
WHERE v.s <> r.valid;

INSERT INTO clean.load_check (name, passed, detail)
SELECT 'Party votes sum to valid votes (postal)', count(*) = 0,
       format('%s districts differ', count(*))
FROM clean.postal_result AS r
JOIN (SELECT bwb, sum(votes) AS s FROM clean.postal_votes GROUP BY bwb) AS v USING (bwb)
WHERE v.s <> r.valid;

-- Reconciliation: station + postal sums equal the official Berlin row, item by item.
WITH sums AS (
    SELECT 'eligible' AS item, sum(eligible) AS value FROM clean.station_result
    UNION ALL SELECT 'voters', (SELECT sum(voters) FROM clean.station_result)
                               + (SELECT sum(voters) FROM clean.postal_result)
    UNION ALL SELECT 'valid', (SELECT sum(valid) FROM clean.station_result)
                              + (SELECT sum(valid) FROM clean.postal_result)
    UNION ALL SELECT 'invalid', (SELECT sum(invalid) FROM clean.station_result)
                                + (SELECT sum(invalid) FROM clean.postal_result)
    UNION ALL
    SELECT party_code, sum(votes)
    FROM (SELECT party_code, votes FROM clean.station_votes
          UNION ALL SELECT party_code, votes FROM clean.postal_votes) AS v
    GROUP BY party_code
)
INSERT INTO clean.load_check (name, passed, detail)
SELECT 'Station + postal sums equal official Berlin row',
       count(*) FILTER (WHERE s.value IS DISTINCT FROM b.value) = 0,
       format('%s items compared, %s differ',
              count(*), count(*) FILTER (WHERE s.value IS DISTINCT FROM b.value))
FROM clean.berlin_total AS b
FULL JOIN sums AS s USING (item);

-- Population: published block area agrees with computed area, and blocks fall inside the
-- district coverage (a precondition for the dasymetric step).
INSERT INTO clean.load_check (name, passed, detail)
SELECT 'Published block area (flalle) matches ST_Area within 1 %',
       count(*) FILTER (WHERE abs(ST_Area(geom) - area_m2) > 0.01 * area_m2) = 0,
       format('%s of %s blocks differ by more than 1 %%',
              count(*) FILTER (WHERE abs(ST_Area(geom) - area_m2) > 0.01 * area_m2), count(*))
FROM clean.population_block;

INSERT INTO clean.load_check (name, passed, detail)
SELECT 'Every populated block intersects a station district', count(*) = 0,
       format('%s populated blocks outside all districts (%s residents)',
              count(*), coalesce(sum(residents), 0))
FROM clean.population_block AS b
WHERE b.residents > 0
  AND NOT EXISTS (
      SELECT 1 FROM clean.station_district AS d WHERE ST_Intersects(d.geom, b.geom)
  );

INSERT INTO clean.load_check (name, passed, detail)
SELECT 'Population total (information)', true,
       format('%s residents in %s blocks, %s blocks with residents',
              sum(residents), count(*), count(*) FILTER (WHERE residents > 0))
FROM clean.population_block;
