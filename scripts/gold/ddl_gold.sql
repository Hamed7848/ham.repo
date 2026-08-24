-- =====================================================================
-- GOLD LAYER — Facts, Dimensions & Reporting Tables
-- Reads from: s_silver.*   |   Writes to: g_gold schema
-- Star-schema style: dimension tables (who/what) + fact tables (events)
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS g_gold;

-- =====================================================================
-- SECTION A — DIMENSION TABLES (descriptive lookup tables)
-- =====================================================================

-- ---------------------------------------------------------------------
-- A1. dim_customer
-- ---------------------------------------------------------------------
DROP view IF EXISTS g_gold.dim_customer;
CREATE view g_gold.dim_customer AS
SELECT
    customer_id,
    customer_name,
    industry,
    market_segment,
    country,
    city
FROM s_silver.customer_master;

ALTER TABLE g_gold.dim_customer ADD PRIMARY KEY (customer_id);

-- ---------------------------------------------------------------------
-- A2. dim_product
-- ---------------------------------------------------------------------
DROP view IF EXISTS g_gold.dim_product;
CREATE view g_gold.dim_product AS
SELECT
    product_id,
    sku,
    product_name,
    category,
    subcategory,
    unit_cost,
    standard_price,
    margin_amount,
    is_active
FROM s_silver.product_master;

ALTER table g_gold.dim_product ADD PRIMARY KEY (product_id);

-- ---------------------------------------------------------------------
-- A3. dim_supplier
-- ---------------------------------------------------------------------
DROP view IF EXISTS g_gold.dim_supplier;
CREATE view g_gold.dim_supplier AS
SELECT
    supplier_id,
    supplier_name,
    country,
    region,
    on_time_delivery_rate,
    certification_level,
    is_certified,
    preferred_supplier_flag
FROM s_silver.supplier_master;

ALTER TABLE g_gold.dim_supplier ADD PRIMARY KEY (supplier_id);

-- =====================================================================
-- SECTION B — FACT TABLES (transactions / events, one row per business event)
-- =====================================================================

-- ---------------------------------------------------------------------
-- B1. fact_sales — one row per sales order line
-- ---------------------------------------------------------------------
DROP view IF EXISTS g_gold.fact_sales;
CREATE view g_gold.fact_sales AS
SELECT
    o.order_id,
    o.customer_id,
    o.product_id,
    o.order_date,
    o.order_status,
    o.order_quantity,
    o.unit_price,
    o.discount_rate,
    o.order_total,
    o.vat_amount,
    o.cogs,
    o.profit_per_order,
    o.shipping_mode,
    o.shipping_carrier,
    o.delivery_status,
    o.shipping_delay_days,
    o.is_late_calc_flag,
    c.customer_name       AS customer_name,
    c.industry           AS customer_industry,
    c.market_segment      AS customer_segment,
    c.country            AS customer_country,
    p.product_name        AS product_name,
    p.category           AS product_category,
    p.subcategory         AS product_subcategory
FROM s_silver.sales_orders o
LEFT JOIN s_silver.customer_master c ON c.customer_id = o.customer_id
LEFT JOIN s_silver.product_master p  ON p.product_id  = o.product_id;

ALTER TABLE g_gold.fact_sales ADD PRIMARY KEY (order_id);

-- ---------------------------------------------------------------------
-- B2. fact_procurement — one row per purchase order line
-- ---------------------------------------------------------------------
DROP view IF EXISTS g_gold.fact_procurement;
CREATE view g_gold.fact_procurement AS
SELECT
    po.po_id,
    po.supplier_id,
    po.raw_material_id AS product_id,
    po.order_date,
    po.order_quantity,
    po.unit_cost,
    po.total_cost,
    po.delivery_date_planned,
    po.delivery_date_actual,
    po.delivery_delay_days,
    po.is_late_flag,
    s.supplier_name,
    s.country          AS supplier_country,
    s.region           AS supplier_region,
    s.is_certified,
    s.preferred_supplier_flag
FROM s_silver.procurement_orders po
LEFT JOIN s_silver.supplier_master s ON s.supplier_id = po.supplier_id;

ALTER table g_gold.fact_procurement ADD PRIMARY KEY (po_id);

-- =====================================================================
-- SECTION C — REPORTING / KPI TABLES (pre-aggregated summaries)
-- =====================================================================

-- ---------------------------------------------------------------------
-- C1. supplier_performance_summary
--     Procurement-focused KPI table: on-time delivery, spend, and
--     delay comparison per supplier
-- ---------------------------------------------------------------------
DROP view IF EXISTS g_gold.supplier_performance_summary;
CREATE view g_gold.supplier_performance_summary AS
SELECT
    s.supplier_id,
    s.supplier_name,
    s.country,
    s.region,
    s.certification_level,
    s.preferred_supplier_flag,
    s.on_time_delivery_rate                        AS stated_on_time_rate,
    COUNT(po.po_id)                                 AS total_purchase_orders,
    SUM(po.total_cost)                              AS total_spend,
    ROUND(AVG(po.delivery_delay_days), 2)            AS avg_delivery_delay_days,
    ROUND(
        SUM(CASE WHEN po.is_late_flag = 0 THEN 1 ELSE 0 END) / COUNT(po.po_id)
    , 4)                                             AS actual_on_time_rate
FROM g_gold.dim_supplier s
LEFT JOIN s_silver.procurement_orders po ON po.supplier_id = s.supplier_id
GROUP BY s.supplier_id, s.supplier_name, s.country, s.region,
         s.certification_level, s.preferred_supplier_flag, s.on_time_delivery_rate;

-- ---------------------------------------------------------------------
-- C2. product_profitability_summary
--     Sales-side profitability per product
-- ---------------------------------------------------------------------
DROP view IF EXISTS g_gold.product_profitability_summary;
CREATE view g_gold.product_profitability_summary AS
SELECT
    p.product_id,
    p.product_name,
    p.category,
    COUNT(o.order_id)         AS total_orders,
    SUM(o.order_quantity)      AS total_quantity_sold,
    SUM(o.order_total)         AS total_revenue,
    SUM(o.profit_per_order)     AS total_profit,
    ROUND(AVG(o.profit_per_order), 2) AS avg_profit_per_order
FROM g_gold.dim_product p
LEFT JOIN s_silver.sales_orders o ON o.product_id = p.product_id
GROUP BY p.product_id, p.product_name, p.category;

-- ---------------------------------------------------------------------
-- C3. monthly_sales_summary
--     Time-based rollup, useful for trend charts
-- ---------------------------------------------------------------------
DROP view IF EXISTS g_gold.monthly_sales_summary;
CREATE view g_gold.monthly_sales_summary AS
SELECT
    DATE_FORMAT(order_date, '%Y-%m')  AS order_month,
    COUNT(order_id)                   AS total_orders,
    SUM(order_total)                  AS total_revenue,
    SUM(profit_per_order)              AS total_profit,
    ROUND(AVG(profit_per_order), 2)     AS avg_profit_per_order
FROM s_silver.sales_orders
GROUP BY DATE_FORMAT(order_date, '%Y-%m')
ORDER BY order_month;
