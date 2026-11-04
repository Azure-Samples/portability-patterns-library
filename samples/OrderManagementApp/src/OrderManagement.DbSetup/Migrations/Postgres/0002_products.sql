-- The products the inventory starts with: 25 of each, reordered below 5.
INSERT INTO inventory.products (sku, name, unit_price, currency, available, reorder_level) VALUES
    ('GEN-500', 'Backup generator 500 kW',      18500.00, 'USD', 25, 5),
    ('UPS-20',  'UPS battery module 20 kVA',     2400.00, 'USD', 25, 5),
    ('SAT-01',  'Satellite uplink terminal',     6100.00, 'USD', 25, 5),
    ('RAD-10',  'Two-way radio kit (10 units)',  1250.00, 'USD', 25, 5),
    ('WAT-200', 'Water purification unit',        890.00, 'USD', 25, 5);
