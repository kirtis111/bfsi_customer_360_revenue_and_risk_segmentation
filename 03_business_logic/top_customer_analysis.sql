-- =============================================================
-- top_customer_analysis.sql
-- Layer   : 03_business_logic/
--
-- Purpose : Identify the bank's most valuable customers using a
--           composite Lifetime Value (LTV) score — not balance
--           alone. Demonstrates that balance is a misleading
--           proxy: only 4 of the top-20 by balance also appear
--           in the top-20 by LTV score.
--
-- LTV Score formula (0–100, higher = more valuable):
--   40% x balance_score      (deposit depth)
--   30% x tx_volume_score    (transaction engagement)
--   30% x interest_rev_score (loan revenue contribution)
--   Each dimension normalised 0-100 against the portfolio max.
--
-- SQL skills demonstrated:
--   . CREATE TEMP TABLE       -> persist CTE results for reuse
--   . Multi-column normalisation -> score components (0-100)
--   . RANK()                  -> balance rank vs LTV rank
--   . DENSE_RANK()            -> gap-free tier ranking
--   . PERCENT_RANK()          -> portfolio percentile
--   . NTILE(4)                -> LTV quartiles (Q1-Q4)
--   . Window SUM + PARTITION  -> revenue share by province
--   . LAG()                   -> rank movement detection
--   . Concentration arithmetic -> top-N share of total LTV
--
-- =============================================================


-- =============================================================
-- SETUP: DROP TEMP TABLE IF IT EXISTS
-- =============================================================

DROP TABLE IF EXISTS customer_ltv_scored;


-- =============================================================
-- BUILD: CREATE TEMP TABLE FROM CTE CHAIN
--
-- WHY TEMP TABLE INSTEAD OF JUST WITH ... SELECT?
--
-- CTEs only exist for the duration of the single SQL statement
-- they belong to. Once the statement ends (;), the CTE is gone.
-- The four Analysis queries below are separate statements -- they
-- cannot reference a CTE defined in an earlier statement.
--
-- CREATE TEMP TABLE materialises the result into a real
-- temporary table that persists for the entire session.
-- All subsequent queries in this file can read from it freely.
-- The table is automatically dropped when the session ends.
-- =============================================================

CREATE TEMP TABLE customer_ltv_scored AS

WITH raw_scores AS (

    SELECT
        customer_id,
        full_name,
        customer_tier,
        province,
        branch_id,
        age_band,
        tenure_band,
        tenure_years,
        product_count,
        has_any_loan,
        preferred_channel,
        total_balance,
        COALESCE(total_inflow + total_outflow, 0)   AS tx_volume,
        COALESCE(est_annual_interest_revenue,  0)   AS interest_revenue,
        total_tx_count,
        tx_count_90d,
        spend_90d,
        loan_count,
        total_outstanding_balance,
        loan_to_asset_ratio,
        has_risk_loan,
        has_defaulted_loan,
        days_since_last_tx,
        recency_label,
        large_tx_count,
        net_financial_position,
        is_investment_cross_sell_target,
        MAX(total_balance)                      OVER () AS max_balance,
        MAX(COALESCE(total_inflow + total_outflow,
                     0))                        OVER () AS max_tx_volume,
        MAX(COALESCE(est_annual_interest_revenue,
                     0))                        OVER () AS max_interest_rev

    FROM customer_360_view
),

scored AS (

    SELECT
        *,
        ROUND(
            (total_balance / NULLIF(max_balance, 0) * 100)::NUMERIC, 1
        )                                       AS balance_score,
        ROUND(
            (tx_volume / NULLIF(max_tx_volume, 0) * 100)::NUMERIC, 1
        )                                       AS tx_volume_score,
        ROUND(
            (interest_revenue
             / NULLIF(max_interest_rev, 0) * 100)::NUMERIC, 1
        )                                       AS interest_rev_score

    FROM raw_scores
),

ranked AS (

    SELECT
        *,
        LEAST(
            ROUND(
                (balance_score      * 0.40
               + tx_volume_score    * 0.30
               + interest_rev_score * 0.30)::NUMERIC, 1
            ),
            100.0
        )                                       AS ltv_score,
        RANK() OVER (
            ORDER BY (balance_score * 0.40
                    + tx_volume_score * 0.30
                    + interest_rev_score * 0.30) DESC
        )                                       AS ltv_rank,
        RANK() OVER (
            ORDER BY total_balance DESC
        )                                       AS balance_rank,
        RANK() OVER (
            ORDER BY interest_revenue DESC
        )                                       AS revenue_rank,
        DENSE_RANK() OVER (
            ORDER BY (balance_score * 0.40
                    + tx_volume_score * 0.30
                    + interest_rev_score * 0.30) DESC
        )                                       AS ltv_dense_rank,
        ROUND(
            PERCENT_RANK() OVER (
                ORDER BY (balance_score * 0.40
                        + tx_volume_score * 0.30
                        + interest_rev_score * 0.30) ASC
            )::NUMERIC * 100, 1
        )                                       AS ltv_percentile,
        NTILE(4) OVER (
            ORDER BY (balance_score * 0.40
                    + tx_volume_score * 0.30
                    + interest_rev_score * 0.30) ASC
        )                                       AS ltv_quartile,
        SUM(balance_score * 0.40
          + tx_volume_score * 0.30
          + interest_rev_score * 0.30) OVER ()  AS portfolio_total_ltv

    FROM scored
),

rank_comparison AS (

    SELECT
        *,
        LAG(balance_rank, 1) OVER (
            ORDER BY ltv_rank ASC
        )                                       AS prev_row_balance_rank,
        (balance_rank - ltv_rank)               AS rank_gap,
        ROUND(
            (
                (balance_score * 0.40
               + tx_volume_score * 0.30
               + interest_rev_score * 0.30)
               / NULLIF(portfolio_total_ltv, 0) * 100
            )::NUMERIC, 2
        )                                       AS individual_ltv_share_pct

    FROM ranked
)

SELECT
    customer_id, full_name, customer_tier, province, branch_id,
    age_band, tenure_band, tenure_years, product_count, has_any_loan,
    preferred_channel, total_balance, tx_volume, interest_revenue,
    total_tx_count, tx_count_90d, spend_90d, loan_count,
    total_outstanding_balance, loan_to_asset_ratio, has_risk_loan,
    has_defaulted_loan, days_since_last_tx, recency_label,
    large_tx_count, net_financial_position, is_investment_cross_sell_target,
    balance_score, tx_volume_score, interest_rev_score,
    ltv_score, ltv_rank, balance_rank, revenue_rank, ltv_dense_rank,
    ltv_percentile, ltv_quartile, rank_gap, individual_ltv_share_pct
FROM rank_comparison;


-- =============================================================
-- CONFIRM BUILD
-- =============================================================

SELECT COUNT(*) AS rows_in_temp_table FROM customer_ltv_scored;
-- Expected: 200


-- =============================================================
-- MAIN OUTPUT: FULL CUSTOMER LTV TABLE
-- =============================================================

SELECT
    ltv_rank,
    customer_id,
    full_name,
    customer_tier,
    ltv_score,
    CASE ltv_quartile
        WHEN 4 THEN 'Q4 - Top 25% (Elite)'
        WHEN 3 THEN 'Q3 - Upper Mid'
        WHEN 2 THEN 'Q2 - Lower Mid'
        WHEN 1 THEN 'Q1 - Bottom 25%'
    END                                             AS ltv_quartile_label,
    balance_score,
    tx_volume_score,
    interest_rev_score,
    ROUND(total_balance::NUMERIC,       2)          AS total_balance,
    ROUND(tx_volume::NUMERIC,           2)          AS total_tx_volume,
    ROUND(interest_revenue::NUMERIC,    2)          AS annual_interest_revenue,
    balance_rank,
    revenue_rank,
    ltv_dense_rank,
    ltv_percentile,
    rank_gap,
    CASE
        WHEN rank_gap >=  20 THEN 'Hidden Gem - High LTV, Low Deposits'
        WHEN rank_gap <= -20 THEN 'Passive Depositor - High Balance, Low Engagement'
        ELSE                      'Consistent Performer'
    END                                             AS customer_profile_type,
    individual_ltv_share_pct,
    product_count,
    total_tx_count,
    days_since_last_tx,
    recency_label,
    loan_count,
    ROUND(total_outstanding_balance::NUMERIC, 2)    AS total_outstanding_balance,
    has_risk_loan,
    ROUND(net_financial_position::NUMERIC,    2)    AS net_financial_position,
    is_investment_cross_sell_target,
    preferred_channel,
    CURRENT_DATE                                    AS snapshot_date
FROM   customer_ltv_scored
ORDER  BY ltv_rank ASC;


-- =============================================================
-- ANALYSIS 1: TOP 20 - LTV vs BALANCE CONTRAST
-- =============================================================

SELECT
    ltv_rank,
    customer_id,
    full_name,
    customer_tier,
    ROUND(ltv_score::NUMERIC,               1)  AS ltv_score,
    ROUND(total_balance::NUMERIC,           2)  AS total_balance,
    balance_rank,
    revenue_rank,
    rank_gap,
    CASE
        WHEN rank_gap >=  20 THEN 'Hidden Gem - High LTV, Low Deposits'
        WHEN rank_gap <= -20 THEN 'Passive Depositor - High Balance, Low Engagement'
        ELSE                      'Consistent Performer'
    END                                         AS customer_profile_type,
    ROUND(individual_ltv_share_pct::NUMERIC, 2) AS ltv_share_pct
FROM   customer_ltv_scored
WHERE  ltv_rank <= 20
ORDER  BY ltv_rank ASC;


-- =============================================================
-- ANALYSIS 2: LTV CONCENTRATION (top 40 = top 20%)
-- =============================================================

WITH ltv_cumulative AS (
    SELECT
        ltv_rank,
        customer_id,
        ROUND(ltv_score::NUMERIC,               1)  AS ltv_score,
        ROUND(individual_ltv_share_pct::NUMERIC, 2) AS individual_share_pct,
        ROUND(
            SUM(individual_ltv_share_pct) OVER (
                ORDER BY ltv_rank ASC
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            )::NUMERIC, 1
        )                                           AS cumulative_share_pct
    FROM customer_ltv_scored
)

SELECT *
FROM   ltv_cumulative
WHERE  ltv_rank <= 40
ORDER  BY ltv_rank ASC;


-- =============================================================
-- ANALYSIS 3: LTV QUARTILE PROFILE
-- =============================================================

SELECT
    CASE ltv_quartile
        WHEN 4 THEN 'Q4 - Elite (Top 25%)'
        WHEN 3 THEN 'Q3 - Upper Mid'
        WHEN 2 THEN 'Q2 - Lower Mid'
        WHEN 1 THEN 'Q1 - Bottom 25%'
    END                                             AS quartile_label,
    COUNT(*)                                        AS customers,
    ROUND(AVG(ltv_score)::NUMERIC,              1)  AS avg_ltv_score,
    ROUND(AVG(total_balance)::NUMERIC,          2)  AS avg_balance,
    ROUND(AVG(tx_volume)::NUMERIC,              2)  AS avg_tx_volume,
    ROUND(AVG(interest_revenue)::NUMERIC,       2)  AS avg_interest_rev,
    ROUND(AVG(product_count)::NUMERIC,          1)  AS avg_products,
    ROUND(AVG(days_since_last_tx)::NUMERIC,     0)  AS avg_days_dormant,
    SUM(is_investment_cross_sell_target)            AS cross_sell_targets
FROM   customer_ltv_scored
GROUP  BY ltv_quartile
ORDER  BY ltv_quartile DESC;


-- =============================================================
-- ANALYSIS 4: PROVINCE-LEVEL LTV CONCENTRATION
-- =============================================================

SELECT
    province,
    COUNT(*)                                        AS customer_count,
    ROUND(SUM(ltv_score)::NUMERIC,          1)      AS total_ltv_score,
    ROUND(AVG(ltv_score)::NUMERIC,          1)      AS avg_ltv_score,
    ROUND(SUM(total_balance)::NUMERIC,      2)      AS total_balance,
    ROUND(SUM(interest_revenue)::NUMERIC,   2)      AS total_interest_rev,
    ROUND(
        SUM(ltv_score)::NUMERIC
        / NULLIF(SUM(SUM(ltv_score)) OVER (), 0) * 100, 1
    )                                               AS pct_of_total_ltv
FROM   customer_ltv_scored
GROUP  BY province
ORDER  BY total_ltv_score DESC;
