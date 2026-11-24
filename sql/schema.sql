-- Member API schema. Safe to run more than once.

CREATE TABLE IF NOT EXISTS members (
    member_id       TEXT PRIMARY KEY,
    first_name      TEXT NOT NULL,
    last_name       TEXT NOT NULL,
    dob             DATE NOT NULL,
    plan_code       TEXT NOT NULL,
    coverage_start  DATE NOT NULL,
    coverage_end    DATE NOT NULL
);

CREATE TABLE IF NOT EXISTS claims (
    claim_id      BIGSERIAL PRIMARY KEY,
    member_id     TEXT NOT NULL REFERENCES members (member_id),
    service_date  DATE NOT NULL,
    amount        NUMERIC(10,2) NOT NULL CHECK (amount > 0),
    status        TEXT NOT NULL
                  CHECK (status IN ('SUBMITTED','IN_REVIEW','APPROVED','DENIED','PAID')),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The API's hot paths. INC-01 is what happens when one of these goes missing.
CREATE INDEX IF NOT EXISTS idx_claims_member_id    ON claims (member_id);
CREATE INDEX IF NOT EXISTS idx_claims_service_date ON claims (service_date);
CREATE INDEX IF NOT EXISTS idx_members_last_name   ON members (last_name);
