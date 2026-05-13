-- =============================================================
-- customer_base_view.sql
-- Layer   : 02_views/core/
--
-- Purpose : Foundational view that joins the clean customers
--           table with accounts. Produces one row per
--           customer-account pair with structural enrichments
--           (age, tenure, flags). 
-- =============================================================


CREATE OR REPLACE VIEW customer_base_view AS

WITH product_counts AS (
    SELECT
        customer_id,
        COUNT(DISTINCT account_type)   AS product_count
    FROM   accounts
    GROUP  BY customer_id
)

SELECT

    -- ==========================================================
    -- BLOCK 1: CUSTOMER IDENTIFIERS
    -- ==========================================================

    c.customer_id,
    a.account_id,

    -- ==========================================================
    -- BLOCK 2: CUSTOMER DEMOGRAPHICS
    -- ==========================================================

    CONCAT_WS(' ', c.first_name, c.last_name)   AS full_name,
    c.first_name,
    c.last_name,
    c.email,
    c.phone,
    c.gender,
    c.province,
    c.city,
    c.postal_code,
    c.branch_id,

    -- ==========================================================
    -- BLOCK 3: CUSTOMER AGE
    -- ==========================================================

    c.date_of_birth,

    CASE
        WHEN c.date_of_birth IS NOT NULL
            THEN DATE_PART('year', AGE(c.date_of_birth))::INTEGER
    END                                         AS age_years,

    CASE
        WHEN c.date_of_birth IS NULL                          THEN 'Unknown'
        WHEN DATE_PART('year', AGE(c.date_of_birth)) < 25    THEN 'Under 25'
        WHEN DATE_PART('year', AGE(c.date_of_birth)) < 35    THEN '25–34'
        WHEN DATE_PART('year', AGE(c.date_of_birth)) < 45    THEN '35–44'
        WHEN DATE_PART('year', AGE(c.date_of_birth)) < 55    THEN '45–54'
        WHEN DATE_PART('year', AGE(c.date_of_birth)) < 65    THEN '55–64'
        ELSE                                                       '65+'
    END                                         AS age_band,

    -- ==========================================================
    -- BLOCK 4: CUSTOMER TENURE
    -- ==========================================================

    c.join_date,

    DATE_PART('year', AGE(c.join_date))::INTEGER
                                                AS tenure_years,

    (CURRENT_DATE - c.join_date)::INTEGER       AS tenure_days,

    -- Tenure band for reporting — mirrors how banks think about
    -- customer lifecycle stages.
    CASE
        WHEN (CURRENT_DATE - c.join_date) < 365        THEN 'New (< 1 yr)'
        WHEN (CURRENT_DATE - c.join_date) < 1095       THEN 'Growing (1–3 yrs)'
        WHEN (CURRENT_DATE - c.join_date) < 2555       THEN 'Established (3–7 yrs)'
        ELSE                                                 'Loyal (7+ yrs)'
    END                                         AS tenure_band,

    -- ==========================================================
    -- BLOCK 5: ACCOUNT DETAILS
    -- ==========================================================

    a.account_type,
    a.balance,
    a.currency,
    a.status                                    AS account_status,
    a.opened_date                               AS account_opened_date,

   (CURRENT_DATE - a.opened_date)::INTEGER     AS account_age_days,

    -- ==========================================================
    -- BLOCK 6: ACCOUNT FLAGS
    -- ==========================================================

    -- Is this account currently active?
    CASE WHEN a.status = 'active'       THEN 1 ELSE 0 END
                                                AS is_active_account,

    -- Does this account hold investable assets?
    -- Used in cross-sell logic to identify wealth management leads.
    CASE WHEN a.account_type IN ('investment', 'RRSP', 'TFSA')
         THEN 1 ELSE 0 END                      AS is_investment_account,

    -- Does this customer have a day-to-day transactional account?
    -- Customers with chequing tend to have higher transaction
    -- volumes — relevant to fee revenue analysis.
    CASE WHEN a.account_type = 'chequing'   THEN 1 ELSE 0 END
                                                AS is_chequing_account,

    -- ==========================================================
    -- BLOCK 7: PRODUCT BREADTH
    -- ==========================================================

    pc.product_count,

    -- Is this a multi-product customer?
    -- A customer with 2+ account types is considered "multi-product."
    -- Banks use this metric to measure relationship depth.
    CASE
        WHEN pc.product_count > 1 THEN 1
        ELSE 0
    END                                         AS is_multi_product,

    -- ==========================================================
    -- BLOCK 8: TOTAL BALANCE ACROSS ALL ACCOUNTS (WINDOW)
    -- ==========================================================

    SUM(a.balance) OVER (
        PARTITION BY c.customer_id
    )                                           AS customer_total_balance,

    -- Each account's share of the customer's total balance.
    -- NULLIF prevents division by zero if total balance is 0.
    ROUND(
        a.balance
        / NULLIF(
            SUM(a.balance) OVER (PARTITION BY c.customer_id),
            0
          ) * 100,
        2
    )                                           AS account_balance_pct,

    -- ==========================================================
    -- BLOCK 9: METADATA
    -- ==========================================================

    CURRENT_DATE                                AS snapshot_date

FROM customers  AS c

-- LEFT JOIN keeps ALL customers in the result even if they
-- somehow have no accounts (data quality edge case).
-- INNER JOIN would silently drop those customers — a dangerous
-- choice for a foundational view that other queries depend on.
LEFT JOIN accounts       AS a
    ON  c.customer_id = a.customer_id

-- LEFT JOIN product_counts so customers with no accounts
-- (NULL from the accounts left join) still appear, with
-- product_count as NULL rather than causing a row to vanish.
LEFT JOIN product_counts AS pc
    ON  c.customer_id = pc.customer_id;

-- =============================================================
-- QUICK VALIDATION QUERIES
-- Run these after CREATE VIEW to confirm the view is working.
-- =============================================================

-- Check grain: confirm row count = number of accounts
-- (every account appears exactly once)
SELECT COUNT(*) AS view_rows FROM customer_base_view;
-- Expected: ~370 (same as accounts table row count)


-- Check window functions worked: each customer's rows should
-- all show the same customer_total_balance
SELECT
    customer_id,
    full_name,
    account_type,
    balance                     AS this_account_balance,
    customer_total_balance      AS all_accounts_total,
    account_balance_pct         AS this_account_pct,
    product_count
FROM   customer_base_view
ORDER  BY customer_id, account_type
LIMIT  10;


-- Check tenure and age calculations look reasonable
SELECT
    full_name,
    date_of_birth,
    age_years,
    age_band,
    join_date,
    tenure_years,
    tenure_band
FROM   customer_base_view
ORDER  BY customer_id
LIMIT  10;


-- Check flag columns: confirm multi-product flag aligns with product_count
SELECT
    customer_id,
    full_name,
    product_count,
    is_multi_product,
    is_active_account,
    is_investment_account,
    is_chequing_account
FROM   customer_base_view
ORDER  BY product_count DESC, customer_id ASC
LIMIT  15;


-- Province breakdown: quick sanity check on distribution
SELECT
    province,
    COUNT(DISTINCT customer_id)            AS customer_count,
    COUNT(account_id)                      AS account_count,
    ROUND(AVG(customer_total_balance), 2)  AS avg_total_balance
FROM   customer_base_view
GROUP  BY province
ORDER  BY customer_count DESC;
