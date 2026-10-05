-- Accessibility: share of each district's residential residents within hgv.buffer_m (Euclidean)
-- of each amenity category from OpenStreetMap.
--   1. Amenities (raw.osm_amenity, EPSG:4326, from src/osm_extract.py) are transformed to
--      EPSG:25833 and validated. Areas keep their shape, so distance is measured to their edge.
--   2. Per category, buffers are dissolved into one catchment and subdivided for indexing.
--   3. Each residential block piece (sql/30_dasymetric.sql) contributes residents x the share of
--      its area inside the catchment, the same uniform-density assumption as the dasymetric step.
--   4. A continuous companion: distance from each piece (ST_PointOnSurface) to the nearest
--      amenity of the category, averaged per district weighted by residents. At 500 m most
--      districts are fully covered for several categories, so the share alone has little spread.
-- Parameters are session settings set by src/run_sql.py from config/params.yaml:
--   hgv.buffer_m   walking distance as a straight-line buffer, metres
--   hgv.amenities  configured category names, '|'-separated
-- Idempotent: all tables are dropped and rebuilt.

DROP TABLE IF EXISTS
    analysis.amenity, analysis.amenity_catchment, analysis.piece_access, analysis.district_access,
    analysis.accessibility_check
    CASCADE;

CREATE TABLE analysis.amenity (
    amenity_id  serial PRIMARY KEY,
    category    text NOT NULL,
    osm_type    text NOT NULL CHECK (osm_type IN ('node', 'way', 'relation')),
    osm_id      bigint NOT NULL,
    name        text,
    tag         text NOT NULL,  -- the key=value that matched the category
    geom        geometry(Geometry, 25833) NOT NULL CHECK (ST_IsValid(geom)),
    UNIQUE (category, osm_type, osm_id)
);

INSERT INTO analysis.amenity (category, osm_type, osm_id, name, tag, geom)
SELECT category, osm_type, osm_id, name, tag,
       CASE WHEN ST_IsValid(g) THEN g ELSE ST_MakeValid(g) END
FROM (SELECT *, ST_Transform(geom, 25833) AS g FROM raw.osm_amenity) AS a;

CREATE INDEX amenity_geom_gix ON analysis.amenity USING gist (geom);

-- Dissolved catchment per category, subdivided into small polygons so the intersection with
-- block pieces can use the spatial index. Parts of one category do not overlap.
CREATE TABLE analysis.amenity_catchment (
    part_id   serial PRIMARY KEY,
    category  text NOT NULL,
    geom      geometry(Polygon, 25833) NOT NULL
);

INSERT INTO analysis.amenity_catchment (category, geom)
SELECT category, ST_Subdivide(ST_Union(ST_Buffer(geom, current_setting('hgv.buffer_m')::float8)), 256)
FROM analysis.amenity
GROUP BY category;

CREATE INDEX amenity_catchment_geom_gix ON analysis.amenity_catchment USING gist (geom);
CREATE INDEX amenity_catchment_category_idx ON analysis.amenity_catchment (category);
ANALYZE analysis.amenity, analysis.amenity_catchment;

-- Covered share of each residential block piece, per category.
CREATE TABLE analysis.piece_access (
    schluessel         text NOT NULL,
    uwb                text NOT NULL,
    category           text NOT NULL,
    residents          double precision NOT NULL,  -- residents of the piece
    covered_share      double precision NOT NULL CHECK (covered_share BETWEEN 0 AND 1 + 1e-9),
    residents_covered  double precision NOT NULL,
    nearest_m          double precision NOT NULL,  -- piece point on surface to nearest amenity
    PRIMARY KEY (schluessel, uwb, category),
    FOREIGN KEY (schluessel, uwb) REFERENCES analysis.block_piece
);

INSERT INTO analysis.piece_access
SELECT p.schluessel, p.uwb, c.category, p.residents,
       least(coalesce(x.covered_m2, 0) / p.area_m2, 1),
       p.residents * least(coalesce(x.covered_m2, 0) / p.area_m2, 1),
       n.nearest_m
FROM analysis.block_piece AS p
CROSS JOIN (SELECT DISTINCT category FROM analysis.amenity) AS c
-- Index-assisted nearest neighbour (<->), then the exact distance to that amenity.
CROSS JOIN LATERAL (
    SELECT ST_Distance(ST_PointOnSurface(p.geom), a.geom) AS nearest_m
    FROM analysis.amenity AS a
    WHERE a.category = c.category
    ORDER BY a.geom <-> ST_PointOnSurface(p.geom)
    LIMIT 1
) AS n
LEFT JOIN LATERAL (
    SELECT sum(CASE WHEN ST_CoveredBy(p.geom, k.geom) THEN p.area_m2
                    ELSE ST_Area(ST_Intersection(p.geom, k.geom)) END) AS covered_m2
    FROM analysis.amenity_catchment AS k
    WHERE k.category = c.category AND ST_Intersects(p.geom, k.geom)
) AS x ON true
WHERE p.residential;

-- One row per district and category. share is NULL where the district has no residential
-- residents (see population_mismatch in analysis.district_population).
CREATE TABLE analysis.district_access (
    uwb                text NOT NULL REFERENCES clean.station_district,
    category           text NOT NULL,
    residents          double precision NOT NULL,  -- residential residents
    residents_covered  double precision NOT NULL,
    share              double precision CHECK (share BETWEEN 0 AND 1 + 1e-9),
    mean_nearest_m     double precision,  -- residents-weighted mean distance to nearest amenity
    PRIMARY KEY (uwb, category)
);

INSERT INTO analysis.district_access
SELECT d.uwb, c.category, d.residential_residents, coalesce(a.covered, 0),
       coalesce(a.covered, 0) / nullif(d.residential_residents, 0),
       a.weighted_m / nullif(d.residential_residents, 0)
FROM analysis.district_population AS d
CROSS JOIN (SELECT DISTINCT category FROM analysis.amenity) AS c
LEFT JOIN (
    SELECT uwb, category, sum(residents_covered) AS covered,
           sum(nearest_m * residents) AS weighted_m
    FROM analysis.piece_access GROUP BY 1, 2
) AS a ON a.uwb = d.uwb AND a.category = c.category;

ANALYZE analysis.piece_access, analysis.district_access;

-- Checks, copied into docs/validation_report.md by src/run_sql.py.
CREATE TABLE analysis.accessibility_check (
    check_id  serial PRIMARY KEY,
    name      text NOT NULL,
    passed    boolean NOT NULL,
    detail    text NOT NULL
);

INSERT INTO analysis.accessibility_check (name, passed, detail)
SELECT 'OSM extract and parameters (information)', true,
       format('%s, replication timestamp %s, written by %s; buffer %s m; '
              '%s category rows dropped for access tags',
              file, replication_timestamp, writingprogram, current_setting('hgv.buffer_m'),
              dropped_access)
FROM raw.osm_meta;

INSERT INTO analysis.accessibility_check (name, passed, detail)
SELECT 'Every configured category has amenities', count(*) FILTER (WHERE n = 0) = 0,
       string_agg(format('%s %s', c, n), ', ' ORDER BY c)
FROM (
    SELECT c, (SELECT count(*) FROM analysis.amenity WHERE category = c) AS n
    FROM unnest(string_to_array(current_setting('hgv.amenities'), '|')) AS c
) AS g;

INSERT INTO analysis.accessibility_check (name, passed, detail)
SELECT 'Amenity geometries valid after transform', bool_and(ST_IsValid(geom)),
       format('%s rows (%s nodes, %s ways, %s relations), %s repaired with ST_MakeValid',
              count(*), count(*) FILTER (WHERE osm_type = 'node'),
              count(*) FILTER (WHERE osm_type = 'way'),
              count(*) FILTER (WHERE osm_type = 'relation'),
              (SELECT count(*) FROM raw.osm_amenity WHERE NOT ST_IsValid(geom)))
FROM analysis.amenity;

INSERT INTO analysis.accessibility_check (name, passed, detail)
SELECT 'Amenities outside the district coverage (information)', true,
       format('%s of %s amenity rows lie outside Berlin''s station districts (extract margin)',
              count(*) FILTER (WHERE NOT EXISTS (
                  SELECT 1 FROM clean.station_district AS d WHERE ST_Intersects(d.geom, a.geom))),
              count(*))
FROM analysis.amenity AS a;

INSERT INTO analysis.accessibility_check (name, passed, detail)
SELECT 'Covered residents never exceed residential residents',
       count(*) FILTER (WHERE residents_covered > residents + 1e-6) = 0,
       format('%s of %s district x category rows exceed',
              count(*) FILTER (WHERE residents_covered > residents + 1e-6), count(*))
FROM analysis.district_access;

INSERT INTO analysis.accessibility_check (name, passed, detail)
SELECT 'Residents within reach, Berlin (information)', true,
       string_agg(format('%s %s %%', category,
                         round((100 * covered / residents)::numeric, 1)), ', ' ORDER BY category)
FROM (
    SELECT category, sum(residents_covered) AS covered, sum(residents) AS residents
    FROM analysis.district_access GROUP BY category
) AS g;

INSERT INTO analysis.accessibility_check (name, passed, detail)
SELECT 'Districts with no resident in reach, per category (information)', true,
       string_agg(format('%s %s', category, n), ', ' ORDER BY category)
FROM (
    SELECT category, count(*) FILTER (WHERE share = 0) AS n
    FROM analysis.district_access GROUP BY category
) AS g;

-- The Geofabrik extract reaches beyond the state border by a margin of varying width, so
-- amenities just across the border are only partly included. This reports the margin and how
-- many residents live close enough to the border to be affected.
INSERT INTO analysis.accessibility_check (name, passed, detail)
SELECT 'Extract margin beyond the state boundary (information)', true,
       format('amenities outside Berlin lie up to %s m beyond the district coverage '
              '(median %s m); beyond that margin amenities are missing',
              round(max(d)::numeric), round(percentile_cont(0.5) WITHIN GROUP (ORDER BY d)::numeric))
FROM (
    SELECT ST_Distance(a.geom, b.g) AS d
    FROM analysis.amenity AS a, (SELECT ST_Union(geom) AS g FROM clean.station_district) AS b
    WHERE NOT ST_Intersects(a.geom, b.g)
) AS m;

INSERT INTO analysis.accessibility_check (name, passed, detail)
SELECT 'Residents near the Berlin boundary (information)', true,
       format('%s residential residents (%s %%) live in block pieces within %s m of the state '
              'boundary, where coverage may be undercounted if the extract margin is narrower',
              round(sum(p.residents)::numeric),
              round((100 * sum(p.residents)
                     / (SELECT sum(residents) FROM analysis.block_piece WHERE residential))::numeric, 2),
              current_setting('hgv.buffer_m'))
FROM analysis.block_piece AS p,
     -- Outer ring only: the coverage has sliver holes whose rings are not the state boundary.
     (SELECT ST_ExteriorRing(ST_GeometryN(ST_Union(geom), 1)) AS g
      FROM clean.station_district) AS b
WHERE p.residential
  AND ST_DWithin(p.geom, b.g, current_setting('hgv.buffer_m')::float8);

INSERT INTO analysis.accessibility_check (name, passed, detail)
SELECT 'Share saturation and distance spread across districts (information)', true,
       string_agg(format('%s: %s %% of districts fully covered, mean nearest distance p10/p50/p90 '
                         '%s/%s/%s m', category, round(100.0 * n_full / n, 1), p10, p50, p90),
                  '; ' ORDER BY category)
FROM (
    SELECT category, count(*) FILTER (WHERE share >= 0.999) AS n_full, count(share) AS n,
           round(percentile_cont(0.1) WITHIN GROUP (ORDER BY mean_nearest_m)::numeric) AS p10,
           round(percentile_cont(0.5) WITHIN GROUP (ORDER BY mean_nearest_m)::numeric) AS p50,
           round(percentile_cont(0.9) WITHIN GROUP (ORDER BY mean_nearest_m)::numeric) AS p90
    FROM analysis.district_access GROUP BY category
) AS g;
