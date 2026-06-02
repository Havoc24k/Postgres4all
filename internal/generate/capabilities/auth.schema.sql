-- auth: row-level security (exposed via PostgREST role switch)
CREATE TABLE notes (
    id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner text NOT NULL DEFAULT current_setting('request.jwt.claims', true)::json ->> 'sub',
    body  text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE notes ENABLE ROW LEVEL SECURITY;

CREATE POLICY notes_isolation ON notes
    USING      (owner = current_setting('request.jwt.claims', true)::json ->> 'sub')
    WITH CHECK (owner = current_setting('request.jwt.claims', true)::json ->> 'sub');
