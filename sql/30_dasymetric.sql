-- Dasymetric step: residential population and residential land per station district.
-- Umweltatlas blocks carry residents (ew2025). Blocks are intersected with station districts;
-- a block split by a district boundary passes residents to each piece in proportion to area.
-- Shares are normalised by the part of the block inside the district coverage, so residents of
-- blocks that overhang Berlin's outer boundary (a digitisation mismatch of a few m2) are kept.
-- Residential land is the union of pieces of residential blocks: at least hgv.min_block_residents
-- residents and a block type not listed in hgv.excluded_block_types (open land and transport
-- infrastructure). Residents of excluded blocks still count in district totals. Blocks exclude
-- street space, so residential land excludes streets.
-- Parameters are session settings set by src/run_sql.py from config/params.yaml:
--   hgv.min_block_residents   minimum residents for a block to count as residential
--   hgv.excluded_block_types  block types (typklar) never counted as residential, '|'-separated
--   hgv.min_piece_m2          pieces smaller than this are boundary slivers and are dropped
--   hgv.known_no_residential_land  station districts allowed to lack residential land, '|'-separated
-- Idempotent: all tables are dropped and rebuilt.

DROP TABLE IF EXISTS analysis.block_piece, analysis.district_population, analysis.dasymetric_check
    CASCADE;

-- One row per (block, district) intersection.
CREATE TABLE analysis.block_piece (
    schluessel   text NOT NULL REFERENCES clean.population_block,
    uwb          text NOT NULL REFERENCES clean.station_district,
    residential  boolean NOT NULL,           -- block meets the residential rule
    area_m2      double precision NOT NULL,  -- area of the piece
    block_share  double precision NOT NULL CHECK (block_share > 0 AND block_share <= 1 + 1e-9),
    residents    double precision NOT NULL,  -- block residents x block_share
    geom         geometry(MultiPolygon, 25833) NOT NULL,
    PRIMARY KEY (schluessel, uwb)
);

INSERT INTO analysis.block_piece
SELECT schluessel, uwb, residential, area_m2,
       area_m2 / sum(area_m2) OVER w,
       residents * area_m2 / sum(area_m2) OVER w,
       geom
FROM (
    SELECT b.schluessel, d.uwb,
           b.residents >= current_setting('hgv.min_block_residents')::int
               AND coalesce(b.block_type <> ALL (
                   string_to_array(current_setting('hgv.excluded_block_types'), '|')
               ), true) AS residential,
           b.residents,
           ST_Area(p.geom) AS area_m2,
           p.geom
    FROM clean.population_block AS b
    JOIN clean.station_district AS d ON ST_Intersects(b.geom, d.geom)
    CROSS JOIN LATERAL (
        -- Fast path: most blocks lie entirely inside one district and need no clipping.
        SELECT CASE WHEN ST_CoveredBy(b.geom, d.geom) THEN b.geom
                    ELSE ST_Multi(ST_CollectionExtract(ST_Intersection(b.geom, d.geom), 3))
               END AS geom
    ) AS p
) AS t
WHERE area_m2 >= current_setting('hgv.min_piece_m2')::double precision
WINDOW w AS (PARTITION BY schluessel);

CREATE INDEX block_piece_geom_gix ON analysis.block_piece USING gist (geom);
CREATE INDEX block_piece_uwb_idx ON analysis.block_piece (uwb);

-- One row per station district.
CREATE TABLE analysis.district_population (
    uwb                    text PRIMARY KEY REFERENCES clean.station_district,
    district_area_m2       double precision NOT NULL,
    block_area_m2          double precision NOT NULL,  -- all blocks, inhabited or not
    residential_area_m2    double precision NOT NULL,
    residents              double precision NOT NULL,  -- all residents in the district
    residential_residents  double precision NOT NULL,  -- residents of residential blocks
    density_gross          double precision NOT NULL,  -- residents per ha of district
    density_residential    double precision,  -- residential residents per ha of residential land
    residential_geom       geometry(MultiPolygon, 25833),  -- NULL when no residential land
    -- Population (2025) and register (2026) disagree: no residential land, or more eligible
    -- voters than residents. Population-weighted indicators are unreliable for these districts.
    population_mismatch    boolean NOT NULL
);

INSERT INTO analysis.district_population
SELECT d.uwb,
       ST_Area(d.geom),
       coalesce(p.block_area, 0),
       coalesce(p.res_area, 0),
       coalesce(p.residents, 0),
       coalesce(p.res_residents, 0),
       coalesce(p.residents, 0) / (ST_Area(d.geom) / 1e4),
       p.res_residents / nullif(p.res_area / 1e4, 0),
       p.res_geom,
       p.res_area IS NULL OR coalesce(p.res_residents, 0) = 0
           OR r.eligible > coalesce(p.residents, 0)
FROM clean.station_district AS d
JOIN clean.station_result AS r USING (uwb)
LEFT JOIN (
    SELECT uwb,
           sum(area_m2) AS block_area,
           sum(area_m2) FILTER (WHERE residential) AS res_area,
           sum(residents) AS residents,
           sum(residents) FILTER (WHERE residential) AS res_residents,
           ST_Multi(ST_CollectionExtract(ST_Union(geom) FILTER (WHERE residential), 3))
               AS res_geom
    FROM analysis.block_piece
    GROUP BY uwb
) AS p USING (uwb);

CREATE INDEX district_population_geom_gix
    ON analysis.district_population USING gist (residential_geom);

ANALYZE analysis.block_piece, analysis.district_population;

-- Checks, copied into docs/validation_report.md by src/run_sql.py.
CREATE TABLE analysis.dasymetric_check (
    check_id  serial PRIMARY KEY,
    name      text NOT NULL,
    passed    boolean NOT NULL,
    detail    text NOT NULL
);

INSERT INTO analysis.dasymetric_check (name, passed, detail)
SELECT 'Parameters (information)', true,
       format('min_block_residents %s, min_piece_m2 %s, %s excluded block types',
              current_setting('hgv.min_block_residents'), current_setting('hgv.min_piece_m2'),
              cardinality(string_to_array(current_setting('hgv.excluded_block_types'), '|')));

-- A misspelt type in params.yaml would silently exclude nothing.
INSERT INTO analysis.dasymetric_check (name, passed, detail)
SELECT 'Every excluded block type exists in the data', count(*) = 0,
       format('%s unknown: %s', count(*), coalesce(string_agg(t, '; '), 'none'))
FROM unnest(string_to_array(current_setting('hgv.excluded_block_types'), '|')) AS t
WHERE NOT EXISTS (SELECT 1 FROM clean.population_block WHERE block_type = t);

INSERT INTO analysis.dasymetric_check (name, passed, detail)
SELECT 'Residents conserved (blocks = sum over districts, within 1 resident)',
       abs(b.total - d.total) < 1,
       format('blocks %s, districts %s, difference %s', b.total, round(d.total::numeric, 3),
              round((b.total - d.total)::numeric, 3))
FROM (SELECT sum(residents)::double precision AS total FROM clean.population_block) AS b,
     (SELECT sum(residents) AS total FROM analysis.district_population) AS d;

INSERT INTO analysis.dasymetric_check (name, passed, detail)
SELECT 'Every populated block fully assigned (block shares sum to 1)',
       count(*) FILTER (WHERE abs(s - 1) > 1e-9) = 0,
       format('%s of %s populated blocks have shares summing outside 1 +/- 1e-9',
              count(*) FILTER (WHERE abs(s - 1) > 1e-9), count(*))
FROM (
    SELECT b.schluessel, coalesce(sum(p.block_share), 0) AS s
    FROM clean.population_block AS b
    LEFT JOIN analysis.block_piece AS p USING (schluessel)
    WHERE b.residents > 0
    GROUP BY b.schluessel
) AS g;

INSERT INTO analysis.dasymetric_check (name, passed, detail)
SELECT 'Block area outside the district coverage (information)', true,
       format('%s populated blocks extend beyond the coverage by more than 1 m2, '
              'max %s m2 (%s %% of the block), total %s m2; their residents are kept',
              count(*) FILTER (WHERE outside > 1), round(max(outside)::numeric, 1),
              round(max(100 * outside / area)::numeric, 2), round(sum(outside)::numeric))
FROM (
    SELECT ST_Area(b.geom) AS area, ST_Area(b.geom) - coalesce(sum(p.area_m2), 0) AS outside
    FROM clean.population_block AS b
    LEFT JOIN analysis.block_piece AS p USING (schluessel)
    WHERE b.residents > 0
    GROUP BY b.schluessel, b.geom
) AS g;

INSERT INTO analysis.dasymetric_check (name, passed, detail)
SELECT 'Blocks split by district boundaries (information)', true,
       format('%s of %s blocks fall in more than one district, holding %s residents (%s %% of all); '
              'their residents are divided by area',
              count(*), (SELECT count(*) FROM clean.population_block), sum(residents),
              round(100.0 * sum(residents) / (SELECT sum(residents) FROM clean.population_block), 2))
FROM clean.population_block AS b
WHERE (SELECT count(*) FROM analysis.block_piece AS p WHERE p.schluessel = b.schluessel) > 1;

INSERT INTO analysis.dasymetric_check (name, passed, detail)
SELECT 'Residents outside residential land (information)', true,
       format('%s residents (%s %%) live in blocks that fail the residential rule; '
              'they count in district residents but not in residential density',
              round(sum(residents - residential_residents)::numeric),
              round((100 * sum(residents - residential_residents) / sum(residents))::numeric, 2))
FROM analysis.district_population;

INSERT INTO analysis.dasymetric_check (name, passed, detail)
SELECT 'Every district has residential land, except listed known cases',
       count(*) FILTER (WHERE NOT known) = 0,
       format('%s districts without residential land (%s listed in known_no_residential_land, '
              '%s unexpected%s)',
              count(*), count(*) FILTER (WHERE known), count(*) FILTER (WHERE NOT known),
              coalesce(': ' || array_to_string((array_agg(uwb ORDER BY uwb)
                                                FILTER (WHERE NOT known))[1:20], ', '), ''))
FROM (
    SELECT uwb, uwb = ANY (string_to_array(current_setting('hgv.known_no_residential_land'), '|'))
               AS known
    FROM analysis.district_population
    WHERE residential_area_m2 = 0 OR residential_residents = 0
) AS g;

INSERT INTO analysis.dasymetric_check (name, passed, detail)
SELECT 'Districts flagged population_mismatch (information)', true,
       format('%s of %s districts, %s eligible voters (%s %% of all)%s',
              count(*) FILTER (WHERE p.population_mismatch), count(*),
              sum(r.eligible) FILTER (WHERE p.population_mismatch),
              round(100.0 * sum(r.eligible) FILTER (WHERE p.population_mismatch)
                    / sum(r.eligible), 2),
              coalesce(': ' || string_agg(p.uwb, ', ' ORDER BY p.uwb)
                                   FILTER (WHERE p.population_mismatch), ''))
FROM analysis.district_population AS p
JOIN clean.station_result AS r USING (uwb);

INSERT INTO analysis.dasymetric_check (name, passed, detail)
SELECT 'Residential land as share of district area (information)', true,
       format('Berlin %s %%; per district median %s %%, min %s %%, max %s %%',
              round((100 * sum(residential_area_m2) / sum(district_area_m2))::numeric, 1),
              round((100 * percentile_cont(0.5) WITHIN GROUP
                     (ORDER BY residential_area_m2 / district_area_m2))::numeric, 1),
              round((100 * min(residential_area_m2 / district_area_m2))::numeric, 1),
              round((100 * max(residential_area_m2 / district_area_m2))::numeric, 1))
FROM analysis.district_population;

-- Eligible voters (election register, 2026) against residents (2025): the ratio should sit
-- below 1 because minors and non-citizens are not eligible. Ratios above 1 flag a mismatch
-- between the two sources in that district.
INSERT INTO analysis.dasymetric_check (name, passed, detail)
SELECT 'Eligible voters vs residents per district (information)', true,
       format('eligible / residents: Berlin %s; per district median %s, p5 %s, p95 %s; '
              '%s districts above 1%s',
              round((sum(r.eligible) / sum(p.residents))::numeric, 3),
              round(percentile_cont(0.5) WITHIN GROUP (ORDER BY r.eligible / p.residents)::numeric, 3),
              round(percentile_cont(0.05) WITHIN GROUP (ORDER BY r.eligible / p.residents)::numeric, 3),
              round(percentile_cont(0.95) WITHIN GROUP (ORDER BY r.eligible / p.residents)::numeric, 3),
              count(*) FILTER (WHERE r.eligible > p.residents),
              coalesce(': ' || string_agg(format('%s (%s)', p.uwb,
                                          round((r.eligible / p.residents)::numeric, 2)), ', '
                                   ORDER BY p.uwb) FILTER (WHERE r.eligible > p.residents), ''))
FROM analysis.district_population AS p
JOIN clean.station_result AS r USING (uwb)
WHERE p.residents > 0;
