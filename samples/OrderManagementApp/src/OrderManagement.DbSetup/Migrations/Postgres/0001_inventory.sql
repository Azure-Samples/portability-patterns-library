-- The inventory database: products with their stock, and each order's reservation of it.
CREATE SCHEMA inventory;

CREATE TABLE inventory.products
(
    sku           text          PRIMARY KEY,
    name          text          NOT NULL,
    unit_price    numeric(12,2) NOT NULL CHECK (unit_price >= 0),
    currency      char(3)       NOT NULL,
    available     int           NOT NULL CHECK (available >= 0),
    reorder_level int           NOT NULL DEFAULT 0
);

CREATE TABLE inventory.reservations
(
    order_id   uuid        PRIMARY KEY,
    status     text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE inventory.reservation_lines
(
    order_id uuid NOT NULL REFERENCES inventory.reservations (order_id) ON DELETE CASCADE,
    sku      text NOT NULL REFERENCES inventory.products (sku),
    quantity int  NOT NULL CHECK (quantity > 0),
    PRIMARY KEY (order_id, sku)
);
