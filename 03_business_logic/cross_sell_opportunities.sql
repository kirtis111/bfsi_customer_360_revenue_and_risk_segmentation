-- =============================================================
-- cross_sell_opportunities.sql
-- Layer   : 03_business_logic/

-- Purpose : Identify customers missing one or more product
--           categories -- the bank's prioritised cross-sell
--           shortlist. Focuses on High Value and Medium tier
--           customers first (highest revenue potential).
--
-- Five opportunity types (from data audit):
--   GAP 1 -- Wealth Management Upsell
--            Has chequing. No investment / RRSP / TFSA.
--            25 customers. Primary wealth management leads.
--   GAP 2 -- Retirement Planning Gap
--            No RRSP and no TFSA.
--            66 customers. Priority for customers aged 35+.
--   GAP 3 -- Primary Banking Acquisition
--            Has savings but no chequing.
--            49 customers. Likely bank primarily elsewhere.
--   GAP 4 -- Secured Lending Opportunity
--            Has investment accounts but no loan product.
--            37 customers. Asset-backed loan candidates.
--
-- SQL skills demonstrated:
--   . CREATE TEMP TABLE     -> persist CTE results for reuse
--   . NOT EXISTS subqueries -> product gap detection
--   . CASE priority scoring -> weighted opportunity score
--   . RANK() OVER()         -> priority ordering within gaps
--   . STRING_AGG            -> readable product gap list
--   . UNION ALL             -> combine all gaps into one list
--
-- =============================================================


-- =============================================================
-- SETUP: DROP TEMP TABLE IF EXISTS
-- Makes script safely re-runnable in the same session.
-- =============================================================

DROP TABLE IF EXISTS cross_sell_pipeline;


-- =============================================================
-- BUILD: CREATE TEMP TABLE FROM FULL CTE CHAIN
--
-- WHY TEMP TABLE?
-- CTEs only live inside the single statement they belong to.
-- Once that statement ends with (;), all CTEs are gone.
-- The Analysis queries below are separate statements and
-- cannot reference CTEs from an earlier statement.
--
-- CREATE TEMP TABLE materialises every gap row into a real
-- session-scoped table. All subsequent queries read from it
-- freely -- no scope issue, computed exactly once.
-- =============================================================

CREATE TEMP TABLE cross_sell_pipeline AS

WITH product_flags AS (

    -- One row per customer -- 1/0 flag for each account type.
    SELECT
        a.customer_id,
        MAX(CASE WHEN a.account_type = 'chequing'   THEN 1 ELSE 0 END) AS has_chequing,
        MAX(CASE WHEN a.account_type = 'savings'    THEN 1 ELSE 0 END) AS has_savings,
        MAX(CASE WHEN a.account_type = 'investment' THEN 1 ELSE 0 END) AS has_investment,
        MAX(CASE WHEN a.account_type = 'RRSP'       THEN 1 ELSE 0 END) AS has_rrsp,
        MAX(CASE WHEN a.account_type = 'TFSA'       THEN 1 ELSE 0 END) AS has_tfsa,
        COUNT(DISTINCT a.account_type)                                  AS product_count
    FROM   accounts AS a
    GROUP  BY a.customer_id
),

customer_profile AS (

    -- Joins product flags with the full 360 view.
    SELECT
        c.customer_id,
        c.full_name,
        c.customer_tier,
        c.province,
        c.branch_id,
        c.age_band,
        c.tenure_years,
        c.total_balance,
        c.tx_count_90d,
        c.days_since_last_tx,
        c.recency_label,
        c.preferred_channel,
        c.has_any_loan,
        c.loan_count,
        c.net_financial_position,
        c.est_annual_interest_revenue,
        COALESCE(p.has_chequing,   0) AS has_chequing,
        COALESCE(p.has_savings,    0) AS has_savings,
        COALESCE(p.has_investment, 0) AS has_investment,
        COALESCE(p.has_rrsp,       0) AS has_rrsp,
        COALESCE(p.has_tfsa,       0) AS has_tfsa,
        COALESCE(p.product_count,  0) AS product_count,
        CASE WHEN COALESCE(p.has_investment, 0) = 1
               OR COALESCE(p.has_rrsp,       0) = 1
               OR COALESCE(p.has_tfsa,       0) = 1
             THEN 1 ELSE 0 END        AS has_any_investment
    FROM       customer_360_view AS c
    LEFT JOIN  product_flags     AS p ON c.customer_id = p.customer_id
),

gap1_wealth AS (

    -- Has chequing, missing ALL investment products.
    -- Excludes defaulted loan customers.
    SELECT
        cp.customer_id, cp.full_name, cp.customer_tier,
        cp.province, cp.branch_id, cp.age_band, cp.tenure_years,
        cp.total_balance, cp.tx_count_90d, cp.days_since_last_tx,
        cp.recency_label, cp.preferred_channel, cp.product_count,
        cp.has_any_loan, cp.net_financial_position,
        'GAP 1'                              AS gap_code,
        'Wealth Management Upsell'           AS opportunity_type,
        'Has chequing, no investment/RRSP/TFSA'
                                             AS gap_description,
        'Investment account, RRSP, or TFSA'  AS recommended_product,
        LEAST(
            CASE cp.customer_tier
                WHEN 'High Value' THEN 50
                WHEN 'Medium'     THEN 30
                ELSE                   10
            END
          + CASE WHEN cp.tx_count_90d >= 10 THEN 20 ELSE 10 END
          + CASE WHEN cp.total_balance >= 5000 THEN 30
                 WHEN cp.total_balance >= 1000 THEN 15
                 ELSE 5 END,
            100
        )                                    AS priority_score
    FROM   customer_profile AS cp
    WHERE  NOT EXISTS (
               SELECT 1 FROM accounts AS a
               WHERE  a.customer_id   = cp.customer_id
                 AND  a.account_type IN ('investment', 'RRSP', 'TFSA')
           )
      AND  cp.has_chequing = 1
      AND  cp.customer_id NOT IN (
               SELECT l.customer_id FROM loans AS l
               WHERE  l.status = 'defaulted'
           )
),

gap2_retirement AS (

    -- No RRSP and no TFSA.
    SELECT
        cp.customer_id, cp.full_name, cp.customer_tier,
        cp.province, cp.branch_id, cp.age_band, cp.tenure_years,
        cp.total_balance, cp.tx_count_90d, cp.days_since_last_tx,
        cp.recency_label, cp.preferred_channel, cp.product_count,
        cp.has_any_loan, cp.net_financial_position,
        'GAP 2'                              AS gap_code,
        'Retirement Planning Gap'            AS opportunity_type,
        'No RRSP or TFSA held'               AS gap_description,
        'RRSP (age 35-71) or TFSA (any age)' AS recommended_product,
        LEAST(
            CASE cp.customer_tier
                WHEN 'High Value' THEN 50
                WHEN 'Medium'     THEN 30
                ELSE                   10
            END
          + CASE cp.age_band
                WHEN '45-54' THEN 20
                WHEN '35-44' THEN 20
                WHEN '55-64' THEN 15
                WHEN '25-34' THEN 10
                ELSE              5
            END
          + CASE WHEN cp.tenure_years >= 3 THEN 15 ELSE 5 END,
            100
        )                                    AS priority_score
    FROM   customer_profile AS cp
    WHERE  NOT EXISTS (
               SELECT 1 FROM accounts AS a
               WHERE  a.customer_id   = cp.customer_id
                 AND  a.account_type IN ('RRSP', 'TFSA')
           )
      AND  cp.customer_id NOT IN (
               SELECT l.customer_id FROM loans AS l
               WHERE  l.status = 'defaulted'
           )
),

gap3_primary_banking AS (

    -- Has savings but no chequing.
    SELECT
        cp.customer_id, cp.full_name, cp.customer_tier,
        cp.province, cp.branch_id, cp.age_band, cp.tenure_years,
        cp.total_balance, cp.tx_count_90d, cp.days_since_last_tx,
        cp.recency_label, cp.preferred_channel, cp.product_count,
        cp.has_any_loan, cp.net_financial_position,
        'GAP 3'                              AS gap_code,
        'Primary Banking Acquisition'        AS opportunity_type,
        'Has savings, no chequing account'   AS gap_description,
        'Chequing account'                   AS recommended_product,
        LEAST(
            CASE cp.customer_tier
                WHEN 'High Value' THEN 50
                WHEN 'Medium'     THEN 30
                ELSE                   10
            END
          + CASE WHEN cp.tenure_years >= 5 THEN 20
                 WHEN cp.tenure_years >= 2 THEN 10
                 ELSE                           5 END
          + CASE WHEN cp.days_since_last_tx <= 90 THEN 15 ELSE 5 END,
            100
        )                                    AS priority_score
    FROM   customer_profile AS cp
    WHERE  cp.has_savings  = 1
      AND  cp.has_chequing = 0
      AND  cp.customer_id NOT IN (
               SELECT l.customer_id FROM loans AS l
               WHERE  l.status = 'defaulted'
           )
),

gap4_lending AS (

    -- Has investment accounts but no loan of any kind.
    SELECT
        cp.customer_id, cp.full_name, cp.customer_tier,
        cp.province, cp.branch_id, cp.age_band, cp.tenure_years,
        cp.total_balance, cp.tx_count_90d, cp.days_since_last_tx,
        cp.recency_label, cp.preferred_channel, cp.product_count,
        cp.has_any_loan, cp.net_financial_position,
        'GAP 4'                                   AS gap_code,
        'Secured Lending Opportunity'             AS opportunity_type,
        'Has investment accounts, no loan'        AS gap_description,
        'Personal loan, auto loan, or mortgage'   AS recommended_product,
        LEAST(
            CASE cp.customer_tier
                WHEN 'High Value' THEN 50
                WHEN 'Medium'     THEN 30
                ELSE                   10
            END
          + CASE WHEN cp.total_balance >= 10000 THEN 25
                 WHEN cp.total_balance >= 3000  THEN 15
                 ELSE                                5 END
          + CASE WHEN cp.tenure_years >= 5 THEN 25 ELSE 10 END,
            100
        )                                         AS priority_score
    FROM   customer_profile AS cp
    WHERE  NOT EXISTS (
               SELECT 1 FROM loans AS l
               WHERE  l.customer_id = cp.customer_id
           )
      AND  cp.has_any_investment = 1
)

-- Materialise all four gaps into one flat table.
SELECT * FROM gap1_wealth
UNION ALL
SELECT * FROM gap2_retirement
UNION ALL
SELECT * FROM gap3_primary_banking
UNION ALL
SELECT * FROM gap4_lending;


-- =============================================================
-- CONFIRM BUILD
-- =============================================================

SELECT
    gap_code,
    COUNT(*) AS rows_loaded
FROM   cross_sell_pipeline
GROUP  BY gap_code
ORDER  BY gap_code;
-- Expected: GAP 1 = 25, GAP 2 = 66, GAP 3 = 49, GAP 4 = 37


-- =============================================================
-- MAIN OUTPUT: PRIORITISED CROSS-SELL LIST
-- Reads from temp table -- window functions computed here.
-- =============================================================

SELECT
    RANK() OVER (
        ORDER BY
            CASE customer_tier
                WHEN 'High Value' THEN 1
                WHEN 'Medium'     THEN 2
                ELSE                   3
            END ASC,
            priority_score DESC
    )                                           AS overall_priority_rank,

    RANK() OVER (
        PARTITION BY gap_code
        ORDER BY     priority_score DESC
    )                                           AS rank_within_gap,

    customer_id,
    full_name,
    customer_tier,
    province,
    branch_id,
    age_band,
    tenure_years,
    gap_code,
    opportunity_type,
    gap_description,
    recommended_product,
    priority_score,
    ROUND(total_balance::NUMERIC,          2)   AS total_balance,
    tx_count_90d,
    days_since_last_tx,
    recency_label,
    product_count,
    has_any_loan,
    ROUND(net_financial_position::NUMERIC, 2)   AS net_financial_position,
    preferred_channel,
    CURRENT_DATE                                AS snapshot_date

FROM   cross_sell_pipeline
ORDER  BY
    CASE customer_tier
        WHEN 'High Value' THEN 1
        WHEN 'Medium'     THEN 2
        ELSE                   3
    END ASC,
    priority_score DESC;


-- =============================================================
-- ANALYSIS 1: GAP SUMMARY -- PIPELINE SIZING
-- =============================================================

SELECT
    gap_code,
    opportunity_type,
    COUNT(DISTINCT customer_id)                     AS total_targets,
    COUNT(DISTINCT CASE WHEN customer_tier = 'High Value'
                        THEN customer_id END)       AS high_value_targets,
    COUNT(DISTINCT CASE WHEN customer_tier = 'Medium'
                        THEN customer_id END)       AS medium_targets,
    ROUND(AVG(priority_score)::NUMERIC,  1)         AS avg_priority_score,
    ROUND(SUM(total_balance)::NUMERIC,   2)         AS combined_balance,
    ROUND(AVG(total_balance)::NUMERIC,   2)         AS avg_balance,
    ROUND(
        COUNT(DISTINCT customer_id)::NUMERIC
        / NULLIF(SUM(COUNT(DISTINCT customer_id)) OVER (), 0) * 100,
        1
    )                                               AS pct_of_all_targets
FROM   cross_sell_pipeline
GROUP  BY gap_code, opportunity_type
ORDER  BY avg_priority_score DESC;


-- =============================================================
-- ANALYSIS 2: HIGH VALUE CUSTOMERS WITH ANY GAP
-- STRING_AGG collapses multiple gap rows per customer
-- into one readable pipe-separated string.
-- =============================================================

SELECT
    customer_id,
    full_name,
    ROUND(total_balance::NUMERIC, 2)                AS total_balance,
    COUNT(*)                                        AS gap_count,
    STRING_AGG(
        opportunity_type,
        ' | '  ORDER BY gap_code
    )                                               AS gaps_identified,
    MAX(priority_score)                             AS highest_priority_score
FROM   cross_sell_pipeline
WHERE  customer_tier = 'High Value'
GROUP  BY customer_id, full_name, total_balance
ORDER  BY total_balance DESC;


-- =============================================================
-- ANALYSIS 3: CHANNEL-BASED OUTREACH PLAN
-- Online/mobile -> digital campaign.
-- Branch/ATM    -> advisor meeting invite.
-- =============================================================

SELECT
    preferred_channel,
    gap_code,
    opportunity_type,
    COUNT(DISTINCT customer_id)                     AS target_count,
    COUNT(DISTINCT CASE WHEN customer_tier = 'High Value'
                        THEN customer_id END)       AS high_value_count,
    ROUND(AVG(priority_score)::NUMERIC, 1)          AS avg_priority_score
FROM   cross_sell_pipeline
GROUP  BY preferred_channel, gap_code, opportunity_type
ORDER  BY preferred_channel ASC, avg_priority_score DESC;
