-- Schemas and typed tables for the cleaned sources.
--   raw       sources as delivered, all attributes as text (written by src/load_postgis.py)
--   clean     typed, keyed and constrained tables built from raw (sql/05_clean.sql)
--   analysis  derived tables: allocation, dasymetric, accessibility, indicators
-- Idempotent: clean tables are dropped and recreated on every run.

CREATE EXTENSION IF NOT EXISTS postgis;

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS clean;
CREATE SCHEMA IF NOT EXISTS analysis;

COMMENT ON SCHEMA raw IS 'Sources as delivered; attributes as text. See data/raw/manifest.csv.';
COMMENT ON SCHEMA clean IS 'Typed, keyed and constrained tables built from raw by sql/05_clean.sql.';
COMMENT ON SCHEMA analysis IS 'Derived tables: postal allocation, dasymetric, accessibility, indicators.';

DROP TABLE IF EXISTS
    clean.postal_votes, clean.station_votes, clean.postal_result, clean.station_result,
    clean.station_district, clean.postal_district, clean.party, clean.berlin_total,
    clean.population_block
    CASCADE;

-- Parties on the Zweitstimme ballot (codes P01..P80 without placeholder slots).
CREATE TABLE clean.party (
    party_code  text PRIMARY KEY CHECK (party_code ~ '^P[0-9]{2}$'),
    party_name  text NOT NULL
);

-- Postal districts (Briefwahlbezirke). No own geometry: each is the union of its stations.
CREATE TABLE clean.postal_district (
    bwb  text PRIMARY KEY CHECK (bwb ~ '^[0-9]{3}[A-Z]{1,2}$'),
    bez  text NOT NULL CHECK (bez ~ '^[0-9]{2}$')
);

-- Polling-station districts (Urnenwahlbezirke) with geometry, EPSG:25833.
CREATE TABLE clean.station_district (
    uwb   text PRIMARY KEY CHECK (uwb ~ '^[0-9]{5}$'),
    bez   text NOT NULL CHECK (bez ~ '^[0-9]{2}$'),
    bwb   text NOT NULL REFERENCES clean.postal_district,
    awk   text NOT NULL CHECK (awk ~ '^[0-9]{4}$'),
    bwk   text NOT NULL CHECK (bwk ~ '^[0-9]{2}$'),
    geom  geometry(MultiPolygon, 25833) NOT NULL CHECK (ST_IsValid(geom)),
    CHECK (left(uwb, 2) = bez AND left(bwb, 2) = bez)
);
CREATE INDEX station_district_geom_gix ON clean.station_district USING gist (geom);
CREATE INDEX station_district_bwb_idx ON clean.station_district (bwb);

-- Turnout and vote totals per station district. Eligible voters exist only here.
CREATE TABLE clean.station_result (
    uwb       text PRIMARY KEY REFERENCES clean.station_district,
    eligible  integer NOT NULL CHECK (eligible > 0),
    voters    integer NOT NULL CHECK (voters BETWEEN 0 AND eligible),
    valid     integer NOT NULL CHECK (valid >= 0),
    invalid   integer NOT NULL CHECK (invalid >= 0),
    CHECK (valid + invalid <= voters)
);

-- Totals per postal district (postal rows report no eligible voters).
CREATE TABLE clean.postal_result (
    bwb      text PRIMARY KEY REFERENCES clean.postal_district,
    voters   integer NOT NULL CHECK (voters >= 0),
    valid    integer NOT NULL CHECK (valid >= 0),
    invalid  integer NOT NULL CHECK (invalid >= 0),
    CHECK (valid + invalid <= voters)
);

-- Party votes in long format, one row per district and party.
CREATE TABLE clean.station_votes (
    uwb         text NOT NULL REFERENCES clean.station_result,
    party_code  text NOT NULL REFERENCES clean.party,
    votes       integer NOT NULL CHECK (votes >= 0),
    PRIMARY KEY (uwb, party_code)
);

CREATE TABLE clean.postal_votes (
    bwb         text NOT NULL REFERENCES clean.postal_result,
    party_code  text NOT NULL REFERENCES clean.party,
    votes       integer NOT NULL CHECK (votes >= 0),
    PRIMARY KEY (bwb, party_code)
);

-- Official Berlin-wide totals (A table, Gebietsart 'Bundesland'), the reconciliation target.
CREATE TABLE clean.berlin_total (
    item   text PRIMARY KEY,  -- 'eligible', 'voters', 'valid', 'invalid' or a party code
    value  bigint NOT NULL CHECK (value >= 0)
);

-- Umweltatlas population blocks 2025, EPSG:25833.
CREATE TABLE clean.population_block (
    schluessel   text PRIMARY KEY,
    residents    integer NOT NULL CHECK (residents >= 0),  -- ew2025
    area_m2      double precision NOT NULL CHECK (area_m2 > 0),  -- flalle as published
    block_type   text,  -- typklar
    geom         geometry(MultiPolygon, 25833) NOT NULL CHECK (ST_IsValid(geom))
);
CREATE INDEX population_block_geom_gix ON clean.population_block USING gist (geom);

COMMENT ON TABLE clean.station_district IS 'Urnenwahlbezirke AGH 2026 (RBS_OD_UWB_AH26), EPSG:25833.';
COMMENT ON TABLE clean.population_block IS 'Einwohnerdichte 2025 (Umweltatlas), WFS ua_einwohnerdichte_2025.';
COMMENT ON TABLE clean.berlin_total IS 'Official Berlin row of the A table, used to reconcile district sums.';
