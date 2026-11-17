-- patch_us_cpi.sql : fill United States inflation_yoy in panel_20.csv from US_CPI.csv
--   US_CPI.csv = FRED series CPALTT01USM657N: CPI all items, percent change from previous month, not seasonally adjusted
--   Steps: chain the monthly changes into an index (Jan 1993 = 100) -> quarterly average index
--          -> year-on-year percent change (same definition as the OECD quarterly series in cpi.csv)
--          -> write into the USA rows of panel_20.csv (and the panel table in panel_20.duckdb)
-- Run from this folder:   duckdb panel_20.duckdb < patch_us_cpi.sql

CREATE OR REPLACE TABLE us_cpi_m AS
  SELECT make_date(CASE WHEN yy >= 50 THEN 1900 + yy ELSE 2000 + yy END, mm, 1) AS month, g
  FROM (SELECT CAST(string_split(observation_date, '/')[1] AS INTEGER) AS mm,
               CAST(string_split(observation_date, '/')[3] AS INTEGER) AS yy,
               TRY_CAST(CPALTT01USM657N AS DOUBLE) AS g
        FROM read_csv('US_CPI.csv', header = true, types = {'observation_date': 'VARCHAR', 'CPALTT01USM657N': 'VARCHAR'}));

-- sanity: months, range, missing values (a missing month would break the chained index)
SELECT COUNT(*) AS months, MIN(month) AS first_month, MAX(month) AS last_month, COUNT(*) FILTER (g IS NULL) AS missing FROM us_cpi_m;

CREATE OR REPLACE TABLE us_cpi_index AS
  SELECT month, 100 * exp(SUM(ln(1 + g / 100)) OVER (ORDER BY month ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS idx
  FROM (SELECT CAST((SELECT MIN(month) FROM us_cpi_m) - INTERVAL 1 MONTH AS DATE) AS month, 0.0 AS g   -- base month
        UNION ALL SELECT month, g FROM us_cpi_m);

CREATE OR REPLACE TABLE us_cpi_q AS
  WITH q AS (SELECT CAST(date_trunc('quarter', month) AS DATE) AS quarter, AVG(idx) AS idx
             FROM us_cpi_index GROUP BY ALL HAVING COUNT(*) = 3)                         -- complete quarters only
  SELECT quarter, 100 * (idx / lag(idx, 4) OVER (ORDER BY quarter) - 1) AS inflation_yoy FROM q
  QUALIFY inflation_yoy IS NOT NULL;

-- the CSV, patched in place
-- read the quarter column as text and rebuild the date from the year and q columns: a spreadsheet app may have
-- re-saved the CSV with m/d/yy dates, which a CSV sniffer can read with month and day swapped
CREATE OR REPLACE TABLE panel_csv AS
  SELECT * REPLACE (make_date(year::INTEGER, 3 * (q::INTEGER - 1) + 1, 1) AS quarter)
  FROM read_csv('panel_20.csv', header = true, types = {'quarter': 'VARCHAR', 'period': 'VARCHAR', 'rate_source': 'VARCHAR'});
UPDATE panel_csv SET inflation_yoy = u.inflation_yoy FROM us_cpi_q u
  WHERE panel_csv.iso3 = 'USA' AND panel_csv.quarter = u.quarter;
COPY (SELECT * FROM panel_csv ORDER BY iso3, quarter) TO 'panel_20.csv' (HEADER, DELIMITER ',');

-- keep the database's panel table in step with the CSV
UPDATE panel SET inflation_yoy = u.inflation_yoy FROM us_cpi_q u
  WHERE panel.iso3 = 'USA' AND panel.quarter = u.quarter;
DROP TABLE panel_csv;

-- result
SELECT COUNT(*) FILTER (inflation_yoy IS NOT NULL) AS us_quarters_filled,
       MIN(quarter) FILTER (inflation_yoy IS NOT NULL) AS from_q, MAX(quarter) FILTER (inflation_yoy IS NOT NULL) AS to_q
FROM panel WHERE iso3 = 'USA';
SELECT period, round(inflation_yoy, 2) AS us_inflation_yoy FROM panel
WHERE iso3 = 'USA' AND period IN ('1994Q1','2000Q1','2008Q3','2009Q3','2015Q1','2021Q4','2022Q2','2023Q4','2024Q1','2024Q2') ORDER BY quarter;
