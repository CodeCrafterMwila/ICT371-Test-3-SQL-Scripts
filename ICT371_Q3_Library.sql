-- =====================================================================
-- ICT371 Advanced Database | Question 3: Library Returns and Overdue Fines
-- PostgreSQL 14+ | schema q3 | scheduling with pg_cron
-- Fine rule: K2 per day AFTER the due date; returned on due date = K0.
-- =====================================================================
DROP SCHEMA IF EXISTS q3 CASCADE;
CREATE SCHEMA q3;
SET search_path = q3;

-- ---------------------------------------------------------------------
-- (a) TABLES
-- ---------------------------------------------------------------------
CREATE TABLE books (
    book_id SERIAL       PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL        PRIMARY KEY,
    book_id       INTEGER       NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100)  NOT NULL,
    borrowed_on   DATE          NOT NULL,
    due_on        DATE          NOT NULL,
    returned_on   DATE          NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT ck_due_after_borrow CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id         SERIAL    PRIMARY KEY,
    loan_id          INTEGER   NOT NULL REFERENCES loans(loan_id),
    old_returned_on  DATE      NULL,
    new_returned_on  DATE      NULL,
    changed_at       TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE          PRIMARY KEY,
    overdue_count INTEGER       NOT NULL,
    total_fine    NUMERIC(12,2) NOT NULL
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Introduction to Algorithms'),
    ('Clean Code');

-- ---------------------------------------------------------------------
-- (b) FUNCTION fn_loan_fine(loan, as_of) = K2 * overdue days, minimum 0
-- The "clock" stops at returned_on: end_date = LEAST(as_of, returned_on).
-- DATE - DATE gives an integer number of days in PostgreSQL.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end      DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;

    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    v_end := LEAST(p_as_of, COALESCE(v_returned, p_as_of));
    RETURN 2.00 * GREATEST(0, v_end - v_due);
END;
$$;

-- ---------------------------------------------------------------------
-- (c) PROCEDURE pr_return_loan
-- Return date and final fine are written in ONE UPDATE statement.
-- Calling fn_loan_fine BEFORE the update works because returned_on is
-- still NULL, so the function uses p_as_of = the return date.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
    v_fine     NUMERIC;
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date must not be NULL';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrow date %', p_returned_on, v_borrowed;
    END IF;

    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans
       SET returned_on = p_returned_on,
           fine_amount = v_fine
     WHERE loan_id = p_loan_id;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) TRIGGER: log returned_on changes only when the value really changes
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_loan_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on, now());
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_loan_audit ON loans;
CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_fn_loan_audit();

-- ---------------------------------------------------------------------
-- (e) VIEW: unreturned loans that are past due, with the fine as of today
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id,
       b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

-- ---------------------------------------------------------------------
-- (f) PARTIAL INDEX: only unreturned loans are indexed, keyed by book_id.
-- Small (returned loans are the vast majority over time) and exactly
-- matches the query predicate "returned_on IS NULL".
-- ---------------------------------------------------------------------
CREATE INDEX idx_loans_open_by_book ON loans (book_id) WHERE returned_on IS NULL;

-- ---------------------------------------------------------------------
-- Seed six loans (dates relative to today so the demo always works)
-- ---------------------------------------------------------------------
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Chanda Mulenga', CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 1 open, overdue (16 days)
    (1, 'Mutale Zulu',    CURRENT_DATE - 20, CURRENT_DATE -  6),  -- 2 open, overdue (6 days)
    (2, 'Bwalya Phiri',   CURRENT_DATE - 10, CURRENT_DATE +  4),  -- 3 open, ON TIME (not yet due)
    (2, 'Natasha Banda',  CURRENT_DATE - 25, CURRENT_DATE - 11),  -- 4 will be returned ON the due date
    (3, 'Kelvin Tembo',   CURRENT_DATE - 20, CURRENT_DATE -  9),  -- 5 will be returned 3 days late
    (3, 'Mercy Daka',     CURRENT_DATE -  8, CURRENT_DATE -  1);  -- 6 open, overdue (1 day)

CALL pr_return_loan(4, CURRENT_DATE - 11);   -- on the due date  -> fine 0
CALL pr_return_loan(5, CURRENT_DATE -  6);   -- 3 days late      -> fine 6.00

-- ---------------------------------------------------------------------
-- (g) SCHEDULED JOB
-- ASSUMPTION: "overdue count" = loans NOT returned as of p_as_of
-- (returned_on IS NULL or returned after p_as_of) AND already past due.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE (returned_on IS NULL OR returned_on > p_as_of)
      AND due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
        SET overdue_count = EXCLUDED.overdue_count,
            total_fine    = EXCLUDED.total_fine;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'q3_refresh_overdue',
    '10 0 * * *',                                  -- 00:10 every day
    $$CALL q3.pr_refresh_overdue(CURRENT_DATE)$$);

-- =====================================================================
-- DEMONSTRATIONS / TESTS
-- =====================================================================
SELECT loan_id, fn_loan_fine(loan_id, CURRENT_DATE) AS fine_today FROM loans ORDER BY 1;
-- expected: 1->32, 2->12, 3->0, 4->0, 5->6, 6->2

DO $$
BEGIN
    BEGIN PERFORM fn_loan_fine(99, CURRENT_DATE);          EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_return_loan(99, CURRENT_DATE);           EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_return_loan(4, CURRENT_DATE);            EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_return_loan(1, CURRENT_DATE - 100);      EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
END $$;

SELECT * FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit ORDER BY audit_id;               -- 2 rows (loans 4 and 5)

-- No audit row when returned_on is unchanged
UPDATE loans SET borrower_name = 'Chanda M.' WHERE loan_id = 1;
UPDATE loans SET returned_on = returned_on WHERE loan_id = 4;
SELECT count(*) AS audit_rows_still_2 FROM loan_audit;

SELECT * FROM v_overdue_loans ORDER BY loan_id;           -- loans 1, 2, 6

SET enable_seqscan = off;
EXPLAIN
SELECT loan_id, borrower_name, due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;
RESET enable_seqscan;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);                    -- rerun replaces same snapshot_date
SELECT * FROM overdue_summary;                            -- 3 loans, K46 (32+12+2)
