-- =============================================================
-- monthly_trends_view.sql

-- Purpose : Aggregates all transactions into a monthly time-
--           series. Powers every trend chart in the Power BI
--           dashboard. One row per calendar month.
--
-- Business logic applied (not in core views):
--   • Month-over-month volume change (absolute + percentage)
--   • Running cumulative totals (inflow, outflow, net)
--   • 3-month rolling average (noise smoothing for charts)
--   • Net flow = inflow - outflow (health indicator)
--   • Tier-level breakdown via conditional aggregation
--   • Active customer count per month
--
-- Grain : ONE row per calendar month.
--         166 months (2010-11 → 2024-12) = 166 rows.
--
-- Window functions used:
--   LAG()   → month-over-month comparison
--   SUM() OVER (ORDER BY month) → cumulative running totals
--   AVG() OVER (rows between 2 preceding and current) → 3M avg
--
-- =============================================================


CREATE OR REPLACE VIEW monthly_trends_view AS

-- =============================================================
-- CTE 1: BASE MONTHLY AGGREGATION
-- =============================================================

WITH monthly_base AS (

    SELECT

        -- Time dimensions — the grain key and its components
        tx_month_start                                  AS month_start,
        tx_year,
        tx_quarter,
        tx_month,

        -- Formatted label for Power BI axis ticks
        -- TO_CHAR on a DATE: 'Mon YYYY' → e.g. 'Jan 2023'
        TO_CHAR(tx_month_start, 'Mon YYYY')             AS month_label,

        -- ── Volume metrics ────────────────────────────────────
        COUNT(transaction_id)                           AS tx_count,
        ROUND(SUM(amount)::NUMERIC,         2)          AS total_volume,

        -- Inflow: deposits only
        ROUND(SUM(
            CASE WHEN flow_direction = 'inflow'
                 THEN amount ELSE 0 END
        )::NUMERIC, 2)                                  AS total_inflow,

        -- Outflow: withdrawals + payments + fees
        ROUND(SUM(
            CASE WHEN flow_direction = 'outflow'
                 THEN amount ELSE 0 END
        )::NUMERIC, 2)                                  AS total_outflow,

        -- Neutral: transfers (money moves but wealth stays same)
        ROUND(SUM(
            CASE WHEN flow_direction = 'neutral'
                 THEN amount ELSE 0 END
        )::NUMERIC, 2)                                  AS total_neutral,

        -- Net flow: money gained minus money spent.
        -- Positive = more deposited than withdrawn (healthy).
        -- Negative = customers drawing down savings (warning signal).
        ROUND((
            SUM(CASE WHEN flow_direction = 'inflow'  THEN amount ELSE 0 END)
          - SUM(CASE WHEN flow_direction = 'outflow' THEN amount ELSE 0 END)
        )::NUMERIC, 2)                                  AS net_flow,

        -- ── Customer metrics ──────────────────────────────────
        -- COUNT(DISTINCT) is valid in regular aggregations (not windows)
        COUNT(DISTINCT customer_id)                     AS active_customers,

        -- Average spend per active customer this month
        ROUND(
            SUM(amount)::NUMERIC
            / NULLIF(COUNT(DISTINCT customer_id), 0),
            2
        )                                               AS avg_volume_per_customer,

        -- Average amount per transaction this month
        ROUND(AVG(amount)::NUMERIC, 2)                  AS avg_tx_amount,

        -- ── Transaction type breakdown ────────────────────────
        -- Conditional counts for each type — same as COUNTIF in Excel.
        -- Gives a breakdown of what drove volume each month.
        COUNT(CASE WHEN transaction_type = 'deposit'    THEN 1 END)
                                                        AS deposit_count,
        COUNT(CASE WHEN transaction_type = 'withdrawal' THEN 1 END)
                                                        AS withdrawal_count,
        COUNT(CASE WHEN transaction_type = 'transfer'   THEN 1 END)
                                                        AS transfer_count,
        COUNT(CASE WHEN transaction_type = 'payment'    THEN 1 END)
                                                        AS payment_count,
        COUNT(CASE WHEN transaction_type = 'fee'        THEN 1 END)
                                                        AS fee_count,

        -- ── Channel breakdown ─────────────────────────────────
        COUNT(CASE WHEN channel = 'online'  THEN 1 END) AS online_tx_count,
        COUNT(CASE WHEN channel = 'mobile'  THEN 1 END) AS mobile_tx_count,
        COUNT(CASE WHEN channel = 'branch'  THEN 1 END) AS branch_tx_count,
        COUNT(CASE WHEN channel = 'atm'     THEN 1 END) AS atm_tx_count,

        -- ── Large transaction flag ────────────────────────────
        -- How many transactions exceeded the 90th percentile ($10,275)?
        SUM(is_large_tx)                                AS large_tx_count

    FROM   transaction_enriched_view
    GROUP  BY
        tx_month_start,
        tx_year,
        tx_quarter,
        tx_month
),

-- =============================================================
-- CTE 2: TIER VOLUME BREAKDOWN
-- =============================================================

monthly_tier AS (

    SELECT
        t.tx_month_start                                AS month_start,

        -- Conditional SUM splits total volume into tier buckets.
        -- The CASE tests the customer_tier from customer_360_view
        -- (c360) joined to each transaction row.
        ROUND(SUM(
            CASE WHEN c360.customer_tier = 'High Value'
                 THEN t.amount ELSE 0 END
        )::NUMERIC, 2)                                  AS high_value_volume,

        ROUND(SUM(
            CASE WHEN c360.customer_tier = 'Medium'
                 THEN t.amount ELSE 0 END
        )::NUMERIC, 2)                                  AS medium_volume,

        ROUND(SUM(
            CASE WHEN c360.customer_tier = 'Low'
                 THEN t.amount ELSE 0 END
        )::NUMERIC, 2)                                  AS low_volume,

        -- Active customers per tier per month
        COUNT(DISTINCT CASE WHEN c360.customer_tier = 'High Value'
                            THEN t.customer_id END)     AS high_value_active_customers,

        COUNT(DISTINCT CASE WHEN c360.customer_tier = 'Medium'
                            THEN t.customer_id END)     AS medium_active_customers,

        COUNT(DISTINCT CASE WHEN c360.customer_tier = 'Low'
                            THEN t.customer_id END)     AS low_active_customers

    FROM   transaction_enriched_view  AS t
    -- JOIN to get customer_tier for each transaction
    -- INNER JOIN: transactions without a matching customer_360
    -- row would be a data quality issue worth knowing about
    INNER JOIN customer_360_view      AS c360
        ON  t.customer_id = c360.customer_id
    GROUP  BY t.tx_month_start
)

-- =============================================================
-- FINAL SELECT — ONE ROW PER MONTH
-- =============================================================

SELECT

    -- ==========================================================
    -- SECTION A: TIME DIMENSIONS
    -- ==========================================================

    b.month_start,
    b.month_label,
    b.tx_year,
    b.tx_quarter,
    b.tx_month,

    -- Quarter label for grouped reporting: e.g. 'Q3 2024'
    CONCAT('Q', b.tx_quarter, ' ', b.tx_year)           AS quarter_label,

    -- ==========================================================
    -- SECTION B: VOLUME METRICS (raw, from monthly_base CTE)
    -- ==========================================================

    b.tx_count,
    b.total_volume,
    b.total_inflow,
    b.total_outflow,
    b.total_neutral,
    b.net_flow,
    b.active_customers,
    b.avg_volume_per_customer,
    b.avg_tx_amount,

    -- ==========================================================
    -- SECTION C: TRANSACTION TYPE + CHANNEL BREAKDOWN
    -- ==========================================================

    b.deposit_count,
    b.withdrawal_count,
    b.transfer_count,
    b.payment_count,
    b.fee_count,
    b.online_tx_count,
    b.mobile_tx_count,
    b.branch_tx_count,
    b.atm_tx_count,
    b.large_tx_count,

    -- ==========================================================
    -- SECTION D: TIER VOLUME BREAKDOWN (from monthly_tier CTE)
    -- COALESCE handles months where a tier had zero transactions.
    -- ==========================================================

    COALESCE(tr.high_value_volume,            0)   AS high_value_volume,
    COALESCE(tr.medium_volume,                0)   AS medium_volume,
    COALESCE(tr.low_volume,                   0)   AS low_volume,
    COALESCE(tr.high_value_active_customers,  0)   AS high_value_active_customers,
    COALESCE(tr.medium_active_customers,      0)   AS medium_active_customers,
    COALESCE(tr.low_active_customers,         0)   AS low_active_customers,

    -- ==========================================================
    -- SECTION E: MONTH-OVER-MONTH CHANGES (WINDOW — LAG)
    --
    -- LAG(column, 1) OVER (ORDER BY month_start) returns the
    -- value of that column from the PREVIOUS row when rows are
    -- ordered by month. For the first month in the dataset,
    -- LAG returns NULL — no previous month exists.
    --
    -- MoM absolute change = current - previous.
    -- MoM % change        = (current - previous) / previous × 100.
    -- NULLIF in denominator prevents division by zero when the
    -- previous month had zero volume.
    -- ==========================================================

    -- Transaction count MoM
    b.tx_count
        - LAG(b.tx_count, 1) OVER (ORDER BY b.month_start)
                                                    AS tx_count_mom_change,

    -- Total volume MoM — absolute dollar change
    ROUND((
        b.total_volume
        - LAG(b.total_volume, 1) OVER (ORDER BY b.month_start)
    )::NUMERIC, 2)                                  AS volume_mom_change,

    -- Total volume MoM — percentage change
    ROUND((
        (b.total_volume
            - LAG(b.total_volume, 1) OVER (ORDER BY b.month_start))
        / NULLIF(
            LAG(b.total_volume, 1) OVER (ORDER BY b.month_start),
            0
          )::NUMERIC
        * 100
    )::NUMERIC, 2)                                  AS volume_mom_pct_change,

    -- Inflow MoM absolute change
    ROUND((
        b.total_inflow
        - LAG(b.total_inflow, 1) OVER (ORDER BY b.month_start)
    )::NUMERIC, 2)                                  AS inflow_mom_change,

    -- Active customers MoM
    b.active_customers
        - LAG(b.active_customers, 1) OVER (ORDER BY b.month_start)
                                                    AS active_customers_mom_change,

    -- ==========================================================
    -- SECTION F: RUNNING CUMULATIVE TOTALS (WINDOW — SUM OVER)
    --
    -- SUM(col) OVER (ORDER BY month_start
    --               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
    --
    -- Adds up every row from the very first month through the
    -- current row, building a cumulative total. Each month's row
    -- shows the year-to-date (or all-time) total up to that point.
    --
    -- Used in Power BI area charts showing portfolio growth over time.
    -- ==========================================================

    ROUND(SUM(b.total_volume) OVER (
        ORDER BY b.month_start
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )::NUMERIC, 2)                                  AS cumulative_volume,

    ROUND(SUM(b.total_inflow) OVER (
        ORDER BY b.month_start
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )::NUMERIC, 2)                                  AS cumulative_inflow,

    ROUND(SUM(b.net_flow) OVER (
        ORDER BY b.month_start
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )::NUMERIC, 2)                                  AS cumulative_net_flow,

    -- ==========================================================
    -- SECTION G: 3-MONTH ROLLING AVERAGE (WINDOW — AVG OVER)
    --
    -- AVG(col) OVER (ORDER BY month ROWS BETWEEN 2 PRECEDING
    --               AND CURRENT ROW)
    --
    -- The window is exactly 3 rows: the current month plus the
    -- 2 months immediately before it. For the first 2 months of
    -- the dataset, fewer than 3 rows exist so PostgreSQL uses
    -- whatever rows are available (1 or 2) — the average is
    -- still valid, just based on fewer data points.
    --
    -- Rolling averages smooth out month-to-month noise and
    -- reveal the underlying trend — essential for executive
    -- trend charts where a single spike would be misleading.
    -- ==========================================================

    ROUND(AVG(b.total_volume) OVER (
        ORDER BY b.month_start
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    )::NUMERIC, 2)                                  AS rolling_3m_avg_volume,

    ROUND(AVG(b.tx_count::NUMERIC) OVER (
        ORDER BY b.month_start
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    )::NUMERIC, 2)                                  AS rolling_3m_avg_tx_count,

    -- ==========================================================
    -- SECTION H: YEAR-TO-DATE TOTALS (WINDOW — PARTITION BY YEAR)
    -- ==========================================================

    ROUND(SUM(b.total_volume) OVER (
        PARTITION BY b.tx_year
        ORDER BY     b.month_start
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )::NUMERIC, 2)                                  AS ytd_volume,

    ROUND(SUM(b.total_inflow) OVER (
        PARTITION BY b.tx_year
        ORDER BY     b.month_start
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )::NUMERIC, 2)                                  AS ytd_inflow,

    -- ==========================================================
    -- SECTION I: METADATA
    -- ==========================================================

    CURRENT_DATE                                    AS snapshot_date

FROM       monthly_base    AS b
LEFT JOIN  monthly_tier    AS tr
    ON  b.month_start = tr.month_start
ORDER BY   b.month_start ASC;


-- =============================================================
-- VALIDATION QUERIES
-- =============================================================

-- 1. Row count — one per calendar month
SELECT COUNT(*) AS total_months FROM monthly_trends_view;
-- Expected: 166


-- 2. MoM sanity check — first row LAG columns must be NULL
SELECT
    month_label,
    total_volume,
    volume_mom_change,
    volume_mom_pct_change,
    cumulative_volume,
    rolling_3m_avg_volume
FROM   monthly_trends_view
ORDER  BY month_start ASC
LIMIT  4;
-- First row: volume_mom_change and pct_change should be NULL


-- 3. Running total must be strictly increasing
SELECT
    month_label,
    total_volume,
    cumulative_volume,
    ytd_volume,
    rolling_3m_avg_volume,
    net_flow
FROM   monthly_trends_view
ORDER  BY month_start DESC
LIMIT  12;
-- Most recent 12 months — key for executive dashboard


-- 4. Tier breakdown check — volumes must sum to total_volume
SELECT
    month_label,
    total_volume,
    high_value_volume,
    medium_volume,
    low_volume,
    ROUND(
        (high_value_volume + medium_volume + low_volume)::NUMERIC,
        2
    )                        AS tier_sum,
    ROUND(
        (total_volume
         - (high_value_volume + medium_volume + low_volume))::NUMERIC,
        2
    )                        AS discrepancy
FROM   monthly_trends_view
ORDER  BY month_start DESC
LIMIT  6;
-- Expected: discrepancy = 0.00 for all rows


-- 5. Annual summary using YTD window — verify year resets
SELECT DISTINCT
    tx_year,
    MAX(ytd_volume) OVER (PARTITION BY tx_year)     AS annual_total_volume,
    MAX(ytd_inflow) OVER (PARTITION BY tx_year)     AS annual_total_inflow,
    SUM(tx_count)   OVER (PARTITION BY tx_year)     AS annual_tx_count
FROM   monthly_trends_view
ORDER  BY tx_year DESC
LIMIT  5;
