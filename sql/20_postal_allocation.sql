-- Allocate postal votes (Briefwahlbezirke) to their polling-station districts (Urnenwahlbezirke).
-- A postal district has no geometry of its own; it is the union of 1 to 4 station districts.
-- Its votes are split among those stations by a weight w that sums to 1 per postal district:
--   A  w = station valid votes / sum of station valid votes in the postal district
--   B  w = station eligible voters / sum of eligible voters in the postal district
--   C  w = station Wahlschein holders (WberA2) / sum of Wahlschein holders in the postal district
--   S  station votes only, postal votes dropped (reference, not a full result)
-- Assumption shared by A to C: postal voters within one postal district split between its stations
-- in the same proportion for every party; only the size of each station's share differs.
-- C is the most direct proxy: postal ballots are requested with a Wahlschein, and no station voter
-- used one (Wahlsch = 0 in every station row).
-- Allocated values are fractional and kept unrounded so totals reconcile exactly.
-- Idempotent: all tables are dropped and rebuilt.

DROP TABLE IF EXISTS
    analysis.postal_weight, analysis.district_votes, analysis.district_result,
    analysis.allocation_check
    CASCADE;

CREATE TABLE analysis.postal_weight (
    uwb     text NOT NULL REFERENCES clean.station_district,
    method  char(1) NOT NULL CHECK (method IN ('A', 'B', 'C')),
    bwb     text NOT NULL REFERENCES clean.postal_district,
    weight  double precision NOT NULL CHECK (weight BETWEEN 0 AND 1),
    PRIMARY KEY (uwb, method)
);

INSERT INTO analysis.postal_weight (uwb, method, bwb, weight)
SELECT d.uwb, m.method, d.bwb,
       m.x / sum(m.x) OVER (PARTITION BY d.bwb, m.method)
FROM clean.station_district AS d
JOIN clean.station_result AS r USING (uwb)
CROSS JOIN LATERAL (
    VALUES ('A', r.valid::double precision),
           ('B', r.eligible::double precision),
           ('C', r.wahlschein::double precision)
) AS m (method, x);

-- Party votes per station district and method, long format.
CREATE TABLE analysis.district_votes (
    uwb         text NOT NULL REFERENCES clean.station_district,
    method      char(1) NOT NULL CHECK (method IN ('A', 'B', 'C', 'S')),
    party_code  text NOT NULL REFERENCES clean.party,
    votes       double precision NOT NULL CHECK (votes >= 0),
    PRIMARY KEY (uwb, method, party_code)
);

INSERT INTO analysis.district_votes (uwb, method, party_code, votes)
SELECT w.uwb, w.method, s.party_code, s.votes + w.weight * p.votes
FROM analysis.postal_weight AS w
JOIN clean.station_votes AS s USING (uwb)
JOIN clean.postal_votes AS p ON p.bwb = w.bwb AND p.party_code = s.party_code
UNION ALL
SELECT uwb, 'S', party_code, votes
FROM clean.station_votes;

-- Turnout and vote totals per station district and method. Eligible voters already include
-- postal voters, so turnout is only meaningful after allocation (A to C). For S, voters counts
-- station voters only and turnout is the station turnout.
CREATE TABLE analysis.district_result (
    uwb            text NOT NULL REFERENCES clean.station_district,
    method         char(1) NOT NULL CHECK (method IN ('A', 'B', 'C', 'S')),
    eligible       integer NOT NULL,
    voters         double precision NOT NULL,
    postal_voters  double precision NOT NULL,
    valid          double precision NOT NULL,
    invalid        double precision NOT NULL,
    turnout        double precision NOT NULL,  -- voters / eligible
    postal_share   double precision NOT NULL,  -- postal_voters / voters
    PRIMARY KEY (uwb, method)
);

INSERT INTO analysis.district_result
SELECT uwb, method, eligible, voters, postal_voters, valid, invalid,
       voters / eligible, postal_voters / nullif(voters, 0)
FROM (
    SELECT w.uwb, w.method, r.eligible,
           r.voters + w.weight * p.voters AS voters,
           w.weight * p.voters AS postal_voters,
           r.valid + w.weight * p.valid AS valid,
           r.invalid + w.weight * p.invalid AS invalid
    FROM analysis.postal_weight AS w
    JOIN clean.station_result AS r USING (uwb)
    JOIN clean.postal_result AS p ON p.bwb = w.bwb
    UNION ALL
    SELECT uwb, 'S', eligible, voters, 0, valid, invalid
    FROM clean.station_result
) AS t;

ANALYZE analysis.postal_weight, analysis.district_votes, analysis.district_result;

-- Checks, copied into docs/validation_report.md by src/run_sql.py.
CREATE TABLE analysis.allocation_check (
    check_id  serial PRIMARY KEY,
    name      text NOT NULL,
    passed    boolean NOT NULL,
    detail    text NOT NULL
);

INSERT INTO analysis.allocation_check (name, passed, detail)
SELECT 'Weights sum to 1 in every postal district and method',
       count(*) FILTER (WHERE abs(s - 1) > 1e-9) = 0,
       format('%s postal district x method groups, %s off by more than 1e-9',
              count(*), count(*) FILTER (WHERE abs(s - 1) > 1e-9))
FROM (SELECT bwb, method, sum(weight) AS s FROM analysis.postal_weight GROUP BY 1, 2) AS g;

INSERT INTO analysis.allocation_check (name, passed, detail)
SELECT 'No undefined weights (zero denominators)', count(*) = 0,
       format('%s station x method rows with NULL or NaN weight', count(*))
FROM analysis.postal_weight
WHERE weight IS NULL OR weight = 'NaN';

-- Each full method must reproduce the official Berlin totals for every party and for voters,
-- valid and invalid; S must reproduce the station sums.
WITH alloc AS (
    SELECT method, party_code AS item, sum(votes) AS value
    FROM analysis.district_votes GROUP BY 1, 2
    UNION ALL
    SELECT method, v.item, sum(v.value)
    FROM analysis.district_result
    CROSS JOIN LATERAL (VALUES ('eligible', eligible::double precision), ('voters', voters),
                               ('valid', valid), ('invalid', invalid)) AS v (item, value)
    GROUP BY 1, 2
),
diff AS (
    SELECT a.method, a.item, abs(a.value - b.value) AS d
    FROM alloc AS a
    JOIN clean.berlin_total AS b USING (item)
    WHERE a.method IN ('A', 'B', 'C')
)
INSERT INTO analysis.allocation_check (name, passed, detail)
SELECT format('Method %s reproduces the official Berlin row', method),
       max(d) < 1e-6,
       format('%s items compared, max absolute difference %s votes', count(*),
              to_char(max(d), 'FM0.000000000'))
FROM diff
GROUP BY method
ORDER BY method;

INSERT INTO analysis.allocation_check (name, passed, detail)
SELECT 'Method S equals station votes only', bool_and(a = s),
       format('S total %s, station total %s', sum(a), sum(s))
FROM (
    SELECT party_code, sum(votes) AS a FROM analysis.district_votes WHERE method = 'S' GROUP BY 1
) AS x
JOIN (SELECT party_code, sum(votes) AS s FROM clean.station_votes GROUP BY 1) AS y
    USING (party_code);

-- Within each postal district, the allocated postal votes must add back to the postal row.
INSERT INTO analysis.allocation_check (name, passed, detail)
SELECT 'Allocated postal votes add back to each postal district', max(d) < 1e-6,
       format('%s postal district x method x party groups, max difference %s', count(*),
              to_char(max(d), 'FM0.000000000'))
FROM (
    SELECT abs(sum(v.votes - s.votes) - p.votes) AS d
    FROM analysis.district_votes AS v
    JOIN clean.station_votes AS s USING (uwb, party_code)
    JOIN clean.station_district AS sd USING (uwb)
    JOIN clean.postal_votes AS p ON p.bwb = sd.bwb AND p.party_code = v.party_code
    WHERE v.method <> 'S'
    GROUP BY v.method, sd.bwb, v.party_code, p.votes
) AS g;

INSERT INTO analysis.allocation_check (name, passed, detail)
SELECT 'Turnout within [0, 1] after allocation', count(*) FILTER (WHERE turnout > 1) = 0,
       format('%s station x method rows above 1 (max %s)',
              count(*) FILTER (WHERE turnout > 1), round(max(turnout)::numeric, 3))
FROM analysis.district_result
WHERE method <> 'S';

-- Information: how far the weights disagree, the sensitivity that Phase 4 reports on.
INSERT INTO analysis.allocation_check (name, passed, detail)
SELECT 'Weight disagreement between methods (information)', true,
       format('median |w_A - w_C| %s, max %s; median |w_B - w_C| %s, max %s; '
              '%s of %s stations sit alone in their postal district (all weights 1)',
              round(percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(a - c))::numeric, 3),
              round(max(abs(a - c))::numeric, 3),
              round(percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(b - c))::numeric, 3),
              round(max(abs(b - c))::numeric, 3),
              count(*) FILTER (WHERE c = 1), count(*))
FROM (
    SELECT uwb,
           max(weight) FILTER (WHERE method = 'A') AS a,
           max(weight) FILTER (WHERE method = 'B') AS b,
           max(weight) FILTER (WHERE method = 'C') AS c
    FROM analysis.postal_weight GROUP BY uwb
) AS w;

INSERT INTO analysis.allocation_check (name, passed, detail)
SELECT 'Wahlschein holders vs postal voters per postal district (information)', true,
       format('postal voters / Wahlschein holders: median %s, min %s, max %s; '
              'Pearson r with postal voters: Wahlschein %s, eligible %s, station valid %s',
              round(percentile_cont(0.5) WITHIN GROUP (ORDER BY pv / ws)::numeric, 3),
              round(min(pv / ws)::numeric, 3), round(max(pv / ws)::numeric, 3),
              round(corr(pv, ws)::numeric, 3), round(corr(pv, el)::numeric, 3),
              round(corr(pv, va)::numeric, 3))
FROM (
    SELECT d.bwb, p.voters::double precision AS pv, sum(r.wahlschein)::double precision AS ws,
           sum(r.eligible)::double precision AS el, sum(r.valid)::double precision AS va
    FROM clean.station_district AS d
    JOIN clean.station_result AS r USING (uwb)
    JOIN clean.postal_result AS p ON p.bwb = d.bwb
    GROUP BY d.bwb, p.voters
) AS g;
