#######that all about gold layer ################
create view gold.dim_customer as
with rankeddate as 
    (select
		row_number()over (order by cst_id) as cutomer_key,
        ci.cst_id as customer_id,
        ci.cst_key as customer_number,
	    ci.cst_firstname as first_name,
        ci.cst_lastname as last_name,
        ci.cst_material_status as material_status,
        case when ci.cst_gndr != 'n/a' then ci.cst_gndr 
             else coalesce(ca.gen, 'n/a')
        end  gender,     
        ci.dwh_create_date as create_date,
        ca.bdate as birth_date,
        la.cntry as country,
        row_number() over(partition by ci.cst_id order by ci.dwh_create_date desc) as rn
      from silver.crm_cust_info ci
      left join silver.erp_cust_az12 ca
      on   ci.cst_key= ca.cid
      left join silver.erp_loc_a101 la
	  on   ci.cst_key= la.cid
)
select*
from rankeddate
where rn = 1;
###########################################################################
CREATE VIEW gold.dim_products AS
SELECT
    ROW_NUMBER() OVER (ORDER BY pn.prd_start_dt, pn.prd_key) AS product_key, -- Surrogate key
    pn.prd_id       AS product_id,
    pn.prd_key      AS product_number,
    pn.prd_nm       AS product_name,
    pn.cat_id       AS category_id,
    pc.cat          AS category,
    pc.subcat       AS subcategory,
    pc.maintenance  AS maintenance,
    pn.prd_cost     AS cost,
    pn.prd_line     AS product_line,
    pn.prd_start_dt AS start_date
FROM silver.crm_prd_info pn
LEFT JOIN silver.erp_px_cat_g1v2 pc
    ON pn.cat_id = pc.id
WHERE pn.prd_end_dt IS NULL;
############################################################################
create view gold.fact_sales as 
select
sls_ord_num as order_number,
pr.product_key,
cu.customer_key,
sd.sls_order_dt  as order_date,
sd.sls_ship_dt as shipping_date,
sd.sls_due_dt as due_date,
sd.sls_sales as sales_amount,
sd.sls_quantity as quantity,
sd.sls_price as price
from silver.crm_sales_details sd 
left join gold.dim_products pr
on sd.sls_prd_key=pr.product_number
left join gold.dim_customers cu
on sd.sls_cust_id= cu.customer_id;
