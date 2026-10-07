-- Satellite indicators per station district: summer LST and NDVI from src/gee_extract.py.
-- raw.ee_zonal holds one row per (district, zone, indicator), zone being the residential land of
-- sql/30_dasymetric.sql or the whole district. Indicators are taken over residential land, unless
-- the district has none or its residential mask holds fewer effective Landsat pixels than
-- hgv.min_residential_pixels; then both LST and NDVI use the whole district and the row is
-- flagged, so the two indicators always describe the same area.
-- Parameters are session settings set by src/run_sql.py from config/params.yaml (imagery):
--   hgv.min_residential_pixels  effective 30 m pixels (area with data / 900 m2); must be set
-- Idempotent: all tables are dropped and rebuilt.

DO $$
BEGIN
    IF current_setting('hgv.min_residential_pixels', true) IS NULL
       OR current_setting('hgv.min_residential_pixels') !~ '^[0-9]+(\.[0-9]+)?$' THEN
        RAISE EXCEPTION 'imagery.min_residential_pixels is not set in config/params.yaml (got %)',
            current_setting('hgv.min_residential_pixels', true);
    END IF;
END $$;

DROP TABLE IF EXISTS analysis.district_satellite, analysis.satellite_check CASCADE;

CREATE TABLE analysis.district_satellite (
    uwb                 text PRIMARY KEY REFERENCES clean.station_district,
    zone                text NOT NULL CHECK (zone IN ('residential', 'district')),
    lst_mean            double precision NOT NULL,  -- degrees C, area-weighted
    lst_median          double precision NOT NULL,
    ndvi_mean           double precision NOT NULL CHECK (ndvi_mean BETWEEN -1 AND 1),
    ndvi_median         double precision NOT NULL CHECK (ndvi_median BETWEEN -1 AND 1),
    lst_pixels          double precision NOT NULL,  -- effective 30 m pixels in the zone used
    res_lst_pixels      double precision NOT NULL,  -- effective 30 m pixels in residential land
    lst_obs             double precision NOT NULL,  -- mean clear observations per pixel
    ndvi_obs            double precision NOT NULL,
    satellite_fallback  boolean NOT NULL  -- whole district used instead of residential land
);

WITH z AS (
    SELECT uwb, zone,
           max(mean) FILTER (WHERE indicator = 'lst') AS lst_mean,
           max(median) FILTER (WHERE indicator = 'lst') AS lst_median,
           max(mean) FILTER (WHERE indicator = 'ndvi') AS ndvi_mean,
           max(median) FILTER (WHERE indicator = 'ndvi') AS ndvi_median,
           max(n_eff_pixels) FILTER (WHERE indicator = 'lst') AS lst_pixels,
           max(mean_obs) FILTER (WHERE indicator = 'lst') AS lst_obs,
           max(mean_obs) FILTER (WHERE indicator = 'ndvi') AS ndvi_obs
    FROM raw.ee_zonal
    GROUP BY uwb, zone
),
pick AS (
    SELECT d.uwb,
           coalesce(r.lst_pixels, 0) AS res_lst_pixels,
           r.lst_mean IS NULL OR r.ndvi_mean IS NULL
               OR r.lst_pixels < current_setting('hgv.min_residential_pixels')::double precision
               AS fallback
    FROM clean.station_district AS d
    LEFT JOIN z AS r ON r.uwb = d.uwb AND r.zone = 'residential'
)
INSERT INTO analysis.district_satellite
SELECT p.uwb, z.zone, z.lst_mean, z.lst_median, z.ndvi_mean, z.ndvi_median, z.lst_pixels,
       p.res_lst_pixels, z.lst_obs, z.ndvi_obs, p.fallback
FROM pick AS p
JOIN z ON z.uwb = p.uwb AND z.zone = CASE WHEN p.fallback THEN 'district' ELSE 'residential' END;

ANALYZE analysis.district_satellite;

-- Checks, copied into docs/validation_report.md by src/run_sql.py.
CREATE TABLE analysis.satellite_check (
    check_id  serial PRIMARY KEY,
    name      text NOT NULL,
    passed    boolean NOT NULL,
    detail    text NOT NULL
);

INSERT INTO analysis.satellite_check (name, passed, detail)
SELECT 'Parameters and run (information)', true,
       format('min_residential_pixels %s; extracted %s with earthengine-api %s',
              current_setting('hgv.min_residential_pixels'), run_utc, ee_version)
FROM raw.ee_meta;

INSERT INTO analysis.satellite_check (name, passed, detail)
SELECT 'Every station district has whole-district LST and NDVI', count(*) = 0,
       format('%s of %s districts missing a value', count(*), (SELECT count(*) FROM clean.station_district))
FROM clean.station_district AS d
WHERE NOT EXISTS (SELECT 1 FROM raw.ee_zonal e WHERE e.uwb = d.uwb AND e.zone = 'district'
                  AND e.indicator = 'lst' AND e.mean IS NOT NULL)
   OR NOT EXISTS (SELECT 1 FROM raw.ee_zonal e WHERE e.uwb = d.uwb AND e.zone = 'district'
                  AND e.indicator = 'ndvi' AND e.mean IS NOT NULL);

INSERT INTO analysis.satellite_check (name, passed, detail)
SELECT 'Every district with residential land has a residential row', count(*) = 0,
       format('%s districts missing', count(*))
FROM analysis.district_population AS p
WHERE p.residential_geom IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM raw.ee_zonal e WHERE e.uwb = p.uwb AND e.zone = 'residential');

INSERT INTO analysis.satellite_check (name, passed, detail)
SELECT 'Every station district has satellite indicators',
       count(*) = (SELECT count(*) FROM clean.station_district),
       format('%s of %s districts', count(*), (SELECT count(*) FROM clean.station_district))
FROM analysis.district_satellite;

-- Summer daytime surface temperatures in Berlin lie well inside this range; values outside point
-- to a scale or unit error.
INSERT INTO analysis.satellite_check (name, passed, detail)
SELECT 'LST plausible (15 to 50 degrees C)', bool_and(lst_mean BETWEEN 15 AND 50),
       format('district means %s to %s, median %s',
              round(min(lst_mean)::numeric, 1), round(max(lst_mean)::numeric, 1),
              round((percentile_cont(0.5) WITHIN GROUP (ORDER BY lst_mean))::numeric, 1))
FROM analysis.district_satellite;

INSERT INTO analysis.satellite_check (name, passed, detail)
SELECT 'NDVI district means (information)', true,
       format('%s to %s, median %s',
              round(min(ndvi_mean)::numeric, 3), round(max(ndvi_mean)::numeric, 3),
              round((percentile_cont(0.5) WITHIN GROUP (ORDER BY ndvi_mean))::numeric, 3))
FROM analysis.district_satellite;

-- The area Earth Engine reduced must match the area PostGIS sent, which validates the geometry
-- transfer (transform, GeoJSON, reduction grid). NDVI is used because the Sentinel-2 composite has
-- no gaps; Landsat surface temperature has permanent no-data pixels (next check).
CREATE TEMP TABLE zone_area AS
SELECT e.uwb, e.zone, e.indicator, e.n_eff_pixels,
       e.n_eff_pixels * CASE e.indicator WHEN 'lst' THEN 900 ELSE 100 END / a.area_m2 AS ratio,
       a.area_m2
FROM raw.ee_zonal AS e
JOIN (
    SELECT uwb, 'residential' AS zone, residential_area_m2 AS area_m2
    FROM analysis.district_population WHERE residential_geom IS NOT NULL
    UNION ALL
    SELECT uwb, 'district', ST_Area(geom) FROM clean.station_district
) AS a USING (uwb, zone);

INSERT INTO analysis.satellite_check (name, passed, detail)
SELECT 'Earth Engine area matches PostGIS area (NDVI, within 2 %, zones of 1,000 m2 or more)',
       count(*) FILTER (WHERE abs(ratio - 1) > 0.02) = 0,
       format('%s of %s zones off by more than 2 %%; ratio min %s, median %s, max %s',
              count(*) FILTER (WHERE abs(ratio - 1) > 0.02), count(*),
              round(min(ratio)::numeric, 4),
              round((percentile_cont(0.5) WITHIN GROUP (ORDER BY ratio))::numeric, 4),
              round(max(ratio)::numeric, 4))
FROM zone_area WHERE indicator = 'ndvi' AND area_m2 >= 1000;

-- Landsat Collection 2 surface temperature is missing in some pixels of every scene (ST_B10
-- masked at the source while QA_PIXEL is clear), so LST describes the covered part of the zone.
INSERT INTO analysis.satellite_check (name, passed, detail)
SELECT 'LST data coverage of zones (information)', true,
       format('share of zone area with LST: min %s, p1 %s, median %s; %s of %s zones below 0.95 (%s residential, %s whole district): %s',
              round(min(ratio)::numeric, 3),
              round((percentile_cont(0.01) WITHIN GROUP (ORDER BY ratio))::numeric, 3),
              round((percentile_cont(0.5) WITHIN GROUP (ORDER BY ratio))::numeric, 3),
              count(*) FILTER (WHERE ratio < 0.95), count(*),
              count(*) FILTER (WHERE ratio < 0.95 AND zone = 'residential'),
              count(*) FILTER (WHERE ratio < 0.95 AND zone = 'district'),
              coalesce(string_agg(uwb || ' ' || left(zone, 3) || ' ' || round(ratio::numeric, 2),
                                  ', ' ORDER BY ratio) FILTER (WHERE ratio < 0.95), 'none'))
FROM zone_area WHERE indicator = 'lst' AND area_m2 >= 9000;

INSERT INTO analysis.satellite_check (name, passed, detail)
SELECT 'Effective LST pixels in residential land (information)', true,
       format('per district p1 %s, p5 %s, p25 %s, median %s; %s districts below 10, %s below 25, %s below 50',
              round((percentile_cont(0.01) WITHIN GROUP (ORDER BY res_lst_pixels))::numeric, 1),
              round((percentile_cont(0.05) WITHIN GROUP (ORDER BY res_lst_pixels))::numeric, 1),
              round((percentile_cont(0.25) WITHIN GROUP (ORDER BY res_lst_pixels))::numeric, 1),
              round((percentile_cont(0.5) WITHIN GROUP (ORDER BY res_lst_pixels))::numeric, 1),
              count(*) FILTER (WHERE res_lst_pixels < 10), count(*) FILTER (WHERE res_lst_pixels < 25),
              count(*) FILTER (WHERE res_lst_pixels < 50))
FROM analysis.district_satellite;

INSERT INTO analysis.satellite_check (name, passed, detail)
SELECT 'Districts using the whole district (information)', true,
       format('%s of %s districts, %s residents (%s %% of all): %s',
              count(*) FILTER (WHERE s.satellite_fallback), count(*),
              round(sum(p.residents) FILTER (WHERE s.satellite_fallback)),
              round((100 * sum(p.residents) FILTER (WHERE s.satellite_fallback)
                     / sum(p.residents))::numeric, 2),
              coalesce(string_agg(s.uwb, ', ' ORDER BY s.uwb) FILTER (WHERE s.satellite_fallback),
                       'none'))
FROM analysis.district_satellite AS s
JOIN analysis.district_population AS p USING (uwb);

INSERT INTO analysis.satellite_check (name, passed, detail)
SELECT 'Clear observations per district (information)', true,
       format('LST mean clear observations per pixel min %s, median %s; NDVI min %s, median %s',
              round(min(lst_obs)::numeric, 1),
              round((percentile_cont(0.5) WITHIN GROUP (ORDER BY lst_obs))::numeric, 1),
              round(min(ndvi_obs)::numeric, 1),
              round((percentile_cont(0.5) WITHIN GROUP (ORDER BY ndvi_obs))::numeric, 1))
FROM analysis.district_satellite;

-- Vegetation cools surfaces, so across districts LST and NDVI must rank in opposite order.
-- Spearman rho as the Pearson correlation of ranks.
INSERT INTO analysis.satellite_check (name, passed, detail)
SELECT 'LST and NDVI negatively related (Spearman rho < 0)', corr(rl, rn) < 0,
       format('rho %s over %s districts', round(corr(rl, rn)::numeric, 3), count(*))
FROM (
    SELECT rank() OVER (ORDER BY lst_mean) AS rl, rank() OVER (ORDER BY ndvi_mean) AS rn
    FROM analysis.district_satellite
) AS r;

INSERT INTO analysis.satellite_check (name, passed, detail)
SELECT 'Residential land minus whole district (information)', true,
       format('median difference LST %s degrees C, NDVI %s, over %s districts with both',
              round((percentile_cont(0.5) WITHIN GROUP (ORDER BY r.lst - d.lst))::numeric, 2),
              round((percentile_cont(0.5) WITHIN GROUP (ORDER BY r.ndvi - d.ndvi))::numeric, 3),
              count(*))
FROM (
    SELECT uwb, max(mean) FILTER (WHERE indicator = 'lst') AS lst,
           max(mean) FILTER (WHERE indicator = 'ndvi') AS ndvi
    FROM raw.ee_zonal WHERE zone = 'residential' GROUP BY uwb
) AS r
JOIN (
    SELECT uwb, max(mean) FILTER (WHERE indicator = 'lst') AS lst,
           max(mean) FILTER (WHERE indicator = 'ndvi') AS ndvi
    FROM raw.ee_zonal WHERE zone = 'district' GROUP BY uwb
) AS d USING (uwb);
