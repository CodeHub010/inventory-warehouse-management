-- Inventory and Warehouse Management (MySQL 8.0.16+ / InnoDB)
-- Run in a fresh database. Quantities are stored per product/warehouse.

CREATE TABLE suppliers (
    supplier_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    supplier_name VARCHAR(200) NOT NULL UNIQUE,
    contact_name VARCHAR(150),
    email VARCHAR(254),
    phone VARCHAR(40),
    active BOOLEAN NOT NULL DEFAULT TRUE
) ENGINE=InnoDB;

CREATE TABLE products (
    product_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    sku VARCHAR(80) NOT NULL UNIQUE,
    product_name VARCHAR(200) NOT NULL,
    description TEXT,
    unit_cost DECIMAL(12,2) NOT NULL CHECK (unit_cost >= 0),
    reorder_level INT UNSIGNED NOT NULL DEFAULT 0,
    preferred_supplier_id BIGINT UNSIGNED,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT fk_products_supplier FOREIGN KEY (preferred_supplier_id) REFERENCES suppliers(supplier_id)
) ENGINE=InnoDB;

CREATE TABLE warehouses (
    warehouse_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    warehouse_name VARCHAR(150) NOT NULL UNIQUE,
    location VARCHAR(255)
) ENGINE=InnoDB;

CREATE TABLE inventory (
    product_id BIGINT UNSIGNED NOT NULL,
    warehouse_id BIGINT UNSIGNED NOT NULL,
    quantity INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (product_id, warehouse_id),
    CONSTRAINT fk_inventory_product FOREIGN KEY (product_id) REFERENCES products(product_id),
    CONSTRAINT fk_inventory_warehouse FOREIGN KEY (warehouse_id) REFERENCES warehouses(warehouse_id)
) ENGINE=InnoDB;

CREATE TABLE purchase_orders (
    purchase_order_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    supplier_id BIGINT UNSIGNED NOT NULL,
    ordered_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status ENUM('open','received','cancelled') NOT NULL DEFAULT 'open',
    notes TEXT,
    CONSTRAINT fk_po_supplier FOREIGN KEY (supplier_id) REFERENCES suppliers(supplier_id)
) ENGINE=InnoDB;

CREATE TABLE purchase_order_items (
    purchase_order_id BIGINT UNSIGNED NOT NULL,
    product_id BIGINT UNSIGNED NOT NULL,
    quantity INT UNSIGNED NOT NULL,
    unit_cost DECIMAL(12,2) NOT NULL,
    PRIMARY KEY (purchase_order_id, product_id),
    CONSTRAINT chk_poi_quantity CHECK (quantity > 0),
    CONSTRAINT chk_poi_cost CHECK (unit_cost >= 0),
    CONSTRAINT fk_poi_order FOREIGN KEY (purchase_order_id) REFERENCES purchase_orders(purchase_order_id) ON DELETE CASCADE,
    CONSTRAINT fk_poi_product FOREIGN KEY (product_id) REFERENCES products(product_id)
) ENGINE=InnoDB;

CREATE TABLE stock_movements (
    movement_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    product_id BIGINT UNSIGNED NOT NULL,
    warehouse_id BIGINT UNSIGNED NOT NULL,
    quantity_delta INT NOT NULL,
    movement_type ENUM('receipt','sale','adjustment','transfer_in','transfer_out') NOT NULL,
    purchase_order_id BIGINT UNSIGNED,
    transfer_group CHAR(36),
    note VARCHAR(500),
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_movement_nonzero CHECK (quantity_delta <> 0),
    CONSTRAINT chk_movement_direction CHECK (
      (movement_type IN ('receipt','transfer_in') AND quantity_delta > 0) OR
      (movement_type IN ('sale','transfer_out') AND quantity_delta < 0) OR
      movement_type = 'adjustment'
    ),
    CONSTRAINT fk_movement_product FOREIGN KEY (product_id) REFERENCES products(product_id),
    CONSTRAINT fk_movement_warehouse FOREIGN KEY (warehouse_id) REFERENCES warehouses(warehouse_id),
    CONSTRAINT fk_movement_order FOREIGN KEY (purchase_order_id) REFERENCES purchase_orders(purchase_order_id),
    INDEX stock_movements_product_time_idx (product_id, created_at),
    INDEX stock_movements_warehouse_time_idx (warehouse_id, created_at)
) ENGINE=InnoDB;

DELIMITER $$

-- BEFORE INSERT blocks negative balances. The inventory row is locked to serialize
-- concurrent movements for the same product and warehouse.
CREATE TRIGGER stock_movement_before_insert
BEFORE INSERT ON stock_movements
FOR EACH ROW
BEGIN
    DECLARE current_qty INT UNSIGNED DEFAULT 0;

    INSERT INTO inventory(product_id, warehouse_id, quantity)
    VALUES (NEW.product_id, NEW.warehouse_id, 0)
    ON DUPLICATE KEY UPDATE quantity = quantity;

    SELECT quantity INTO current_qty
    FROM inventory
    WHERE product_id = NEW.product_id AND warehouse_id = NEW.warehouse_id
    FOR UPDATE;

    IF CAST(current_qty AS SIGNED) + NEW.quantity_delta < 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Insufficient stock: movement would make inventory negative';
    END IF;
END$$

-- AFTER INSERT applies the accepted movement to the current balance.
CREATE TRIGGER stock_movement_after_insert
AFTER INSERT ON stock_movements
FOR EACH ROW
BEGIN
    UPDATE inventory
    SET quantity = quantity + NEW.quantity_delta
    WHERE product_id = NEW.product_id AND warehouse_id = NEW.warehouse_id;
END$$

-- Keep the audit ledger immutable; add a correcting adjustment instead.
CREATE TRIGGER stock_movement_before_update
BEFORE UPDATE ON stock_movements
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Stock movements are immutable; add a correcting adjustment instead';
END$$

CREATE TRIGGER stock_movement_before_delete
BEFORE DELETE ON stock_movements
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Stock movements are immutable; add a correcting adjustment instead';
END$$

DELIMITER ;

CREATE VIEW reorder_list AS
SELECT p.product_id, p.sku, p.product_name,
       w.warehouse_id, w.warehouse_name,
       COALESCE(i.quantity, 0) AS quantity_on_hand,
       p.reorder_level,
       GREATEST(p.reorder_level - COALESCE(i.quantity, 0), 0) AS suggested_reorder_qty,
       s.supplier_name AS preferred_supplier
FROM products p
CROSS JOIN warehouses w
LEFT JOIN inventory i ON i.product_id = p.product_id AND i.warehouse_id = w.warehouse_id
LEFT JOIN suppliers s ON s.supplier_id = p.preferred_supplier_id
WHERE p.active = TRUE AND COALESCE(i.quantity, 0) < p.reorder_level;

-- Seed data
INSERT INTO suppliers (supplier_name, contact_name, email, phone) VALUES
 ('Northstar Components','Mira Shah','orders@northstar.example','+1-555-0101'),
 ('Pioneer Supply Co','Evan Cole','sales@pioneer.example','+1-555-0102');

INSERT INTO products (sku, product_name, description, unit_cost, reorder_level, preferred_supplier_id) VALUES
 ('CAB-USB-C','USB-C Cable 1m','Braided cable, black',4.25,20,1),
 ('ADP-65W','65W USB-C Adapter','Universal power adapter',18.50,10,1),
 ('MOU-WL','Wireless Mouse','2.4GHz optical mouse',11.00,12,2);

INSERT INTO warehouses (warehouse_name, location) VALUES
 ('Central','Chicago'), ('East','Newark');

-- Opening balances are receipts, keeping stock and movement history consistent.
INSERT INTO stock_movements (product_id, warehouse_id, quantity_delta, movement_type, note) VALUES
 (1,1,60,'receipt','Opening balance'), (1,2,8,'receipt','Opening balance'),
 (2,1,25,'receipt','Opening balance'), (2,2,5,'receipt','Opening balance'),
 (3,1,18,'receipt','Opening balance'), (3,2,14,'receipt','Opening balance');

INSERT INTO purchase_orders (supplier_id, status, notes) VALUES (1,'open','Initial replenishment example');
INSERT INTO purchase_order_items (purchase_order_id, product_id, quantity, unit_cost) VALUES
 (1,1,100,4.10), (1,2,30,18.00);

-- REPORT 1: stock value per warehouse
SELECT w.warehouse_name,
       SUM(i.quantity * p.unit_cost) AS stock_value
FROM inventory i
JOIN products p ON p.product_id = i.product_id
JOIN warehouses w ON w.warehouse_id = i.warehouse_id
GROUP BY w.warehouse_id, w.warehouse_name
ORDER BY w.warehouse_name;

-- REPORT 2: supplier-wise purchase totals
SELECT s.supplier_name,
       SUM(poi.quantity * poi.unit_cost) AS purchase_value,
       SUM(poi.quantity) AS units_ordered
FROM purchase_orders po
JOIN suppliers s ON s.supplier_id = po.supplier_id
JOIN purchase_order_items poi ON poi.purchase_order_id = po.purchase_order_id
WHERE po.status IN ('open','received')
GROUP BY s.supplier_id, s.supplier_name
ORDER BY purchase_value DESC;

-- EXAMPLE: record a sale; rejected automatically if stock would become negative
-- INSERT INTO stock_movements (product_id, warehouse_id, quantity_delta, movement_type, note)
-- VALUES (1, 1, -3, 'sale', 'Order #123');

-- ATOMIC TRANSFER: run as a unit. UUID() supplies a shared transfer identifier.
-- START TRANSACTION;
-- SET @transfer_id = UUID();
-- INSERT INTO stock_movements(product_id, warehouse_id, quantity_delta, movement_type, transfer_group, note)
-- VALUES (1, 1, -5, 'transfer_out', @transfer_id, 'Central to East');
-- INSERT INTO stock_movements(product_id, warehouse_id, quantity_delta, movement_type, transfer_group, note)
-- VALUES (1, 2, 5, 'transfer_in', @transfer_id, 'Central to East');
-- COMMIT;
-- If an insert fails, issue ROLLBACK instead of COMMIT.

-- CSV IMPORT: use a staging table and LOAD DATA LOCAL INFILE from a trusted local CSV.
-- CSV header: sku,unit_cost,reorder_level,supplier_name
-- CREATE TEMPORARY TABLE supplier_price_import (
--   sku VARCHAR(80), unit_cost DECIMAL(12,2), reorder_level INT UNSIGNED, supplier_name VARCHAR(200)
-- );
-- LOAD DATA LOCAL INFILE '/path/to/supplier_prices.csv'
-- INTO TABLE supplier_price_import FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
-- LINES TERMINATED BY '\n' IGNORE 1 LINES (sku,unit_cost,reorder_level,supplier_name);
-- UPDATE products p JOIN supplier_price_import i ON i.sku = p.sku
-- SET p.unit_cost = i.unit_cost, p.reorder_level = i.reorder_level
-- WHERE i.unit_cost >= 0;
-- Review rows whose SKUs do not exist before adding products:
-- SELECT i.* FROM supplier_price_import i LEFT JOIN products p ON p.sku = i.sku WHERE p.product_id IS NULL;

-- CSV EXPORT: MySQL server writes this file in its permitted export directory.
-- SELECT w.warehouse_name, p.sku, p.product_name, i.quantity, p.unit_cost,
--        (i.quantity * p.unit_cost) AS stock_value
-- FROM inventory i JOIN products p ON p.product_id = i.product_id
-- JOIN warehouses w ON w.warehouse_id = i.warehouse_id
-- ORDER BY w.warehouse_name, p.sku
-- INTO OUTFILE '/var/lib/mysql-files/stock_report.csv'
-- FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' LINES TERMINATED BY '\n';
