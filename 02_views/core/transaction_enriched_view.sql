-- =============================================================
-- transaction_enriched_view.sql
-- Layer   : 02_views/core/

-- Purpose : Foundational view that enriches the clean
--           transactions table with account context, temporal
--           breakdowns, flow direction, running balances,
--           and transaction ranking. No business logic here.
--
-- What this view adds on top of raw transactions:
--   • account_type + account_status  — from accounts table
--   • full_name, province, branch_id — from customers table
--   • flow_direction                 — inflow / outflow / neutral
--   • signed_amount                  — positive or negative value
--   • tx_year, tx_month, tx_quarter  — date part extractions
--   • tx_month_start                 — for time-series grouping
--   • days_since_prev_tx             — gap between transactions
--   • running_balance                — cumulative per account
--   • tx_rank_in_account             — chronological position
--   • is_latest_tx                   — most recent tx per account
--   • amount_band                    — size bucket for filtering
--   • is_large_tx                    — flag for outlier amounts
--
-- =============================================================


CREATE OR REPLACE VIEW transaction_enriched_view AS

SELECT

    -- ==========================================================
    -- BLOCK 1: TRANSACTION IDENTIFIERS
    -- Primary key and foreign keys passed through unchanged.
    -- All downstream joins use these columns.
    -- ==========================================================

    t.transaction_id,
    t.account_id,
    t.customer_id,

    -- ==========================================================
    -- BLOCK 2: ACCOUNT + CUSTOMER CONTEXT
    -- ==========================================================

    a.account_type,
    a.status                                    AS account_status,
    a.balance                                   AS current_account_balance,
    CONCAT_WS(' ', cu.first_name, cu.last_name) AS customer_full_name,
    cu.province,
    cu.branch_id,

    -- ==========================================================
    -- BLOCK 3: TRANSACTION CORE FIELDS
    -- ==========================================================

    t.transaction_type,
    t.amount,
    t.transaction_date,
    t.channel,
    t.description,

    -- ==========================================================
    -- BLOCK 4: FLOW DIRECTION + SIGNED AMOUNT
    -- ==========================================================

    CASE t.transaction_type
        WHEN 'deposit'    THEN 'inflow'
        WHEN 'withdrawal' THEN 'outflow'
        WHEN 'payment'    THEN 'outflow'
        WHEN 'fee'        THEN 'outflow'
        WHEN 'transfer'   THEN 'neutral'
    END                                         AS flow_direction,

    -- CASE applies the sign to amount based on flow direction.
    -- Fees and payments are outflows → negative.
    -- Transfers become 0 — they move money between accounts
    -- within the bank; net wealth effect is zero.
    CASE t.transaction_type
        WHEN 'deposit'    THEN  t.amount
        WHEN 'withdrawal' THEN -t.amount
        WHEN 'payment'    THEN -t.amount
        WHEN 'fee'        THEN -t.amount
        WHEN 'transfer'   THEN  0
    END                                         AS signed_amount,

    -- ==========================================================
    -- BLOCK 5: TEMPORAL BREAKDOWNS
    -- ==========================================================

    EXTRACT(YEAR    FROM t.transaction_date)::INTEGER   AS tx_year,
    EXTRACT(MONTH   FROM t.transaction_date)::INTEGER   AS tx_month,
    EXTRACT(QUARTER FROM t.transaction_date)::INTEGER   AS tx_quarter,
    EXTRACT(DOW     FROM t.transaction_date)::INTEGER   AS tx_day_of_week,
    -- DOW: 0 = Sunday, 1 = Monday ... 6 = Saturday

    -- Friendly day name — used in Power BI channel/day heatmaps.
    -- TO_CHAR(date, format) converts a date to a formatted string.
    -- 'Day' returns the full day name padded with spaces ('Monday   ')
    -- TRIM() removes the trailing spaces PostgreSQL adds.
    TRIM(TO_CHAR(t.transaction_date, 'Day'))            AS tx_day_name,

    -- First day of the transaction's month — used as the
    -- x-axis label in monthly trend line charts in Power BI.
    DATE_TRUNC('month', t.transaction_date)::DATE       AS tx_month_start,

    -- Is this transaction within the last 90 days from today?
    -- 90 days is the standard "recent activity" window used
    -- in the Customer 360 view and risk scoring logic.
    -- CURRENT_DATE - INTERVAL '90 days' computes the cutoff.
    CASE
        WHEN t.transaction_date >= CURRENT_DATE - INTERVAL '90 days'
        THEN 1 ELSE 0
    END                                                 AS is_recent_90d,

    -- Is this transaction within the last 30 days?
    -- Used for month-to-date spend analysis in executive reports.
    CASE
        WHEN t.transaction_date >= CURRENT_DATE - INTERVAL '30 days'
        THEN 1 ELSE 0
    END                                                 AS is_recent_30d,

    -- ==========================================================
    -- BLOCK 6: TRANSACTION SIZE BAND
    -- ==========================================================

    CASE
        WHEN t.amount <  1525   THEN 'Small   (< $1,525)'
        WHEN t.amount <  6684   THEN 'Medium  ($1,525–$6,683)'
        WHEN t.amount < 10276   THEN 'Large   ($6,684–$10,275)'
        ELSE                         'Very Large (> $10,275)'
    END                                         AS amount_band,

    -- Binary flag for large transactions — anything above the
    -- 90th percentile ($10,275) is flagged for risk review.
    CASE WHEN t.amount >= 10276 THEN 1 ELSE 0 END
                                                AS is_large_tx,

    -- ==========================================================
    -- BLOCK 7: RUNNING BALANCE PER ACCOUNT (WINDOW FUNCTION)
    -- ==========================================================

    SUM(
        CASE t.transaction_type
            WHEN 'deposit'    THEN  t.amount
            WHEN 'withdrawal' THEN -t.amount
            WHEN 'payment'    THEN -t.amount
            WHEN 'fee'        THEN -t.amount
            WHEN 'transfer'   THEN  0
        END
    ) OVER (
        PARTITION BY t.account_id
        ORDER BY     t.transaction_date ASC,
                     t.transaction_id  ASC
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                           AS running_balance,

    -- ==========================================================
    -- BLOCK 8: TRANSACTION RANK WITHIN ACCOUNT (WINDOW)
    -- ==========================================================

    ROW_NUMBER() OVER (
        PARTITION BY t.account_id
        ORDER BY     t.transaction_date ASC,
                     t.transaction_id  ASC
    )                                           AS tx_rank_in_account,

    -- ==========================================================
    -- BLOCK 9: LATEST TRANSACTION FLAG (WINDOW)
    -- ==========================================================

    CASE
        WHEN ROW_NUMBER() OVER (
            PARTITION BY t.account_id
            ORDER BY     t.transaction_date DESC,
                         t.transaction_id  DESC
        ) = 1
        THEN 1 ELSE 0
    END                                         AS is_latest_tx,

    -- ==========================================================
    -- BLOCK 10: DAYS SINCE PREVIOUS TRANSACTION (WINDOW)
    -- ==========================================================

    (
        t.transaction_date
        - LAG(t.transaction_date, 1) OVER (
            PARTITION BY t.account_id
            ORDER BY     t.transaction_date ASC,
                         t.transaction_id  ASC
        )
    )                                           AS days_since_prev_tx

FROM transactions AS t

-- INNER JOIN accounts: every transaction must have a valid
-- account. Because of FK constraints on the clean table,
-- orphaned transactions cannot exist — INNER JOIN is safe here
-- unlike the LEFT JOIN used in customer_base_view.
INNER JOIN accounts  AS a
    ON  t.account_id  = a.account_id

-- INNER JOIN customers: similarly, every transaction has a
-- valid customer_id enforced by the FK constraint.
INNER JOIN customers AS cu
    ON  t.customer_id = cu.customer_id;


-- =============================================================
-- QUICK VALIDATION QUERIES
-- Run after CREATE VIEW to confirm correctness.
-- =============================================================

-- 1. Row count matches transactions table exactly
SELECT COUNT(*) AS view_rows FROM transaction_enriched_view;
-- Expected: same count as SELECT COUNT(*) FROM transactions


-- 2. Flow direction distribution — verify no NULLs
SELECT
    flow_direction,
    COUNT(*)            AS tx_count,
    ROUND(SUM(amount), 2) AS total_amount
FROM   transaction_enriched_view
GROUP  BY flow_direction
ORDER  BY tx_count DESC;


-- 3. Running balance spot-check for one account
-- All rows for one account showing the cumulative balance build
SELECT
    account_id,
    transaction_date,
    transaction_type,
    amount,
    signed_amount,
    running_balance,
    tx_rank_in_account,
    is_latest_tx,
    days_since_prev_tx
FROM   transaction_enriched_view
WHERE  account_id = (
    SELECT tx.account_id
    FROM   transactions AS tx
    GROUP  BY tx.account_id
    ORDER  BY COUNT(*) DESC
    LIMIT  1
)
ORDER  BY tx_rank_in_account ASC;


-- 4. Confirm is_latest_tx = 1 appears exactly once per account
SELECT
    COUNT(DISTINCT account_id)              AS total_accounts,
    SUM(is_latest_tx)                       AS latest_tx_flags,
    COUNT(DISTINCT account_id)
        - SUM(is_latest_tx)                 AS discrepancy
FROM   transaction_enriched_view;
-- Expected: total_accounts = latest_tx_flags, discrepancy = 0


-- 5. Amount band distribution
SELECT
    amount_band,
    COUNT(*)              AS tx_count,
    ROUND(AVG(amount), 2) AS avg_amount,
    ROUND(MIN(amount), 2) AS min_amount,
    ROUND(MAX(amount), 2) AS max_amount
FROM   transaction_enriched_view
GROUP  BY amount_band
ORDER  BY min_amount ASC;


-- 6. Monthly volume trend — quick time-series sanity check
SELECT
    tx_month_start,
    COUNT(*)               AS tx_count,
    ROUND(SUM(amount), 2)  AS total_volume
FROM   transaction_enriched_view
GROUP  BY tx_month_start
ORDER  BY tx_month_start ASC
LIMIT  12;
