-- =====================================================================
-- ICT371 Advanced Database | Question 6: Monthly Payroll Processing
-- PostgreSQL 14+ | schema q6 | scheduling with pg_cron
-- gross = basic_salary + allowance ; net = gross - deduction
-- =====================================================================
DROP SCHEMA IF EXISTS q6 CASCADE;
CREATE SCHEMA q6;
SET search_path = q6;

-- ---------------------------------------------------------------------
-- (a) TABLES
-- pay_month must be the FIRST day of a month: date_trunc('month', d) = d
-- ---------------------------------------------------------------------
CREATE TABLE employees (
    employee_id  SERIAL        PRIMARY KEY,
    full_name    VARCHAR(100)  NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance    >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction    >= 0),
    active       BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL        PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE          NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL,
    net_pay     NUMERIC(12,2) NOT NULL,
    CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month),
    CONSTRAINT ck_month_start CHECK (pay_month = date_trunc('month', pay_month)::date)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL        PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP     NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Chanda Mulenga', 8000.00, 1500.00, 1200.00, TRUE),
    ('Bwalya Phiri',   6500.00, 1000.00,  900.00, TRUE),
    ('Natasha Banda',  7200.00,  800.00, 1000.00, TRUE),
    ('Kelvin Tembo',   5000.00,  500.00,  700.00, TRUE),
    ('Mercy Daka',     4500.00,  400.00,  600.00, TRUE);   -- will become inactive after Sept

-- ---------------------------------------------------------------------
-- (b) FUNCTION fn_net_pay
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_net NUMERIC;
BEGIN
    SELECT basic_salary + allowance - deduction
      INTO v_net
      FROM employees
     WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) PROCEDURE pr_process_payroll using a query FOR loop
-- * ON CONFLICT DO NOTHING keeps an existing month's row UNCHANGED.
-- * fn_net_pay raises for an invalid (negative-net) employee; the exception
--   propagates, so the WHOLE call rolls back (all-or-nothing).
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    r       RECORD;
    v_net   NUMERIC;
    v_gross NUMERIC;
BEGIN
    IF p_month IS NULL OR p_month <> date_trunc('month', p_month)::date THEN
        RAISE EXCEPTION 'p_month must be the first day of a month (got %)', p_month;
    END IF;

    FOR r IN SELECT employee_id, basic_salary, allowance
             FROM employees
             WHERE active
             ORDER BY employee_id
    LOOP
        v_net   := fn_net_pay(r.employee_id);          -- may raise -> aborts everything
        v_gross := r.basic_salary + r.allowance;

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) TRIGGER: log only real basic_salary changes
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary, now());
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_salary_audit ON employees;
CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- ---------------------------------------------------------------------
-- (e) VIEW: INNER JOIN on all employees (no "active" filter), so history
-- stays visible after an employee is deactivated.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.employee_id,
       e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

-- ---------------------------------------------------------------------
-- (f) INDEX on pay_month alone.
-- The existing UNIQUE (employee_id, pay_month) index is ordered by
-- employee_id first, so it cannot efficiently answer "all employees for
-- month X". A leading-pay_month index can. It is NOT a duplicate: its
-- column order is different.
-- ---------------------------------------------------------------------
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

-- ---------------------------------------------------------------------
-- Seed two payroll months through the procedure
-- ---------------------------------------------------------------------
CALL pr_process_payroll(DATE '2026-09-01');                -- all 5 employees active
UPDATE employees SET active = FALSE WHERE employee_id = 5; -- Mercy leaves after September
CALL pr_process_payroll(DATE '2026-10-01');                -- only 4 employees

-- ---------------------------------------------------------------------
-- (g) SCHEDULE: 02:00 on day 1 of every month, for the PREVIOUS month
-- ---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'q6_monthly_payroll',
    '0 2 1 * *',                                    -- minute 0, hour 2, day-of-month 1
    $$CALL q6.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);

-- Inspect the job definition and its run history (pg_cron catalogue tables)
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'q6_monthly_payroll';

SELECT d.jobid, d.runid, d.status, d.return_message, d.start_time, d.end_time
FROM cron.job_run_details d
JOIN cron.job j ON j.jobid = d.jobid
WHERE j.jobname = 'q6_monthly_payroll'
ORDER BY d.start_time DESC;

-- To remove the job:  SELECT cron.unschedule('q6_monthly_payroll');

-- =====================================================================
-- DEMONSTRATIONS / TESTS
-- =====================================================================
SELECT employee_id, fn_net_pay(employee_id) AS net FROM employees ORDER BY 1;

DO $$
BEGIN
    BEGIN PERFORM fn_net_pay(99);                               EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_process_payroll(DATE '2026-11-15');           EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_process_payroll(NULL);                        EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
END $$;

-- Rerun = existing rows unchanged, no duplicates
UPDATE employees SET allowance = allowance + 100 WHERE employee_id = 1;   -- not a salary change: no audit
CALL pr_process_payroll(DATE '2026-10-01');
SELECT count(*) AS payroll_rows_still_9 FROM payroll;                     -- 5 (Sep) + 4 (Oct)
SELECT * FROM payroll WHERE employee_id = 1 ORDER BY pay_month;           -- Oct row NOT re-priced

-- Atomic failure: make one employee's net pay negative, then process November
UPDATE employees SET deduction = 99999 WHERE employee_id = 3;
DO $$
BEGIN
    BEGIN CALL pr_process_payroll(DATE '2026-11-01');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK whole call failed: %', SQLERRM; END;
END $$;
SELECT count(*) AS nov_rows_must_be_0 FROM payroll WHERE pay_month = DATE '2026-11-01';
UPDATE employees SET deduction = 1000 WHERE employee_id = 3;              -- restore

-- Trigger test
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;           -- audited
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;           -- unchanged: NOT audited
SELECT * FROM salary_audit;

SELECT * FROM v_payroll_report ORDER BY pay_month, employee_id;           -- Mercy still appears (Sep)

SET enable_seqscan = off;
EXPLAIN
SELECT employee_id, gross_pay, net_pay
FROM payroll
WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;
