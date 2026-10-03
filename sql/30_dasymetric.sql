-- Dasymetric step: residential population and residential land per station district.
-- Umweltatlas blocks carry residents (ew2025). Blocks are intersected with station districts;
-- a block split by a district boundary passes residents to each piece in proportion to area.
-- Residential land is the union of pieces of blocks with at least hgv.min_block_residents
-- residents, so indicators can be computed over inhabited land rather than water, forest,
-- allotments or industry. Blocks exclude street space, so residential land excludes streets.
-- Parameters are session settings set by src/run_sql.py from config/params.yaml:
--   hgv.min_block_residents  minimum residents for a block to count as residential
--   hgv.min_piece_m2         pieces smaller than this are boundary slivers and are dropped
-- Idempotent: all tables are dropped and rebuilt.

DROP TABLE IF EXISTS analysis.block_piece, analysis.district_population, analysis.dasymetric_check
    CASCADE;

-- One row per (block, district) intersection.
CREATE TABLE analysis.block_piece (
    schluessel   text NOT NULL REFERENCES clean.population_block,
    uwb          text NOT NULL REFERENCES clean.station_district,
    residential  boolean NOT NULL,           -- block meets hgv.min_block_residents
    area_m2      double precision NOT NULL,  -- area of the piece
    block_share  double precision NOT NULL CHECK (block_share > 0 AND block_share <= 1 + 1e-9),
    residents    double precision NOT NULL,  -- block residents x block_share
    geom         geometry(MultiPolygon, 25833) NOT NULL,
    PRIMARY KEY (schluessel, uwb)
);

INSERT INTO analysis.block_piece
SELECT schluessel, uwb, residential, area_m2, area_m2 / block_area, residents * area_m2 / block_area,
       geom
FROM (
    SELECT b.schluessel, d.uwb,
           b.residents >= current_setting('hgv.min_block_residents')::int AS residential,
           b.residents,
           ST_Area(b.geom) AS block_area,
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
WHERE area_m2 >= current_setting('hgv.min_piece_m2')::double precision;

CREATE INDEX block_piece_geom_gix ON analysis.block_piece USING gist (geom);
CREATE INDEX block_piece_uwb_idx ON analysis.block_piece (uwb);

-- One row per station district.
CREATE TABLE analysis.district_population (
    uwb                  text PRIMARY KEY REFERENCES clean.station_district,
    district_area_m2     double precision NOT NULL,
    block_area_m2        double precision NOT NULL,  -- all blocks, inhabited or not
    residential_area_m2  double precision NOT NULL,
    residents            double precision NOT NULL,
    density_gross        double precision NOT NULL,  -- residents per ha of district
    density_residential  double precision,           -- residents per ha of residential land
    residential_geom     geometry(MultiPolygon, 25833)  -- NULL when no residential land
);

INSERT INTO analysis.district_population
SELECT d.uwb,
       ST_Area(d.geom),
       coalesce(p.block_area, 0),
       coalesce(p.res_area, 0),
       coalesce(p.residents, 0),
       coalesce(p.residents, 0) / (ST_Area(d.geom) / 1e4),
       p.residents / nullif(p.res_area / 1e4, 0),
       p.res_geom
FROM clean.station_district AS d
LEFT JOIN (
    SELECT uwb,
           sum(area_m2) AS block_area,
           sum(area_m2) FILTER (WHERE residential) AS res_area,
           sum(residents) AS residents,
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
       format('min_block_residents %s, min_piece_m2 %s',
              current_setting('hgv.min_block_residents'), current_setting('hgv.min_piece_m2'));

INSERT INTO analysis.dasymetric_check (name, passed, detail)
SELECT 'Residents conserved (blocks = sum over districts, within 1 resident)',
       abs(b.total - d.total) < 1,
       format('blocks %s, districts %s, difference %s', b.total, round(d.total::numeric, 3),
              round((b.total - d.total)::numeric, 3))
FROM (SELECT sum(residents)::double precision AS total FROM clean.population_block) AS b,
     (SELECT sum(residents) AS total FROM analysis.district_population) AS d;

INSERT INTO analysis.dasymetric_check (name, passed, detail)
SELECT 'Every populated block fully assigned (block shares sum to 1)',
       count(*) FILTER (WHERE abs(s - 1) > 1e-3) = 0,
       format('%s of %s populated blocks have shares summing outside 1 +/- 0.001 (min %s)',
              count(*) FILTER (WHERE abs(s - 1) > 1e-3), count(*), round(min(s)::numeric, 4))
FROM (
    SELECT b.schluessel, coalesce(sum(p.block_share), 0) AS s
    FROM clean.population_block AS b
    LEFT JOIN analysis.block_piece AS p USING (schluessel)
    WHERE b.residents > 0
    GROUP BY b.schluessel
) AS g;

INSERT INTO analysis.dasymetric_check (name, passed, detail)
SELECT 'Blocks split by district boundaries (information)', true,
       format('%s of %s blocks fall in more than one district, holding %s residents (%s %% of all)',
              count(*), (SELECT count(*) FROM clean.population_block), sum(residents),
              round(100.0 * sum(residents) / (SELECT sum(residents) FROM clean.population_block), 2))
FROM clean.population_block AS b
WHERE (SELECT count(*) FROM analysis.block_piece AS p WHERE p.schluessel = b.schluessel) > 1;

INSERT INTO analysis.dasymetric_check (name, passed, detail)
SELECT 'Every district has residential land and residents', count(*) = 0,
       format('%s districts without residential land%s', count(*),
              coalesce(': ' || array_to_string((array_agg(uwb ORDER BY uwb))[1:20], ', ')
                       || CASE WHEN count(*) > 20 THEN ', ...' ELSE '' END, ''))
FROM analysis.district_population
WHERE residential_area_m2 = 0 OR residents = 0;

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
              '%s districts above 1',
              round((sum(r.eligible) / sum(p.residents))::numeric, 3),
              round(percentile_cont(0.5) WITHIN GROUP (ORDER BY r.eligible / p.residents)::numeric, 3),
              round(percentile_cont(0.05) WITHIN GROUP (ORDER BY r.eligible / p.residents)::numeric, 3),
              round(percentile_cont(0.95) WITHIN GROUP (ORDER BY r.eligible / p.residents)::numeric, 3),
              count(*) FILTER (WHERE r.eligible > p.residents))
FROM analysis.district_population AS p
JOIN clean.station_result AS r USING (uwb)
WHERE p.residents > 0;
