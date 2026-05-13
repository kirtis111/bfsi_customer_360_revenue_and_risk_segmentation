-- =============================================================
-- null_checks.sql
-- Layer   : 06_validation/
--
-- Purpose : Two-stage null verification

-- =============================================================
-- SECTION 1: STAGING TABLE NULL CHECKS (nulls EXPECTED)
-- =============================================================

SELECT
    'STG NULL: customers.email'                            AS check_name,
    CASE WHEN COUNT(*) BETWEEN 15 AND 30
         THEN 'PASS (expected ~21)' ELSE 'INVESTIGATE'
    END                                                    AS status,
    COUNT(*)                                               AS null_count,
    21                                                     AS expected_approx,
    'Email nulls seeded in raw CSV (~10% of rows)'        AS detail
FROM stg_customers
WHERE email IS NULL

UNION ALL

SELECT
    'STG NULL: customers.phone_number'                     AS check_name,
    CASE WHEN COUNT(*) BETWEEN 15 AND 30
         THEN 'PASS (expected ~21)' ELSE 'INVESTIGATE'
    END                                                    AS status,
    COUNT(*)                                               AS null_count,
    21                                                     AS expected_approx,
    'Phone nulls seeded in raw CSV (~10% of rows)'        AS detail
FROM stg_customers
WHERE phone_number IS NULL

UNION ALL

SELECT
    'STG NULL: customers.postal_code'                      AS check_name,
    CASE WHEN COUNT(*) BETWEEN 15 AND 30
         THEN 'PASS (expected ~21)' ELSE 'INVESTIGATE'
    END                                                    AS status,
    COUNT(*)                                               AS null_count,
    21                                                     AS expected_approx,
    'Postal code nulls seeded in raw CSV (~10% of rows)'  AS detail
FROM stg_customers
WHERE postal_code IS NULL

UNION ALL

SELECT
    'STG NULL: accounts.balance'                           AS check_name,
    CASE WHEN COUNT(*) BETWEEN 10 AND 25
         THEN 'PASS (expected ~18)' ELSE 'INVESTIGATE'
    END                                                    AS status,
    COUNT(*)                                               AS null_count,
    18                                                     AS expected_approx,
    'Balance nulls seeded in raw CSV (~5% of rows)'       AS detail
FROM stg_accounts
WHERE balance IS NULL

UNION ALL

SELECT
    'STG NULL: transactions.amount'                        AS check_name,
    CASE WHEN COUNT(*) BETWEEN 100 AND 200
         THEN 'PASS (expected ~153)' ELSE 'INVESTIGATE'
    END                                                    AS status,
    COUNT(*)                                               AS null_count,
    153                                                    AS expected_approx,
    'Amount nulls seeded -- excluded from clean table'    AS detail
FROM stg_transactions
WHERE amount IS NULL

UNION ALL

SELECT
    'STG NULL: loans.outstanding_balance'                  AS check_name,
    CASE WHEN COUNT(*) BETWEEN 2 AND 10
         THEN 'PASS (expected ~5)' ELSE 'INVESTIGATE'
    END                                                    AS status,
    COUNT(*)                                               AS null_count,
    5                                                      AS expected_approx,
    'Outstanding balance nulls seeded in raw CSV (~4%)'   AS detail
FROM stg_loans
WHERE outstanding_balance IS NULL;


-- =============================================================
-- SECTION 2: CLEAN TABLE NOT NULL CHECKS (nulls NOT EXPECTED)
-- =============================================================

-- customers
SELECT
    'CLEAN NULL: customers.customer_id'                    AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END     AS status,
    COUNT(*)                                               AS null_count,
    0                                                      AS expected,
    'PRIMARY KEY -- must never be null'                    AS detail
FROM customers
WHERE customer_id IS NULL

UNION ALL

SELECT
    'CLEAN NULL: customers.first_name'                     AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END     AS status,
    COUNT(*)                                               AS null_count,
    0                                                      AS expected,
    'NOT NULL -- cleaned with TRIM()'                     AS detail
FROM customers
WHERE first_name IS NULL

UNION ALL

SELECT
    'CLEAN NULL: customers.last_name'                      AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END     AS status,
    COUNT(*)                                               AS null_count,
    0                                                      AS expected,
    'NOT NULL -- cleaned with TRIM()'                     AS detail
FROM customers
WHERE last_name IS NULL

UNION ALL

SELECT
    'CLEAN NULL: customers.province'                       AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END     AS status,
    COUNT(*)                                               AS null_count,
    0                                                      AS expected,
    'NOT NULL -- always present in raw data'              AS detail
FROM customers
WHERE province IS NULL

UNION ALL

SELECT
    'CLEAN NULL: customers.city'                           AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END     AS status,
    COUNT(*)                                               AS null_count,
    0                                                      AS expected,
    'NOT NULL -- always present in raw data'              AS detail
FROM customers
WHERE city IS NULL

UNION ALL

SELECT
    'CLEAN NULL: customers.join_date'                      AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END     AS status,
    COUNT(*)                                               AS null_count,
    0                                                      AS expected,
    'NOT NULL -- WHERE filter removed unparseable dates'  AS detail
FROM customers
WHERE join_date IS NULL

UNION ALL

SELECT
    'CLEAN NULL: customers.branch_id'                      AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END     AS status,
    COUNT(*)                                               AS null_count,
    0                                                      AS expected,
    'NOT NULL -- always present in raw data'              AS detail
FROM customers
WHERE branch_id IS NULL

UNION ALL

-- accounts
SELECT
    'CLEAN NULL: accounts.account_id'                      AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END     AS status,
    COUNT(*)                                               AS null_count,
    0                                                      AS expected,
    'PRIMARY KEY -- must never be null'                   AS detail
FROM accounts
WHERE account_id IS NULL

UNION ALL

SELECT
    'CLEAN NULL: accounts.customer_id'                     AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END     AS status,
    COUNT(*)                                               AS null_count,
    0                                                      AS expected,
    'FOREIGN KEY -- must never be null'                   AS detail
FROM accounts
WHERE customer_id IS NULL

UNION ALL

SELECT
    'CLEAN NULL: accounts.account_type'                    AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END     AS status,
    COUNT(*)                                               AS null_count,
    0                                                      AS expected,
    'NOT NULL -- normalised in cleaning'                  AS detail
FROM accounts
WHERE account_type IS NULL

UNION ALL

SELECT
    'CLEAN NULL: accounts.balance'                         AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END     AS status,
    COUNT(*)                                               AS null_count,
    0                                                      AS expected,
    'NOT NULL -- 18 raw nulls replaced with 0.00 by COALESCE' AS detail
FROM accounts
WHERE balance IS NULL

UNION ALL

SELECT
    'CLEAN NULL: accounts.status'                          AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END     AS status,
    COUNT(*)                                               AS null_count,
    0                                                      AS expected,
    'NOT NULL -- always present in raw data'              AS detail
FROM accounts
WHERE status IS NULL

UNION ALL

SELECT
    'CLEAN NULL: accounts.opened_date'                     AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END     AS status,
    COUNT(*)                                               AS null_count,
    0                                                      AS expected,
    'NOT NULL -- WHERE filter removed unparseable dates'  AS detail
FROM accounts
WHERE opened_date IS NULL

UNION ALL

-- transactions
SELECT
    'CLEAN NULL: transactions.transaction_id'              AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END     AS status,
    COUNT(*)                                               AS null_count,
    0                                                      AS expected,
    'PRIMARY KEY -- must never be null'                   AS detail
FROM transactions
WHERE transaction_id IS NULL

UNION ALL

SELECT
    'CLEAN NULL: transactions.amount'                      AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END     AS status,
    COUNT(*)                                               AS null_count,
    0                                                      AS expected,
    'NOT NULL -- 153 null rows excluded by WHERE clause'  AS detail
FROM transactions
WHERE amount IS NULL

UNION ALL

SELECT
    'CLEAN NULL: transactions.transaction_date'            AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END     AS status,
    COUNT(*)                                               AS null_count,
    0                                                      AS expected,
    'NOT NULL -- WHERE filter removed unparseable dates'  AS detail
FROM transactions
WHERE transaction_date IS NULL

UNION ALL

-- loans
SELECT
    'CLEAN NULL: loans.loan_id'                            AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END     AS status,
    COUNT(*)                                               AS null_count,
    0                                                      AS expected,
    'PRIMARY KEY -- must never be null'                   AS detail
FROM loans
WHERE loan_id IS NULL

UNION ALL

SELECT
    'CLEAN NULL: loans.outstanding_balance'                AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END     AS status,
    COUNT(*)                                               AS null_count,
    0                                                      AS expected,
    'NOT NULL -- 5 raw nulls replaced with 0.00 by COALESCE' AS detail
FROM loans
WHERE outstanding_balance IS NULL

UNION ALL

SELECT
    'CLEAN NULL: loans.interest_rate'                      AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END     AS status,
    COUNT(*)                                               AS null_count,
    0                                                      AS expected,
    'NOT NULL -- always present in raw data'              AS detail
FROM loans
WHERE interest_rate IS NULL

UNION ALL

SELECT
    'CLEAN NULL: loans.start_date'                         AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END     AS status,
    COUNT(*)                                               AS null_count,
    0                                                      AS expected,
    'NOT NULL -- WHERE filter removed unparseable dates'  AS detail
FROM loans
WHERE start_date IS NULL;


-- =============================================================
-- SECTION 3: NULLABLE COLUMN AUDIT
-- Nullable columns should have nulls within expected bounds.
-- =============================================================

SELECT
    'NULLABLE AUDIT: customers.email'                      AS check_name,
    COUNT(*)                                               AS total_rows,
    SUM(CASE WHEN email IS NULL THEN 1 ELSE 0 END)         AS null_count,
    ROUND(
        SUM(CASE WHEN email IS NULL THEN 1 ELSE 0 END)::NUMERIC
        / NULLIF(COUNT(*), 0) * 100, 1
    )                                                      AS null_pct,
    '5-15% expected -- nullable, some customers omitted'  AS expected_range
FROM customers

UNION ALL

SELECT
    'NULLABLE AUDIT: customers.phone'                      AS check_name,
    COUNT(*)                                               AS total_rows,
    SUM(CASE WHEN phone IS NULL THEN 1 ELSE 0 END)         AS null_count,
    ROUND(
        SUM(CASE WHEN phone IS NULL THEN 1 ELSE 0 END)::NUMERIC
        / NULLIF(COUNT(*), 0) * 100, 1
    )                                                      AS null_pct,
    '5-15% expected'                                      AS expected_range
FROM customers

UNION ALL

SELECT
    'NULLABLE AUDIT: customers.date_of_birth'              AS check_name,
    COUNT(*)                                               AS total_rows,
    SUM(CASE WHEN date_of_birth IS NULL THEN 1 ELSE 0 END) AS null_count,
    ROUND(
        SUM(CASE WHEN date_of_birth IS NULL THEN 1 ELSE 0 END)::NUMERIC
        / NULLIF(COUNT(*), 0) * 100, 1
    )                                                      AS null_pct,
    '0% expected -- dob always present in raw data'       AS expected_range
FROM customers

UNION ALL

SELECT
    'NULLABLE AUDIT: customers.gender'                     AS check_name,
    COUNT(*)                                               AS total_rows,
    SUM(CASE WHEN gender IS NULL THEN 1 ELSE 0 END)        AS null_count,
    ROUND(
        SUM(CASE WHEN gender IS NULL THEN 1 ELSE 0 END)::NUMERIC
        / NULLIF(COUNT(*), 0) * 100, 1
    )                                                      AS null_pct,
    '0-2% expected -- null only if cleaning CASE missed a value' AS expected_range
FROM customers

UNION ALL

SELECT
    'NULLABLE AUDIT: loans.end_date'                       AS check_name,
    COUNT(*)                                               AS total_rows,
    SUM(CASE WHEN end_date IS NULL THEN 1 ELSE 0 END)      AS null_count,
    ROUND(
        SUM(CASE WHEN end_date IS NULL THEN 1 ELSE 0 END)::NUMERIC
        / NULLIF(COUNT(*), 0) * 100, 1
    )                                                      AS null_pct,
    '0% expected -- end_date always present in raw data'  AS expected_range
FROM loans;
