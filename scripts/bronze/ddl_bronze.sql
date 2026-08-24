create table b_bronze.customer_master(
bronze_id int(11),
customer_id varchar(50),
customer_name varchar(255),
industry varchar(100),
market_segment varchar(50),
country varchar(100),
city varchar(100),
latitude varchar(50),
longitude varchar(50)
);
create table b_bronze.procurement_orders(
po_id varchar(50),
supplier_id varchar(50),
raw_material_id varchar(50),
order_date varchar(50),
order_quantity varchar(50),
unit_cost varchar(50),
delivery_date_planned varchar(50),
delivery_date_actual varchar(50),
total_cost varchar(50)
);
create table b_bronze.product_master(
bronze_id int(11),
product_id varchar(50),
sku varchar(50),
product_name varchar(255),
category varchar(100),
subcategory varchar(100),
unit varchar(20),
unit_cost varchar(50),
standard_price varchar(50),
launch_date varchar(50),
discontinuation_date varchar(50)
);
create table b_bronze.sales_orders (
bronze_id int(11),
order_id varchar(50),
customer_id varchar(50),
product_id varchar(50),
order_date varchar(50),
order_status varchar(50),
order_quantity varchar(50),
unit_price varchar(50),
discount varchar(50),
shipping_mode varchar(50),
shipping_carrier varchar(50),
shipping_date_scheduled varchar(50),
shipping_date_actual varchar(50),
delivery_status varchar(50),
late_delivery_risk_flag varchar(10),
vat_rate varchar(50),
cogs varchar(50),
unit_price_effective varchar(50),
order_total varchar(50),
vat_amount varchar(50),
profit_per_order varchar(50)
);
create table b_bronze.supplier_master(
supplier_id varchar(50),
supplier_name varchar(255),
country varchar(100),
region varchar(100),
on_time_delivery_rate varchar(50),
certification_level varchar(100),
preferred_supplier_flag varchar(10)
);

