-- =====================================================================
-- ICT371 Advanced Database | Question 1: Pharmacy Stock and Daily Sales
-- Dialect: PostgreSQL 14+ (PL/pgSQL). Scheduling: pg_cron extension.
-- Each question uses its own schema (q1) so scripts never clash.
-- =====================================================================
DROP SCHEMA IF EXISTS q1 CASCADE;
CREATE SCHEMA q1;
SET search_path = q1;

-- ---------------------------------------------------------------------
-- (a) TABLES (constraints enforce: price > 0, stock >= 0, quantity > 0)
-- ---------------------------------------------------------------------
CREATE TABLE medicines (
    medicine_id   SERIAL        PRIMARY KEY,
    medicine_name VARCHAR(100)  NOT NULL UNIQUE,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER       NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL        PRIMARY KEY,
    medicine_id INTEGER       NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER       NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),  -- price frozen at time of sale
    sold_on     DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id    SERIAL       PRIMARY KEY,
    medicine_id INTEGER      NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER      NOT NULL,
    new_qty     INTEGER      NOT NULL,
    changed_at  TIMESTAMP    NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date   DATE          PRIMARY KEY,
    total_qty    INTEGER       NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL
);

-- Seed medicines (sales are loaded later, through the procedure)
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 2.50, 100),
    ('Amoxicillin 250mg', 8.00,  40),
    ('ORS Sachet',        3.00,  12),
    ('Ibuprofen 200mg',   4.00,  15);

-- ---------------------------------------------------------------------
-- (b) FUNCTION fn_sale_value
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be a positive number)', p_quantity;
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) PROCEDURE pr_record_sale
-- A procedure runs inside the caller's transaction: any RAISE EXCEPTION
-- rolls back everything, so an invalid sale leaves both tables unchanged.
-- FOR UPDATE locks the medicine row so two concurrent sales cannot
-- both pass the stock check (prevents overselling).
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity    INTEGER,
    p_sold_on     DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date must not be NULL';
    END IF;

    SELECT unit_price, stock_qty
      INTO v_price, v_stock
      FROM medicines
     WHERE medicine_id = p_medicine_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: requested %, available %',
                        p_medicine_id, p_quantity, v_stock;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    -- stock is deducted exactly once, here (the trigger only audits)
    UPDATE medicines
       SET stock_qty = stock_qty - p_quantity
     WHERE medicine_id = p_medicine_id;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) TRIGGER: AFTER UPDATE row trigger, fires only if stock_qty changed
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
    VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty, now());
    RETURN NEW;   -- ignored for AFTER triggers, but conventional
END;
$$;

DROP TRIGGER IF EXISTS trg_stock_audit ON medicines;
CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)   -- NULL-safe "actually changed" test
EXECUTE FUNCTION trg_fn_stock_audit();

-- ---------------------------------------------------------------------
-- (e) VIEW v_low_stock
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

-- ---------------------------------------------------------------------
-- (f) INDEX: composite (medicine_id, sold_on)
-- Equality column first (medicine_id), range column second (sold_on):
-- one B-tree descent to the medicine, then a contiguous range scan of
-- its dates, already ordered by date.
-- ---------------------------------------------------------------------
CREATE INDEX idx_sales_medicine_soldon ON sales (medicine_id, sold_on);

-- ---------------------------------------------------------------------
-- Load six valid sales THROUGH THE PROCEDURE
-- ---------------------------------------------------------------------
CALL pr_record_sale(1, 10, CURRENT_DATE - 2);
CALL pr_record_sale(2,  5, CURRENT_DATE - 2);
CALL pr_record_sale(1, 20, CURRENT_DATE - 1);
CALL pr_record_sale(3,  4, CURRENT_DATE - 1);
CALL pr_record_sale(4,  3, CURRENT_DATE - 1);
CALL pr_record_sale(3,  2, CURRENT_DATE);        -- ORS stock: 12 - 4 - 2 = 6  (low stock)

-- ---------------------------------------------------------------------
-- (g) SCHEDULED JOB
-- Idempotent: the row for p_day is recomputed from the sales table and
-- UPSERTed (ON CONFLICT DO UPDATE), never "added to" the old value.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
        SET total_qty    = EXCLUDED.total_qty,
            total_amount = EXCLUDED.total_amount;
END;
$$;

-- pg_cron (needs: shared_preload_libraries = 'pg_cron' in postgresql.conf)
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- cron format: minute hour day-of-month month day-of-week  -> 00:15 every day
SELECT cron.schedule(
    'q1_refresh_sales',
    '15 0 * * *',
    $$CALL q1.pr_refresh_sales(CURRENT_DATE - 1)$$);

-- =====================================================================
-- DEMONSTRATIONS / TESTS
-- =====================================================================
-- Function
SELECT fn_sale_value(2, 3) AS value_of_3_amoxicillin;          -- 24.00

-- Invalid calls (each is rejected; wrapped so the script keeps running)
DO $$
BEGIN
    BEGIN PERFORM fn_sale_value(999, 1);  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN PERFORM fn_sale_value(1, 0);    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_record_sale(3, 500);    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
END $$;

SELECT * FROM medicines ORDER BY medicine_id;     -- stock unchanged by the failed calls
SELECT * FROM sales ORDER BY sale_id;
SELECT * FROM stock_audit ORDER BY audit_id;       -- one row per stock change (6 rows)

-- View after a sale
SELECT * FROM v_low_stock;                         -- ORS Sachet, 6 left

-- Trigger must NOT fire when stock_qty is unchanged
UPDATE medicines SET unit_price = 2.75 WHERE medicine_id = 1;
SELECT count(*) AS audit_rows_still_6 FROM stock_audit;

-- Index plan (seq scan is cheaper on tiny tables, so we disable it ONLY to show the index)
SET enable_seqscan = off;
EXPLAIN
SELECT sale_id, quantity, unit_price, sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- Scheduled job: run twice -> same answer (no double counting)
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);
SELECT * FROM daily_sales;
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q1_refresh_sales';
