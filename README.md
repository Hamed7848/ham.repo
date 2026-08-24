# Multi-Source Data Pipeline & Analytics Layer (Bronze → Silver → Gold)

A medallion-architecture data pipeline built in **MySQL**, transforming five raw business datasets into a clean, analysis-ready star schema, with Power BI dashboards on top.

## Overview

This project simulates a real-world data engineering workflow for a retail/procurement business, taking raw CSV exports through three progressive layers of data quality — **Bronze** (raw), **Silver** (cleaned & validated), and **Gold** (business-ready facts, dimensions, and KPIs) — following the same layering approach used in modern data platforms like Databricks and Microsoft Fabric.

## Datasets

| Dataset | Rows | Description |
|---|---|---|
| `sales_orders` | 20,000 | Customer sales transactions |
| `customer_master` | 500 | Customer reference data |
| `product_master` | 200 | Product catalog and pricing |
| `procurement_orders` | 2,000 | Purchase orders from suppliers |
| `supplier_master` | 100 | Supplier reference and performance data |

## Architecture

```
Raw CSVs
   │
   ▼
┌─────────────┐     type casting, dedup, standardization,
│   BRONZE    │ →   business-rule validation (recalculated
│  (b_bronze) │     totals, mismatch flags, orphan-key checks)
└─────────────┘
   │
   ▼
┌─────────────┐     star schema: dimension + fact tables,
│   SILVER    │ →   pre-aggregated KPI tables
│  (s_silver) │
└─────────────┘
   │
   ▼
┌─────────────┐
│    GOLD     │ →   Power BI dashboards (DAX measures)
│   (g_gold)  │
└─────────────┘
```

### Bronze Layer
Raw data loaded as-is (all columns as `VARCHAR`) with an auto-incrementing `bronze_id` surrogate key added per table to support ordered deduplication in later layers — no transformation, no business logic.

### Silver Layer
- Type casting (text → `DATE`, `DECIMAL`, `INT`)
- Deduplication — keeps the latest-loaded row per business key
- Text standardization (casing, whitespace trimming)
- **Business rule validation**: recalculates derived fields (e.g. order totals, VAT) from raw inputs and flags any row where the source value doesn't match
- Cross-field consistency checks (e.g. delivery status vs. calculated lateness from shipping dates)

### Gold Layer
Implemented as **SQL views** (not physical tables) — each object queries live against Silver on every read, so the Gold layer always reflects the current state of Silver with no separate refresh/load step needed.
- **Dimension views**: `dim_customer`, `dim_product`, `dim_supplier`
- **Fact views**: `fact_sales`, `fact_procurement`
- **Pre-aggregated KPI views**: `supplier_performance_summary`, `product_profitability_summary`, `monthly_sales_summary`

## Data Quality Checks

Every Silver-layer script includes automated checks run after load, including:
- Recalculated totals vs. source totals (mismatch flags)
- Delivery/status field consistency
- Orphan foreign keys across related tables (e.g. procurement orders referencing a supplier that doesn't exist)
- Row-count reconciliation between Bronze and Silver

## Power BI / DAX Layer

Built on top of `g_gold.fact_procurement` and `g_gold.dim_supplier`, including:
- `Total Spend`, `Total Purchase Orders`, `Avg Delivery Delay (Days)`
- `Actual On-Time Rate` (recalculated from shipping dates, not taken at face value from the source)
- `On-Time Rate Gap` — compares each supplier's *self-reported* on-time rate against their *actual* calculated rate
- `Supplier Spend Rank` (via `RANKX`)

## Tech Stack

- **SQL** (MySQL / SQL Workbench) — ETL logic, window functions, data validation
- **Power BI** — dashboarding, DAX measures, star-schema data modeling

## Repository Structure

```
├── bronze/
│   ├── bronze_sales_orders.sql
│   ├── bronze_customer_master.sql
│   ├── bronze_product_master.sql
│   ├── bronze_procurement_orders.sql
│   └── bronze_supplier_master.sql
├── silver/
│   ├── silver_sales_orders.sql
│   ├── silver_customer_master.sql
│   ├── silver_product_master.sql
│   ├── silver_procurement_orders.sql
│   └── silver_supplier_master.sql
├── gold/
│   └── gold_layer.sql   (views: dimensions, facts, and KPI summaries)
└── README.md
```

## Key Design Decisions

- **Bronze tables store everything as `VARCHAR`.** This preserves source fidelity — a malformed date or number is still captured, not silently dropped — with all type conversion and validation happening explicitly in Silver.
- **Every business total is recalculated, not trusted blindly.** Order totals, VAT, and delivery lateness are all independently recomputed from raw fields and compared against the source values, surfacing potential upstream data issues rather than propagating them downstream.
- **Deduplication uses an auto-increment surrogate key (`bronze_id`)** rather than a load timestamp, since the source tables had no natural ordering column — the highest `bronze_id` per business key is always the most recently loaded row.
- **Gold-layer objects are views, not materialized tables.** This keeps the layer always in sync with Silver without a separate load step — the trade-off is that queries against Gold re-run the underlying joins/aggregations each time, which is acceptable at this dataset's scale but would need revisiting (e.g. materialized tables refreshed on a schedule) at larger volumes.

## Author

**Hamed Ahmed Hamed** — [LinkedIn](https://linkedin.com/in/hamed-ahmed-data)
