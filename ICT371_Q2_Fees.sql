-- =====================================================================
-- ICT371 Advanced Database | Question 2: University Fee Payments
-- PostgreSQL 14+ | schema q2 | scheduling with pg_cron
-- =====================================================================
DROP SCHEMA IF EXISTS q2 CASCADE;
CREATE SCHEMA q2;
SET search_path = q2;

-- ---------------------------------------------------------------------
-- (a) TABLES
-- ---------------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL        PRIMARY KEY,
    student_number VARCHAR(20)   NOT NULL UNIQUE,
    full_name      VARCHAR(100)  NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL        PRIMARY KEY,
    student_id INTEGER       NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id   SERIAL        PRIMARY KEY,
    payment_id INTEGER       NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER       NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMP     NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
    collection_date DATE          PRIMARY KEY,
    payment_count   INTEGER       NOT NULL,
    total_amount    NUMERIC(12,2) NOT NULL
);

-- Three students, three different balances.
-- Student 3 will have NO payments; student 2 will end fully settled.
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('MU2024001', 'Chanda Mulenga', 6000.00),
    ('MU2024002', 'Bwalya Phiri',   3000.00),
    ('MU2024003', 'Natasha Banda',  4500.00);

-- ---------------------------------------------------------------------
-- (b) FUNCTION fn_fee_balance = fee_due - SUM(payments)
-- COALESCE makes "no payments" return the full fee.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee  NUMERIC;
    v_paid NUMERIC;
BEGIN
    SELECT fee_due INTO v_fee
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee - v_paid;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) PROCEDURE pr_receive_payment
-- NOTE: it does NOT touch fee_due and does NOT write the audit row;
--       the trigger in (d) does that.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount     NUMERIC,
    p_paid_on    DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be positive (got %)', p_amount;
    END IF;
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date must not be NULL';
    END IF;

    -- lock the student row: serialises two simultaneous payments for one student
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance % (credit balances not allowed)',
                        p_amount, v_balance;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- ---------------------------------------------------------------------
-- (d) TRIGGER: AFTER INSERT row trigger writes the audit record
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_payment_audit ON payments;
CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payment_audit();

-- ---------------------------------------------------------------------
-- (e) VIEW: only students who still owe money (outstanding > 0)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

-- ---------------------------------------------------------------------
-- (f) COMPOSITE INDEX (student_id, paid_on)
-- equality on student_id first, range on paid_on second.
-- ---------------------------------------------------------------------
CREATE INDEX idx_payments_student_paidon ON payments (student_id, paid_on);

-- ---------------------------------------------------------------------
-- Seed payments THROUGH THE PROCEDURE (so the trigger audits them)
-- Student 1: 4 payments (total 4000 -> owes 2000)
-- Student 2: 3 payments (total 3000 -> fully settled)
-- Student 3: none
-- ---------------------------------------------------------------------
CALL pr_receive_payment(1, 1000.00, CURRENT_DATE - 3);
CALL pr_receive_payment(1, 1500.00, CURRENT_DATE - 2);
CALL pr_receive_payment(1,  500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(1, 1000.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE - 2);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE - 1);

-- ---------------------------------------------------------------------
-- (g) SCHEDULED JOB: replace (upsert) the summary for p_day
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM payments
    WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
        SET payment_count = EXCLUDED.payment_count,
            total_amount  = EXCLUDED.total_amount;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'q2_refresh_collections',
    '0 1 * * *',                                   -- 01:00 every day
    $$CALL q2.pr_refresh_collections(CURRENT_DATE - 1)$$);

-- =====================================================================
-- DEMONSTRATIONS / TESTS
-- =====================================================================
SELECT student_id, fn_fee_balance(student_id) AS balance FROM students ORDER BY 1;  -- 2000, 0, 4500

DO $$
BEGIN
    BEGIN PERFORM fn_fee_balance(99);               EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_receive_payment(1, NULL);         EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_receive_payment(1, 0);            EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_receive_payment(1, -50);          EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_receive_payment(3, 99999);        EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_receive_payment(77, 10);          EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
END $$;

SELECT * FROM students ORDER BY student_id;          -- fee_due unchanged
SELECT * FROM payment_audit ORDER BY audit_id;       -- 7 rows, written by the trigger
SELECT * FROM v_fee_balances;                        -- student 2 (settled) is excluded

SET enable_seqscan = off;
EXPLAIN
SELECT payment_id, amount, paid_on
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);       -- rerun replaces, never duplicates
SELECT * FROM daily_collections;
