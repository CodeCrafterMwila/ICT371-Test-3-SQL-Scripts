-- =====================================================================
-- ICT371 Advanced Database | Question 5: Hostel Room Allocation
-- PostgreSQL 14+ | schema q5 | scheduling with pg_cron
-- =====================================================================
DROP SCHEMA IF EXISTS q5 CASCADE;
CREATE SCHEMA q5;
SET search_path = q5;

-- ---------------------------------------------------------------------
-- (a) TABLES
-- The CHECK ck_status_release ties status to released_on:
--   ACTIVE -> released_on IS NULL ;  ENDED -> released_on IS NOT NULL
-- ---------------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL       PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL      PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INTEGER     NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL      PRIMARY KEY,
    student_id    INTEGER     NOT NULL REFERENCES students(student_id),
    room_id       INTEGER     NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE        NOT NULL,
    released_on   DATE        NULL,
    status        VARCHAR(10) NOT NULL DEFAULT 'ACTIVE',
    CONSTRAINT ck_status CHECK (status IN ('ACTIVE','ENDED')),
    CONSTRAINT ck_status_release CHECK (
           (status = 'ACTIVE' AND released_on IS NULL)
        OR (status = 'ENDED'  AND released_on IS NOT NULL)),
    CONSTRAINT ck_release_after_alloc CHECK (released_on IS NULL OR released_on >= allocated_on)
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE    NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL,
    free_beds     INTEGER NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)          -- composite key: one row per date AND room
);

INSERT INTO rooms (room_number, capacity) VALUES ('R101', 2), ('R102', 3), ('R103', 2);
INSERT INTO students (student_number, full_name) VALUES
    ('MU2024001', 'Chanda Mulenga'),
    ('MU2024002', 'Bwalya Phiri'),
    ('MU2024003', 'Natasha Banda'),
    ('MU2024004', 'Kelvin Tembo'),
    ('MU2024005', 'Mercy Daka');

-- ---------------------------------------------------------------------
-- (b) FUNCTION fn_free_beds = capacity - ACTIVE allocations
-- ENDED rows are simply not counted.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_active   INTEGER;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active
    FROM allocations
    WHERE room_id = p_room_id AND status = 'ACTIVE';

    RETURN v_capacity - v_active;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) PROCEDURE pr_allocate_room
-- Locking the ROOM row serialises concurrent allocations to that room.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id   INTEGER,
    p_room_id      INTEGER,
    p_allocated_on DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date must not be NULL';
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % is full', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- ---------------------------------------------------------------------
-- (d) TRIGGER: enforces the same two rules for DIRECT INSERT/UPDATE.
-- Only ACTIVE rows need checking (ENDED rows occupy nothing).
-- "Other" rows are counted with allocation_id IS DISTINCT FROM NEW.allocation_id,
-- so an UPDATE never counts the row being updated against itself.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_allocation_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_others   INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        -- lock the room row so concurrent direct inserts queue up
        SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;

        -- rule 1: one ACTIVE allocation per student
        IF EXISTS (SELECT 1 FROM allocations a
                   WHERE a.student_id = NEW.student_id
                     AND a.status = 'ACTIVE'
                     AND a.allocation_id IS DISTINCT FROM NEW.allocation_id) THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;

        -- rule 2: room capacity
        SELECT COUNT(*) INTO v_others
        FROM allocations a
        WHERE a.room_id = NEW.room_id
          AND a.status = 'ACTIVE'
          AND a.allocation_id IS DISTINCT FROM NEW.allocation_id;

        IF v_others >= v_capacity THEN
            RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_allocation_rules ON allocations;
CREATE TRIGGER trg_allocation_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_allocation_rules();

-- ---------------------------------------------------------------------
-- (e) VIEW: every room, even empty ones -> LEFT JOIN.
-- The ACTIVE filter MUST be in the ON clause (not WHERE) or the empty
-- rooms would disappear.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id
      AND a.status  = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

-- ---------------------------------------------------------------------
-- (f) PARTIAL INDEX on ACTIVE rows by room_id.
-- Counting occupancy only ever looks at ACTIVE rows; ENDED history grows
-- forever but is not indexed, so the index stays small and fast.
-- ---------------------------------------------------------------------
CREATE INDEX idx_alloc_active_room ON allocations (room_id) WHERE status = 'ACTIVE';

-- ---------------------------------------------------------------------
-- Seed: full (R101), partly occupied (R102), empty (R103 - only history)
-- ---------------------------------------------------------------------
CALL pr_allocate_room(1, 1, CURRENT_DATE - 60);     -- R101 full (2/2)
CALL pr_allocate_room(2, 1, CURRENT_DATE - 55);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 40);     -- R102 1/3
CALL pr_allocate_room(4, 3, CURRENT_DATE - 90);     -- becomes history below
UPDATE allocations
   SET status = 'ENDED', released_on = CURRENT_DATE - 30
 WHERE student_id = 4;                              -- R103 now empty, history kept

-- ---------------------------------------------------------------------
-- (g) SCHEDULED JOB: one row per (date, room); UPSERT on the composite key
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds
    FROM v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
        SET occupied_beds = EXCLUDED.occupied_beds,
            free_beds     = EXCLUDED.free_beds;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'q5_refresh_occupancy',
    '55 23 * * *',                                  -- 23:55 every day
    $$CALL q5.pr_refresh_occupancy()$$);

-- =====================================================================
-- DEMONSTRATIONS / TESTS
-- =====================================================================
SELECT room_id, fn_free_beds(room_id) AS free_beds FROM rooms ORDER BY 1;   -- 0, 2, 2

DO $$
BEGIN
    BEGIN PERFORM fn_free_beds(99);                           EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_allocate_room(99, 2, CURRENT_DATE);         EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_allocate_room(5, 99, CURRENT_DATE);         EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_allocate_room(5, 1, CURRENT_DATE);          EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected (full): %', SQLERRM; END;
    BEGIN CALL pr_allocate_room(3, 3, CURRENT_DATE);          EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected (has active): %', SQLERRM; END;
    -- direct SQL must obey the same rules (trigger)
    BEGIN INSERT INTO allocations (student_id, room_id, allocated_on) VALUES (5, 1, CURRENT_DATE);
                                                              EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected (direct, full): %', SQLERRM; END;
    BEGIN INSERT INTO allocations (student_id, room_id, allocated_on) VALUES (1, 2, CURRENT_DATE);
                                                              EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected (direct, 2nd active): %', SQLERRM; END;
END $$;

-- Update of an existing ACTIVE row must not count itself (moves student 3 within R102 untouched)
UPDATE allocations SET allocated_on = allocated_on + 1 WHERE student_id = 3;

-- A student with ENDED history may be allocated again
CALL pr_allocate_room(4, 3, CURRENT_DATE);

SELECT * FROM v_room_occupancy ORDER BY room_id;

SET enable_seqscan = off;
EXPLAIN
SELECT allocation_id, student_id, allocated_on
FROM allocations
WHERE room_id = 1 AND status = 'ACTIVE';
RESET enable_seqscan;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();                                 -- rerun replaces
SELECT * FROM occupancy_snapshot ORDER BY snapshot_date, room_id;
