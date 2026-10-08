-- Indicators: one analysis table with one row per station district, and a long table of outcomes
-- for every postal allocation method (sensitivity checks in src/analysis.py).
--   analysis.outcome     (uwb, method, outcome, value): party shares (votes / valid), the
--                        left-right contrasts, and turnout. Turnout is not defined for method S
--                        (station votes only: postal voters are missing from the numerator).
--   analysis.indicators  one row per district: outcomes of the primary method as columns, summer
--                        LST and NDVI, residential density, mean nearest distance per amenity
--                        category, the accessibility index, flags and the district geometry.
-- The accessibility index is the mean over categories of the z-scored ln(1 + mean nearest
-- distance in m) (docs/methods.md, "Analysis plan"); higher means worse access. The 1 keeps
-- districts whose residents live inside an amenity area (distance 0).
-- Parameters are session settings set by src/run_sql.py from config/params.yaml (analysis):
--   hgv.parties, hgv.parties_<name>     outcome names and party codes
--   hgv.contrast_left / _right          party codes of each camp, '|'-separated
--   hgv.contrast_with_spd_left / _right the Tier 2 variant
--   hgv.primary_method                  allocation method whose outcomes become columns
-- Idempotent: all tables are dropped and rebuilt.

DROP TABLE IF EXISTS analysis.outcome, analysis.indicators, analysis.indicators_check CASCADE;

CREATE TABLE analysis.outcome (
    uwb      text NOT NULL REFERENCES clean.station_district,
    method   char(1) NOT NULL CHECK (method IN ('A', 'B', 'C', 'S')),
    outcome  text NOT NULL,
    value    double precision NOT NULL,
    PRIMARY KEY (uwb, method, outcome)
);

-- Party shares of valid votes, under the names used in params.yaml.
WITH party AS (
    SELECT name, current_setting('hgv.parties_' || name) AS party_code
    FROM unnest(string_to_array(current_setting('hgv.parties'), '|')) AS name
),
share AS (
    SELECT v.uwb, v.method, v.party_code, v.votes / r.valid AS share
    FROM analysis.district_votes AS v
    JOIN analysis.district_result AS r USING (uwb, method)
)
INSERT INTO analysis.outcome
SELECT s.uwb, s.method, p.name, s.share
FROM share AS s JOIN party AS p USING (party_code)
UNION ALL
-- Left-right contrasts: share of the left camp minus share of the right camp.
SELECT s.uwb, s.method, c.outcome,
       sum(s.share) FILTER (WHERE s.party_code = ANY (c.left_codes))
       - sum(s.share) FILTER (WHERE s.party_code = ANY (c.right_codes))
FROM share AS s
CROSS JOIN (
    VALUES ('contrast',
            string_to_array(current_setting('hgv.contrast_left'), '|'),
            string_to_array(current_setting('hgv.contrast_right'), '|')),
           ('contrast_with_spd',
            string_to_array(current_setting('hgv.contrast_with_spd_left'), '|'),
            string_to_array(current_setting('hgv.contrast_with_spd_right'), '|'))
) AS c (outcome, left_codes, right_codes)
GROUP BY s.uwb, s.method, c.outcome
UNION ALL
SELECT uwb, method, 'turnout', turnout
FROM analysis.district_result
WHERE method <> 'S';

-- Accessibility: z-scored log distance per category, then the mean over categories.
CREATE TEMP TABLE access_z AS
SELECT uwb, category, mean_nearest_m,
       (ln(1 + mean_nearest_m) - avg(ln(1 + mean_nearest_m)) OVER w)
           / stddev_samp(ln(1 + mean_nearest_m)) OVER w AS z
FROM analysis.district_access
WHERE mean_nearest_m IS NOT NULL
WINDOW w AS (PARTITION BY category);

CREATE TABLE analysis.indicators AS
SELECT d.uwb,
       d.bez,
       p.residents,
       p.residential_residents,
       p.density_residential,                          -- residents per ha of residential land
       ln(p.density_residential) AS log_density_residential,
       s.lst_mean AS lst,                              -- degrees C, summer median composite
       s.ndvi_mean AS ndvi,
       s.zone AS satellite_zone,
       s.satellite_fallback,
       a.access_index,
       p.population_mismatch,
       d.geom
FROM clean.station_district AS d
JOIN analysis.district_population AS p USING (uwb)
JOIN analysis.district_satellite AS s USING (uwb)
LEFT JOIN (
    SELECT uwb, avg(z) AS access_index, count(*) AS n_categories
    FROM access_z GROUP BY uwb
) AS a ON a.uwb = d.uwb
       AND a.n_categories = (SELECT count(DISTINCT category) FROM analysis.district_access);

-- Distance and outcome columns are added from the data and params, so their names follow
-- params.yaml (categories: accessibility.amenities; outcomes: analysis.parties).
DO $$
DECLARE
    col text;
BEGIN
    FOR col IN SELECT DISTINCT category FROM analysis.district_access ORDER BY 1 LOOP
        EXECUTE format('ALTER TABLE analysis.indicators ADD COLUMN %I double precision',
                       'dist_' || col);
        EXECUTE format('UPDATE analysis.indicators AS i SET %I = a.mean_nearest_m
                        FROM analysis.district_access AS a
                        WHERE a.uwb = i.uwb AND a.category = %L', 'dist_' || col, col);
    END LOOP;
    FOR col IN SELECT DISTINCT outcome FROM analysis.outcome ORDER BY 1 LOOP
        EXECUTE format('ALTER TABLE analysis.indicators ADD COLUMN %I double precision', col);
        EXECUTE format('UPDATE analysis.indicators AS i SET %I = o.value
                        FROM analysis.outcome AS o
                        WHERE o.uwb = i.uwb AND o.outcome = %L AND o.method = %L',
                       col, col, current_setting('hgv.primary_method'));
    END LOOP;
END $$;

ALTER TABLE analysis.indicators ADD PRIMARY KEY (uwb);
CREATE INDEX indicators_geom_gix ON analysis.indicators USING gist (geom);
ANALYZE analysis.outcome, analysis.indicators;

-- Checks, copied into docs/validation_report.md by src/run_sql.py.
CREATE TABLE analysis.indicators_check (
    check_id  serial PRIMARY KEY,
    name      text NOT NULL,
    passed    boolean NOT NULL,
    detail    text NOT NULL
);

INSERT INTO analysis.indicators_check (name, passed, detail)
SELECT 'Parameters (information)', true,
       format('primary method %s; outcomes %s; contrast %s minus %s',
              current_setting('hgv.primary_method'),
              (SELECT string_agg(DISTINCT outcome, ', ') FROM analysis.outcome),
              current_setting('hgv.contrast_left'), current_setting('hgv.contrast_right'));

INSERT INTO analysis.indicators_check (name, passed, detail)
SELECT 'One row per station district', count(*) = (SELECT count(*) FROM clean.station_district),
       format('%s rows, %s station districts', count(*),
              (SELECT count(*) FROM clean.station_district))
FROM analysis.indicators;

-- Every configured party code must exist, or its share would silently be missing.
INSERT INTO analysis.indicators_check (name, passed, detail)
SELECT 'Every configured party code exists', count(*) = 0,
       format('%s unknown: %s', count(*), coalesce(string_agg(code, ', '), 'none'))
FROM (
    SELECT current_setting('hgv.parties_' || n) AS code
    FROM unnest(string_to_array(current_setting('hgv.parties'), '|')) AS n
    UNION
    SELECT unnest(string_to_array(current_setting('hgv.contrast_with_spd_left'), '|')
                  || string_to_array(current_setting('hgv.contrast_with_spd_right'), '|'))
) AS c
WHERE code NOT IN (SELECT party_code FROM clean.party);

INSERT INTO analysis.indicators_check (name, passed, detail)
SELECT 'Every district has every outcome for every method',
       count(*) = (SELECT count(*) FROM clean.station_district)
                  * ((SELECT cardinality(string_to_array(current_setting('hgv.parties'), '|'))) + 2)
                  * 4
                  + (SELECT count(*) FROM clean.station_district) * 3,
       format('%s rows (parties and contrasts for methods A, B, C, S; turnout for A, B, C)',
              count(*))
FROM analysis.outcome;

-- Votes summed over districts reproduce the official Berlin share of each configured party,
-- for every method that includes postal votes.
INSERT INTO analysis.indicators_check (name, passed, detail)
SELECT 'Vote-weighted shares reproduce the official Berlin shares (methods A, B, C)',
       max(abs(t.share - b.share)) < 1e-9,
       format('%s party x method comparisons, max difference %s', count(*),
              to_char(max(abs(t.share - b.share)), '9.9EEEE'))
FROM (
    SELECT v.method, v.party_code, sum(v.votes) / sum(sum(v.votes)) OVER (PARTITION BY v.method)
           AS share
    FROM analysis.district_votes AS v
    WHERE v.method <> 'S'
    GROUP BY v.method, v.party_code
) AS t
JOIN (
    SELECT item AS party_code,
           value::double precision / (SELECT value FROM clean.berlin_total WHERE item = 'valid')
           AS share
    FROM clean.berlin_total WHERE item ~ '^P[0-9]{2}$'
) AS b USING (party_code);

INSERT INTO analysis.indicators_check (name, passed, detail)
SELECT 'Shares and turnout within [0, 1]; contrasts within [-1, 1]',
       bool_and(CASE WHEN outcome LIKE 'contrast%' THEN value BETWEEN -1 AND 1
                     ELSE value BETWEEN 0 AND 1 END),
       format('%s values checked', count(*))
FROM analysis.outcome;

INSERT INTO analysis.indicators_check (name, passed, detail)
SELECT 'Districts with missing indicators (information)', true,
       format('no residential density %s (%s), no accessibility index %s (%s)',
              count(*) FILTER (WHERE density_residential IS NULL),
              coalesce(string_agg(uwb, ', ') FILTER (WHERE density_residential IS NULL), 'none'),
              count(*) FILTER (WHERE access_index IS NULL),
              coalesce(string_agg(uwb, ', ') FILTER (WHERE access_index IS NULL), 'none'))
FROM analysis.indicators;

INSERT INTO analysis.indicators_check (name, passed, detail)
SELECT 'Accessibility index (information)', true,
       format('mean %s, sd %s, min %s, max %s over %s districts',
              round(avg(access_index)::numeric, 3), round(stddev_samp(access_index)::numeric, 3),
              round(min(access_index)::numeric, 2), round(max(access_index)::numeric, 2),
              count(access_index))
FROM analysis.indicators;

INSERT INTO analysis.indicators_check (name, passed, detail)
SELECT 'Contrast across districts (information)', true,
       format('contrast min %s, median %s, max %s; %s districts with the left camp ahead',
              round(min(contrast)::numeric, 3),
              round((percentile_cont(0.5) WITHIN GROUP (ORDER BY contrast))::numeric, 3),
              round(max(contrast)::numeric, 3), count(*) FILTER (WHERE contrast > 0))
FROM analysis.indicators;
