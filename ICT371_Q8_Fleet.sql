-- =====================================================================
-- ICT371 Advanced Database | Question 8: Transport Fleet Maintenance
-- PostgreSQL 14+ | schema q8 | scheduling with pg_cron
-- Service rule: due when current_odometer - last_service_odometer >= 5000
-- =====================================================================
DROP SCHEMA IF EXISTS q8 CASCADE;
CREATE SCHEMA q8;
SET search_path = q8;

-- ---------------------------------------------------------------------
-- (a) TABLES
-- ---------------------------------------------------------------------
CREATE TABLE vehicles (
    vehicle_id            SERIAL      PRIMARY KEY,
    registration          VARCHAR(15) NOT NULL UNIQUE,
    current_odometer      INTEGER     NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INTEGER     NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL  PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE    NOT NULL,
    start_odometer INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INTEGER NOT NULL CHECK (end_odometer   >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),   -- at most one alert per vehicle
    km_since_service INTEGER NOT NULL,
    flagged_on       DATE    NOT NULL DEFAULT CURRENT_DATE
);

-- Three different service positions:
--   V1: 7000 km since service (overdue)   V2: 3000 km (fine)   V3: exactly 5000 km (due: ">= 5000")
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ABC 1234 ZM', 12000, 5000),
    ('BAF 5678 ZM',  8000, 5000),
    ('ACD 9012 ZM', 10000, 5000);

-- ---------------------------------------------------------------------
-- (b) FUNCTION fn_service_due
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_current INTEGER;
    v_last    INTEGER;
BEGIN
    SELECT current_odometer, last_service_odometer
      INTO v_current, v_last
      FROM vehicles
     WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_current - v_last) >= 5000;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) PROCEDURE pr_record_trip - validates and inserts ONLY.
-- It must NOT update the vehicle: the trigger does that exactly once.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on    DATE,
    p_start      INTEGER,
    p_end        INTEGER)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date and odometer readings must not be NULL';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- ---------------------------------------------------------------------
-- (d) TRIGGER: BEFORE INSERT row trigger on trips
-- 1. lock the vehicle row (so two trips cannot start from the same value)
-- 2. start must equal the vehicle's current odometer
-- 3. mileage must be valid (end > start)
-- 4. move current_odometer to end_odometer (once per inserted trip).
-- If the trip INSERT later fails, the vehicle UPDATE rolls back with it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current INTEGER;
BEGIN
    SELECT current_odometer INTO v_current
      FROM vehicles
     WHERE vehicle_id = NEW.vehicle_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;
    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip must start at the current odometer % (got %)', v_current, NEW.start_odometer;
    END IF;
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end % is not greater than start %',
                        NEW.end_odometer, NEW.start_odometer;
    END IF;

    UPDATE vehicles
       SET current_odometer = NEW.end_odometer
     WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_trip_odometer ON trips;
CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trip_odometer();

-- ---------------------------------------------------------------------
-- (e) VIEW
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

-- ---------------------------------------------------------------------
-- (f) INDEX (vehicle_id, trip_on): equality on vehicle, range on date.
-- ---------------------------------------------------------------------
CREATE INDEX idx_trips_vehicle_tripon ON trips (vehicle_id, trip_on);

-- ---------------------------------------------------------------------
-- Six trips THROUGH THE PROCEDURE (trigger already installed).
-- Each trip starts where the previous one for that vehicle ended.
-- ---------------------------------------------------------------------
CALL pr_record_trip(1, CURRENT_DATE - 6, 12000, 12150);
CALL pr_record_trip(1, CURRENT_DATE - 3, 12150, 12300);
CALL pr_record_trip(2, CURRENT_DATE - 5,  8000,  8100);
CALL pr_record_trip(2, CURRENT_DATE - 2,  8100,  8250);
CALL pr_record_trip(3, CURRENT_DATE - 4, 10000, 10200);
CALL pr_record_trip(3, CURRENT_DATE - 1, 10200, 10350);

-- ---------------------------------------------------------------------
-- (g) SCHEDULED JOB: synchronise service_alerts with the current rule
-- Step 1 upserts an alert per due vehicle (keeps the original flagged_on).
-- Step 2 deletes alerts for vehicles that are no longer due.
-- Running it repeatedly gives the same result (idempotent).
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM vehicles
    WHERE fn_service_due(vehicle_id)
    ON CONFLICT (vehicle_id) DO UPDATE
        SET km_since_service = EXCLUDED.km_since_service;

    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (SELECT 1 FROM vehicles v
                      WHERE v.vehicle_id = sa.vehicle_id
                        AND fn_service_due(v.vehicle_id));
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'q8_refresh_service_alerts',
    '0 6 * * 1',                                    -- 06:00 every Monday (1 = Monday)
    $$CALL q8.pr_refresh_service_alerts()$$);

-- =====================================================================
-- DEMONSTRATIONS / TESTS
-- =====================================================================
SELECT vehicle_id, registration, current_odometer, fn_service_due(vehicle_id) AS due FROM vehicles ORDER BY 1;
-- V1 12300-5000=7300 -> true ; V2 8250-5000=3250 -> false ; V3 10350-5000=5350 -> true

DO $$
BEGIN
    BEGIN PERFORM fn_service_due(99);                          EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_record_trip(99, CURRENT_DATE, 1, 2);         EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_record_trip(2, CURRENT_DATE, 8250, 8250);    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected (end<=start): %', SQLERRM; END;
    BEGIN CALL pr_record_trip(2, CURRENT_DATE, 8000, 8300);    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected (wrong start, trigger): %', SQLERRM; END;
    -- direct SQL: trigger rejects bad mileage too
    BEGIN INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer) VALUES (2, CURRENT_DATE, 8250, 8200);
                                                               EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected (direct, mileage): %', SQLERRM; END;
END $$;

SELECT * FROM vehicles ORDER BY vehicle_id;                     -- odometers moved exactly once per trip
SELECT * FROM trips ORDER BY trip_id;
SELECT * FROM v_service_due;

SET enable_seqscan = off;
EXPLAIN
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 1
  AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;               -- vehicles 1 and 3

-- Vehicle 1 is serviced -> alert must disappear; vehicle 2 becomes due -> alert appears
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 1;
UPDATE vehicles SET current_odometer = 13500 WHERE vehicle_id = 2;
CALL pr_refresh_service_alerts();
CALL pr_refresh_service_alerts();                               -- rerun: no duplicates (PK anyway)
SELECT * FROM service_alerts ORDER BY vehicle_id;               -- vehicles 2 and 3
