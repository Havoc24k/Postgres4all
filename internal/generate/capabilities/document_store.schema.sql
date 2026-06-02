-- document_store: MongoDB -> jsonb + GIN index
CREATE TABLE products (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       text  NOT NULL,
    attributes jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX products_attrs_gin ON products USING gin (attributes jsonb_path_ops);
