-- =============================================================
-- duplicate_checks.sql
-- Layer   : 06_validation/

-- Purpose : Detect duplicate and near-duplicate records.
-- =============================================================


-- =============================================================
-- SECTION 1: STAGING TABLE DUPLICATE AUDIT
-- =============================================================

SELECT
    'STG DUPE: customer_id duplicates exist'            AS check_name,
    CASE WHEN COUNT(*) = 5
         THEN 'PASS (5 deliberate dupes found)'
         ELSE 'INVESTIGATE'
    END                                                  AS status,
    COUNT(*)                                             AS duplicate_rows_found,
    5                                                    AS expected,
    'Deliberate duplicates seeded to test dedup logic'  AS detail
FROM (
    SELECT
        customer_id,
        ROW_NUMBER() OVER (
            PARTITION BY customer_id
            ORDER BY     ctid
        ) AS rn
    FROM stg_customers
) AS duped
WHERE rn > 1;


-- Which specific customer_ids were duplicated?
SELECT
    customer_id,
    COUNT(*) AS occurrences
FROM   stg_customers
GROUP  BY customer_id
HAVING COUNT(*) > 1
ORDER  BY customer_id;
-- Expected: C0016, C0031, C0096, C0129, C0159 (each twice)


-- =============================================================
-- SECTION 2: CLEAN TABLE PRIMARY KEY UNIQUENESS
-- =============================================================

SELECT
    'CLEAN PK: customers.customer_id'                   AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END  AS status,
    COUNT(*)                                             AS duplicate_groups,
    0                                                    AS expected,
    'customer_id appears more than once in customers'   AS detail
FROM (
    SELECT customer_id
    FROM   customers
    GROUP  BY customer_id
    HAVING COUNT(*) > 1
) AS duped_customers

UNION ALL

SELECT
    'CLEAN PK: accounts.account_id'                     AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END  AS status,
    COUNT(*)                                             AS duplicate_groups,
    0                                                    AS expected,
    'account_id appears more than once in accounts'     AS detail
FROM (
    SELECT account_id
    FROM   accounts
    GROUP  BY account_id
    HAVING COUNT(*) > 1
) AS duped_accounts

UNION ALL

SELECT
    'CLEAN PK: transactions.transaction_id'             AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END  AS status,
    COUNT(*)                                             AS duplicate_groups,
    0                                                    AS expected,
    'transaction_id appears more than once'             AS detail
FROM (
    SELECT transaction_id
    FROM   transactions
    GROUP  BY transaction_id
    HAVING COUNT(*) > 1
) AS duped_tx

UNION ALL

SELECT
    'CLEAN PK: loans.loan_id'                           AS check_name,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END  AS status,
    COUNT(*)                                             AS duplicate_groups,
    0                                                    AS expected,
    'loan_id appears more than once in loans'           AS detail
FROM (
    SELECT loan_id
    FROM   loans
    GROUP  BY loan_id
    HAVING COUNT(*) > 1
) AS duped_loans;


-- =============================================================
-- SECTION 3: NEAR-DUPLICATE CUSTOMER DETECTION
-- =============================================================

SELECT
    c1.customer_id                          AS customer_id_1,
    c2.customer_id                          AS customer_id_2,
    c1.first_name,
    c1.last_name,
    c1.date_of_birth,
    c1.email                                AS email_1,
    c2.email                                AS email_2,
    c1.province                             AS province_1,
    c2.province                             AS province_2,
    'Same name + DOB, different IDs'        AS flag
FROM   customers AS c1
INNER JOIN customers AS c2
    ON  c1.first_name    = c2.first_name
    AND c1.last_name     = c2.last_name
    AND c1.date_of_birth = c2.date_of_birth
    AND c1.customer_id   < c2.customer_id
ORDER BY c1.last_name, c1.first_name;
-- Expected: 0 rows. If rows appear, investigate whether they
-- are true duplicates or coincidental name+DOB matches.


-- =============================================================
-- SECTION 4: SAME-DAY SAME-ACCOUNT TRANSACTION DUPLICATES
-- Identical transactions (same account, date, type, amount)
-- are likely double-postings. Self-join deduplicates pairs.
-- =============================================================

-- Detail view: inspect individual suspicious pairs
SELECT
    t1.account_id,
    t1.transaction_date,
    t1.transaction_type,
    t1.amount,
    t1.transaction_id       AS tx_id_1,
    t2.transaction_id       AS tx_id_2,
    t1.channel              AS channel_1,
    t2.channel              AS channel_2,
    'Same account + date + type + amount'   AS flag
FROM   transactions AS t1
INNER JOIN transactions AS t2
    ON  t1.account_id       = t2.account_id
    AND t1.transaction_date = t2.transaction_date
    AND t1.transaction_type = t2.transaction_type
    AND t1.amount           = t2.amount
    AND t1.transaction_id   < t2.transaction_id
ORDER BY t1.account_id, t1.transaction_date
LIMIT 20;
-- A non-zero result is not automatically wrong -- a customer
-- could legitimately deposit the same amount twice on the same
-- day. Investigate each pair individually.


-- Summary PASS/FAIL count
SELECT
    'DUPE TX: same-day same-account same-amount'        AS check_name,
    CASE WHEN COUNT(*) = 0
         THEN 'PASS'
         ELSE 'REVIEW -- ' || COUNT(*)::TEXT || ' pairs found'
    END                                                  AS status,
    COUNT(*)                                             AS duplicate_pairs,
    0                                                    AS expected,
    'Same account + date + type + amount (possible double-posting)' AS detail
FROM (
    SELECT t1.transaction_id
    FROM   transactions AS t1
    INNER JOIN transactions AS t2
        ON  t1.account_id       = t2.account_id
        AND t1.transaction_date = t2.transaction_date
        AND t1.transaction_type = t2.transaction_type
        AND t1.amount           = t2.amount
        AND t1.transaction_id   < t2.transaction_id
) AS possible_dupes;


-- =============================================================
-- SECTION 5: DUPLICATE ACCOUNT TYPE PER CUSTOMER
-- Flags customers holding 2+ accounts of the same type.
-- Unusual but not impossible -- surfaced for review.
-- =============================================================

-- Detail view: which customers have duplicate account types?
SELECT
    a.customer_id,
    c.first_name,
    c.last_name,
    a.account_type,
    COUNT(*)                                             AS account_count,
    STRING_AGG(a.account_id, ', ' ORDER BY a.account_id) AS account_ids,
    'Multiple accounts of same type'                     AS flag
FROM   accounts  AS a
INNER JOIN customers AS c ON a.customer_id = c.customer_id
GROUP  BY a.customer_id, c.first_name, c.last_name, a.account_type
HAVING COUNT(*) > 1
ORDER  BY a.customer_id, a.account_type;
-- Expected: 0 rows. generate_data.py issues DISTINCT types
-- per customer. Real data loads may legitimately have these.


-- Summary PASS/FAIL count
SELECT
    'DUPE ACCOUNT TYPE: same customer same type'        AS check_name,
    CASE WHEN COUNT(*) = 0
         THEN 'PASS'
         ELSE 'REVIEW -- ' || COUNT(*)::TEXT || ' customer-type pairs'
    END                                                  AS status,
    COUNT(*)                                             AS duplicate_groups,
    0                                                    AS expected,
    'Customers holding 2+ accounts of the same type'   AS detail
FROM (
    SELECT customer_id, account_type
    FROM   accounts
    GROUP  BY customer_id, account_type
    HAVING COUNT(*) > 1
) AS duped_types;
