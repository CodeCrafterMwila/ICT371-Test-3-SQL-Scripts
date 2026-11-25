-- =====================================================================
-- ICT371 Advanced Database | Question 10: Scholarship Application Assessment
-- PostgreSQL 14+ | schema q10 | scheduling with pg_cron
-- Eligible only if: age 18..25 inclusive AND income <= K3,000 AND mark >= 70
-- =====================================================================
DROP SCHEMA IF EXISTS q10 CASCADE;
CREATE SCHEMA q10;
SET search_path = q10;

-- ---------------------------------------------------------------------
-- (a) TABLES
-- ---------------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL       PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL        PRIMARY KEY,
    student_id         INTEGER       NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER       NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE          NOT NULL DEFAULT CURRENT_DATE,
    status             VARCHAR(10)   NOT NULL DEFAULT 'PENDING',
    CONSTRAINT ck_status CHECK (status IN ('PENDING','APPROVED','REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL      PRIMARY KEY,
    application_id INTEGER     NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP   NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
    ('MU2024001', 'Chanda Mulenga'),
    ('MU2024002', 'Bwalya Phiri'),
    ('MU2024003', 'Natasha Banda'),
    ('MU2024004', 'Kelvin Tembo');

-- ---------------------------------------------------------------------
-- (b) FUNCTION fn_scholarship_eligible
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INTEGER, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark must not be NULL';
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income must not be negative (got %)', p_income;
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive (got %)', p_age;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100 (got %)', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark   >= 70;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) PROCEDURE pr_assess_application
-- FOR UPDATE locks the row so two assessors cannot both process it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_age      INTEGER;
    v_income   NUMERIC;
    v_mark     NUMERIC;
    v_status   VARCHAR(10);
    v_eligible BOOLEAN;
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
      INTO v_age, v_income, v_mark, v_status
      FROM applications
     WHERE application_id = p_application_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application % does not exist', p_application_id;
    END IF;
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status: %)',
                        p_application_id, v_status;
    END IF;

    v_eligible := fn_scholarship_eligible(v_age, v_income, v_mark);

    UPDATE applications
       SET status = CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
     WHERE application_id = p_application_id;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) TRIGGER: audit only REAL status changes
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, now());
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_decision_audit ON applications;
CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

-- ---------------------------------------------------------------------
-- (e) VIEW: APPROVED only; income deliberately NOT exposed
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- ---------------------------------------------------------------------
-- (f) COMPOSITE INDEX (status, submitted_on)
-- Equality column (status) first, range column (submitted_on) second.
-- ---------------------------------------------------------------------
CREATE INDEX idx_app_status_submitted ON applications (status, submitted_on);

-- ---------------------------------------------------------------------
-- Seed six PENDING applications: qualifying, non-qualifying, boundaries
-- ---------------------------------------------------------------------
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
    (1, 20, 2500.00, 75.00, CURRENT_DATE - 10),   -- 1 qualifies
    (2, 18, 3000.00, 70.00, CURRENT_DATE -  9),   -- 2 lower-age + income + mark boundaries -> qualifies
    (2, 25, 3000.00, 70.00, CURRENT_DATE -  8),   -- 3 upper-age boundary -> qualifies
    (3, 26, 1000.00, 90.00, CURRENT_DATE -  7),   -- 4 too old
    (3, 22, 3000.01, 85.00, CURRENT_DATE -  6),   -- 5 income just over limit
    (4, 22, 2000.00, 69.99, CURRENT_DATE -  5);   -- 6 mark just under limit

-- ---------------------------------------------------------------------
-- (g) SCHEDULED JOB: query FOR loop over PENDING rows only.
-- Reruns are safe: completed applications are no longer PENDING, so they
-- are never selected again -> no reassessment, no duplicate audit rows.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT application_id
             FROM applications
             WHERE status = 'PENDING'
             ORDER BY application_id
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'q10_assess_pending',
    '0 8 * * 1',                                    -- 08:00 every Monday
    $$CALL q10.pr_assess_pending()$$);

-- =====================================================================
-- DEMONSTRATIONS / TESTS
-- =====================================================================
SELECT fn_scholarship_eligible(18, 3000, 70)      AS lower_boundary,   -- true
       fn_scholarship_eligible(25, 3000, 70)      AS upper_boundary,   -- true
       fn_scholarship_eligible(26, 1000, 90)      AS too_old,          -- false
       fn_scholarship_eligible(22, 3000.01, 85)   AS income_over,      -- false
       fn_scholarship_eligible(22, 2000, 69.99)   AS mark_under;       -- false

DO $$
BEGIN
    BEGIN PERFORM fn_scholarship_eligible(NULL, 1000, 80);  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN PERFORM fn_scholarship_eligible(20, -1, 80);      EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN PERFORM fn_scholarship_eligible(0, 1000, 80);     EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN PERFORM fn_scholarship_eligible(20, 1000, 101);   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_assess_application(999);                  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
END $$;

-- Assess one by hand, then try it again
CALL pr_assess_application(1);
DO $$
BEGIN
    BEGIN CALL pr_assess_application(1); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected (already assessed): %', SQLERRM; END;
END $$;

-- Non-status update must NOT create an audit row
UPDATE applications SET monthly_income = 2400 WHERE application_id = 2;
SELECT count(*) AS audit_rows_so_far_1 FROM decision_audit;

-- Run the batch job twice: second run must change nothing
CALL pr_assess_pending();
CALL pr_assess_pending();

SELECT application_id, age_at_application, monthly_income, average_mark, status
FROM applications ORDER BY application_id;       -- 1,2,3 APPROVED ; 4,5,6 REJECTED
SELECT * FROM decision_audit ORDER BY audit_id;  -- exactly 6 rows (no duplicates)
SELECT * FROM v_approved_applicants ORDER BY student_number;

SET enable_seqscan = off;
EXPLAIN
SELECT application_id, student_id, submitted_on
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;
