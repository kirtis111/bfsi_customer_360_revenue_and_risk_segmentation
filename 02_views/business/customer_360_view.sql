-- =============================================================
-- customer_360_view.sql
-- Layer   : 02_views/business/

-- Purpose : The centrepiece of the project. Aggregates all four
--           clean tables into ONE ROW PER CUSTOMER — a complete
--           unified profile covering accounts, transactions,
--           loans, and derived business metrics.
--
-- Business logic applied here (none in core views):
--   • customer_tier  → High Value / Medium / Low
--   • net_financial_position → total balance minus loan debt
--   • est_annual_interest_revenue → bank's loan income estimate
--   • has_risk_loan  → flags defaulted or delinquent borrowers
--   • spend_to_balance_ratio → liquidity risk indicator
--
-- Grain : ONE row per customer.
--         200 customers = 200 rows.
--
-- Tier thresholds (derived from actual data percentiles):
--   High Value : total_balance >= 5,611  (80th percentile)
--   Medium     : total_balance >= 1,167  (40th–80th percentile)
--   Low        : total_balance <  1,167  (below 40th percentile)
--   → Top 20% of customers hold ~75% of total deposits.
--
-- =============================================================


CREATE OR REPLACE VIEW customer_360_view AS

-- =============================================================
-- CTE 1: ACCOUNT SUMMARY
-- =============================================================

WITH account_summary AS (

    SELECT
        -- Customer identity and demographics
        -- These columns are identical across all account rows
        -- for the same customer, so MAX() safely picks one value.
        customer_id,
        MAX(full_name)          AS full_name,
        MAX(first_name)         AS first_name,
        MAX(last_name)          AS last_name,
        MAX(email)              AS email,
        MAX(phone)              AS phone,
        MAX(gender)             AS gender,
        MAX(province)           AS province,
        MAX(city)               AS city,
        MAX(postal_code)        AS postal_code,
        MAX(branch_id)          AS branch_id,
        MAX(date_of_birth)      AS date_of_birth,
        MAX(age_years)          AS age_years,
        MAX(age_band)           AS age_band,
        MAX(join_date)          AS join_date,
        MAX(tenure_years)       AS tenure_years,
        MAX(tenure_days)        AS tenure_days,
        MAX(tenure_band)        AS tenure_band,

        -- Account counts and totals
        -- COUNT(account_id) counts one row per account — correct.
        COUNT(account_id)       AS total_accounts,
        SUM(balance)            AS total_balance,

        -- COUNT + CASE instead of SUM(is_active_account) to be
        -- explicit about what we're counting. Both produce the
        -- same result; this is more readable to a code reviewer.
        COUNT(
            CASE WHEN account_status = 'active' THEN 1 END
        )                       AS active_account_count,

        -- MAX on binary flags: if ANY account row has the flag = 1,
        -- the customer-level flag becomes 1. This is the correct
        -- way to roll up per-account flags to customer level.
        MAX(is_chequing_account)    AS has_chequing,
        MAX(is_investment_account)  AS has_investment_account,
        MAX(is_multi_product)       AS is_multi_product,

        -- product_count is identical for all rows of a customer
        -- (from the CTE in customer_base_view), so MAX = MIN = value.
        MAX(product_count)      AS product_count,

        MAX(snapshot_date)      AS snapshot_date

    FROM   customer_base_view
    GROUP  BY customer_id
),

-- =============================================================
-- CTE 2: TRANSACTION SUMMARY
-- =============================================================

tx_summary AS (

    SELECT
        customer_id,

        -- Total lifetime transaction count for this customer
        COUNT(transaction_id)                               AS total_tx_count,

        -- Transactions in the last 90 days
        -- is_recent_90d is a precomputed 1/0 flag from the core view.
        -- SUM(flag) = count of rows where flag = 1.
        SUM(is_recent_90d)                                  AS tx_count_90d,

        -- Total outflow spend in the last 90 days.
        -- Outflow only (withdrawals, payments, fees) — not inflows.
        -- CASE inside SUM: add the amount only when both conditions
        -- are true; otherwise add 0. This is a conditional sum —
        -- the SQL equivalent of SUMIF in Excel.
        SUM(
            CASE
                WHEN is_recent_90d   = 1
                 AND flow_direction  = 'outflow'
                THEN amount
                ELSE 0
            END
        )                                                   AS spend_90d,

        -- Lifetime inflow and outflow totals
        SUM(
            CASE WHEN flow_direction = 'inflow'  THEN amount ELSE 0 END
        )                                                   AS total_inflow,
        SUM(
            CASE WHEN flow_direction = 'outflow' THEN amount ELSE 0 END
        )                                                   AS total_outflow,

        -- Most recent transaction date
        MAX(transaction_date)                               AS last_tx_date,

        -- Days since the customer last transacted
        -- CURRENT_DATE - MAX(date) gives an integer in PostgreSQL.
        (CURRENT_DATE - MAX(transaction_date))              AS days_since_last_tx,

        -- Average monthly transaction count.
        -- Numerator: total transactions.
        -- Denominator: number of months active, calculated as the
        -- difference in months between first and last transaction + 1
        -- (the +1 ensures a customer active for < 1 month counts as 1).
        -- NULLIF guards against a zero denominator.
        ROUND(
            COUNT(transaction_id)::NUMERIC
            / NULLIF(
                (DATE_PART('year',  AGE(MAX(transaction_date), MIN(transaction_date))) * 12
                 + DATE_PART('month', AGE(MAX(transaction_date), MIN(transaction_date)))
                 + 1)::NUMERIC,
                0
            ),
            1
        )                                                   AS avg_monthly_tx_count,

        -- Count of large transactions (above 90th percentile = $10,275)
        -- is_large_tx is a precomputed 1/0 flag from the core view.
        SUM(is_large_tx)                                    AS large_tx_count,

        -- Most common channel used by this customer.
        -- MODE() WITHIN GROUP is a PostgreSQL ordered-set aggregate
        -- that returns the most frequently occurring value.
        MODE() WITHIN GROUP (ORDER BY channel)              AS preferred_channel

    FROM   transaction_enriched_view
    GROUP  BY customer_id
),

-- =============================================================
-- CTE 3: LOAN SUMMARY
-- =============================================================

loan_summary AS (

    SELECT
        customer_id,

        COUNT(loan_id)                      AS loan_count,

        -- Total debt still owed across all loans
        SUM(outstanding_balance)            AS total_outstanding_balance,

        -- Original loan amount — shows total borrowing history
        SUM(principal_amount)               AS total_principal_borrowed,

        -- Monthly debt obligation — used in affordability analysis
        SUM(monthly_payment)                AS total_monthly_loan_payment,

        -- Estimated annual interest revenue this customer generates
        -- for the bank. Formula: outstanding_balance × interest_rate.
        -- This is the bank's primary revenue stream from this customer.
        -- Rounded to 2 decimal places for reporting readability.
        ROUND(
            SUM(outstanding_balance * interest_rate / 100.0)::NUMERIC,
            2
        )                                   AS est_annual_interest_revenue,

        -- Risk flags — roll up loan-level status to customer level.
        -- MAX() on a 1/0 flag: if ANY loan matches, customer = 1.
        MAX(CASE WHEN status = 'active'     THEN 1 ELSE 0 END)
                                            AS has_active_loan,
        MAX(CASE WHEN status = 'defaulted'  THEN 1 ELSE 0 END)
                                            AS has_defaulted_loan,
        MAX(CASE WHEN status = 'delinquent' THEN 1 ELSE 0 END)
                                            AS has_delinquent_loan,

        -- Combined risk flag — either defaulted OR delinquent = at-risk
        MAX(CASE WHEN status IN ('defaulted','delinquent')
                 THEN 1 ELSE 0 END)         AS has_risk_loan,

        -- Comma-separated list of loan types this customer holds.
        -- STRING_AGG(DISTINCT ...) aggregates unique values into one
        -- string. Example: 'auto, mortgage'
        -- DISTINCT avoids repeating 'personal, personal' for a customer
        -- with two personal loans.
        STRING_AGG(
            DISTINCT loan_type,
            ', '  ORDER BY loan_type
        )                                   AS loan_types_held

    FROM   loans
    GROUP  BY customer_id
)

-- =============================================================
-- FINAL SELECT — ONE ROW PER CUSTOMER
-- Joins the three CTEs and applies all business logic:
--   • customer_tier
--   • net_financial_position
--   • spend_to_balance_ratio
--   • days_since_last_tx category
-- LEFT JOIN for loan_summary because only 50% of customers
-- have loans — INNER JOIN would drop the other 100 customers.
-- =============================================================

SELECT

    -- ==========================================================
    -- SECTION A: CUSTOMER IDENTITY
    -- ==========================================================

    a.customer_id,
    a.full_name,
    a.first_name,
    a.last_name,
    a.email,
    a.phone,
    a.gender,
    a.province,
    a.city,
    a.postal_code,
    a.branch_id,

    -- ==========================================================
    -- SECTION B: DEMOGRAPHICS
    -- ==========================================================

    a.date_of_birth,
    a.age_years,
    a.age_band,
    a.join_date,
    a.tenure_years,
    a.tenure_days,
    a.tenure_band,

    -- ==========================================================
    -- SECTION C: ACCOUNT METRICS
    -- ==========================================================

    a.total_accounts,
    a.active_account_count,
    a.total_balance,
    a.product_count,
    a.is_multi_product,
    a.has_chequing,
    a.has_investment_account,

    -- ==========================================================
    -- SECTION D: TRANSACTION BEHAVIOUR
    -- COALESCE handles the rare edge case of a customer with
    -- zero transactions (would have no row in tx_summary).
    -- ==========================================================

    COALESCE(t.total_tx_count,       0)     AS total_tx_count,
    COALESCE(t.tx_count_90d,         0)     AS tx_count_90d,
    COALESCE(t.spend_90d,            0)     AS spend_90d,
    COALESCE(t.total_inflow,         0)     AS total_inflow,
    COALESCE(t.total_outflow,        0)     AS total_outflow,
    t.last_tx_date,
    COALESCE(t.days_since_last_tx,   9999)  AS days_since_last_tx,
    COALESCE(t.avg_monthly_tx_count, 0)     AS avg_monthly_tx_count,
    COALESCE(t.large_tx_count,       0)     AS large_tx_count,
    t.preferred_channel,

    -- Recency label — categorises how recently the customer transacted.
    -- Used as a slicer in Power BI and in risk_tagging_query.sql.
    CASE
        WHEN t.days_since_last_tx IS NULL      THEN 'Never Transacted'
        WHEN t.days_since_last_tx <=  30       THEN 'Active   (≤ 30 days)'
        WHEN t.days_since_last_tx <=  90       THEN 'Recent   (31–90 days)'
        WHEN t.days_since_last_tx <= 365       THEN 'Dormant  (91–365 days)'
        ELSE                                        'Inactive (> 1 year)'
    END                                       AS recency_label,

    -- ==========================================================
    -- SECTION E: LOAN METRICS
    -- COALESCE to 0 for customers with no loans — they should
    -- show 0 exposure, not NULL, in reports and aggregations.
    -- ==========================================================

    COALESCE(l.loan_count,                   0)  AS loan_count,
    COALESCE(l.total_outstanding_balance,    0)  AS total_outstanding_balance,
    COALESCE(l.total_principal_borrowed,     0)  AS total_principal_borrowed,
    COALESCE(l.total_monthly_loan_payment,   0)  AS total_monthly_loan_payment,
    COALESCE(l.est_annual_interest_revenue,  0)  AS est_annual_interest_revenue,
    COALESCE(l.has_active_loan,              0)  AS has_active_loan,
    COALESCE(l.has_defaulted_loan,           0)  AS has_defaulted_loan,
    COALESCE(l.has_delinquent_loan,          0)  AS has_delinquent_loan,
    COALESCE(l.has_risk_loan,                0)  AS has_risk_loan,
    l.loan_types_held,

    -- ==========================================================
    -- SECTION F: BUSINESS LOGIC — DERIVED METRICS
    -- ==========================================================

    -- ── Customer Tier ─────────────────────────────────────────
    -- Thresholds derived from actual data percentiles:
    --   >= 5,611  → High Value  (80th pct, top 20% of customers)
    --   >= 1,167  → Medium      (40th–80th pct)
    --   <  1,167  → Low         (bottom 40%)
    -- High Value customers hold ~75% of total deposit base.
    CASE
        WHEN a.total_balance >= 5611    THEN 'High Value'
        WHEN a.total_balance >= 1167    THEN 'Medium'
        ELSE                                 'Low'
    END                                       AS customer_tier,

    -- ── Net Financial Position ────────────────────────────────
    -- Total assets held at the bank minus total loan obligations.
    -- A negative value means the customer owes more than they hold —
    -- relevant for credit risk assessment.
    ROUND(
        (a.total_balance
        - COALESCE(l.total_outstanding_balance, 0))::NUMERIC,
        2
    )                                         AS net_financial_position,

    -- ── Spend-to-Balance Ratio ────────────────────────────────
    -- Last 90 days outflow spend as a percentage of total balance.
    -- A high ratio (> 50%) signals potential liquidity stress —
    -- the customer is spending heavily relative to their savings.
    -- NULLIF prevents division by zero for customers with 0 balance.
    ROUND(
        (COALESCE(t.spend_90d, 0)
        / NULLIF(a.total_balance, 0)
        * 100)::NUMERIC,
        2
    )                                         AS spend_to_balance_ratio,

    -- ── Loan-to-Asset Ratio ───────────────────────────────────
    -- Standard credit risk metric. Outstanding loan balance
    -- divided by total assets held at the bank.
    -- > 100% means the customer is underwater (owes more than held).
    ROUND(
        (COALESCE(l.total_outstanding_balance, 0)
        / NULLIF(a.total_balance, 0)
        * 100)::NUMERIC,
        2
    )                                         AS loan_to_asset_ratio,

    -- ── Has Any Loan ─────────────────────────────────────────
    -- Simple flag: does this customer have any loan at all?
    -- Used in cross-sell queries to find loan-free customers
    -- who are candidates for personal loan products.
    CASE WHEN l.loan_count > 0 THEN 1 ELSE 0 END
                                              AS has_any_loan,

    -- ── Cross-Sell Gap Flag ───────────────────────────────────
    -- Flags High Value or Medium customers who have a chequing
    -- account but no investment product. These are the bank's
    -- primary wealth management cross-sell targets.
    CASE
        WHEN a.has_chequing          = 1
         AND a.has_investment_account = 0
         AND (
             CASE
                 WHEN a.total_balance >= 5611 THEN 'High Value'
                 WHEN a.total_balance >= 1167 THEN 'Medium'
                 ELSE 'Low'
             END
         ) IN ('High Value', 'Medium')
        THEN 1
        ELSE 0
    END                                       AS is_investment_cross_sell_target,

    -- ==========================================================
    -- SECTION G: METADATA
    -- ==========================================================

    a.snapshot_date

FROM       account_summary     AS a
LEFT JOIN  tx_summary          AS t  ON a.customer_id = t.customer_id
LEFT JOIN  loan_summary        AS l  ON a.customer_id = l.customer_id;


-- =============================================================
-- VALIDATION QUERIES
-- Run after CREATE VIEW to confirm grain, counts, and logic.
-- =============================================================

-- 1. Confirm grain: must be exactly 200 rows (one per customer)
SELECT COUNT(*) AS total_rows FROM customer_360_view;
-- Expected: 200


-- 2. Tier distribution — confirm 3 tiers with expected counts
SELECT
    customer_tier,
    COUNT(*)                            AS customer_count,
    ROUND(AVG(total_balance)::NUMERIC, 2)        AS avg_balance,
    ROUND(SUM(total_balance)::NUMERIC, 2)        AS tier_total_balance,
    ROUND(
        (SUM(total_balance)
        / NULLIF(SUM(SUM(total_balance)) OVER (), 0) * 100)::NUMERIC,
        1
    )                                            AS pct_of_total_balance
FROM   customer_360_view
GROUP  BY customer_tier
ORDER  BY avg_balance DESC;
-- Expected: High Value ~40 customers, ~75% of total balances


-- 3. Loan coverage — confirm ~50% of customers have loans
SELECT
    has_any_loan,
    COUNT(*)    AS customer_count
FROM   customer_360_view
GROUP  BY has_any_loan
ORDER  BY has_any_loan DESC;
-- Expected: ~100 with loans, ~100 without


-- 4. Cross-sell targets — how many High/Medium chequing
--    customers have no investment product?
SELECT
    customer_tier,
    SUM(is_investment_cross_sell_target)    AS cross_sell_targets,
    COUNT(*)                                AS tier_total
FROM   customer_360_view
GROUP  BY customer_tier
ORDER  BY cross_sell_targets DESC;


-- 5. Risk snapshot — defaulted + delinquent loan holders
SELECT
    customer_tier,
    SUM(has_defaulted_loan)     AS defaulted,
    SUM(has_delinquent_loan)    AS delinquent,
    SUM(has_risk_loan)          AS total_at_risk
FROM   customer_360_view
GROUP  BY customer_tier
ORDER  BY total_at_risk DESC;


-- 6. Full 360 profile for a sample of customers
SELECT
    customer_id,
    full_name,
    customer_tier,
    total_balance,
    total_accounts,
    product_count,
    total_tx_count,
    spend_90d,
    loan_count,
    total_outstanding_balance,
    net_financial_position,
    spend_to_balance_ratio,
    est_annual_interest_revenue,
    has_risk_loan,
    recency_label,
    preferred_channel
FROM   customer_360_view
ORDER  BY total_balance DESC
LIMIT  10;
