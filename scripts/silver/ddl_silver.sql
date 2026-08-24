ALTER TABLE b_bronze.procurement_orders
    ADD COLUMN bronze_id INT AUTO_INCREMENT PRIMARY KEY FIRST;

-- ---------------------------------------------------------------------
-- 1. Make sure the silver schema exists (run once — skip if already created)
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS s_silver;

-- ---------------------------------------------------------------------
-- 2. TARGET TABLE
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS s_silver.procurement_orders;

CREATE TABLE s_silver.procurement_orders (
    po_id                        VARCHAR(20)     PRIMARY KEY,
    supplier_id                   VARCHAR(20)     NOT NULL,
    raw_material_id                VARCHAR(20)     NOT NULL,
    order_date                    DATE            NOT NULL,
    order_quantity                 INT             NOT NULL,
    unit_cost                     DECIMAL(12,4)   NOT NULL,
    delivery_date_planned           DATE,
    delivery_date_actual            DATE,
    total_cost                    DECIMAL(14,4)   NOT NULL,
    -- recalculated + flags
    total_cost_calc                DECIMAL(14,4),
    total_cost_mismatch_flag       TINYINT(1),
    delivery_delay_days             INT,          -- actual - planned (positive = late)
    is_late_flag                   TINYINT(1),
    _silver_load_timestamp         TIMESTAMP       DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------------------------------------------------------
-- 3. TRANSFORM + LOAD FROM BRONZE
-- ---------------------------------------------------------------------
INSERT INTO s_silver.procurement_orders
SELECT
    TRIM(po_id)                                                        AS po_id,
    TRIM(supplier_id)                                                  AS supplier_id,
    TRIM(raw_material_id)                                              AS raw_material_id,

    -- source format is ISO (YYYY-MM-DD), same as product_master
    STR_TO_DATE(TRIM(order_date), '%Y-%m-%d')                          AS order_date,

    CAST(TRIM(order_quantity) AS UNSIGNED)                             AS order_quantity,
    ROUND(CAST(TRIM(unit_cost) AS DECIMAL(14,6)), 4)                    AS unit_cost,

    STR_TO_DATE(TRIM(delivery_date_planned), '%Y-%m-%d')                AS delivery_date_planned,
    STR_TO_DATE(TRIM(delivery_date_actual), '%Y-%m-%d')                 AS delivery_date_actual,

    ROUND(CAST(TRIM(total_cost) AS DECIMAL(16,6)), 4)                   AS total_cost,

    -- recompute total_cost = quantity * unit_cost, to catch bad source math
    ROUND(
        CAST(TRIM(order_quantity) AS UNSIGNED)
        * CAST(TRIM(unit_cost) AS DECIMAL(14,6))
    , 4)                                                                AS total_cost_calc,

    CASE
        WHEN ABS(
            CAST(TRIM(total_cost) AS DECIMAL(16,6)) -
            (CAST(TRIM(order_quantity) AS UNSIGNED) * CAST(TRIM(unit_cost) AS DECIMAL(14,6)))
        ) > 0.01 THEN 1
        ELSE 0
    END                                                                 AS total_cost_mismatch_flag,

    DATEDIFF(
        STR_TO_DATE(TRIM(delivery_date_actual), '%Y-%m-%d'),
        STR_TO_DATE(TRIM(delivery_date_planned), '%Y-%m-%d')
    )                                                                   AS delivery_delay_days,

    CASE
        WHEN STR_TO_DATE(TRIM(delivery_date_actual), '%Y-%m-%d') >
             STR_TO_DATE(TRIM(delivery_date_planned), '%Y-%m-%d')
        THEN 1 ELSE 0
    END                                                                 AS is_late_flag,

    CURRENT_TIMESTAMP                                                  AS _silver_load_timestamp

FROM b_bronze.procurement_orders AS src

-- ---------------------------------------------------------------------
-- 4. DEDUPLICATE (keep latest loaded row per po_id)
-- ---------------------------------------------------------------------
WHERE src.bronze_id IN (
    SELECT bronze_id FROM (
        SELECT bronze_id, po_id,
               ROW_NUMBER() OVER (
                   PARTITION BY po_id
                   ORDER BY bronze_id DESC
               ) AS rn
        FROM b_bronze.procurement_orders
    ) ranked
    WHERE rn = 1
);

-- ---------------------------------------------------------------------
-- 5. DATA QUALITY CHECKS
-- ---------------------------------------------------------------------

-- 5a. Total_cost mismatches vs recalculated
SELECT po_id, total_cost, total_cost_calc,
       ROUND(total_cost - total_cost_calc, 2) AS diff
FROM s_silver.procurement_orders
WHERE total_cost_mismatch_flag = 1;

-- 5b. Late deliveries
SELECT po_id, order_date, delivery_date_planned, delivery_date_actual, delivery_delay_days
FROM s_silver.procurement_orders
WHERE is_late_flag = 1;

-- 5c. raw_material_id values that don't exist in s_silver.product_master
--     (orphan foreign keys — worth checking since raw_material_id looks
--      like it references product_id)
SELECT DISTINCT po.raw_material_id
FROM s_silver.procurement_orders po
LEFT JOIN s_silver.product_master pm ON pm.product_id = po.raw_material_id
WHERE pm.product_id IS NULL;

-- 5d. Row count reconciliation: bronze vs silver
SELECT
    (SELECT COUNT(*) FROM b_bronze.procurement_orders) AS bronze_row_count,
    (SELECT COUNT(*) FROM s_silver.procurement_orders)  AS silver_row_count;
-------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------
-- 1. TARGET TABLE
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS s_silver.sales_orders;

CREATE TABLE s_silver.sales_orders (
    order_id                    VARCHAR(20)     PRIMARY KEY,
    customer_id                 VARCHAR(20)     NOT NULL,
    product_id                  VARCHAR(20)     NOT NULL,
    order_date                  DATE            NOT NULL,
    order_status                VARCHAR(20)     NOT NULL,
    order_quantity               INT             NOT NULL,
    unit_price                  DECIMAL(10,2)   NOT NULL,
    discount_rate                DECIMAL(5,2)    NOT NULL,
    shipping_mode                VARCHAR(20),
    shipping_carrier             VARCHAR(20),
    shipping_date_scheduled      DATE,
    shipping_date_actual         DATE,
    delivery_status               VARCHAR(20),
    late_delivery_risk_flag      TINYINT(1),
    vat_rate                    DECIMAL(5,2),
    cogs                        DECIMAL(10,2),
    unit_price_effective         DECIMAL(10,2),
    order_total                  DECIMAL(12,2),
    vat_amount                   DECIMAL(12,2),
    profit_per_order              DECIMAL(12,2),
    -- recalculated columns, used to flag mismatches against source math
    order_total_calc             DECIMAL(12,2),
    order_total_mismatch_flag    TINYINT(1),
    shipping_delay_days          INT,
    is_late_calc_flag             TINYINT(1),
    _silver_load_timestamp       TIMESTAMP       DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------------------------------------------------------
-- 2. TRANSFORM + LOAD FROM BRONZE
-- ---------------------------------------------------------------------
INSERT INTO s_silver.sales_orders
SELECT
    TRIM(order_id)                                                         AS order_id,
    TRIM(customer_id)                                                      AS customer_id,
    TRIM(product_id)                                                       AS product_id,

    -- text -> real DATE (source format e.g. "6/16/2023")
    STR_TO_DATE(TRIM(order_date), '%c/%e/%Y')                              AS order_date,

    -- standardize casing (completed / COMPLETED -> Completed)
    CONCAT(
        UPPER(SUBSTRING(TRIM(order_status), 1, 1)),
        LOWER(SUBSTRING(TRIM(order_status), 2))
    )                                                                       AS order_status,

    -- text -> numbers. CAST(... AS UNSIGNED/DECIMAL) since source column is VARCHAR
    CAST(TRIM(order_quantity) AS UNSIGNED)                                  AS order_quantity,
    ROUND(CAST(TRIM(unit_price) AS DECIMAL(12,4)), 2)                       AS unit_price,
    ROUND(CAST(TRIM(discount) AS DECIMAL(6,4)), 2)                          AS discount_rate,

    TRIM(shipping_mode)                                                    AS shipping_mode,
    TRIM(shipping_carrier)                                                 AS shipping_carrier,

    STR_TO_DATE(TRIM(shipping_date_scheduled), '%c/%e/%Y')                 AS shipping_date_scheduled,
    STR_TO_DATE(TRIM(shipping_date_actual), '%c/%e/%Y')                    AS shipping_date_actual,

    TRIM(delivery_status)                                                  AS delivery_status,
    CAST(TRIM(late_delivery_risk_flag) AS UNSIGNED)                        AS late_delivery_risk_flag,

    ROUND(CAST(TRIM(vat_rate) AS DECIMAL(6,4)), 2)                         AS vat_rate,
    ROUND(CAST(TRIM(cogs) AS DECIMAL(12,4)), 2)                            AS cogs,
    ROUND(CAST(TRIM(unit_price_effective) AS DECIMAL(12,4)), 4)            AS unit_price_effective,
    ROUND(CAST(TRIM(order_total) AS DECIMAL(14,4)), 2)                     AS order_total,
    ROUND(CAST(TRIM(vat_amount) AS DECIMAL(14,6)), 4)                      AS vat_amount,
    ROUND(CAST(TRIM(profit_per_order) AS DECIMAL(14,4)), 2)                AS profit_per_order,

    -- recompute order total from raw inputs to catch bad source math:
    -- Order_Total = Qty * Unit_Price * (1 - Discount) * (1 + VAT_Rate)
    ROUND(
        CAST(TRIM(order_quantity) AS UNSIGNED)
        * CAST(TRIM(unit_price) AS DECIMAL(12,4))
        * (1 - CAST(TRIM(discount) AS DECIMAL(6,4)))
        * (1 + CAST(TRIM(vat_rate) AS DECIMAL(6,4)))
    , 2)                                                                    AS order_total_calc,

    -- flag rows where source order_total drifts from the recomputed value
    -- by more than 1 cent (rounding tolerance)
    CASE
        WHEN ABS(
            CAST(TRIM(order_total) AS DECIMAL(14,4)) -
            (CAST(TRIM(order_quantity) AS UNSIGNED)
             * CAST(TRIM(unit_price) AS DECIMAL(12,4))
             * (1 - CAST(TRIM(discount) AS DECIMAL(6,4)))
             * (1 + CAST(TRIM(vat_rate) AS DECIMAL(6,4))))
        ) > 0.01 THEN 1
        ELSE 0
    END                                                                     AS order_total_mismatch_flag,

    DATEDIFF(
        STR_TO_DATE(TRIM(shipping_date_actual), '%c/%e/%Y'),
        STR_TO_DATE(TRIM(shipping_date_scheduled), '%c/%e/%Y')
    )                                                                       AS shipping_delay_days,

    -- recompute lateness independently of the source flag
    CASE
        WHEN STR_TO_DATE(TRIM(shipping_date_actual), '%c/%e/%Y') >
             STR_TO_DATE(TRIM(shipping_date_scheduled), '%c/%e/%Y')
        THEN 1 ELSE 0
    END                                                                     AS is_late_calc_flag,

    CURRENT_TIMESTAMP                                                      AS _silver_load_timestamp

FROM b_bronze.sales_orders AS src

-- ---------------------------------------------------------------------
-- 3. DEDUPLICATE (keep the most recently loaded row per order_id,
--    using bronze_id — the highest bronze_id per order_id = the latest
--    insert, since AUTO_INCREMENT always goes up)
-- ---------------------------------------------------------------------
WHERE src.bronze_id IN (
    SELECT bronze_id FROM (
        SELECT bronze_id, order_id,
               ROW_NUMBER() OVER (
                   PARTITION BY order_id
                   ORDER BY bronze_id DESC
               ) AS rn
        FROM b_bronze.sales_orders
    ) ranked
    WHERE rn = 1
);

-- ---------------------------------------------------------------------
-- 4. DATA QUALITY CHECKS (run after load — review before promoting to Gold)
-- ---------------------------------------------------------------------

-- 4a. Rows where source order_total doesn't match recalculated total
SELECT order_id, order_total, order_total_calc,
       ROUND(order_total - order_total_calc, 2) AS diff
FROM s_silver.sales_orders
WHERE order_total_mismatch_flag = 1;

-- 4b. Rows where source delivery_status disagrees with the recalculated flag
SELECT order_id, delivery_status, late_delivery_risk_flag, is_late_calc_flag
FROM s_silver.sales_orders
WHERE (delivery_status = 'Late'    AND is_late_calc_flag = 0)
   OR (delivery_status = 'On Time' AND is_late_calc_flag = 1);

-- 4c. Negative profit orders (not necessarily an error, but worth reviewing)
SELECT order_id, order_status, cogs, order_total, profit_per_order
FROM s_silver.sales_orders
WHERE profit_per_order < 0;

-- 4d. Row count reconciliation: bronze vs silver
SELECT
    (SELECT COUNT(*) FROM b_bronze.sales_orders) AS bronze_row_count,
    (SELECT COUNT(*) FROM s_silver.sales_orders)   AS silver_row_count;
--------------------------------------------------------------------------------------------  
--------------------------------------------------------------------------------------------
DROP TABLE IF EXISTS s_silver.customer_master;

CREATE TABLE s_silver.customer_master (
    customer_id            VARCHAR(20)     PRIMARY KEY,
    customer_name           VARCHAR(100)    NOT NULL,
    industry                VARCHAR(50)     NOT NULL,
    market_segment           VARCHAR(10)     NOT NULL,
    country                 VARCHAR(50)     NOT NULL,
    city                    VARCHAR(50)     NOT NULL,
    latitude                DECIMAL(9,6),
    longitude               DECIMAL(9,6),
    -- flags for values outside valid geographic bounds
    is_lat_out_of_range      TINYINT(1),
    is_lon_out_of_range      TINYINT(1),
    _silver_load_timestamp   TIMESTAMP       DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------------------------------------------------------
-- 3. TRANSFORM + LOAD FROM BRONZE
-- ---------------------------------------------------------------------
INSERT INTO s_silver.customer_master
SELECT
    TRIM(customer_id)                                          AS customer_id,
    TRIM(customer_name)                                        AS customer_name,

    -- standardize casing (education / EDUCATION -> Education)
    CONCAT(
        UPPER(SUBSTRING(TRIM(industry), 1, 1)),
        LOWER(SUBSTRING(TRIM(industry), 2))
    )                                                           AS industry,

    UPPER(TRIM(market_segment))                                AS market_segment,   -- B2B / B2C

    TRIM(country)                                              AS country,
    TRIM(city)                                                 AS city,

    ROUND(CAST(TRIM(latitude) AS DECIMAL(12,6)), 6)             AS latitude,
    ROUND(CAST(TRIM(longitude) AS DECIMAL(12,6)), 6)            AS longitude,

    -- valid latitude range is -90 to 90
    CASE
        WHEN CAST(TRIM(latitude) AS DECIMAL(12,6)) NOT BETWEEN -90 AND 90 THEN 1
        ELSE 0
    END                                                         AS is_lat_out_of_range,

    -- valid longitude range is -180 to 180
    CASE
        WHEN CAST(TRIM(longitude) AS DECIMAL(12,6)) NOT BETWEEN -180 AND 180 THEN 1
        ELSE 0
    END                                                         AS is_lon_out_of_range,

    CURRENT_TIMESTAMP                                          AS _silver_load_timestamp

FROM b_bronze.customer_master AS src

-- ---------------------------------------------------------------------
-- 4. DEDUPLICATE (keep latest loaded row per customer_id)
-- ---------------------------------------------------------------------
WHERE src.bronze_id IN (
    SELECT bronze_id FROM (
        SELECT bronze_id, customer_id,
               ROW_NUMBER() OVER (
                   PARTITION BY customer_id
                   ORDER BY bronze_id DESC
               ) AS rn
        FROM b_bronze.customer_master
    ) ranked
    WHERE rn = 1
);

-- ---------------------------------------------------------------------
-- 5. DATA QUALITY CHECKS
-- ---------------------------------------------------------------------

-- 5a. Any customer_id with no matching orders in silver.sales_orders
--     (orphan customers — not necessarily wrong, but worth knowing)
-- SELECT c.customer_id
-- FROM s_silver.customer_master c
-- LEFT JOIN s_silver.sales_orders o ON o.customer_id = c.customer_id
-- WHERE o.customer_id IS NULL;

-- 5b. Lat/long out of valid range
SELECT customer_id, latitude, longitude
FROM s_silver.customer_master
WHERE is_lat_out_of_range = 1 OR is_lon_out_of_range = 1;

-- 5c. Row count reconciliation: bronze vs silver
SELECT
    (SELECT COUNT(*) FROM b_bronze.customer_master) AS bronze_row_count,
    (SELECT COUNT(*) FROM s_silver.customer_master)  AS silver_row_count;

--------------------------------------------------------------------------------
ALTER TABLE b_bronze.product_master

    ADD COLUMN bronze_id INT AUTO_INCREMENT PRIMARY KEY FIRST;

-- ---------------------------------------------------------------------
-- 1. Make sure the silver schema exists (run once — skip if already created)
-- ---------------------------------------------------------------------


-- ---------------------------------------------------------------------
-- 2. TARGET TABLE
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS s_silver.product_master;

CREATE TABLE s_silver.product_master (
    product_id               VARCHAR(20)     PRIMARY KEY,
    sku                      VARCHAR(20)     NOT NULL,
    product_name              VARCHAR(100)    NOT NULL,
    category                 VARCHAR(50)     NOT NULL,
    subcategory               VARCHAR(20)     NOT NULL,
    unit                     VARCHAR(20)     NOT NULL,
    unit_cost                 DECIMAL(10,2)   NOT NULL,
    standard_price             DECIMAL(10,2)   NOT NULL,
    launch_date               DATE            NOT NULL,
    discontinuation_date       DATE,
    is_active                 TINYINT(1)      NOT NULL,   -- 1 = still sold (no discontinuation date)
    margin_amount              DECIMAL(10,2),              -- standard_price - unit_cost
    is_loss_making            TINYINT(1),                 -- unit_cost > standard_price
    _silver_load_timestamp    TIMESTAMP       DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------------------------------------------------------
-- 3. TRANSFORM + LOAD FROM BRONZE
-- ---------------------------------------------------------------------
INSERT INTO s_silver.product_master
SELECT
    TRIM(product_id)                                            AS product_id,
    TRIM(sku)                                                   AS sku,
    TRIM(product_name)                                          AS product_name,

    -- standardize casing (food / FOOD -> Food)
    CONCAT(
        UPPER(SUBSTRING(TRIM(category), 1, 1)),
        LOWER(SUBSTRING(TRIM(category), 2))
    )                                                            AS category,

    UPPER(TRIM(subcategory))                                    AS subcategory,
    LOWER(TRIM(unit))                                           AS unit,

    ROUND(CAST(TRIM(unit_cost) AS DECIMAL(12,4)), 2)             AS unit_cost,
    ROUND(CAST(TRIM(standard_price) AS DECIMAL(12,4)), 2)        AS standard_price,

    -- source format is already ISO (YYYY-MM-DD)
    STR_TO_DATE(TRIM(launch_date), '%Y-%m-%d')                  AS launch_date,

    -- discontinuation_date is blank for active products — NULLIF turns
    -- an empty string into a real NULL before casting, so STR_TO_DATE
    -- doesn't choke on ''
    STR_TO_DATE(NULLIF(TRIM(discontinuation_date), ''), '%Y-%m-%d') AS discontinuation_date,

    CASE
        WHEN NULLIF(TRIM(discontinuation_date), '') IS NULL THEN 1
        ELSE 0
    END                                                          AS is_active,

    ROUND(
        CAST(TRIM(standard_price) AS DECIMAL(12,4))
        - CAST(TRIM(unit_cost) AS DECIMAL(12,4))
    , 2)                                                         AS margin_amount,

    CASE
        WHEN CAST(TRIM(unit_cost) AS DECIMAL(12,4)) >
             CAST(TRIM(standard_price) AS DECIMAL(12,4)) THEN 1
        ELSE 0
    END                                                          AS is_loss_making,

    CURRENT_TIMESTAMP                                           AS _silver_load_timestamp

FROM b_bronze.product_master AS src

-- ---------------------------------------------------------------------
-- 4. DEDUPLICATE (keep latest loaded row per product_id)
-- ---------------------------------------------------------------------
WHERE src.bronze_id IN (
    SELECT bronze_id FROM (
        SELECT bronze_id, product_id,
               ROW_NUMBER() OVER (
                   PARTITION BY product_id
                   ORDER BY bronze_id DESC
               ) AS rn
        FROM b_bronze.product_master
    ) ranked
    WHERE rn = 1
);

-- ---------------------------------------------------------------------
-- 5. DATA QUALITY CHECKS
-- ---------------------------------------------------------------------

-- 5a. Products where discontinuation_date is before launch_date (invalid)
SELECT product_id, launch_date, discontinuation_date
FROM s_silver.product_master
WHERE discontinuation_date IS NOT NULL
  AND discontinuation_date < launch_date;

-- 5b. Loss-making products (cost higher than standard price)
SELECT product_id, product_name, unit_cost, standard_price, margin_amount
FROM s_silver.product_master
WHERE is_loss_making = 1;

-- 5c. Row count reconciliation: bronze vs silver
SELECT
    (SELECT COUNT(*) FROM b_bronze.product_master) AS bronze_row_count,
    (SELECT COUNT(*) FROM s_silver.product_master)  AS silver_row_count;

--------------------------------------------------------------------------------------------
ALTER TABLE b_bronze.supplier_master
    ADD COLUMN bronze_id INT AUTO_INCREMENT PRIMARY KEY FIRST;

-- ---------------------------------------------------------------------
-- 1. Make sure the silver schema exists (run once — skip if already created)
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS s_silver;

-- ---------------------------------------------------------------------
-- 2. TARGET TABLE
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS s_silver.supplier_master;

CREATE TABLE s_silver.supplier_master (
    supplier_id                  VARCHAR(20)     PRIMARY KEY,
    supplier_name                 VARCHAR(100)    NOT NULL,
    country                      VARCHAR(50)     NOT NULL,
    region                       VARCHAR(20)     NOT NULL,
    on_time_delivery_rate           DECIMAL(5,4)    NOT NULL,
    certification_level             VARCHAR(20)     NOT NULL,   -- 'None' kept as a valid value, not NULL
    is_certified                  TINYINT(1)      NOT NULL,   -- 0 if certification_level = 'None'
    preferred_supplier_flag         TINYINT(1)      NOT NULL,
    _silver_load_timestamp         TIMESTAMP       DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------------------------------------------------------
-- 3. TRANSFORM + LOAD FROM BRONZE
-- ---------------------------------------------------------------------
INSERT INTO s_silver.supplier_master
SELECT
    TRIM(supplier_id)                                          AS supplier_id,
    TRIM(supplier_name)                                        AS supplier_name,
    TRIM(country)                                              AS country,
    TRIM(region)                                               AS region,

    ROUND(CAST(TRIM(on_time_delivery_rate) AS DECIMAL(8,6)), 4) AS on_time_delivery_rate,

    -- 21 rows have the literal text "None" (no blank/NULL in source) —
    -- this IS a valid business value ("no certification"), so we keep it
    -- as-is rather than turning it into NULL
    COALESCE(NULLIF(TRIM(certification_level), ''), 'None')     AS certification_level,

    CASE
        WHEN TRIM(certification_level) = 'None'
          OR TRIM(certification_level) = '' THEN 0
        ELSE 1
    END                                                         AS is_certified,

    CAST(TRIM(preferred_supplier_flag) AS UNSIGNED)             AS preferred_supplier_flag,

    CURRENT_TIMESTAMP                                          AS _silver_load_timestamp

FROM b_bronze.supplier_master AS src

-- ---------------------------------------------------------------------
-- 4. DEDUPLICATE (keep latest loaded row per supplier_id)
-- ---------------------------------------------------------------------
WHERE src.bronze_id IN (
    SELECT bronze_id FROM (
        SELECT bronze_id, supplier_id,
               ROW_NUMBER() OVER (
                   PARTITION BY supplier_id
                   ORDER BY bronze_id DESC
               ) AS rn
        FROM b_bronze.supplier_master
    ) ranked
    WHERE rn = 1
);

-- ---------------------------------------------------------------------
-- 5. DATA QUALITY CHECKS
-- ---------------------------------------------------------------------

-- 5a. On_time_delivery_rate outside a sane 0–1 range
SELECT supplier_id, on_time_delivery_rate
FROM s_silver.supplier_master
WHERE on_time_delivery_rate NOT BETWEEN 0 AND 1;

-- 5b. supplier_id values in procurement_orders that don't exist here
--     (orphan foreign keys)
SELECT DISTINCT po.supplier_id
FROM s_silver.procurement_orders po
LEFT JOIN s_silver.supplier_master sm ON sm.supplier_id = po.supplier_id
WHERE sm.supplier_id IS NULL;

-- 5c. Row count reconciliation: bronze vs silver
SELECT
    (SELECT COUNT(*) FROM b_bronze.supplier_master) AS bronze_row_count,
    (SELECT COUNT(*) FROM s_silver.supplier_master)  AS silver_row_count;
