-- build_panel.sql : quarterly cross-sectional time-series (panel) dataset, 20 countries, from the three raw exports
--   gdp.csv          OECD quarterly GDP, two unlabelled measures per quarter (current- and constant-price PPP $)
--   cpi.csv          OECD year-on-year CPI inflation, percent
--   policy_rate.csv  BIS policy rates, monthly, percent
-- Run from this folder:   duckdb panel_20.duckdb < build_panel.sql
-- Outputs: panel_20.csv (the dataset), panel_20.duckdb (all intermediate tables), summary tables printed below.

-------------------------------------------------------------------------------
-- 0. Country list (edit here to change the panel). euro_from = month the ECB rate replaces the national rate.
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE countries (iso3 VARCHAR, country VARCHAR, bis_name VARCHAR, region VARCHAR, euro_from DATE);
INSERT INTO countries VALUES
  ('USA','United States','United States','North America',NULL),
  ('CAN','Canada',       'Canada',       'North America',NULL),
  ('MEX','Mexico',       'Mexico',       'North America',NULL),
  ('CHL','Chile',        'Chile',        'South America',NULL),
  ('JPN','Japan',        'Japan',        'Asia',         NULL),
  ('ZAF','South Africa', 'South Africa', 'Africa',       NULL),
  ('FRA','France',       'France',       'Europe, euro area', DATE '1999-01-01'),
  ('ITA','Italy',        'Italy',        'Europe, euro area', DATE '1999-01-01'),
  ('ESP','Spain',        'Spain',        'Europe, euro area', DATE '1999-01-01'),
  ('NLD','Netherlands',  'Netherlands',  'Europe, euro area', DATE '1999-01-01'),
  ('BEL','Belgium',      'Belgium',      'Europe, euro area', DATE '1999-01-01'),
  ('FIN','Finland',      'Finland',      'Europe, euro area', DATE '1999-01-01'),   -- Austria has only 3 CPI quarters in cpi.csv
  ('PRT','Portugal',     'Portugal',     'Europe, euro area', DATE '1999-01-01'),
  ('GRC','Greece',       'Greece',       'Europe, euro area', DATE '2001-01-01'),
  ('SWE','Sweden',       'Sweden',       'Europe',       NULL),
  ('NOR','Norway',       'Norway',       'Europe',       NULL),
  ('DNK','Denmark',      'Denmark',      'Europe',       NULL),
  ('CHE','Switzerland',  'Switzerland',  'Europe',       NULL),
  ('CZE','Czechia',      'Czechia',      'Europe',       NULL),
  ('HUN','Hungary',      'Hungary',      'Europe',       NULL);

-------------------------------------------------------------------------------
-- 1. Raw loads
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE gdp_raw AS
  SELECT REF_AREA AS iso3, TIME_PERIOD AS period, OBS_VALUE::DOUBLE AS value
  FROM read_csv('gdp.csv', header = true);

CREATE OR REPLACE TABLE cpi_raw AS
  SELECT REF_AREA AS iso3, TIME_PERIOD AS period, OBS_VALUE::DOUBLE AS value
  FROM read_csv('cpi.csv', header = true);

CREATE OR REPLACE TABLE rate_raw AS
  SELECT "References" AS bis_name, "Period" AS period_txt, TRY_CAST(value AS DOUBLE) AS value
  FROM read_csv('policy_rate.csv', header = true, types = {'Period': 'VARCHAR', 'value': 'VARCHAR'});

-- helper: '2019-Q3' -> first day of the quarter
CREATE OR REPLACE MACRO quarter_start(p) AS
  make_date(CAST(substr(p, 1, 4) AS INTEGER), 3 * (CAST(substr(p, 7, 1) AS INTEGER) - 1) + 1, 1);

-------------------------------------------------------------------------------
-- 2. GDP: pick the constant-price series out of the two unlabelled measures.
--    Sorted into lo/hi per quarter, the two series swap order once at the base year (2019-2022 for every unit).
--    Try every labelling that starts with hi or lo and switches at most once inside that window; keep the one
--    with the smoothest quarterly growth. The current-price series carries price swings, so it is rougher.
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE gdp_q AS
  SELECT iso3, quarter_start(period) AS quarter, MIN(value) AS lo, MAX(value) AS hi, COUNT(*) AS n
  FROM gdp_raw GROUP BY ALL;

CREATE OR REPLACE TABLE gdp_candidates AS
  SELECT DISTINCT quarter AS sw FROM gdp_q WHERE quarter BETWEEN DATE '2019-01-01' AND DATE '2022-10-01'
  UNION ALL SELECT NULL;

CREATE OR REPLACE TABLE gdp_scores AS
  WITH lab AS (
    SELECT q.iso3, q.quarter, c.sw, s.start_hi,
           CASE WHEN (c.sw IS NULL AND s.start_hi) OR (c.sw IS NOT NULL AND ((q.quarter < c.sw) = s.start_hi))
                THEN q.hi ELSE q.lo END AS vol
    FROM gdp_q q CROSS JOIN gdp_candidates c CROSS JOIN (VALUES (true), (false)) AS s(start_hi)
    WHERE q.n >= 2),
  g AS (
    SELECT iso3, sw, start_hi, ln(vol) - lag(ln(vol)) OVER (PARTITION BY iso3, sw, start_hi ORDER BY quarter) AS growth
    FROM lab)
  SELECT iso3, sw, start_hi, stddev_samp(growth) AS roughness FROM g GROUP BY ALL;

CREATE OR REPLACE TABLE gdp_best AS
  SELECT iso3, sw AS switch_quarter, start_hi, roughness
  FROM gdp_scores QUALIFY row_number() OVER (PARTITION BY iso3 ORDER BY roughness) = 1;

CREATE OR REPLACE TABLE gdp_volume AS
  SELECT q.iso3, q.quarter,
         CASE WHEN q.n = 1 AND b.iso3 IS NULL THEN q.hi                      -- clean single-measure file
              WHEN q.n < 2 THEN NULL                                          -- only one of two measures published
              WHEN (b.switch_quarter IS NULL AND b.start_hi)
                OR (b.switch_quarter IS NOT NULL AND ((q.quarter < b.switch_quarter) = b.start_hi)) THEN q.hi
              ELSE q.lo END AS gdp_volume,
         CASE WHEN q.n < 2 THEN NULL
              WHEN (b.switch_quarter IS NULL AND b.start_hi)
                OR (b.switch_quarter IS NOT NULL AND ((q.quarter < b.switch_quarter) = b.start_hi)) THEN q.lo
              ELSE q.hi END AS gdp_current
  FROM gdp_q q LEFT JOIN gdp_best b USING (iso3);

-------------------------------------------------------------------------------
-- 3. CPI: year-on-year inflation, already quarterly
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE cpi_q AS
  SELECT iso3, quarter_start(period) AS quarter, AVG(value) AS inflation_yoy FROM cpi_raw GROUP BY ALL;

-------------------------------------------------------------------------------
-- 4. Policy rate: monthly -> ECB splice for euro members -> forward-fill gaps -> quarterly mean
--    (a policy rate keeps its last setting until changed, so a missing month inherits the previous value)
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE rate_m AS
  SELECT bis_name,
         make_date(CASE WHEN yy >= 50 THEN 1900 + yy ELSE 2000 + yy END, mm, 1) AS month,
         AVG(value) AS rate
  FROM (SELECT bis_name, value,
               CAST(string_split(period_txt, '/')[1] AS INTEGER) AS mm,
               CAST(string_split(period_txt, '/')[3] AS INTEGER) AS yy
        FROM rate_raw WHERE value IS NOT NULL)
  GROUP BY ALL;

CREATE OR REPLACE TABLE rate_country_m AS
  WITH grid AS (
    SELECT c.iso3, CAST(m AS DATE) AS month
    FROM countries c CROSS JOIN (SELECT unnest(generate_series(DATE '1994-01-01', (SELECT max(month) FROM rate_m), INTERVAL 1 MONTH)) AS m)),
  obs AS (
    SELECT g.iso3, g.month,
           CASE WHEN c.euro_from IS NOT NULL AND g.month >= c.euro_from THEN 'ECB' ELSE 'national' END AS rate_source,
           CASE WHEN c.euro_from IS NOT NULL AND g.month >= c.euro_from THEN e.rate ELSE n.rate END AS rate_obs
    FROM grid g JOIN countries c USING (iso3)
    LEFT JOIN rate_m n ON n.bis_name = c.bis_name AND n.month = g.month
    LEFT JOIN rate_m e ON e.bis_name = 'Euro area'  AND e.month = g.month)
  SELECT iso3, month, rate_source, rate_obs,
         last_value(rate_obs IGNORE NULLS) OVER (PARTITION BY iso3 ORDER BY month ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS rate_filled
  FROM obs;

CREATE OR REPLACE TABLE rate_q AS
  SELECT iso3, CAST(date_trunc('quarter', month) AS DATE) AS quarter,
         AVG(rate_filled) AS policy_rate,
         SUM(CASE WHEN rate_obs IS NULL AND rate_filled IS NOT NULL THEN 1 ELSE 0 END) AS rate_months_filled,
         MAX(rate_source) AS rate_source
  FROM rate_country_m GROUP BY ALL;

-------------------------------------------------------------------------------
-- 5. The panel: one row per country-quarter on a common grid, NULL where a source has no value
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE panel AS
  WITH grid AS (
    SELECT c.iso3, q.quarter FROM countries c
    CROSS JOIN (SELECT DISTINCT quarter FROM gdp_q WHERE quarter >= DATE '1993-01-01') q)
  SELECT c.iso3, c.country, c.region, g.quarter,
         year(g.quarter) AS year, quarter(g.quarter) AS q,
         year(g.quarter)::VARCHAR || 'Q' || quarter(g.quarter)::VARCHAR AS period,
         v.gdp_volume, v.gdp_current,
         100 * (ln(v.gdp_volume) - lag(ln(v.gdp_volume))    OVER w) AS gdp_growth_qoq,
         100 * (ln(v.gdp_volume) - lag(ln(v.gdp_volume), 4) OVER w) AS gdp_growth_yoy,
         p.inflation_yoy,
         r.policy_rate, r.rate_source, r.rate_months_filled
  FROM grid g
  JOIN countries c USING (iso3)
  LEFT JOIN gdp_volume v ON v.iso3 = g.iso3 AND v.quarter = g.quarter
  LEFT JOIN cpi_q      p ON p.iso3 = g.iso3 AND p.quarter = g.quarter
  LEFT JOIN rate_q     r ON r.iso3 = g.iso3 AND r.quarter = g.quarter
  WINDOW w AS (PARTITION BY c.iso3 ORDER BY g.quarter)
  ORDER BY c.iso3, g.quarter;

COPY panel TO 'panel_20.csv' (HEADER, DELIMITER ',');

-------------------------------------------------------------------------------
-- 6. Summaries
-------------------------------------------------------------------------------
SELECT 'rows' AS what, COUNT(*) AS n FROM panel
UNION ALL SELECT 'countries', COUNT(DISTINCT iso3) FROM panel
UNION ALL SELECT 'quarters', COUNT(DISTINCT quarter) FROM panel;

-- GDP selection diagnostics: the implied price growth must be positive for every country
SELECT b.iso3, b.switch_quarter, b.start_hi, round(b.roughness * 100, 2) AS growth_sd_pct,
       round(100 * (ln(last(v.gdp_volume ORDER BY v.quarter)) - ln(first(v.gdp_volume ORDER BY v.quarter)))
             / ((count(*) - 1) / 4.0), 2) AS volume_growth_pct_yr,
       round(100 * (ln(last(v.gdp_current / v.gdp_volume ORDER BY v.quarter)) - ln(first(v.gdp_current / v.gdp_volume ORDER BY v.quarter)))
             / ((count(*) - 1) / 4.0), 2) AS price_growth_pct_yr
FROM gdp_best b JOIN gdp_volume v USING (iso3) WHERE v.gdp_volume IS NOT NULL GROUP BY ALL ORDER BY iso3;

-- Coverage per country: first and last quarter with each variable, and the window where all three are present
SELECT iso3, country,
       min(quarter) FILTER (gdp_volume IS NOT NULL)   AS gdp_from,   max(quarter) FILTER (gdp_volume IS NOT NULL)   AS gdp_to,
       min(quarter) FILTER (inflation_yoy IS NOT NULL) AS cpi_from,  max(quarter) FILTER (inflation_yoy IS NOT NULL) AS cpi_to,
       min(quarter) FILTER (policy_rate IS NOT NULL)  AS rate_from,  max(quarter) FILTER (policy_rate IS NOT NULL)  AS rate_to,
       min(quarter) FILTER (gdp_volume IS NOT NULL AND inflation_yoy IS NOT NULL AND policy_rate IS NOT NULL) AS all3_from,
       max(quarter) FILTER (gdp_volume IS NOT NULL AND inflation_yoy IS NOT NULL AND policy_rate IS NOT NULL) AS all3_to,
       sum(rate_months_filled) AS rate_months_filled
FROM panel GROUP BY ALL ORDER BY iso3;
