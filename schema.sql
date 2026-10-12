--- TODO: Python script for the automation for finding the best zones divisions, warehouses, drivers to use for every delivery to maximise effiency using k-means clustering (use sci-kit learn)


-- Create the database 
--- CREATE DATABASE netgeo

-- Use the database
--- \c netgeo

-- Dropping tables
--- DROP in the opposite order in which they are created for data hierarchy i.e. deliveries is the child of everything else
--- CASCADE helps to circumvent the foreign key constraint 
--- E.g. packages references the zone id so CASCADE drops packages first then zones table 
DROP TABLE IF EXISTS deliveries CASCADE;
DROP TABLE IF EXISTS packages CASCADE;
DROP TABLE IF EXISTS drivers CASCADE;
DROP TABLE IF EXISTS vehicles CASCADE;
DROP TABLE IF EXISTS zones CASCADE;
DROP TABLE IF EXISTS warehouses CASCADE;

-- Dropping roles 
DROP ROLE IF EXISTS tom_coordinator;
DROP ROLE IF EXISTS jack_driver;
DROP ROLE IF EXISTS logistics_coordinator;
DROP ROLE IF EXISTS delivery_driver;

-- Adding in the extension needed for the geometry data type 
CREATE EXTENSION IF NOT EXISTS postgis;

 
---------------------------- TABLES ----------------------------

-- Table for warehouses 
DROP TYPE IF EXISTS warehouse_status;
CREATE TYPE warehouse_status AS ENUM('Active', 'Decommissioned'); 

--- The status column lets one know if the warehouse is still in use and if not, new packages will not be assigned to it 
--- It also protects old data since if you accidentally delete the decommissioned warehouse from the database, the historical data from that warehouse will not be deleted/orphaned i.e. data that is not attached to any warehouse (soft deletion)

CREATE TABLE warehouses (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    status warehouse_status NOT NULL,
    location GEOMETRY(POINT, 4326) NOT NULL
);

-- Table for delivery zones
DROP TYPE IF EXISTS zone_status;
CREATE TYPE zone_status AS ENUM('Active', 'Decommissioned'); 

CREATE TABLE zones (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    status zone_status NOT NULL,
    boundary GEOMETRY(POLYGON, 4326) NOT NULL
    -- Overlap between active zones is enforced by trg_zones_no_overlap (see TRIGGERS section).
    -- An EXCLUDE ... WITH && constraint was NOT used: && compares bounding boxes only, so it
    -- rejects valid zones whose boxes overlap even though the shapes do not.
);

-- Table for drivers
DROP TYPE IF EXISTS driver_status;
CREATE TYPE driver_status AS ENUM('Available', 'Busy', 'Decommissioned');

CREATE TABLE drivers (
    id SERIAL PRIMARY KEY,
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    status driver_status NOT NULL,
    zone_id INT,
    
    -- Relationships
    FOREIGN KEY(zone_id) REFERENCES zones(id) ON DELETE RESTRICT
);

-- Table for vehicles (tracking of the fleet)
DROP TYPE IF EXISTS vehicle_status;
CREATE TYPE vehicle_status AS ENUM('Available', 'In-Transit', 'Maintenance', 'Decommissioned');

CREATE TABLE vehicles (
    id SERIAL PRIMARY KEY,
    model TEXT NOT NULL,
    vrn TEXT NOT NULL UNIQUE, -- Represents the license plate for the vehicle 
    driver_id INT,
    current_load NUMERIC(5,2) NOT NULL DEFAULT 0.00,
    max_capacity NUMERIC(5,2) NOT NULL,
    status vehicle_status NOT NULL,

    -- Relationships
    FOREIGN KEY(driver_id) REFERENCES drivers(id) ON DELETE RESTRICT
);

-- Table for packages (this table has auto inserts for zone and warehouse id, specifying when adding in a new row to the table is not necessary)
DROP TYPE IF EXISTS package_status;
CREATE TYPE package_status AS ENUM('Pending', 'Shipped', 'Delivered');

CREATE TABLE packages (
    id SERIAL PRIMARY KEY,
    weight NUMERIC(5,2) NOT NULL,
    destination GEOMETRY(POINT, 4326) NOT NULL, -- Refers to the correct recipient address
    current_location GEOMETRY(POINT, 4326) NOT NULL,    -- Refers to the current location be it wrong or correct
    status package_status NOT NULL,
    zone_id INT,
    warehouse_id INT,

    -- Relationships
    FOREIGN KEY(zone_id) REFERENCES zones(id) ON DELETE RESTRICT,
    FOREIGN KEY(warehouse_id) REFERENCES warehouses(id) ON DELETE RESTRICT
);

-- Table for deliveries (A join table that links the tables)
CREATE TABLE deliveries (
    id SERIAL PRIMARY KEY,
    driver_id INT,
    vehicle_id INT,
    package_id INT,
    assigned_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,    -- To keep track of when the delivery was assigned to the driver 
    delivered_at TIMESTAMPTZ,   -- To keep track at when the package was marked as delivered

    -- Relationships
    FOREIGN KEY (driver_id) REFERENCES drivers(id) ON DELETE RESTRICT,  -- RESTRICT blocks hard deletion to ensure no orphaned data (zones, warehouses, drivers and vehicles should not be hard deleted)
    FOREIGN KEY (vehicle_id) REFERENCES vehicles(id) ON DELETE RESTRICT,
    FOREIGN KEY (package_id) REFERENCES packages(id) ON DELETE CASCADE  -- Using CASCADE here since packages should be able to be deleted e.g. package is cancelled. If the package is deleted, CASCADE deletes the rows relating to the package in this deliveries table 
);


------------ VIEWS (Dashboard for tracking of important information) -------------

-- 1. View to see which zones experience the most delay in delivery times (in mins)
DROP VIEW IF EXISTS delays;

CREATE VIEW delays AS
SELECT z.name, AVG(EXTRACT(EPOCH FROM (d.delivered_at - d.assigned_at)) / 60) AS avg_delivery_time
FROM deliveries d
JOIN packages p ON d.package_id = p.id
JOIN zones z ON p.zone_id = z.id
WHERE d.delivered_at IS NOT NULL 
GROUP BY z.name
ORDER BY avg_delivery_time DESC;

-- 2. View to find orphan packages (packages that are not within any zones)
--- This is needed because there may be areas that do not fall within any zones (algo limitation) --> easy to manually assign them to nearby zones
DROP VIEW IF EXISTS orphans;

CREATE VIEW orphans AS 
SELECT 
    p.id, 
    p.destination, 
    COALESCE(z.name, 'Unassigned') AS zone_name -- COALESCE returns first value within the brackets that is not NULL
FROM packages p
LEFT JOIN zones z ON ST_Contains(z.boundary, p.destination)   -- Left join preserves package id regardless if they have a zone assigned, ST_Contains checks the destination against every boundary you have 
WHERE z.name IS NULL;

-- 3. View to determine if you need more small vans or larger trucks in specific zones
DROP VIEW IF EXISTS fleet_management;

CREATE VIEW fleet_management AS
SELECT 
    v.id, 
    v.model, 
    v.max_capacity, 
    p.zone_id, 
    SUM(p.weight) AS total_package_weight, 
    (v.max_capacity - SUM(p.weight)) AS difference
FROM deliveries d
JOIN vehicles v ON d.vehicle_id = v.id
JOIN packages p ON d.package_id = p.id
WHERE v.status != 'Decommissioned'
GROUP BY v.id, v.model, v.max_capacity, p.zone_id
ORDER BY p.zone_id;


---------------------------- INDEXES (Optimisation) ----------------------------

-- 1. GIST INDEXES for the columns using GEOMETRY data type --> faster search for package-in-zone cases 
DROP INDEX IF EXISTS idx_zones_boundary;
CREATE INDEX idx_zones_boundary ON zones USING GIST (boundary);

DROP INDEX IF EXISTS idx_warehouses_location;
CREATE INDEX idx_warehouses_location ON warehouses USING GIST (location);

DROP INDEX IF EXISTS idx_packages_destination;
CREATE INDEX idx_packages_destination ON packages USING GIST (destination);

DROP INDEX IF EXISTS idx_packages_current_location;
CREATE INDEX idx_packages_current_location ON packages USING GIST (current_location);

-- 2. Regular indexes for those (for columns using enum --> likely to be commonly searched for)
DROP INDEX IF EXISTS idx_drivers_status;
CREATE INDEX idx_drivers_status ON drivers (status);

DROP INDEX IF EXISTS idx_vehicles_status;
CREATE INDEX idx_vehicles_status ON vehicles (status);

DROP INDEX IF EXISTS idx_packages_status;
CREATE INDEX idx_packages_status ON packages (status);

-- 3. Others
DROP INDEX IF EXISTS idx_packages_zone_id;
CREATE INDEX idx_packages_zone_id ON packages (zone_id);

DROP INDEX IF EXISTS idx_packages_warehouse_id;
CREATE INDEX idx_packages_warehouse_id ON packages (warehouse_id);

DROP INDEX IF EXISTS idx_deliveries_assigned_at;
CREATE INDEX idx_deliveries_assigned_at ON deliveries (assigned_at);

-- This one may be needed since a Seq Scan is done on deliveries when a package in packages is deleted due to the ON DELETE CASCADE foreign key 
DROP INDEX IF EXISTS idx_deliveries_package_id;
CREATE INDEX idx_deliveries_package_id ON deliveries (package_id);


---------------------------- TRIGGERS (Automation) ----------------------------

-- NOTE:
--- UPDATE: Uses both OLD (to refer to the row data being updated) and NEW (to refer to the new replacement row)
--- INSERT: Uses only NEW since there is no old row 
--- DELETE: Uses only OLD (to refer to the current row being deleted) since there is no new data replacing it

-- 1. Auto assign active zone and warehouse on package INSERT or destination UPDATE
CREATE OR REPLACE FUNCTION auto_zone_warehouse()
RETURNS TRIGGER AS $$   -- the dollar-quote opens the function body; it ends at the next dollar-quote
BEGIN 
    -- Find and set an active zone for the package destination
    SELECT id INTO NEW.zone_id
    FROM zones
    WHERE status = 'Active' 
    AND ST_Contains(boundary, NEW.destination)
    LIMIT 1;

    -- Fallback: Find closest active zone
    IF NEW.zone_id IS NULL THEN
        SELECT id INTO NEW.zone_id
        FROM zones
        WHERE status = 'Active'
        ORDER BY boundary <-> NEW.destination   -- <-> is the symbol for distance between the two places for POSTGIS 
        LIMIT 1;
    END IF;

    -- Assign active warehouse corresponding to the assigned zone
    IF NEW.zone_id IS NOT NULL THEN
        SELECT w.id INTO NEW.warehouse_id
        FROM warehouses w
        JOIN zones z ON z.id = NEW.zone_id
        WHERE w.status = 'Active'
        AND ST_Contains(z.boundary, w.location)
        LIMIT 1;

        -- Fallback: Find closest active warehouse to destination
        IF NEW.warehouse_id IS NULL THEN
            SELECT id INTO NEW.warehouse_id
            FROM warehouses w
            WHERE w.status = 'Active'
            ORDER BY w.location <-> NEW.destination
            LIMIT 1;
        END IF;
    END IF;

    -- Warning if no active infrastructure exists to process package
    IF NEW.zone_id IS NULL OR NEW.warehouse_id IS NULL THEN
        RAISE NOTICE 'Warning: Package ID % destination could not be assigned to an active zone/warehouse.', NEW.id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_auto_zone_warehouse ON packages;
CREATE TRIGGER trg_auto_zone_warehouse
BEFORE INSERT OR UPDATE OF destination ON packages
FOR EACH ROW 
EXECUTE FUNCTION auto_zone_warehouse();


-- 2. Auto assign an available driver and vehicle for a new delivery
CREATE OR REPLACE FUNCTION auto_driver_vehicle()
RETURNS TRIGGER AS $$
DECLARE -- To declare variables that hold values for an instance of the trigger function
    auto_driver_id INT;
    auto_vehicle_id INT;
    auto_zone_id INT;
    pkg_weight NUMERIC(5,2);
    v_max_cap NUMERIC(5,2);
    v_curr_load NUMERIC(5,2);
BEGIN
    -- Find out the zone and weight of the package
    SELECT zone_id, weight INTO auto_zone_id, pkg_weight 
    FROM packages 
    WHERE id = NEW.package_id;

    -- Find an available driver in the package's zone
    SELECT id INTO auto_driver_id FROM drivers
    WHERE status = 'Available'
      AND zone_id = auto_zone_id
      AND id NOT IN (
        SELECT driver_id FROM deliveries 
        WHERE delivered_at IS NULL AND driver_id IS NOT NULL    -- delieved_at not null to ensure that the driver is not currently out on delivery while driver_id not null is to filter out packages which do not have a driver assigned to it yet. This is needed because otherwise, the query returns something like (1, 2, NULL) and the whole thing resolves to NULL --> where clause fails for all drivers and you get no available drivers 
      )
    LIMIT 1;

    -- Find an available vehicle with remaining weight capacity
    SELECT id, max_capacity, current_load 
    INTO auto_vehicle_id, v_max_cap, v_curr_load
    FROM vehicles
    WHERE status = 'Available'
    AND (max_capacity - current_load) >= pkg_weight
    LIMIT 1;

    -- Assign assets if found
    IF auto_driver_id IS NOT NULL AND auto_vehicle_id IS NOT NULL THEN
        NEW.driver_id := auto_driver_id;
        NEW.vehicle_id := auto_vehicle_id;

        -- Update vehicle current payload
        UPDATE vehicles 
        SET current_load = current_load + pkg_weight 
        WHERE id = auto_vehicle_id;

        -- Capacity threshold alert
        IF (v_max_cap - (v_curr_load + pkg_weight) <= 10.00) THEN
            RAISE NOTICE 'Vehicle ID % is near maximum weight capacity limit.', auto_vehicle_id;
        END IF;
    ELSE 
       RAISE NOTICE 'No available drivers or vehicles for package ID %', NEW.package_id;    -- % symbol acts as a placeholder that later gets replaced by NEW.package_id
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS tgr_auto_driver_vehicle ON deliveries;
CREATE TRIGGER tgr_auto_driver_vehicle 
BEFORE INSERT ON deliveries
FOR EACH ROW
EXECUTE FUNCTION auto_driver_vehicle();


-- 3. Auto sync delivery completion timestamps and asset statuses across entities
CREATE OR REPLACE FUNCTION sync_delivery_status()
RETURNS TRIGGER AS $$
BEGIN 
    -- When a delivery is first created/assigned
    IF (TG_OP = 'INSERT') THEN
        IF NEW.driver_id IS NOT NULL AND NEW.vehicle_id IS NOT NULL THEN 
            UPDATE drivers SET status = 'Busy' WHERE id = NEW.driver_id;
            UPDATE vehicles SET status = 'In-Transit' WHERE id = NEW.vehicle_id;
            UPDATE packages SET status = 'Shipped' WHERE id = NEW.package_id;
        ELSE
            UPDATE packages SET status = 'Pending' WHERE id = NEW.package_id;
        END IF;

    -- When a delivery is completed
    ELSIF (TG_OP = 'UPDATE' AND NEW.delivered_at IS NOT NULL AND OLD.delivered_at IS NULL) THEN
        UPDATE drivers SET status = 'Available' WHERE id = NEW.driver_id;
        UPDATE vehicles SET status = 'Available' WHERE id = NEW.vehicle_id;
        UPDATE packages SET status = 'Delivered' WHERE id = NEW.package_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_delivery_status_sync ON deliveries;
CREATE TRIGGER trg_delivery_status_sync
AFTER INSERT OR UPDATE ON deliveries
FOR EACH ROW 
EXECUTE FUNCTION sync_delivery_status();


-- 4. Block overlapping ACTIVE zones (exact geometry, checked at COMMIT)
--- DEFERRABLE INITIALLY DEFERRED: the check runs once at the end of the transaction, so a script such as
--- auto_zones.py can rewrite several zones in a row without tripping over a neighbour's old boundary.
--- ST_Relate with the pattern T******** is true only when the INTERIORS intersect, so zones that merely
--- share an edge are allowed. The && test first uses the GiST index to shortlist candidates.
CREATE OR REPLACE FUNCTION zones_no_overlap()
RETURNS TRIGGER AS $$
DECLARE
    cur zones%ROWTYPE;
BEGIN
    SELECT * INTO cur FROM zones WHERE id = NEW.id;   -- latest version of this row at commit time
    IF NOT FOUND OR cur.status <> 'Active' THEN
        RETURN NULL;
    END IF;

    IF EXISTS (
        SELECT 1 FROM zones z
        WHERE z.id <> cur.id
          AND z.status = 'Active'
          AND z.boundary && cur.boundary
          AND ST_Relate(z.boundary, cur.boundary, 'T********')
    ) THEN
        RAISE EXCEPTION 'Zone "%" overlaps another active zone', cur.name
            USING ERRCODE = 'exclusion_violation';
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_zones_no_overlap ON zones;
CREATE CONSTRAINT TRIGGER trg_zones_no_overlap
AFTER INSERT OR UPDATE OF boundary, status ON zones
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION zones_no_overlap();


---------------------------- Rule-Based Access Control (RBAC) ----------------------------

-- Creating the roles 
CREATE ROLE logistics_coordinator;
CREATE ROLE delivery_driver;


-- Permissions granted for logisitics coordinator 
--- Let them look at the public schema (where all the tables live by default)
GRANT USAGE ON SCHEMA public TO logistics_coordinator;  

--- Let them read, insert, update, delete for all tables 
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public to logistics_coordinator;

--- Let them use the auto-incrementing SERIAL sequences
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public to logistics_coordinator;


-- Permissions for delivery drivers 
GRANT USAGE ON SCHEMA public to delivery_driver;
--- Let them read zones, warehouses, vehicles and packages
GRANT SELECT ON zones, warehouses, vehicles, packages TO delivery_driver;

--- Let them edit the package status 
GRANT SELECT, UPDATE(status) ON packages TO delivery_driver;


-- Create employees + onboard employees
-- NOTE: passwords intentionally left out of version control.
-- Set them after running this script with, e.g.:
--   ALTER ROLE tom_coordinator WITH LOGIN PASSWORD 'your_password_here';
--   ALTER ROLE jack_driver WITH LOGIN PASSWORD 'your_password_here';
CREATE ROLE tom_coordinator WITH LOGIN;
CREATE ROLE jack_driver WITH LOGIN;

GRANT logistics_coordinator to tom_coordinator;
GRANT delivery_driver to jack_driver;
