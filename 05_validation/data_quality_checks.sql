-- =============================================================
-- data_quality_checks.sql
-- Layer   : 06_validation/
--
-- Purpose : Validate business rules on the CLEAN tables after
--           03_clean_raw_data.sql has run. Every check returns
--           a PASS or FAIL status with a violation count.
--
-- Sections:
--   1 -> Row count assertions    (4 checks)
--   2 -> Enum / categorical      (5 checks)
--   3 -> Date validity           (4 checks)
--   4 -> Financial constraints   (4 checks)
--   5 -> Referential integrity   (3 checks)
--   6 -> Cross-table consistency (2 checks)
--   Total: 22 checks
-- =============================================================


-- =============================================================
-- SECTION 1: ROW COUNT ASSERTIONS
-- =============================================================

SELECT
    'ROW COUNT: customers'                             AS check_name,
    CASE WHEN COUNT(*) = 200 THEN 'PASS' ELSE 'FAIL' END AS status,
    COUNT(*)                                           AS found,
    200                                                AS expected,
    '200 real customers after 5 duplicates removed'   AS detail
FROM customers

UNION ALL

SELECT
    'ROW COUNT: accounts'                              AS check_name,
    CASE WHEN COUNT(*) = 370 THEN 'PASS' ELSE 'FAIL' END AS status,
    COUNT(*)                                           AS found,
    370                                                AS expected,
    '370 accounts across all customers'               AS detail
FROM accounts

UNION ALL

SELECT
    'ROW COUNT: loans'                                 AS check_name,
    CASE WHEN COUNT(*) = 124 THEN 'PASS' ELSE 'FAIL' END AS status,
    COUNT(*)                                           AS found,
    124                                                AS expected,
    '124 loans -- 50% of customers have at least one' AS detail
FROM loans

UNION ALL

SELECT
    'ROW COUNT: transactions (min threshold)'         AS check_name,
    CASE WHEN COUNT(*) >= 4800 THEN 'PASS' ELSE 'FAIL' END AS status,
    COUNT(*)                                          AS found,
    4800                                              AS expected,
    '153 null-amount rows excluded; expecting ~4,949' AS detail
FROM transactions;


-- =============================================================
-- SECTION 2: ENUM / CATEGORICAL VALUE CHECKS
-- =============================================================

SELECT
    'ENUM: gender values'                             AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    COUNT(*)                                          AS found,
    0                                                 AS expected,
    'Non-canonical gender values (not Male/Female/Non-binary)' AS detail
FROM customers
WHERE gender NOT IN ('Male', 'Female', 'Non-binary')
  AND gender IS NOT NULL

UNION ALL

SELECT
    'ENUM: account_type values'                       AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    COUNT(*)                                          AS found,
    0                                                 AS expected,
    'Non-canonical account types detected'            AS detail
FROM accounts
WHERE account_type NOT IN ('chequing', 'savings', 'investment', 'RRSP', 'TFSA')

UNION ALL

SELECT
    'ENUM: account status values'                     AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    COUNT(*)                                          AS found,
    0                                                 AS expected,
    'Non-canonical account status detected'           AS detail
FROM accounts
WHERE status NOT IN ('active', 'inactive', 'closed')

UNION ALL

SELECT
    'ENUM: transaction_type values'                   AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    COUNT(*)                                          AS found,
    0                                                 AS expected,
    'Non-canonical tx types (should all be lowercase)' AS detail
FROM transactions
WHERE transaction_type NOT IN
    ('deposit', 'withdrawal', 'transfer', 'payment', 'fee')

UNION ALL

SELECT
    'ENUM: loan status values'                        AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    COUNT(*)                                          AS found,
    0                                                 AS expected,
    'Non-canonical loan status values detected'       AS detail
FROM loans
WHERE status NOT IN ('active', 'closed', 'defaulted', 'delinquent');


-- =============================================================
-- SECTION 3: DATE VALIDITY CHECKS
-- =============================================================

SELECT
    'DATE: join_date not in future'                   AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    COUNT(*)                                          AS found,
    0                                                 AS expected,
    'Customers with join_date after today'            AS detail
FROM customers
WHERE join_date > CURRENT_DATE

UNION ALL

SELECT
    'DATE: age between 18 and 100'                    AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    COUNT(*)                                          AS found,
    0                                                 AS expected,
    'Customers with implausible age (<18 or >100)'    AS detail
FROM customers
WHERE date_of_birth IS NOT NULL
  AND (
      DATE_PART('year', AGE(date_of_birth)) < 18
   OR DATE_PART('year', AGE(date_of_birth)) > 100
  )

UNION ALL

SELECT
    'DATE: loan end_date after start_date'            AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    COUNT(*)                                          AS found,
    0                                                 AS expected,
    'Loans where end_date is on or before start_date' AS detail
FROM loans
WHERE end_date IS NOT NULL
  AND end_date <= start_date

UNION ALL

SELECT
    'DATE: account opened after customer join'        AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    COUNT(*)                                          AS found,
    0                                                 AS expected,
    'Accounts opened before the customer join date'   AS detail
FROM accounts AS a
INNER JOIN customers AS c ON a.customer_id = c.customer_id
WHERE a.opened_date < c.join_date;


-- =============================================================
-- SECTION 4: FINANCIAL CONSTRAINT CHECKS
-- =============================================================

SELECT
    'FINANCIAL: balance >= 0'                         AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    COUNT(*)                                          AS found,
    0                                                 AS expected,
    'Accounts with negative balance'                  AS detail
FROM accounts
WHERE balance < 0

UNION ALL

SELECT
    'FINANCIAL: amount > 0'                           AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    COUNT(*)                                          AS found,
    0                                                 AS expected,
    'Transactions with zero or negative amount'       AS detail
FROM transactions
WHERE amount <= 0

UNION ALL

SELECT
    'FINANCIAL: principal_amount > 0'                 AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    COUNT(*)                                          AS found,
    0                                                 AS expected,
    'Loans with zero or negative principal'           AS detail
FROM loans
WHERE principal_amount <= 0

UNION ALL

SELECT
    'FINANCIAL: outstanding <= principal'             AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    COUNT(*)                                          AS found,
    0                                                 AS expected,
    'Loans where outstanding balance exceeds principal' AS detail
FROM loans
WHERE outstanding_balance > principal_amount;


-- =============================================================
-- SECTION 5: REFERENTIAL INTEGRITY CHECKS
-- =============================================================

SELECT
    'FK: accounts -> customers'                       AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    COUNT(*)                                          AS found,
    0                                                 AS expected,
    'Accounts with no matching customer_id'           AS detail
FROM accounts AS a
WHERE NOT EXISTS (
    SELECT 1 FROM customers AS c
    WHERE c.customer_id = a.customer_id
)

UNION ALL

SELECT
    'FK: transactions -> accounts'                    AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    COUNT(*)                                          AS found,
    0                                                 AS expected,
    'Transactions with no matching account_id'        AS detail
FROM transactions AS t
WHERE NOT EXISTS (
    SELECT 1 FROM accounts AS a
    WHERE a.account_id = t.account_id
)

UNION ALL

SELECT
    'FK: loans -> customers'                          AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    COUNT(*)                                          AS found,
    0                                                 AS expected,
    'Loans with no matching customer_id'              AS detail
FROM loans AS l
WHERE NOT EXISTS (
    SELECT 1 FROM customers AS c
    WHERE c.customer_id = l.customer_id
);


-- =============================================================
-- SECTION 6: CROSS-TABLE CONSISTENCY CHECKS
-- =============================================================

SELECT
    'CROSS: no orphaned accounts'                     AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    COUNT(*)                                          AS found,
    0                                                 AS expected,
    'Customer IDs in accounts not found in customers' AS detail
FROM (
    SELECT DISTINCT a.customer_id FROM accounts   AS a
    EXCEPT
    SELECT          c.customer_id FROM customers  AS c
) AS orphaned

UNION ALL

SELECT
    'CROSS: tx customer matches account customer'     AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    COUNT(*)                                          AS found,
    0                                                 AS expected,
    'Transactions where customer_id != account owner' AS detail
FROM transactions  AS t
INNER JOIN accounts AS a ON t.account_id = a.account_id
WHERE t.customer_id <> a.customer_id;
