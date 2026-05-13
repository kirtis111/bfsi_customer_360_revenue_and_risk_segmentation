-- =============================================================
-- 01_create_tables.sql
-- Purpose : Create staging tables (raw TEXT) and clean tables
--           (typed + constrained) for all 4 entities.
--
-- =============================================================
-- SECTION 1: STAGING TABLES
-- =============================================================

DROP TABLE IF EXISTS stg_customers    CASCADE;
DROP TABLE IF EXISTS stg_accounts     CASCADE;
DROP TABLE IF EXISTS stg_transactions CASCADE;
DROP TABLE IF EXISTS stg_loans        CASCADE;

-- Column mapping from CSV → staging is handled in 02_seed_data.sql.

CREATE TABLE stg_customers (
    customer_id       TEXT,
    first_name        TEXT,
    last_name         TEXT,
    email             TEXT,
    phone_number      TEXT,
    dob               TEXT,   
    gender            TEXT,   
    province          TEXT,
    city              TEXT,
    postal_code       TEXT,
    join_date         TEXT,   
    branch_id         TEXT,
    customer_segment  TEXT    
);

CREATE TABLE stg_accounts (
    account_id    TEXT,
    customer_id   TEXT,
    account_type  TEXT,  
    balance       TEXT,  
    currency      TEXT,
    status        TEXT,
    opened_date   TEXT,  
    branch_id     TEXT
);

CREATE TABLE stg_transactions (
    transaction_id    TEXT,
    account_id        TEXT,
    customer_id       TEXT,
    tx_type           TEXT,  
    amount            TEXT,  
    tx_date           TEXT,  
    channel           TEXT,
    description       TEXT
);

CREATE TABLE stg_loans (
    loan_id              TEXT,
    customer_id          TEXT,
    loan_type            TEXT,
    principal_amount     TEXT,
    outstanding_balance  TEXT,  
    interest_rate        TEXT,
    start_date           TEXT,  
    end_date             TEXT,  
    status               TEXT,
    monthly_payment      TEXT
);


-- =============================================================
-- SECTION 2: CLEAN TABLES
-- =============================================================

DROP TABLE IF EXISTS loans        CASCADE;
DROP TABLE IF EXISTS transactions CASCADE;
DROP TABLE IF EXISTS accounts     CASCADE;
DROP TABLE IF EXISTS customers    CASCADE;

-- ── customers ─────────────────────────────────────────────────
CREATE TABLE customers (
    customer_id      VARCHAR(6)   PRIMARY KEY,
    first_name       VARCHAR(100) NOT NULL,
    last_name        VARCHAR(100) NOT NULL,
    email            VARCHAR(200),
    phone            VARCHAR(30),
    date_of_birth    DATE,
    gender           VARCHAR(20)  CHECK (gender IN ('Male', 'Female', 'Non-binary')),
    province         CHAR(2)      NOT NULL,
    city             VARCHAR(100) NOT NULL,
    postal_code      VARCHAR(10),
    join_date        DATE         NOT NULL,
    branch_id        VARCHAR(6)   NOT NULL,
    customer_segment VARCHAR(20)  
);

-- ── accounts ──────────────────────────────────────────────────
CREATE TABLE accounts (
    account_id   VARCHAR(7)    PRIMARY KEY,
    customer_id  VARCHAR(6)    NOT NULL REFERENCES customers (customer_id),
    account_type VARCHAR(20)   NOT NULL
                               CHECK (account_type IN
                                   ('chequing','savings','investment','TFSA','RRSP')),
    balance      NUMERIC(15,2) NOT NULL DEFAULT 0.00
                               CHECK (balance >= 0),
    currency     CHAR(3)       NOT NULL DEFAULT 'CAD',
    status       VARCHAR(10)   NOT NULL
                               CHECK (status IN ('active','inactive','closed')),
    opened_date  DATE          NOT NULL,
    branch_id    VARCHAR(6)    NOT NULL
);

-- ── transactions ──────────────────────────────────────────────
CREATE TABLE transactions (
    transaction_id   VARCHAR(8)    PRIMARY KEY,
    account_id       VARCHAR(7)    NOT NULL REFERENCES accounts (account_id),
    customer_id      VARCHAR(6)    NOT NULL REFERENCES customers (customer_id),
    transaction_type VARCHAR(20)   NOT NULL
                                   CHECK (transaction_type IN
                                       ('deposit','withdrawal','transfer','payment','fee')),
    amount           NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    transaction_date DATE          NOT NULL,
    channel          VARCHAR(20)   CHECK (channel IN ('online','branch','atm','mobile')),
    description      VARCHAR(200)
);

-- ── loans ─────────────────────────────────────────────────────
CREATE TABLE loans (
    loan_id              VARCHAR(7)    PRIMARY KEY,
    customer_id          VARCHAR(6)    NOT NULL REFERENCES customers (customer_id),
    loan_type            VARCHAR(20)   NOT NULL
                                       CHECK (loan_type IN
                                           ('mortgage','personal','auto','business')),
    principal_amount     NUMERIC(15,2) NOT NULL CHECK (principal_amount > 0),
    outstanding_balance  NUMERIC(15,2) NOT NULL DEFAULT 0.00
                                       CHECK (outstanding_balance >= 0),
    interest_rate        NUMERIC(5,2)  NOT NULL CHECK (interest_rate > 0),
    start_date           DATE          NOT NULL,
    end_date             DATE,
    status               VARCHAR(15)   NOT NULL
                                       CHECK (status IN
                                           ('active','closed','defaulted','delinquent')),
    monthly_payment      NUMERIC(10,2) CHECK (monthly_payment > 0),

    CONSTRAINT end_after_start CHECK (end_date IS NULL OR end_date > start_date)
);


-- =============================================================
-- SECTION 3: INDEXES
-- =============================================================

-- accounts
CREATE INDEX idx_accounts_customer_id  ON accounts     (customer_id);
CREATE INDEX idx_accounts_status       ON accounts     (status);
CREATE INDEX idx_accounts_type         ON accounts     (account_type);

-- transactions
CREATE INDEX idx_tx_account_id         ON transactions (account_id);
CREATE INDEX idx_tx_customer_id        ON transactions (customer_id);
CREATE INDEX idx_tx_date               ON transactions (transaction_date);
CREATE INDEX idx_tx_type               ON transactions (transaction_type);

-- loans
CREATE INDEX idx_loans_customer_id     ON loans        (customer_id);
CREATE INDEX idx_loans_status          ON loans        (status);
CREATE INDEX idx_loans_type            ON loans        (loan_type);
