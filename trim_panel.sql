-- trim_panel.sql : remove every observation from 2024Q2 to 2026Q3 (all countries) from panel_20.csv and panel_20.duckdb
-- Run from this folder:   duckdb panel_20.duckdb < trim_panel.sql

CREATE OR REPLACE TABLE panel_csv AS
  SELECT * REPLACE (make_date(year::INTEGER, 3 * (q::INTEGER - 1) + 1, 1) AS quarter)
  FROM read_csv('panel_20.csv', header = true, types = {'quarter': 'VARCHAR', 'period': 'VARCHAR', 'rate_source': 'VARCHAR'});

SELECT 'before' AS stage, COUNT(*) AS rows, MIN(period) AS first_period, MAX(quarter) AS last_quarter FROM panel_csv;

DELETE FROM panel_csv WHERE quarter >= DATE '2024-04-01' AND quarter <= DATE '2026-07-01';
DELETE FROM panel     WHERE quarter >= DATE '2024-04-01' AND quarter <= DATE '2026-07-01';

COPY (SELECT * FROM panel_csv ORDER BY iso3, quarter) TO 'panel_20.csv' (HEADER, DELIMITER ',');
DROP TABLE panel_csv;

SELECT 'after (csv)' AS stage, COUNT(*) AS rows, COUNT(DISTINCT iso3) AS countries, COUNT(DISTINCT quarter) AS quarters, MAX(period) AS last_period
FROM read_csv('panel_20.csv', header = true, types = {'quarter': 'VARCHAR'})
UNION ALL
SELECT 'after (duckdb)', COUNT(*), COUNT(DISTINCT iso3), COUNT(DISTINCT quarter), MAX(period) FROM panel;
