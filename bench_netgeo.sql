-- =====================================================================
-- NetGeo benchmark: median execution time, indexes ON vs OFF
-- Run AFTER seed_netgeo.sql:   psql -d netgeo -f bench_netgeo.sql
--
-- "Indexes OFF" = planner told not to use index/bitmap scans, i.e. a forced
-- sequential scan. No index is dropped, so nothing in the schema changes
-- (the one exception is the proposed partial index in step 5, which is
-- created only AFTER the as-is results and reported separately).
-- Numbers = median of 7 runs of EXPLAIN (ANALYZE), first run discarded as
-- warm-up. Absolute ms depend on your machine; the speedup ratio is what
-- matters. Re-run 2-3 times and quote the range you can reproduce.
-- =====================================================================

\set ON_ERROR_STOP on
\pset pager off

-- 1. Helper --------------------------------------------------------------
CREATE OR REPLACE FUNCTION bench_ms(q text, use_index boolean, runs int DEFAULT 7)
RETURNS numeric AS $$
DECLARE
  plan json;
  t numeric[] := '{}';
  i int;
BEGIN
  IF NOT use_index THEN
    PERFORM set_config('enable_indexscan',     'off', true);
    PERFORM set_config('enable_bitmapscan',    'off', true);
    PERFORM set_config('enable_indexonlyscan', 'off', true);
  END IF;

  FOR i IN 0..runs LOOP                       -- i = 0 is the discarded warm-up
    EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON) ' || q INTO plan;
    IF i > 0 THEN t := t || (plan->0->>'Execution Time')::numeric; END IF;
  END LOOP;

  PERFORM set_config('enable_indexscan',     'on', true);
  PERFORM set_config('enable_bitmapscan',    'on', true);
  PERFORM set_config('enable_indexonlyscan', 'on', true);

  RETURN (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY x) FROM unnest(t) x);
END;
$$ LANGUAGE plpgsql;

-- 2. Test inputs: a package that definitely has a delivery --------------------
SELECT package_id AS pid FROM deliveries OFFSET 40000 LIMIT 1 \gset

-- 3. The cases (Q1-Q10 from queries.sql, plus extras) -------------------------
CREATE TEMP TABLE bench_cases (label text PRIMARY KEY, query text);

INSERT INTO bench_cases VALUES
('Q01 package by id (PK)',
 'SELECT current_location, status FROM packages WHERE id = ' || :pid),

('Q02 pending packages',
 'SELECT * FROM packages WHERE status = ''Pending'''),

('Q03 packages in zone 1 (big zone)',
 'SELECT * FROM packages WHERE zone_id = 1'),

('Q03b packages in zone 5 (small zone)',
 'SELECT * FROM packages WHERE zone_id = 5'),

('Q04 packages in warehouse 1',
 'SELECT * FROM packages WHERE warehouse_id = 1'),

('Q05 stuck deliveries, AS WRITTEN (no delivered_at filter)',
 'SELECT package_id FROM deliveries WHERE assigned_at <= CURRENT_TIMESTAMP - INTERVAL ''7 days'''),

('Q05b stuck deliveries, CORRECTED',
 'SELECT package_id FROM deliveries WHERE delivered_at IS NULL AND assigned_at <= CURRENT_TIMESTAMP - INTERVAL ''7 days'''),

('Q06 possibly missing (geography cast)',
 'SELECT id FROM packages p WHERE p.status = ''Delivered'' AND NOT ST_DWithin(p.destination::GEOGRAPHY, p.current_location::GEOGRAPHY, 1000)'),

('Q07 full delivery details for one package',
 'SELECT dr.id, dr.first_name, dr.last_name, v.model, v.vrn, d.assigned_at, d.delivered_at
  FROM deliveries d JOIN drivers dr ON d.driver_id = dr.id JOIN vehicles v ON d.vehicle_id = v.id
  WHERE d.package_id = ' || :pid),

('Q08 package volume per zone',
 'SELECT z.name, COUNT(p.id) AS package_count FROM zones z LEFT JOIN packages p ON p.zone_id = z.id GROUP BY z.name ORDER BY package_count DESC'),

('Q09 available drivers with no open delivery',
 'SELECT * FROM drivers WHERE status = ''Available'' AND NOT EXISTS (SELECT 1 FROM deliveries WHERE deliveries.driver_id = drivers.id AND delivered_at IS NULL)'),

('Q10 orphan packages by age',
 'SELECT o.id, d.assigned_at FROM orphans o JOIN deliveries d ON d.package_id = o.id ORDER BY d.assigned_at ASC'),

('G01 packages within ~500 m of a point (GiST)',
 'SELECT count(*) FROM packages WHERE ST_DWithin(destination, ST_SetSRID(ST_MakePoint(103.68, 1.28), 4326), 0.0045)'),

('G02 packages inside zone 5 boundary (GiST containment)',
 'SELECT count(*) FROM packages p JOIN zones z ON ST_Contains(z.boundary, p.destination) WHERE z.id = 5');

-- 4. Run on the schema AS-IS ------------------------------------------------------------------
SELECT (SELECT count(*) FROM packages)   AS packages,
       (SELECT count(*) FROM deliveries) AS deliveries;

SELECT label,
       w                      AS with_index_ms,
       n                      AS no_index_ms,
       round(n / NULLIF(w, 0), 1) AS speedup_x
FROM (
  SELECT label,
         round(bench_ms(query, true), 3)  AS w,
         round(bench_ms(query, false), 3) AS n
  FROM bench_cases
) t
ORDER BY label;

-- 5. PROPOSED index (NOT in schema.sql). Q05 and Q09 only care about OPEN
--    deliveries (delivered_at IS NULL), so index just those rows.
--    Compare these two rows with the same labels in the table above.
CREATE INDEX IF NOT EXISTS idx_deliveries_open
  ON deliveries (assigned_at) WHERE delivered_at IS NULL;
ANALYZE deliveries;

SELECT label || '  [+ idx_deliveries_open]' AS label,
       w AS with_index_ms, n AS no_index_ms, round(n / NULLIF(w, 0), 1) AS speedup_x
FROM (
  SELECT label,
         round(bench_ms(query, true), 3)  AS w,
         round(bench_ms(query, false), 3) AS n
  FROM bench_cases
  WHERE label LIKE 'Q05b%' OR label LIKE 'Q09%'
) t
ORDER BY label;
