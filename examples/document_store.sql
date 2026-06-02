-- 📄 document_store  (replaces MongoDB)  — JSONB documents + GIN index
-- Enable: "capabilities": { "document_store": true }
-- Run:    psql "$DB_URL" -f examples/document_store.sql

-- Find products matching a nested JSON shape (uses the products_attrs_gin index):
SELECT name, attributes->>'brand' AS brand
FROM products
WHERE attributes @> '{"wireless": true}';

-- Aggregate over a JSON field:
SELECT attributes->>'brand' AS brand, count(*)
FROM products
GROUP BY 1
ORDER BY 1;
