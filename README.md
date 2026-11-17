# Inventory and Warehouse Management

An intermediate MySQL project based on the attached brief. It models products supplied by vendors and stocked across warehouses, with auditable movements, automatic balance updates, reorder reporting, purchase reporting, transfers, and CSV workflows.

## Run it

Use MySQL 8.0.16 or newer with InnoDB. Create a fresh database, then run `inventory_management.sql` with the MySQL client:

```sh
mysql -u your_user -p -e "CREATE DATABASE inventory_demo;"
mysql -u your_user -p inventory_demo < inventory_management.sql
```

The script creates the schema, triggers and view, inserts a small example dataset, then runs the two sample reports. It is intended for a fresh database because table creation is not idempotent.

## Main design choices

- `inventory` stores the current quantity for each product and warehouse.
- `stock_movements` is the audit ledger. Receipts, sales, adjustments, and transfer legs are recorded there.
- A `BEFORE INSERT` trigger locks the balance row and rejects any movement that would take stock below zero; an `AFTER INSERT` trigger applies accepted movements to the balance.
- Movement records are immutable. Record a correcting adjustment instead of editing history.
- `reorder_list` compares each active product's balance at each warehouse to its minimum level.
- Purchase order headers and lines store supplier-wise purchasing history.
- A transfer uses two movement rows in one transaction and shares a `transfer_group` UUID. If either leg fails, the transaction rolls back both.

## Example operations

The SQL file includes examples for recording a sale, transferring stock atomically, importing a supplier price CSV through a staging table, and exporting a stock valuation report. Update the placeholder file paths and IDs before running those examples. `LOAD DATA LOCAL INFILE` may need to be enabled in both the MySQL client and server. `INTO OUTFILE` writes on the database server and is restricted by MySQL's `secure_file_priv` setting.

The CSV price import updates existing SKUs only. Its unmatched-SKU query is included so new products can be reviewed and inserted deliberately rather than silently created.
