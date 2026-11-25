-- =====================================================================
-- ICT371 Advanced Database | Question 9: Farmer Cooperative Maize Deliveries
-- PostgreSQL 14+ | schema q9 | scheduling with pg_cron
-- Rates: grade A = K5/kg, B = K4/kg, C = K3/kg
-- =====================================================================
DROP SCHEMA IF EXISTS q9 CASCADE;
CREATE SCHEMA q9;
SET search_path = q9;

-- ---------------------------------------------------------------------
-- (a) TABLES
-- unit_rate / total_value are NOT NULL, yet inserts may omit them: a
-- BEFORE trigger fills them in BEFORE constraints are checked.
-- ---------------------------------------------------------------------
CREATE TABLE farmers (
    farmer_id     SERIAL       PRIMARY KEY,
    farmer_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL        PRIMARY KEY,
    farmer_id    INTEGER       NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1)       NOT NULL CHECK (grade IN ('A','B','C')),
    weight_kg    NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(8,2)  NOT NULL,
    total_value  NUMERIC(12,2) NOT NULL,
    delivered_on DATE          NOT NULL DEFAULT CURRENT_DATE,
    is_paid      BOOLEAN       NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE          PRIMARY KEY,
    total_weight  NUMERIC(12,2) NOT NULL,
    total_value   NUMERIC(14,2) NOT NULL
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Chanda Mulenga'),
    ('F002', 'Bwalya Phiri'),
    ('F003', 'Natasha Banda');          -- will have no unpaid deliveries

-- ---------------------------------------------------------------------
-- (b) FUNCTION fn_maize_rate
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade must not be NULL';
    END IF;

    IF    p_grade = 'A' THEN RETURN 5.00;
    ELSIF p_grade = 'B' THEN RETURN 4.00;
    ELSIF p_grade = 'C' THEN RETURN 3.00;
    ELSE
        RAISE EXCEPTION 'Unsupported grade: % (allowed: A, B, C)', p_grade;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) TRIGGER: BEFORE INSERT OR UPDATE - the ONE place pricing is done.
-- Whatever unit_rate/total_value the caller supplies is overwritten,
-- so direct SQL cannot bypass the pricing rule.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_price_delivery()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_price_delivery ON deliveries;
CREATE TRIGGER trg_price_delivery
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_price_delivery();

-- ---------------------------------------------------------------------
-- (c) PROCEDURE pr_receive_delivery - inserts only basic fields, is_paid = false
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER,
    p_grade     TEXT,
    p_weight    NUMERIC,
    p_date      DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;

    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', p_weight;
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date must not be NULL';
    END IF;

    PERFORM fn_maize_rate(p_grade);          -- early, friendly rejection of NULL/bad grade

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);   -- trigger supplies rate + value
END;
$$;

-- ---------------------------------------------------------------------
-- (e) VIEW: LEFT JOIN with the "unpaid" condition in the ON clause so that
-- farmers with nothing unpaid still appear, with COALESCE(...) = 0.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d
       ON d.farmer_id = f.farmer_id
      AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

-- ---------------------------------------------------------------------
-- (f) COMPOSITE INDEX (farmer_id, delivered_on)
-- ---------------------------------------------------------------------
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

-- ---------------------------------------------------------------------
-- Load six deliveries AFTER the trigger is installed: all grades, paid + unpaid.
-- Three go through the procedure, three by direct SQL.
-- ---------------------------------------------------------------------
CALL pr_receive_delivery(1, 'A', 100, CURRENT_DATE - 2);     -- K500
CALL pr_receive_delivery(1, 'B', 250, CURRENT_DATE - 1);     -- K1000
CALL pr_receive_delivery(2, 'C', 400, CURRENT_DATE - 1);     -- K1200

-- direct SQL: supplied unit_rate / total_value are WRONG on purpose -> trigger overwrites them
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid)
VALUES (2, 'A', 80, 99, 1, CURRENT_DATE - 1, FALSE);         -- becomes 5.00 / K400
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
VALUES (3, 'B', 150, CURRENT_DATE - 3, TRUE);                -- paid, K600
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
VALUES (3, 'C', 300, CURRENT_DATE - 2, TRUE);                -- paid, K900

-- ---------------------------------------------------------------------
-- (g) SCHEDULED JOB
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
    FROM deliveries
    WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
        SET total_weight = EXCLUDED.total_weight,       -- REPLACE, never "+="
            total_value  = EXCLUDED.total_value;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'q9_refresh_purchases',
    '30 1 * * *',                                   -- 01:30 every day
    $$CALL q9.pr_refresh_purchases(CURRENT_DATE - 1)$$);

-- =====================================================================
-- DEMONSTRATIONS / TESTS
-- =====================================================================
SELECT fn_maize_rate('A') AS a, fn_maize_rate('B') AS b, fn_maize_rate('C') AS c;

DO $$
BEGIN
    BEGIN PERFORM fn_maize_rate(NULL);                          EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN PERFORM fn_maize_rate('D');                           EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_receive_delivery(1, 'A', 0, CURRENT_DATE);    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN CALL pr_receive_delivery(1, 'Z', 10, CURRENT_DATE);   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected: %', SQLERRM; END;
    BEGIN INSERT INTO deliveries (farmer_id, grade, weight_kg) VALUES (1, 'A', -5);
                                                                EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK rejected (direct): %', SQLERRM; END;
END $$;

SELECT * FROM deliveries ORDER BY delivery_id;                   -- rates/values all set by the trigger

-- UPDATE re-prices too: changing the grade changes rate and value automatically
UPDATE deliveries SET grade = 'B' WHERE delivery_id = 1;         -- was A (K500) -> B (K400)
UPDATE deliveries SET grade = 'A' WHERE delivery_id = 1;         -- back to K500

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;        -- F003 shows 0

SET enable_seqscan = off;
EXPLAIN
SELECT delivery_id, grade, weight_kg, total_value
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);                     -- rerun replaces
SELECT * FROM daily_purchases;                                   -- 730 kg, K2600
