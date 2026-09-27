-- Typical queries ran by users of the NetGeo database i.e. logistics coordinator/customer service/delivery driver

-- 1. Finding out where a package currently is for the customer 
--- Uses id primary key index to search
EXPLAIN ANALYZE 
SELECT current_location, status FROM packages
WHERE id = 1;

-- 2. Finding all pending packages
EXPLAIN ANALYZE
SELECT * FROM packages
WHERE status = 'Pending';

-- 3. Finding all packages in a zone e.g. zone A
EXPLAIN ANALYZE
SELECT * FROM packages
WHERE zone_id = 1;

-- 4. Finding all packages in a warehouse e.g. warehouse A
EXPLAIN ANALYZE
SELECT * FROM packages
WHERE warehouse_id = 1;

-- 5. Finding possibly stuck packages (not delivered for >= 7 days)
EXPLAIN ANALYZE
SELECT package_id FROM deliveries 
WHERE assigned_at <= CURRENT_TIMESTAMP - INTERVAL '7 days';

-- 6. Finding packages that are possibly missing (delivered yet dist between destination and current location is more than 1km)
EXPLAIN ANALYZE
SELECT id
FROM packages p
WHERE p.status = 'Delivered'
AND NOT ST_DWithin(p.destination::GEOGRAPHY, p.current_location::GEOGRAPHY, 1000);  
-- Convert to geography from geometry bacause geometry treats coords as flat 2d cartesian plane in degrees for SRID 4326 while geography treats coords as points on real spherical earth where distance calc are done in degrees. The geography datatype is however more costly in compute.
-- Also have to convert instead of having them as geography because the orphans view uses ST_Contains which does not support geography data type

-- 7. Getting the full delivery details for a package 
--- This includes driver id, first + last name, vehicle model, vehicle plate, assigned at, delivered_at
EXPLAIN ANALYZE
SELECT 
    dr.id, 
    dr.first_name, 
    dr.last_name, 
    v.model, 
    v.vrn, 
    d.assigned_at, 
    d.delivered_at
FROM deliveries d
JOIN drivers dr ON d.driver_id = dr.id
JOIN vehicles v ON d.vehicle_id = v.id
WHERE d.package_id = 1;

-- 8. Getting the package volume per zone
EXPLAIN ANALYZE
SELECT z.name, COUNT(p.id) AS package_count -- Has to be COUNT(p.id) because the left join will cause a zone with 0 packages to be reported as 1 if COUNT(*) is used
FROM zones z
LEFT JOIN packages p ON p.zone_id = z.id
GROUP BY z.name
ORDER BY package_count DESC;

-- 9. Getting all the drivers that are available (possibly to deploy more drivers to busier zones)
EXPLAIN ANALYZE
SELECT * FROM drivers 
WHERE status = 'Available'
AND NOT EXISTS (    -- Checking does this driver have any active undelivered delivery
    SELECT 1 FROM deliveries
    WHERE deliveries.driver_id = drivers.id  -- correlated to outer query
    AND delivered_at IS NULL
);

-- 10. Searching for all the orphan packages i.e. those that bypassed even the auto assigning of zones and warehouses (sorted by orphaned for the longest)
EXPLAIN ANALYZE 
SELECT o.id, d.assigned_at FROM orphans o
JOIN deliveries d ON d.package_id = o.id
ORDER BY d.assigned_at ASC; 


-- Video overview: <https://youtu.be/ziYXj9axdkc>