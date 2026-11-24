-- ICT371 Advanced Database - Mulungushi University
-- Student: Augustine lukaki (202306775)
-- Question 9: Farmer Cooperative Maize Deliveries
-- PostgreSQL / PL/pgSQL

-- Grade A pays K5/kg, grade B K4/kg and grade C K3/kg. The BEFORE trigger calculates rate
-- and total value for both procedure-based and direct SQL inserts.

-- ============================================================
-- 9(a) Tables and seed data
-- Three farmers and six deliveries are loaded after the trigger is installed.

CREATE TABLE farmers (
 farmer_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 farmer_number VARCHAR(30) UNIQUE NOT NULL,full_name VARCHAR(120) NOT NULL
);
CREATE TABLE deliveries (
 delivery_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 farmer_id BIGINT NOT NULL REFERENCES farmers(farmer_id),
 grade CHAR(1) NOT NULL CHECK(grade IN ('A','B','C')),
 weight_kg NUMERIC(12,2) NOT NULL CHECK(weight_kg>0),
 unit_rate NUMERIC(8,2) NOT NULL,total_value NUMERIC(14,2) NOT NULL,
 delivered_on DATE NOT NULL,is_paid BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE daily_purchases (
 purchase_date DATE PRIMARY KEY,total_weight NUMERIC(14,2) NOT NULL,
 total_value NUMERIC(14,2) NOT NULL
);
INSERT INTO farmers(farmer_number,full_name) VALUES
 ('F001','Mwamba'),('F002','Banda'),('F003','Phiri');

-- ============================================================
-- 9(b) Grade-rate function
-- Returns the rate for A, B or C and rejects unsupported values.

CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade CHAR(1))
RETURNS NUMERIC(8,2) LANGUAGE plpgsql AS $$
BEGIN
 IF p_grade IS NULL THEN RAISE EXCEPTION 'Grade is required'; END IF;
 CASE UPPER(p_grade)
  WHEN 'A' THEN RETURN 5.00;
  WHEN 'B' THEN RETURN 4.00;
  WHEN 'C' THEN RETURN 3.00;
  ELSE RAISE EXCEPTION 'Unsupported maize grade %',p_grade;
 END CASE;
END; $$;

-- ============================================================
-- 9(c) Delivery procedure
-- Inserts only basic values. The trigger fills unit_rate and total_value.

CREATE OR REPLACE PROCEDURE pr_receive_delivery(
 p_farmer_id BIGINT,p_grade CHAR(1),p_weight NUMERIC(12,2),p_date DATE
) LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM farmers WHERE farmer_id=p_farmer_id) THEN
  RAISE EXCEPTION 'Unknown farmer';
 END IF;
 IF p_weight IS NULL OR p_weight<=0 OR p_date IS NULL THEN
  RAISE EXCEPTION 'Invalid delivery weight or date';
 END IF;
 PERFORM fn_maize_rate(p_grade);
 INSERT INTO deliveries(farmer_id,grade,weight_kg,unit_rate,total_value,delivered_on,is_paid)
 VALUES(p_farmer_id,UPPER(p_grade),p_weight,0,0,p_date,FALSE);
END; $$;

-- ============================================================
-- 9(d) Pricing trigger
-- The trigger overrides rate and value on every insert or relevant update, ensuring direct
-- SQL follows the pricing rule.

CREATE OR REPLACE FUNCTION fn_set_delivery_value()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.weight_kg IS NULL OR NEW.weight_kg<=0 THEN
  RAISE EXCEPTION 'Delivery weight must be positive';
 END IF;
 NEW.grade:=UPPER(NEW.grade);
 NEW.unit_rate:=fn_maize_rate(NEW.grade);
 NEW.total_value:=ROUND(NEW.weight_kg*NEW.unit_rate,2);
 RETURN NEW;
END; $$;
CREATE TRIGGER trg_set_delivery_value
BEFORE INSERT OR UPDATE OF grade,weight_kg ON deliveries
FOR EACH ROW EXECUTE FUNCTION fn_set_delivery_value();
-- Six records: all grades and both paid states are represented.
CALL pr_receive_delivery(1,'A',100,CURRENT_DATE);
CALL pr_receive_delivery(1,'B',80,CURRENT_DATE);
CALL pr_receive_delivery(2,'C',120,CURRENT_DATE);
CALL pr_receive_delivery(2,'A',50,CURRENT_DATE);
CALL pr_receive_delivery(3,'B',75,CURRENT_DATE);
CALL pr_receive_delivery(3,'C',60,CURRENT_DATE);
UPDATE deliveries SET is_paid=TRUE WHERE delivery_id IN (1,3,5);

-- ============================================================
-- 9(e) Farmer amount-due view
-- LEFT JOIN includes farmers with no unpaid deliveries and COALESCE displays zero.

CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,f.full_name,
       COALESCE(SUM(d.total_value) FILTER(WHERE d.is_paid=FALSE),0) AS amount_due
FROM farmers f LEFT JOIN deliveries d ON d.farmer_id=f.farmer_id
GROUP BY f.farmer_id,f.farmer_number,f.full_name;

-- ============================================================
-- 9(f) Composite index
-- Farmer equality followed by delivered_on date range is supported by this index.

CREATE INDEX idx_deliveries_farmer_date ON deliveries(farmer_id,delivered_on);
EXPLAIN SELECT delivery_id,grade,weight_kg,total_value
FROM deliveries WHERE farmer_id=1
AND delivered_on>=DATE '2026-11-01' AND delivered_on<DATE '2026-12-01';

-- ============================================================
-- 9(g) Daily purchase summary and schedule
-- UPSERT replaces daily totals instead of adding them on repeated execution.

CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO daily_purchases(purchase_date,total_weight,total_value)
 SELECT p_day,COALESCE(SUM(weight_kg),0),COALESCE(SUM(total_value),0)
 FROM deliveries WHERE delivered_on=p_day
 ON CONFLICT(purchase_date) DO UPDATE SET
 total_weight=EXCLUDED.total_weight,total_value=EXCLUDED.total_value;
END; $$;
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('daily-maize-purchases','30 1 * * *',
 $$CALL pr_refresh_purchases(CURRENT_DATE-1)$$);
