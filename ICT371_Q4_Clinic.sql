-- =====================================================================
-- ICT371 Advanced Database | Question 4: Clinic Appointment Scheduling
-- PostgreSQL 14+ | schema q4 | scheduling with pg_cron
-- =====================================================================
DROP SCHEMA IF EXISTS q4 CASCADE;
CREATE SCHEMA q4;
SET search_path = q4;

-- ---------------------------------------------------------------------
-- (a) TABLES
-- ---------------------------------------------------------------------
CREATE TABLE patients (
    patient_id SERIAL       PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL       PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL      PRIMARY KEY,
    patient_id      INTEGER     NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER     NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE        NOT NULL,
    slot_time       TIME        NOT NULL,
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
    CONSTRAINT ck_status CHECK (status IN ('BOOKED','ATTENDED','CANCELLED')),
    CONSTRAINT ck_slot   CHECK (slot_time IN ('09:00','10:00','11:00','12:00'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE    PRIMARY KEY,
    booked_count    INTEGER NOT NULL,
    attended_count  INTEGER NOT NULL,
    cancelled_count INTEGER NOT NULL
);

-- Safety net for concurrency: even if two sessions pass the trigger check at
-- the same instant, this partial UNIQUE index makes the second one fail.
-- (Cancelled rows are excluded, so a cancelled slot can be re-booked.)
CREATE UNIQUE INDEX uq_active_slot
    ON appointments (doctor_id, appointment_day, slot_time)
    WHERE status <> 'CANCELLED';

INSERT INTO patients (full_name) VALUES ('Chanda Mulenga'), ('Bwalya Phiri'), ('Natasha Banda');
INSERT INTO doctors  (full_name) VALUES ('Dr. Mutale'), ('Dr. Tembo'), ('Dr. Zulu');

-- ---------------------------------------------------------------------
-- (b) FUNCTION fn_daily_load: non-cancelled appointments for doctor/day
-- COUNT(*) returns 0 (not NULL) when there are no rows.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_count;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) PROCEDURE pr_book_appointment
-- The clash itself is rejected by the trigger in (d) (single source of truth).
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INTEGER,
    p_doctor_id  INTEGER,
    p_day        DATE,
    p_slot       TIME)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is NULL or in the past', p_day;
    END IF;

    IF p_slot IS NULL OR p_slot NOT IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot % (allowed: 09:00, 10:00, 11:00, 12:00)', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- ---------------------------------------------------------------------
-- (d) TRIGGER: BEFORE INSERT OR UPDATE, reject clash with another
--     NON-CANCELLED appointment (same doctor, day, slot).
-- On UPDATE the row being changed must be excluded, otherwise it would
-- "clash with itself". IS DISTINCT FROM also works on INSERT, where the
-- new id is not yet in the table.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_slot_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' AND EXISTS (
           SELECT 1
           FROM appointments a
           WHERE a.doctor_id       = NEW.doctor_id
             AND a.appointment_day = NEW.appointment_day
             AND a.slot_time       = NEW.slot_time
             AND a.status         <> 'CANCELLED'
             AND a.appointment_id IS DISTINCT FROM NEW.appointment_id) THEN
        RAISE EXCEPTION 'Slot clash: doctor % already has an appointment on % at %',
                        NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
    END IF;
    RETURN NEW;     -- BEFORE trigger must return the row to let it through
END;
$$;

DROP TRIGGER IF EXISTS trg_slot_clash ON appointments;
CREATE TRIGGER trg_slot_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_slot_clash();

-- ---------------------------------------------------------------------
-- (e) VIEW: today's BOOKED appointments, minimal columns only
-- (no patient_id, no other patient data)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED'
ORDER BY a.slot_time, d.full_name;

-- ---------------------------------------------------------------------
-- (f) NON-UNIQUE INDEX (appointment_day, doctor_id)
-- Both columns are tested with equality, so either order is usable;
-- day first as the brief states, since it is the most selective filter
-- for daily lists and also supports day-only queries.
-- ---------------------------------------------------------------------
CREATE INDEX idx_appt_day_doctor ON appointments (appointment_day, doctor_id);

-- ---------------------------------------------------------------------
-- Seed six appointments (direct INSERT because the procedure refuses past
-- dates; the trigger is already installed and checks every row)
-- The cancelled row shares a slot with a live one: allowed by the rule.
-- ---------------------------------------------------------------------
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE,     '09:00', 'BOOKED'),
    (2, 1, CURRENT_DATE,     '10:00', 'BOOKED'),
    (3, 2, CURRENT_DATE,     '09:00', 'BOOKED'),
    (1, 2, CURRENT_DATE - 1, '11:00', 'ATTENDED'),
    (2, 3, CURRENT_DATE - 1, '09:00', 'ATTENDED'),
    (3, 1, CURRENT_DATE,     '10:00', 'CANCELLED');

-- ---------------------------------------------------------------------
-- (g) SCHEDULED JOB
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments
    WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
        SET booked_count    = EXCLUDED.booked_count,
            attended_count  = EXCLUDED.attended_count,
            cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'q4_refresh_clinic_summary',
    '0 1 * * *',                                    -- 01:00 every day
    $$CALL q4.pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);

-- =====================================================================
-- DEMONSTRATIONS / TESTS
-- =====================================================================
SELECT fn_daily_load(1, CURRENT_DATE)     AS dr1_today,         -- 2 (cancelled not counted)
       fn_daily_load(3, CURRENT_DATE)     AS dr3_today_empty,   -- 0
       fn_daily_load(1, CURRENT_DATE + 30) AS dr1_no_bookings;  -- 0

DO $$
BEGIN
    BEGIN PERFORM fn_daily_load(99, CURRENT_DATE);                          EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(99, 1, CURRENT_DATE + 1, '09:00');       EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(1, 99, CURRENT_DATE + 1, '09:00');       EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '09:00');        EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE + 1, '13:00');        EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(2, 1, CURRENT_DATE,     '09:00');        EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected (clash): %', SQLERRM; END;
END $$;

CALL pr_book_appointment(3, 3, CURRENT_DATE + 1, '12:00');       -- valid booking
SELECT * FROM appointments ORDER BY appointment_id;

-- UPDATE test: moving an appointment onto an occupied slot is rejected ...
DO $$
BEGIN
    BEGIN UPDATE appointments SET slot_time = '10:00' WHERE appointment_id = 1;
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected (update clash): %', SQLERRM; END;
END $$;
-- ... but updating a row without moving it does not clash with itself
UPDATE appointments SET status = 'ATTENDED' WHERE appointment_id = 1;

SELECT * FROM v_today_appointments;

SET enable_seqscan = off;
EXPLAIN
SELECT appointment_id, patient_id, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;
RESET enable_seqscan;

CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);                -- rerun replaces
CALL pr_refresh_clinic_summary(CURRENT_DATE);
SELECT * FROM clinic_summary ORDER BY summary_date;
