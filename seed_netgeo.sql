-- =====================================================================
-- NetGeo synthetic seed data
-- Run AFTER schema.sql.
--
--   psql -d netgeo -f seed_netgeo.sql                       (100,000 packages)
--   psql -d netgeo -v n_packages=10000 -f seed_netgeo.sql   (custom size)
--
-- Layout : 6 non-overlapping zones (3x2 grid over Singapore's lon/lat box)
-- Fleet  : 72 drivers (12/zone), 72 vehicles, 7 warehouses (1 decommissioned)
-- Demand : 5 Gaussian "neighbourhood hubs" + 3% uniform noise, so K-means
--          has real structure to find (true K = 5 while 6 zones are seeded)
-- Deterministic: setseed() makes the random data reproducible.
-- The timestamps are relative to now(), so re-run the seed before each benchmark.
-- =====================================================================

\set ON_ERROR_STOP on
\if :{?n_packages}
\else
  \set n_packages 100000
\endif

SELECT setseed(0.42);

TRUNCATE deliveries, packages, vehicles, drivers, zones, warehouses RESTART IDENTITY CASCADE;

-- ---------------------------------------------------------------------
-- 1. Zones: 3 columns x 2 rows, with 0.01 degree (~1.1 km) gaps between them.
--    The gaps are deliberate: the schema's exclusion constraint uses &&
--    (bounding-box overlap), which also rejects zones that only touch.
--    Points that land in a gap become "orphans" (see the orphans view).
-- ---------------------------------------------------------------------
INSERT INTO zones (name, status, boundary) VALUES
  ('Zone A', 'Active', ST_MakeEnvelope(103.620, 1.220, 103.745, 1.335, 4326)),  -- SW
  ('Zone B', 'Active', ST_MakeEnvelope(103.755, 1.220, 103.875, 1.335, 4326)),  -- S-central
  ('Zone C', 'Active', ST_MakeEnvelope(103.885, 1.220, 104.020, 1.335, 4326)),  -- SE
  ('Zone D', 'Active', ST_MakeEnvelope(103.620, 1.345, 103.745, 1.470, 4326)),  -- NW
  ('Zone E', 'Active', ST_MakeEnvelope(103.755, 1.345, 103.875, 1.470, 4326)),  -- N-central (no hub: near-empty)
  ('Zone F', 'Active', ST_MakeEnvelope(103.885, 1.345, 104.020, 1.470, 4326));  -- NE

-- ---------------------------------------------------------------------
-- 2. Warehouses: one active per zone (near the centre) + 1 decommissioned
--    inside Zone A to prove the trigger ignores decommissioned sites.
-- ---------------------------------------------------------------------
INSERT INTO warehouses (name, status, location) VALUES
  ('WH Tuas',        'Active',         ST_SetSRID(ST_MakePoint(103.680, 1.278), 4326)),
  ('WH Queenstown',  'Active',         ST_SetSRID(ST_MakePoint(103.815, 1.278), 4326)),
  ('WH Changi',      'Active',         ST_SetSRID(ST_MakePoint(103.950, 1.278), 4326)),
  ('WH Woodlands',   'Active',         ST_SetSRID(ST_MakePoint(103.680, 1.408), 4326)),
  ('WH Ang Mo Kio',  'Active',         ST_SetSRID(ST_MakePoint(103.815, 1.408), 4326)),
  ('WH Punggol',     'Active',         ST_SetSRID(ST_MakePoint(103.950, 1.408), 4326)),
  ('WH Jurong (old)','Decommissioned', ST_SetSRID(ST_MakePoint(103.700, 1.300), 4326));

-- ---------------------------------------------------------------------
-- 3. Drivers: 12 per zone (ids 1-12 -> Zone A, 13-24 -> Zone B, ...).
--    Drivers 12 and 48 are decommissioned.
-- ---------------------------------------------------------------------
INSERT INTO drivers (first_name, last_name, status, zone_id)
SELECT
  (ARRAY['Wei','Aisyah','Ravi','Mei','Farhan','Jia','Kumar','Siti','Daniel','Hui','Arjun','Nurul'])[1 + (g * 7) % 12],
  (ARRAY['Tan','Lim','Wong','Lee','Ng','Chua','Goh','Teo','Rahman','Singh','Ong','Koh'])[1 + (g * 5) % 12],
  CASE WHEN g IN (12, 48) THEN 'Decommissioned' ELSE 'Available' END::driver_status,
  1 + (g - 1) / 12
FROM generate_series(1, 72) g;

-- ---------------------------------------------------------------------
-- 4. Vehicles: one per driver (vehicle i <-> driver i).
--    Every 12th vehicle (offset 6) is in Maintenance; vehicles of
--    decommissioned drivers are decommissioned. Capacities fit NUMERIC(5,2).
-- ---------------------------------------------------------------------
INSERT INTO vehicles (model, vrn, driver_id, current_load, max_capacity, status)
SELECT
  (ARRAY['Suzuki Carry','Toyota Hiace','Isuzu NPR'])[1 + g % 3],
  'SGD' || lpad(((g * 37) % 9999)::text, 4, '0') || chr(65 + g % 26),
  g,
  0.00,
  (ARRAY[350.00, 700.00, 950.00])[1 + g % 3],
  CASE WHEN g IN (12, 48) THEN 'Decommissioned'
       WHEN g % 12 = 6    THEN 'Maintenance'
       ELSE 'Available' END::vehicle_status
FROM generate_series(1, 72) g;

-- ---------------------------------------------------------------------
-- 5. Packages (TIMED). trg_auto_zone_warehouse fires on every row.
--    85% delivered, 15% pending (some of these become 'Shipped' in step 6).
--    1.5% of delivered packages sit >1 km from their destination
--    (drives the "possibly missing" query).
-- ---------------------------------------------------------------------
CREATE TEMP TABLE hubs (id int, lon float8, lat float8, sigma float8, cum_weight float8);
INSERT INTO hubs VALUES
  (1, 103.680, 1.280, 0.018, 0.30),   -- West-South
  (2, 103.815, 1.285, 0.018, 0.55),   -- Central-South
  (3, 103.950, 1.280, 0.018, 0.75),   -- East-South
  (4, 103.680, 1.410, 0.018, 0.90),   -- West-North
  (5, 103.950, 1.410, 0.018, 1.00);   -- East-North

SELECT clock_timestamp() AS t0 \gset

WITH base AS (
  SELECT g AS n,
         random() AS u_hub, random() AS u1, random() AS u2, random() AS u_noise,
         random() AS u_lon, random() AS u_lat, random() AS u_status,
         random() AS u_weight, random() AS u_miss, random() AS u_dx, random() AS u_dy
  FROM generate_series(1, :n_packages) g
),
pts AS (
  SELECT b.*,
         CASE WHEN b.u_noise < 0.03
              THEN 103.62 + b.u_lon * 0.40
              ELSE h.lon + h.sigma * sqrt(-2 * ln(1 - b.u1)) * cos(2 * pi() * b.u2) END AS lon,
         CASE WHEN b.u_noise < 0.03
              THEN 1.22 + b.u_lat * 0.25
              ELSE h.lat + h.sigma * sqrt(-2 * ln(1 - b.u1)) * sin(2 * pi() * b.u2) END AS lat
  FROM base b
  JOIN hubs h ON h.id = (SELECT min(id) FROM hubs WHERE cum_weight >= b.u_hub)
)
INSERT INTO packages (weight, destination, current_location, status)
SELECT
  round((0.2 + power(u_weight, 2) * 29.8)::numeric, 2),
  ST_SetSRID(ST_MakePoint(lon, lat), 4326),
  CASE WHEN u_status < 0.85 AND u_miss < 0.015
       THEN ST_SetSRID(ST_MakePoint(lon + (u_dx - 0.5) * 0.06, lat + (u_dy - 0.5) * 0.06), 4326)  -- ~2-3 km off
       ELSE ST_SetSRID(ST_MakePoint(lon, lat), 4326) END,
  CASE WHEN u_status < 0.85 THEN 'Delivered' ELSE 'Pending' END::package_status
FROM pts;

SELECT :n_packages AS packages_inserted,
       round(extract(epoch FROM clock_timestamp() - :'t0'::timestamptz)::numeric, 2) AS seconds,
       round(:n_packages / extract(epoch FROM clock_timestamp() - :'t0'::timestamptz)) AS packages_per_sec_with_triggers;

-- Packages that are not yet delivered start their journey at their warehouse
-- (UPDATE OF current_location does not fire the destination trigger).
UPDATE packages p
SET current_location = w.location
FROM warehouses w
WHERE w.id = p.warehouse_id AND p.status <> 'Delivered';

-- ---------------------------------------------------------------------
-- 6. Deliveries. The delivery triggers are switched off for the bulk load
--    (history has to be loaded as-is) and switched back on at the end.
-- ---------------------------------------------------------------------
ALTER TABLE deliveries DISABLE TRIGGER USER;

-- 6a. Completed history: 1 delivery per delivered package, driver from the
--     package's zone, assigned within the last 90 days. Delivery time grows
--     with zone id so the `delays` view has something to rank.
WITH drv AS (
  SELECT d.id AS driver_id, d.zone_id, v.id AS vehicle_id,
         row_number() OVER (PARTITION BY d.zone_id ORDER BY d.id) - 1 AS k,
         count(*)     OVER (PARTITION BY d.zone_id)                 AS cnt
  FROM drivers d JOIN vehicles v ON v.driver_id = d.id
)
INSERT INTO deliveries (driver_id, vehicle_id, package_id, assigned_at, delivered_at)
SELECT drv.driver_id, drv.vehicle_id, p.id, ts.assigned_at,
       ts.assigned_at + make_interval(secs => 60 * (30 + random() * 150 * (0.6 + 0.2 * p.zone_id)))
FROM packages p
JOIN drv ON drv.zone_id = p.zone_id AND drv.k = p.id % drv.cnt
CROSS JOIN LATERAL (SELECT now() - random() * interval '90 days' AS assigned_at) ts
WHERE p.status = 'Delivered';

-- 6b. Open deliveries: up to 8 per zone, each with its own available driver
--     and vehicle. The first one in every zone was assigned 9-12 days ago (stuck).
WITH pend AS (
  SELECT id, zone_id, row_number() OVER (PARTITION BY zone_id ORDER BY id) AS rn
  FROM packages WHERE status = 'Pending'
),
drv AS (
  SELECT d.id AS driver_id, d.zone_id, v.id AS vehicle_id,
         row_number() OVER (PARTITION BY d.zone_id ORDER BY d.id) AS rn
  FROM drivers d JOIN vehicles v ON v.driver_id = d.id
  WHERE d.status = 'Available' AND v.status = 'Available'
)
INSERT INTO deliveries (driver_id, vehicle_id, package_id, assigned_at, delivered_at)
SELECT drv.driver_id, drv.vehicle_id, pend.id,
       CASE WHEN drv.rn = 1 THEN now() - interval '9 days' - random() * interval '3 days'
            ELSE now() - random() * interval '2 days' END,
       NULL
FROM pend JOIN drv ON pend.zone_id = drv.zone_id AND pend.rn = drv.rn
WHERE drv.rn <= 8;

-- 6c. Bring statuses in line with the open deliveries (what
--     trg_delivery_status_sync would have done), then re-enable the triggers.
UPDATE packages SET status = 'Shipped'
WHERE id IN (SELECT package_id FROM deliveries WHERE delivered_at IS NULL);

UPDATE drivers SET status = 'Busy'
WHERE id IN (SELECT driver_id FROM deliveries WHERE delivered_at IS NULL);

UPDATE vehicles v
SET status = 'In-Transit', current_load = p.weight
FROM deliveries d JOIN packages p ON p.id = d.package_id
WHERE d.vehicle_id = v.id AND d.delivered_at IS NULL;

ALTER TABLE deliveries ENABLE TRIGGER USER;

-- ---------------------------------------------------------------------
-- 7. Planner statistics (required for representative EXPLAIN ANALYZE) + summary
-- ---------------------------------------------------------------------
VACUUM ANALYZE;

SELECT 'warehouses' AS tbl, count(*) FROM warehouses UNION ALL
SELECT 'zones',      count(*) FROM zones      UNION ALL
SELECT 'drivers',    count(*) FROM drivers    UNION ALL
SELECT 'vehicles',   count(*) FROM vehicles   UNION ALL
SELECT 'packages',   count(*) FROM packages   UNION ALL
SELECT 'deliveries', count(*) FROM deliveries;

SELECT z.name, count(p.id) AS packages,
       count(*) FILTER (WHERE p.status = 'Pending')   AS pending,
       count(*) FILTER (WHERE p.status = 'Shipped')   AS shipped,
       count(*) FILTER (WHERE p.status = 'Delivered') AS delivered
FROM zones z LEFT JOIN packages p ON p.zone_id = z.id
GROUP BY z.name ORDER BY z.name;

SELECT (SELECT count(*) FROM orphans) AS orphan_packages;
