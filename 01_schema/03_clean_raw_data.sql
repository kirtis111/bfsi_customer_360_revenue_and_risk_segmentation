-- =============================================================
-- 03_clean_raw_data.sql

-- Prerequisite : 01_create_tables.sql + 02_seed_data.sql done.
--
-- Cleaning inventory (discovered from raw data audit):
--
--  CUSTOMERS
--    ✦ Date formats  : DD/MM/YYYY | DD-Mon-YYYY | YYYY-MM-DD
--    ✦ Gender values : M/Male/male/F/Female/female/Non-binary → 3 canonical values
--    ✦ Whitespace    : trailing spaces on first_name
--    ✦ Duplicates    : 5 customer IDs appear twice → keep first occurrence
--    ✦ Nulls         : EMAIL (21) | Phone_Number (21) | PostalCode (21) → keep as NULL
--
--  ACCOUNTS
--    ✦ Account type  : SAVINGS/CHEQUING/INVESTMENT → lowercase
--    ✦ Date formats  : DD/MM/YYYY | YYYY-MM-DD
--    ✦ Nulls         : Balance (18) → default to 0.00
--
--  TRANSACTIONS
--    ✦ Tx type       : DEPOSIT/WITHDRAWAL/TRANSFER/PAYMENT/FEE → lowercase
--    ✦ Date formats  : YYYY-MM-DD | MM-DD-YYYY
--    ✦ Nulls         : Amount (153) → EXCLUDED (no zero-amount transactions allowed)
--
--  LOANS
--    ✦ Date formats  : YYYY-MM-DD | DD-Mon-YYYY | DD/MM/YYYY
--    ✦ Nulls         : OutstandingBalance (5) → default to 0.00
-- =============================================================


-- =============================================================
-- SECTION 0: SAFETY TRUNCATE
-- =============================================================

TRUNCATE TABLE transactions RESTART IDENTITY CASCADE;
TRUNCATE TABLE loans        RESTART IDENTITY CASCADE;
TRUNCATE TABLE accounts     RESTART IDENTITY CASCADE;
TRUNCATE TABLE customers    RESTART IDENTITY CASCADE;


-- =============================================================
-- SECTION 1: CLEAN CUSTOMERS
--
-- Issues handled:
--   1. Mixed date formats   → CASE + TO_DATE() with format masks
--   2. Gender normalisation → CASE mapping all variants to 3 values
--   3. Trailing whitespace  → TRIM()
--   4. Duplicate rows       → ROW_NUMBER() OVER (PARTITION BY customer_id)
--   5. Nulls in EMAIL/Phone/PostalCode → passed through as NULL (acceptable)
-- =============================================================

INSERT INTO customers (
    customer_id,
    first_name,
    last_name,
    email,
    phone,
    date_of_birth,
    gender,
    province,
    city,
    postal_code,
    join_date,
    branch_id,
    customer_segment
)

WITH deduped AS (
    -- ── Step 1: Remove duplicate customer rows ─────────────────
    -- ROW_NUMBER() assigns 1 to the first occurrence of each
    -- customer_id, and 2, 3... to any duplicates.
    -- The outer WHERE rn = 1 keeps only the first occurrence.
    -- PARTITION BY customer_id means the count resets for each
    -- unique customer_id. ORDER BY ctid uses the physical row
    -- order (the order rows were inserted by COPY) as a tiebreaker.
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY customer_id
            ORDER BY     ctid
        ) AS rn
    FROM stg_customers
),

cleaned AS (
    -- ── Step 2: Apply all type conversions and normalisation ───
    SELECT
        -- Pass through as-is — already clean
        customer_id,

        -- TRIM() removes leading and trailing whitespace.
        -- Some first_name values had 2 trailing spaces in raw data.
        TRIM(first_name)                                AS first_name,
        TRIM(last_name)                                 AS last_name,

        -- Nulls in email are acceptable — not every customer
        -- provided one. NULLIF(x, '') converts empty string to NULL
        -- as a safety net, even though COPY NULL '' should have
        -- handled this already.
        NULLIF(TRIM(email), '')                         AS email,

        -- Standardise phone: strip to digits and common separators.
        -- REGEXP_REPLACE removes everything except digits, spaces,
        -- hyphens, plus signs, parentheses.
        NULLIF(
            TRIM(REGEXP_REPLACE(phone_number, '[^0-9 \-\+\(\)]', '', 'g')),
            ''
        )                                               AS phone,

        -- ── Date parsing: DOB ───────────────────────────────────
        -- Three formats exist in raw data. CASE detects each by
        -- pattern and applies the matching TO_DATE format mask.
        --
        --   ~ '^[0-9]{4}-'    matches YYYY-MM-DD  (year first, 4 digits)
        --   ~ '/'             matches DD/MM/YYYY  (contains slash)
        --   ~ '-[A-Za-z]'     matches DD-Mon-YYYY (has alpha month)
        --
        -- TO_DATE(string, format) converts text → DATE.
        -- Format codes: YYYY=4-digit year, MM=numeric month,
        -- DD=day, Mon=abbreviated month name (Jan/Feb/Mar...).
        CASE
            WHEN dob ~ '^[0-9]{4}-'   THEN TO_DATE(dob, 'YYYY-MM-DD')
            WHEN dob ~ '/'            THEN TO_DATE(dob, 'DD/MM/YYYY')
            WHEN dob ~ '-[A-Za-z]'    THEN TO_DATE(dob, 'DD-Mon-YYYY')
        END                                             AS date_of_birth,

        -- ── Gender normalisation ────────────────────────────────
        -- Raw data has 7 variants of 3 logical values.
        -- Map all of them to the 3 canonical values that pass
        -- the CHECK constraint on the clean table.
        CASE
            WHEN UPPER(TRIM(gender)) IN ('M', 'MALE')     THEN 'Male'
            WHEN UPPER(TRIM(gender)) IN ('F', 'FEMALE')   THEN 'Female'
            WHEN UPPER(TRIM(gender)) = 'NON-BINARY'       THEN 'Non-binary'
        END                                             AS gender,

        UPPER(TRIM(province))                           AS province,
        INITCAP(TRIM(city))                             AS city,
        NULLIF(TRIM(postal_code), '')                   AS postal_code,

        -- ── Date parsing: join_date ─────────────────────────────
        -- Same three formats as DOB. Identical CASE logic.
        CASE
            WHEN join_date ~ '^[0-9]{4}-'  THEN TO_DATE(join_date, 'YYYY-MM-DD')
            WHEN join_date ~ '/'           THEN TO_DATE(join_date, 'DD/MM/YYYY')
            WHEN join_date ~ '-[A-Za-z]'   THEN TO_DATE(join_date, 'DD-Mon-YYYY')
        END                                             AS join_date,

        UPPER(TRIM(branch_id))                          AS branch_id,

        -- customer_segment is NULL in all raw rows.
        -- Left NULL here — populated later by segmentation_query.sql.
        NULL::VARCHAR(20)                               AS customer_segment

    FROM deduped
    -- Only keep the first occurrence of each customer_id.
    -- This is what removes the 5 deliberate duplicate rows.
    WHERE rn = 1
)

SELECT
    customer_id,
    first_name,
    last_name,
    email,
    phone,
    date_of_birth,
    gender,
    province,
    city,
    postal_code,
    join_date,
    branch_id,
    customer_segment
FROM cleaned
-- Final safety filter: drop rows missing business-critical fields.
-- A customer without an ID or join_date cannot be used in any analysis.
WHERE customer_id IS NOT NULL
  AND join_date   IS NOT NULL;

-- Validation
SELECT COUNT(*) FROM customers;

SELECT * FROM customers LIMIT 10;

-- =============================================================
-- SECTION 2: CLEAN ACCOUNTS
--
-- Issues handled:
--   1. Mixed account_type casing → LOWER() then INITCAP exceptions
--   2. Mixed date formats on opened_date → CASE + TO_DATE()
--   3. Null balance (18 rows) → COALESCE to 0.00
-- =============================================================

INSERT INTO accounts (
    account_id,
    customer_id,
    account_type,
    balance,
    currency,
    status,
    opened_date,
    branch_id
)

WITH cleaned AS (
    SELECT
        TRIM(account_id)                                AS account_id,
        TRIM(customer_id)                               AS customer_id,

        -- ── Account type normalisation ──────────────────────────
        -- Raw values: chequing / CHEQUING / savings / SAVINGS /
        --             investment / INVESTMENT / RRSP / TFSA
        -- RRSP and TFSA are acronyms — must stay uppercase.
        -- All others → lowercase to match CHECK constraint values.
        --
        -- LOWER() first normalises everything, then a CASE
        -- re-uppercases the two acronyms.
        CASE LOWER(TRIM(account_type))
            WHEN 'rrsp' THEN 'RRSP'
            WHEN 'tfsa' THEN 'TFSA'
            ELSE LOWER(TRIM(account_type))  -- chequing / savings / investment
        END                                             AS account_type,

        -- ── Null balance handling ───────────────────────────────
        -- NULLIF(balance, '') converts any empty string remnants
        -- to NULL (belt-and-suspenders after COPY NULL '').
        -- ::NUMERIC casts the TEXT to a number.
        -- COALESCE(x, 0.00) replaces NULL with 0.00 so the
        -- NOT NULL constraint on the clean table is satisfied.
        COALESCE(NULLIF(TRIM(balance), '')::NUMERIC, 0.00) AS balance,

        UPPER(TRIM(currency))                           AS currency,
        LOWER(TRIM(status))                             AS status,

        -- ── Date parsing: opened_date ───────────────────────────
        -- Two formats in raw data:
        --   DD/MM/YYYY  e.g. 05/09/2015
        --   YYYY-MM-DD  e.g. 2023-04-08
        CASE
            WHEN opened_date ~ '^[0-9]{4}-' THEN TO_DATE(opened_date, 'YYYY-MM-DD')
            WHEN opened_date ~ '/'          THEN TO_DATE(opened_date, 'DD/MM/YYYY')
        END                                             AS opened_date,

        UPPER(TRIM(branch_id))                          AS branch_id

    FROM stg_accounts
)

SELECT
    account_id,
    customer_id,
    account_type,
    balance,
    currency,
    status,
    opened_date,
    branch_id
FROM cleaned
-- Only load accounts whose customer exists in the clean customers table.
-- This is a referential integrity guard — if a customer was dropped
-- during dedup, their accounts must also be excluded.
WHERE account_id    IS NOT NULL
  AND customer_id   IN (SELECT c.customer_id FROM customers c)
  AND opened_date   IS NOT NULL;

-- Validation
SELECT COUNT(*) FROM accounts;

-- =============================================================
-- SECTION 3: CLEAN TRANSACTIONS
--
-- Issues handled:
--   1. Mixed tx_type casing → LOWER()
--   2. Mixed date formats   → CASE + TO_DATE()
--      Raw formats: YYYY-MM-DD | MM-DD-YYYY (e.g. 07-31-2017)
--   3. Null amounts (153 rows) → EXCLUDED entirely
--      Rationale: a transaction with no amount has no analytical
--      value. Including it as 0.00 would corrupt running totals.
-- =============================================================

INSERT INTO transactions (
    transaction_id,
    account_id,
    customer_id,
    transaction_type,
    amount,
    transaction_date,
    channel,
    description
)

WITH cleaned AS (
    SELECT
        TRIM(transaction_id)                            AS transaction_id,
        TRIM(account_id)                                AS account_id,
        TRIM(customer_id)                               AS customer_id,

        -- tx_type arrives as deposit/DEPOSIT/withdrawal/WITHDRAWAL etc.
        -- LOWER() handles all variants in one expression.
        LOWER(TRIM(tx_type))                            AS transaction_type,

        -- Cast amount TEXT → NUMERIC.
        -- NULLIF handles any empty string remnants.
        -- Rows where this is NULL are filtered out in WHERE below.
        NULLIF(TRIM(amount), '')::NUMERIC               AS amount,

        -- ── Date parsing: tx_date ───────────────────────────────
        -- Two formats in raw data:
        --   YYYY-MM-DD   e.g. 2018-05-27   → year-first pattern
        --   MM-DD-YYYY   e.g. 07-31-2017   → month-first with dashes
        --
        -- Distinguishing MM-DD-YYYY from YYYY-MM-DD:
        --   YYYY-MM-DD always starts with 4 digits then a dash.
        --   MM-DD-YYYY starts with exactly 2 digits then a dash.
        --   Regex '^[0-9]{4}-' captures YYYY-MM-DD unambiguously.
        --   The ELSE handles MM-DD-YYYY.
        CASE
            WHEN tx_date ~ '^[0-9]{4}-' THEN TO_DATE(tx_date, 'YYYY-MM-DD')
            ELSE                              TO_DATE(tx_date, 'MM-DD-YYYY')
        END                                             AS transaction_date,

        LOWER(TRIM(channel))                            AS channel,
        TRIM(description)                               AS description

    FROM stg_transactions
)

SELECT
    transaction_id,
    account_id,
    customer_id,
    transaction_type,
    amount,
    transaction_date,
    channel,
    description
FROM cleaned
WHERE transaction_id   IS NOT NULL
  AND amount           IS NOT NULL     -- exclude the 153 null-amount rows
  AND amount           > 0             -- enforce the clean table CHECK constraint
  AND account_id       IN (SELECT a.account_id  FROM accounts  a)
  AND customer_id      IN (SELECT c.customer_id FROM customers c)
  AND transaction_date IS NOT NULL;

-- Validation
SELECT COUNT(*) FROM transactions;

-- =============================================================
-- SECTION 4: CLEAN LOANS
--
-- Issues handled:
--   1. Mixed date formats on start_date → CASE + TO_DATE()
--      Formats: YYYY-MM-DD | DD-Mon-YYYY  (e.g. 26-Jul-2016)
--   2. Mixed date formats on end_date   → CASE + TO_DATE()
--      Formats: YYYY-MM-DD | DD/MM/YYYY  (e.g. 21/04/2053)
--   3. Null outstanding_balance (5 rows) → COALESCE to 0.00
-- =============================================================

INSERT INTO loans (
    loan_id,
    customer_id,
    loan_type,
    principal_amount,
    outstanding_balance,
    interest_rate,
    start_date,
    end_date,
    status,
    monthly_payment
)

WITH cleaned AS (
    SELECT
        TRIM(loan_id)                                   AS loan_id,
        TRIM(customer_id)                               AS customer_id,
        LOWER(TRIM(loan_type))                          AS loan_type,

        NULLIF(TRIM(principal_amount), '')::NUMERIC     AS principal_amount,

        -- ── Null outstanding_balance handling ───────────────────
        -- 5 rows have no outstanding balance in raw data.
        -- For a closed or fully-paid loan this is legitimately 0.
        -- COALESCE replaces NULL with 0.00 to satisfy NOT NULL.
        COALESCE(
            NULLIF(TRIM(outstanding_balance), '')::NUMERIC,
            0.00
        )                                               AS outstanding_balance,

        NULLIF(TRIM(interest_rate), '')::NUMERIC        AS interest_rate,

        -- ── Date parsing: start_date ────────────────────────────
        -- Two formats:
        --   YYYY-MM-DD   e.g. 2017-04-21
        --   DD-Mon-YYYY  e.g. 26-Jul-2016
        CASE
            WHEN start_date ~ '^[0-9]{4}-' THEN TO_DATE(start_date, 'YYYY-MM-DD')
            WHEN start_date ~ '-[A-Za-z]'  THEN TO_DATE(start_date, 'DD-Mon-YYYY')
        END                                             AS start_date,

        -- ── Date parsing: end_date ──────────────────────────────
        -- Two formats:
        --   YYYY-MM-DD   e.g. 2032-04-17
        --   DD/MM/YYYY   e.g. 21/04/2053
        CASE
            WHEN end_date ~ '^[0-9]{4}-' THEN TO_DATE(end_date, 'YYYY-MM-DD')
            WHEN end_date ~ '/'          THEN TO_DATE(end_date, 'DD/MM/YYYY')
        END                                             AS end_date,

        LOWER(TRIM(status))                             AS status,

        NULLIF(TRIM(monthly_payment), '')::NUMERIC      AS monthly_payment

    FROM stg_loans
)

SELECT
    loan_id,
    customer_id,
    loan_type,
    principal_amount,
    outstanding_balance,
    interest_rate,
    start_date,
    end_date,
    status,
    monthly_payment
FROM cleaned
WHERE loan_id         IS NOT NULL
  AND principal_amount IS NOT NULL
  AND interest_rate   IS NOT NULL
  AND start_date      IS NOT NULL
  AND customer_id     IN (SELECT c.customer_id FROM customers c);

-- Validation 
SELECT COUNT(*) FROM loans;

-- =============================================================
-- SECTION 5: POST-CLEAN VERIFICATION
-- Confirm row counts, null elimination, and value standardisation.
-- =============================================================

-- ── 5A: Row count summary ─────────────────────────────────────
SELECT
    'customers'    AS table_name,
    COUNT(*)       AS clean_rows,
    200            AS expected_rows,
    CASE WHEN COUNT(*) = 200 THEN 'PASS' ELSE 'INVESTIGATE' END AS status
FROM customers

UNION ALL

SELECT
    'accounts'                                                        AS table_name,
    COUNT(*)                                                          AS clean_rows,
    370                                                               AS expected_rows,
    CASE WHEN COUNT(*) = 370 THEN 'PASS' ELSE 'INVESTIGATE' END       AS status
FROM accounts

UNION ALL

SELECT
    'transactions'                                                    AS table_name,
    COUNT(*)                                                          AS clean_rows,
    NULL::INTEGER                                                     AS expected_rows,
    'see 5B for detail'                                               AS status
FROM transactions

UNION ALL

SELECT
    'loans'                                                           AS table_name,
    COUNT(*)                                                          AS clean_rows,
    124                                                               AS expected_rows,
    CASE WHEN COUNT(*) = 124 THEN 'PASS' ELSE 'INVESTIGATE' END       AS status
FROM loans;


-- ── 5B: Transaction exclusion audit ──────────────────────────
-- Shows how many raw rows had null amounts and were excluded.
SELECT
    (SELECT COUNT(*) FROM stg_transactions)                     AS raw_tx_rows,
    (SELECT COUNT(*) FROM stg_transactions
     WHERE  NULLIF(TRIM(amount), '') IS NULL)                   AS null_amount_rows_excluded,
    (SELECT COUNT(*) FROM transactions)                         AS clean_tx_rows,
    (SELECT COUNT(*) FROM stg_transactions)
    - (SELECT COUNT(*) FROM stg_transactions
       WHERE NULLIF(TRIM(amount), '') IS NULL)
    - (SELECT COUNT(*) FROM transactions)                       AS other_exclusions;


-- ── 5C: Confirm no dirty gender values remain ─────────────────
SELECT gender, COUNT(*) AS customer_count
FROM   customers
GROUP  BY gender
ORDER  BY gender;


-- ── 5D: Confirm account_type values are all clean ─────────────
SELECT account_type, COUNT(*) AS account_count
FROM   accounts
GROUP  BY account_type
ORDER  BY account_type;


-- ── 5E: Confirm transaction_type values are all lowercase ─────
SELECT transaction_type, COUNT(*) AS tx_count
FROM   transactions
GROUP  BY transaction_type
ORDER  BY transaction_type;


-- ── 5F: Confirm no null balances remain in accounts ───────────
SELECT COUNT(*) AS null_balance_count
FROM   accounts
WHERE  balance IS NULL;


-- ── 5G: Confirm date columns are proper DATE type (not text) ──
SELECT
    MIN(date_of_birth)  AS earliest_dob,
    MAX(date_of_birth)  AS latest_dob,
    MIN(join_date)      AS earliest_join,
    MAX(join_date)      AS latest_join
FROM customers;


-- ── 5H: Confirm duplicate customers were removed ──────────────
SELECT customer_id, COUNT(*) AS occurrences
FROM   customers
GROUP  BY customer_id
HAVING COUNT(*) > 1;
-- Expected: 0 rows returned (no duplicates)
