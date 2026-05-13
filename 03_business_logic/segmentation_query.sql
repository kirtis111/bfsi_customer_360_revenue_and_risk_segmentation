-- =============================================================
-- segmentation_query.sql
-- Layer   : 03_business_logic/

-- Purpose : Segment all 200 customers into value tiers using
--           NTILE() quintiles. Produces the core business insight:
--           "Top 20% of customers hold ~76% of total deposits."
--           Also updates the customer_segment column in the
--           customers table so every downstream view reflects
--           the live segmentation.
--
-- SQL skills demonstrated:
--   • NTILE(5)        → equal-size quintile buckets
--   • RANK()          → ranking within and across segments
--   • DENSE_RANK()    → gap-free ranking for ties
--   • PERCENT_RANK()  → percentile position (0.0 – 1.0)
--   • CASE            → map quintiles → business tier labels
--   • Window SUM      → concentration % across segments
--   • UPDATE + CTE    → write segment back to customers table
--   • ROLLUP          → subtotals in summary table
--
-- Concentration finding (from data):
--   Top 10%  (20 customers) → 58.8% of total balances
--   Top 20%  (40 customers) → 75.8% of total balances
--   Top 30%  (60 customers) → 83.8% of total balances
--
-- =============================================================


-- =============================================================
-- STEP 1: QUINTILE SCORING
-- =============================================================

WITH quintile_scores AS (

    SELECT
        customer_id,
        full_name,
        province,
        branch_id,
        age_band,
        tenure_band,
        total_balance,
        product_count,
        total_tx_count,
        has_any_loan,
        est_annual_interest_revenue,

        -- ── NTILE(5) ──────────────────────────────────────────
        -- Divides all rows into 5 equal groups ordered by balance.
        -- Group 1 = lowest 20% of balances.
        -- Group 5 = highest 20% of balances.
        -- When 200 rows divide evenly by 5, each bucket = 40 rows.
        -- If rows don't divide evenly, NTILE distributes the
        -- remainder to the earlier buckets (e.g. NTILE(3) on 200
        -- rows gives groups of 67, 67, 66).
        NTILE(5) OVER (
            ORDER BY total_balance ASC
        )                                       AS balance_quintile,

        -- ── RANK() ───────────────────────────────────────────
        -- Assigns each customer their exact balance rank.
        -- Rank 1 = highest balance. Ties receive the same rank
        -- and the next rank skips: 1, 2, 2, 4 (gap after tie).
        -- Used to identify the top N customers precisely.
        RANK() OVER (
            ORDER BY total_balance DESC
        )                                       AS balance_rank,

        -- ── DENSE_RANK() ─────────────────────────────────────
        -- Like RANK() but with no gaps after ties: 1, 2, 2, 3.
        -- Useful when you want "top 10 distinct balance levels"
        -- rather than "top 10 customers ignoring ties."
        DENSE_RANK() OVER (
            ORDER BY total_balance DESC
        )                                       AS balance_dense_rank,

        -- ── PERCENT_RANK() ───────────────────────────────────
        -- Returns a value between 0.0 and 1.0 representing the
        -- customer's relative position in the full distribution.
        -- Formula: (rank - 1) / (total_rows - 1)
        -- 0.0 = the lowest balance customer.
        -- 1.0 = the highest balance customer.
        -- Multiply by 100 to express as a percentile (0–100).
        ROUND(
            PERCENT_RANK() OVER (
                ORDER BY total_balance ASC
            )::NUMERIC * 100,
            1
        )                                       AS balance_percentile,

        -- Portfolio total used in share calculations below
        SUM(total_balance) OVER ()              AS portfolio_total_balance

    FROM customer_360_view
),

-- =============================================================
-- STEP 2: TIER LABELLING
-- Map each quintile to a business tier label and compute
-- each customer's share of the total portfolio balance.
-- =============================================================

tier_labels AS (

    SELECT
        *,

        -- ── Customer Tier (from quintile) ────────────────────
        -- Q5 = top 20% by balance      → High Value
        -- Q3 + Q4 = middle 40%         → Medium
        -- Q1 + Q2 = bottom 40%         → Low
        --
        -- This mapping deliberately aligns with the thresholds
        -- already used in customer_360_view so the labels are
        -- consistent across the entire project.
        CASE balance_quintile
            WHEN 5 THEN 'High Value'
            WHEN 4 THEN 'Medium'
            WHEN 3 THEN 'Medium'
            WHEN 2 THEN 'Low'
            WHEN 1 THEN 'Low'
        END                                     AS customer_segment,

        -- ── Balance Tier Label (more granular, 5 buckets) ────
        -- Kept separately from customer_segment for deep-dive
        -- analysis. Shows which fifth of the distribution a
        -- customer sits in.
        CASE balance_quintile
            WHEN 5 THEN 'Q5 — Top 20%'
            WHEN 4 THEN 'Q4 — 60th–80th pct'
            WHEN 3 THEN 'Q3 — 40th–60th pct'
            WHEN 2 THEN 'Q2 — 20th–40th pct'
            WHEN 1 THEN 'Q1 — Bottom 20%'
        END                                     AS quintile_label,

        -- ── Individual Balance Share ──────────────────────────
        -- What percentage of the total portfolio balance does
        -- this single customer represent?
        ROUND(
            (total_balance / NULLIF(portfolio_total_balance, 0))::NUMERIC
            * 100,
            3
        )                                       AS individual_balance_share_pct,

        -- ── Segment Running Total (window) ───────────────────
        -- Within each quintile, what is the running cumulative
        -- balance from the lowest customer upward?
        -- Shows how balance accumulates within a tier.
        ROUND(
            SUM(total_balance) OVER (
                PARTITION BY
                    CASE balance_quintile
                        WHEN 5 THEN 'High Value'
                        WHEN 4 THEN 'Medium'
                        WHEN 3 THEN 'Medium'
                        WHEN 2 THEN 'Low'
                        WHEN 1 THEN 'Low'
                    END
                ORDER BY total_balance ASC
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            )::NUMERIC,
            2
        )                                       AS segment_running_total

    FROM quintile_scores
)

-- =============================================================
-- STEP 3: FULL CUSTOMER SEGMENT TABLE
-- Final SELECT — one row per customer with all scoring columns.
-- =============================================================

SELECT
    customer_id,
    full_name,
    province,
    branch_id,
    age_band,
    tenure_band,
    product_count,
    has_any_loan,
    ROUND(total_balance::NUMERIC,          2)   AS total_balance,
    ROUND(est_annual_interest_revenue::NUMERIC, 2) AS est_annual_interest_revenue,
    balance_quintile,
    quintile_label,
    customer_segment,
    balance_rank,
    balance_dense_rank,
    balance_percentile,
    ROUND(individual_balance_share_pct::NUMERIC, 3) AS individual_balance_share_pct,
    ROUND(segment_running_total::NUMERIC,  2)   AS segment_running_total,
    ROUND(portfolio_total_balance::NUMERIC, 2)  AS portfolio_total_balance
FROM   tier_labels
ORDER  BY balance_rank ASC;


-- =============================================================
-- STEP 4: WRITE SEGMENT BACK TO customers TABLE
-- Updates customer_segment column so it flows into all views.
-- Uses a CTE inside UPDATE to compute segments before writing.
--
-- =============================================================

UPDATE customers AS c
SET    customer_segment = seg.customer_segment
FROM (
    SELECT
        customer_id,
        CASE NTILE(5) OVER (ORDER BY total_balance ASC)
            WHEN 5 THEN 'High Value'
            WHEN 4 THEN 'Medium'
            WHEN 3 THEN 'Medium'
            WHEN 2 THEN 'Low'
            WHEN 1 THEN 'Low'
        END AS customer_segment
    FROM customer_360_view
) AS seg
WHERE c.customer_id = seg.customer_id;

-- Confirm the UPDATE wrote to all 200 rows
SELECT
    customer_segment,
    COUNT(*) AS customer_count
FROM   customers
GROUP  BY customer_segment
ORDER  BY customer_count DESC;


-- =============================================================
-- STEP 5: CONCENTRATION ANALYSIS
-- =============================================================

WITH segment_totals AS (
    SELECT
        customer_tier,
        COUNT(*)                                AS customer_count,
        ROUND(SUM(total_balance)::NUMERIC,  2)  AS segment_balance,
        ROUND(AVG(total_balance)::NUMERIC,  2)  AS avg_balance,
        ROUND(MIN(total_balance)::NUMERIC,  2)  AS min_balance,
        ROUND(MAX(total_balance)::NUMERIC,  2)  AS max_balance,
        SUM(SUM(total_balance)) OVER ()         AS grand_total
    FROM   customer_360_view
    GROUP  BY customer_tier
)

SELECT
    customer_tier,
    customer_count,
    segment_balance,
    avg_balance,
    min_balance,
    max_balance,

    -- Share of total portfolio — the headline concentration metric
    ROUND(
        (segment_balance / NULLIF(grand_total, 0))::NUMERIC * 100,
        1
    )                                           AS pct_of_total_balance,

    -- Cumulative share (running total of pct across segments)
    -- Ordered High Value first to read as "top X% hold Y%"
    ROUND(
        SUM(segment_balance) OVER (
            ORDER BY segment_balance DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )::NUMERIC
        / NULLIF(grand_total, 0) * 100,
        1
    )                                           AS cumulative_pct

FROM   segment_totals
ORDER  BY segment_balance DESC;


-- =============================================================
-- STEP 6: DECILE DEEP-DIVE
-- Breaks the portfolio into 10 equal groups (20 customers each)
-- for granular concentration analysis. 
-- =============================================================

WITH deciles AS (
    SELECT
        customer_id,
        full_name,
        total_balance,
        NTILE(10) OVER (
            ORDER BY total_balance ASC
        )                                       AS decile
    FROM customer_360_view
)

SELECT
    decile,
    COUNT(*)                                    AS customers,
    ROUND(MIN(total_balance)::NUMERIC,  2)      AS min_balance,
    ROUND(MAX(total_balance)::NUMERIC,  2)      AS max_balance,
    ROUND(SUM(total_balance)::NUMERIC,  2)      AS decile_balance,
    ROUND(
        SUM(total_balance)::NUMERIC
        / NULLIF(SUM(SUM(total_balance)) OVER (), 0) * 100,
        1
    )                                           AS pct_of_portfolio,
    ROUND(
        SUM(SUM(total_balance)) OVER (
            ORDER BY decile DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )::NUMERIC
        / NULLIF(SUM(SUM(total_balance)) OVER (), 0) * 100,
        1
    )                                           AS cumulative_pct_from_top
FROM   deciles
GROUP  BY decile
ORDER  BY decile DESC;
-- Reading this output from top (D10) down shows:
--   D10 alone (top 10%) = ~59% of total balances
--   D10 + D9  (top 20%) = ~76% of total balances


-- =============================================================
-- STEP 7: SEGMENT PROFILE SUMMARY
-- =============================================================

SELECT
    customer_tier,
    COUNT(*)                                            AS customers,
    ROUND(AVG(total_balance)::NUMERIC,              2)  AS avg_balance,
    ROUND(AVG(product_count)::NUMERIC,              1)  AS avg_products,
    ROUND(AVG(total_tx_count)::NUMERIC,             1)  AS avg_lifetime_tx,
    ROUND(AVG(avg_monthly_tx_count)::NUMERIC,       1)  AS avg_monthly_tx,
    ROUND(AVG(spend_90d)::NUMERIC,                  2)  AS avg_spend_90d,
    SUM(has_any_loan)                                   AS customers_with_loans,
    SUM(has_risk_loan)                                  AS at_risk_loan_customers,
    ROUND(AVG(est_annual_interest_revenue)::NUMERIC, 2)  AS avg_annual_interest_rev,
    ROUND(SUM(est_annual_interest_revenue)::NUMERIC, 2)  AS total_annual_interest_rev,
    SUM(is_investment_cross_sell_target)                AS cross_sell_targets
FROM   customer_360_view
GROUP  BY customer_tier
ORDER  BY avg_balance DESC;
