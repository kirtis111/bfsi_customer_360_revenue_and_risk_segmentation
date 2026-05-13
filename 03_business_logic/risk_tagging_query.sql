-- =============================================================
-- risk_tagging_query.sql
-- Layer   : 03_business_logic/
--
-- Purpose : Score every customer across four risk dimensions,
--           assign a risk tier (High / Medium / Low), compute a
--           numeric risk score (0–100), and surface the latest
--           transaction per account using ROW_NUMBER().
--
-- Risk dimensions assessed:
--   1. Loan risk      — defaulted or delinquent loan status
--   2. Dormancy risk  — days since last transaction
--   3. Exposure risk  — loan outstanding vs deposit balance
--   4. Activity risk  — unusually high large-transaction count
--
-- SQL skills demonstrated:
--   • ROW_NUMBER()   → isolate latest transaction per account
--   • CASE           → multi-condition risk tier assignment
--   • Weighted score → numeric 0–100 composite risk index
--   • Window SUM     → risk distribution across tiers
--   → customer_360_view already computed all inputs; this file
--     assembles them into a decision framework.
--
-- Risk tier definitions (derived from data audit):
--   HIGH RISK   : defaulted loan
--                 OR delinquent loan + dormant >= 180 days
--   MEDIUM RISK : delinquent loan (still active)
--                 OR dormant >= 365 days
--                 OR loan_to_asset_ratio >= 200
--                 OR 5+ large transactions
--   LOW RISK    : all other customers
--
-- =============================================================


-- =============================================================
-- STEP 1: LATEST TRANSACTION PER ACCOUNT
-- =============================================================

WITH latest_tx_per_account AS (

    SELECT
        t.account_id,
        t.customer_id,
        t.transaction_id,
        t.transaction_type,
        t.amount,
        t.transaction_date              AS last_tx_date,
        t.channel,
        t.flow_direction,
        t.amount_band,
        t.is_large_tx,
        t.days_since_prev_tx,
        t.account_type,
        t.account_status,
        t.current_account_balance,

        -- ROW_NUMBER() assigns 1 to the most recent transaction
        -- per account, 2 to the second most recent, and so on.
        -- PARTITION BY account_id → restart numbering per account.
        -- ORDER BY date DESC, id DESC → most recent = rank 1.
        ROW_NUMBER() OVER (
            PARTITION BY t.account_id
            ORDER BY     t.transaction_date DESC,
                         t.transaction_id   DESC
        )                               AS rn

    FROM transaction_enriched_view AS t
),

-- =============================================================
-- STEP 2: ACCOUNT-LEVEL LATEST TRANSACTION SNAPSHOT
-- =============================================================

account_snapshot AS (

    SELECT
        account_id,
        customer_id,
        transaction_id              AS latest_tx_id,
        transaction_type            AS latest_tx_type,
        amount                      AS latest_tx_amount,
        last_tx_date,
        channel                     AS latest_channel,
        flow_direction              AS latest_flow,
        amount_band                 AS latest_amount_band,
        is_large_tx                 AS latest_is_large,
        days_since_prev_tx          AS latest_gap_days,
        account_type,
        account_status,
        current_account_balance
    FROM latest_tx_per_account
    WHERE rn = 1
),

-- =============================================================
-- STEP 3: CUSTOMER-LEVEL RISK INPUTS
-- =============================================================

risk_inputs AS (

    SELECT
        c.customer_id,
        c.full_name,
        c.customer_tier,
        c.province,
        c.branch_id,
        c.age_band,
        c.tenure_years,

        -- ── Balance and loan metrics (from customer_360_view) ─
        c.total_balance,
        c.loan_count,
        c.total_outstanding_balance,
        c.loan_to_asset_ratio,
        c.has_active_loan,
        c.has_defaulted_loan,
        c.has_delinquent_loan,
        c.has_risk_loan,
        c.est_annual_interest_revenue,

        -- ── Transaction behaviour (from customer_360_view) ────
        c.total_tx_count,
        c.tx_count_90d,
        c.spend_90d,
        c.spend_to_balance_ratio,
        c.days_since_last_tx,
        c.last_tx_date,
        c.recency_label,
        c.large_tx_count,
        c.preferred_channel,

        -- ── Account-level signals (from account_snapshot) ────
        -- Most recent transaction amount across all accounts
        -- MAX picks the largest last-tx if customer has multiple
        -- accounts — the most concerning signal wins.
        MAX(s.latest_tx_amount)             AS max_last_tx_amount,
        MAX(s.latest_is_large)              AS any_account_last_tx_large,

        -- Longest gap (days) between the two most recent
        -- transactions across all of this customer's accounts.
        -- A sudden long gap after activity can signal distress.
        MAX(s.latest_gap_days)              AS max_gap_between_tx,

        -- Count of accounts whose last transaction was an outflow
        -- (withdrawal, payment, fee) — signals drawdown behaviour.
        COUNT(
            CASE WHEN s.latest_flow = 'outflow' THEN 1 END
        )                                   AS accounts_last_tx_outflow,

        -- Count of currently inactive or closed accounts
        COUNT(
            CASE WHEN s.account_status IN ('inactive','closed')
                 THEN 1 END
        )                                   AS inactive_account_count,

        -- Total current balance across all accounts
        -- (cross-check against customer_360_view.total_balance)
        SUM(s.current_account_balance)      AS total_current_balance

    FROM       customer_360_view    AS c
    LEFT JOIN  account_snapshot     AS s
        ON  c.customer_id = s.customer_id
    GROUP BY
        c.customer_id, c.full_name, c.customer_tier,
        c.province, c.branch_id, c.age_band, c.tenure_years,
        c.total_balance, c.loan_count, c.total_outstanding_balance,
        c.loan_to_asset_ratio, c.has_active_loan,
        c.has_defaulted_loan, c.has_delinquent_loan,
        c.has_risk_loan, c.est_annual_interest_revenue,
        c.total_tx_count, c.tx_count_90d, c.spend_90d,
        c.spend_to_balance_ratio, c.days_since_last_tx,
        c.last_tx_date, c.recency_label, c.large_tx_count,
        c.preferred_channel
),

-- =============================================================
-- STEP 4: RISK SCORING
-- Assigns each customer:
--   A) A risk_tier label   (High / Medium / Low)
--   B) Individual flag for each risk dimension (0/1)
--   C) A numeric risk_score (0–100) built from weighted signals
--
-- RISK TIER LOGIC:
--
--   HIGH RISK (any condition):
--     • has_defaulted_loan = 1
--         Borrower has stopped repaying — highest severity.
--     • has_delinquent_loan = 1 AND days_since_last_tx >= 180
--         Behind on payments AND no recent activity — dual signal.
--
--   MEDIUM RISK (any condition, not already High):
--     • has_delinquent_loan = 1 (still active, catching up)
--     • days_since_last_tx >= 365 (gone fully dormant)
--     • loan_to_asset_ratio >= 200 (owes 2x more than held)
--     • large_tx_count >= 5 (unusual transaction frequency)
--
--   LOW RISK:
--     • All other customers
--
-- RISK SCORE (0–100, higher = riskier):
--   Points are additive across independent signals.
--   Weights calibrated so a customer with every signal maxes
--   out near 100, while a clean customer scores near 0.
-- =============================================================

risk_scoring AS (

    SELECT
        *,

        -- ── Individual Risk Flags ─────────────────────────────
        has_defaulted_loan                          AS flag_loan_default,

        has_delinquent_loan                         AS flag_loan_delinquent,

        CASE WHEN days_since_last_tx >= 365
             THEN 1 ELSE 0 END                      AS flag_dormant_365d,

        CASE WHEN days_since_last_tx >= 180
             THEN 1 ELSE 0 END                      AS flag_dormant_180d,

        -- Loan-to-asset > 200 means customer owes more than
        -- 2x their total deposits — significant exposure risk.
        CASE WHEN loan_to_asset_ratio >= 200
             THEN 1 ELSE 0 END                      AS flag_high_loan_exposure,

        -- 5+ large transactions (>$10,275 each) in lifetime —
        -- potential fraud signal or unusual cash movement.
        CASE WHEN large_tx_count >= 5
             THEN 1 ELSE 0 END                      AS flag_high_large_tx,

        -- Most recent transaction being an outflow across all
        -- accounts suggests active drawdown rather than saving.
        CASE WHEN accounts_last_tx_outflow > 0
             THEN 1 ELSE 0 END                      AS flag_last_tx_outflow,

        -- ── Risk Tier Assignment ──────────────────────────────
        CASE
            -- HIGH: defaulted loan is the clearest hard signal
            WHEN has_defaulted_loan = 1
                THEN 'High Risk'

            -- HIGH: delinquent + long dormancy = dual distress signal
            WHEN has_delinquent_loan = 1
             AND days_since_last_tx >= 180
                THEN 'High Risk'

            -- MEDIUM: delinquent but still showing activity
            WHEN has_delinquent_loan = 1
                THEN 'Medium Risk'

            -- MEDIUM: fully dormant for over a year
            WHEN days_since_last_tx >= 365
                THEN 'Medium Risk'

            -- MEDIUM: severe loan-to-asset imbalance
            WHEN loan_to_asset_ratio >= 200
                THEN 'Medium Risk'

            -- MEDIUM: unusually high large transaction count
            WHEN large_tx_count >= 5
                THEN 'Medium Risk'

            -- LOW: no elevated signals
            ELSE 'Low Risk'
        END                                         AS risk_tier,

        -- ── Numeric Risk Score (0–100) ────────────────────────
        -- Each flag contributes a weighted number of points.
        -- Weights reflect severity:
        --   Defaulted loan       → 40 pts (highest severity)
        --   Delinquent loan      → 25 pts
        --   Dormant 365+ days    → 15 pts
        --   Dormant 180+ days    →  5 pts (partial credit)
        --   High loan exposure   → 10 pts
        --   High large tx count  →  5 pts
        -- Maximum achievable score = 100 pts
        LEAST(
            (has_defaulted_loan                              * 40)
          + (has_delinquent_loan                             * 25)
          + (CASE WHEN days_since_last_tx >= 365 THEN 15 ELSE 0 END)
          + (CASE WHEN days_since_last_tx >= 180
                   AND days_since_last_tx <  365 THEN 5  ELSE 0 END)
          + (CASE WHEN loan_to_asset_ratio >= 200 THEN 10 ELSE 0 END)
          + (CASE WHEN large_tx_count >= 5 THEN 5 ELSE 0 END),
            100
        )                                           AS risk_score

    FROM risk_inputs
)

-- =============================================================
-- STEP 5: FINAL RISK REGISTER — ONE ROW PER CUSTOMER
-- =============================================================

SELECT

    -- Identity
    customer_id,
    full_name,
    customer_tier,
    province,
    branch_id,

    -- Risk verdict
    risk_tier,
    risk_score,

    -- Individual flags — explainability for the business
    flag_loan_default,
    flag_loan_delinquent,
    flag_dormant_365d,
    flag_dormant_180d,
    flag_high_loan_exposure,
    flag_high_large_tx,
    flag_last_tx_outflow,

    -- Supporting evidence — the "why" behind the tier
    has_defaulted_loan,
    has_delinquent_loan,
    days_since_last_tx,
    recency_label,
    loan_to_asset_ratio,
    total_outstanding_balance,
    total_balance,
    large_tx_count,
    spend_to_balance_ratio,
    spend_90d,
    tx_count_90d,
    last_tx_date,
    preferred_channel,
    max_last_tx_amount,
    max_gap_between_tx,
    inactive_account_count,
    est_annual_interest_revenue,

    -- Risk percentile within the full customer population
    -- PERCENT_RANK on risk_score: 1.0 = riskiest customer.
    ROUND(
        PERCENT_RANK() OVER (
            ORDER BY risk_score ASC
        )::NUMERIC * 100,
        1
    )                                           AS risk_percentile,

    -- Rank within tier — who is the riskiest within High Risk?
    RANK() OVER (
        PARTITION BY
            CASE
                WHEN has_defaulted_loan = 1               THEN 'High Risk'
                WHEN has_delinquent_loan = 1
                 AND days_since_last_tx >= 180             THEN 'High Risk'
                WHEN has_delinquent_loan = 1               THEN 'Medium Risk'
                WHEN days_since_last_tx >= 365             THEN 'Medium Risk'
                WHEN loan_to_asset_ratio >= 200            THEN 'Medium Risk'
                WHEN large_tx_count >= 5                   THEN 'Medium Risk'
                ELSE 'Low Risk'
            END
        ORDER BY risk_score DESC
    )                                           AS rank_within_tier,

    -- Window: portfolio-level risk exposure
    -- Total outstanding balance for all High Risk customers.
    -- Tells the credit team how much is at risk in dollar terms.
    ROUND(
        SUM(
            CASE WHEN risk_tier = 'High Risk'
                 THEN total_outstanding_balance ELSE 0 END
        ) OVER ()::NUMERIC,
        2
    )                                           AS portfolio_high_risk_exposure,

    CURRENT_DATE                                AS snapshot_date

FROM risk_scoring
ORDER BY risk_score DESC, total_outstanding_balance DESC;


-- =============================================================
-- VALIDATION QUERIES
-- =============================================================

-- 1. Risk tier distribution
SELECT
    risk_tier,
    COUNT(*)                                    AS customer_count,
    ROUND(AVG(risk_score)::NUMERIC, 1)          AS avg_risk_score,
    ROUND(MIN(risk_score)::NUMERIC, 0)          AS min_score,
    ROUND(MAX(risk_score)::NUMERIC, 0)          AS max_score,
    SUM(has_defaulted_loan)                     AS defaulted_loans,
    SUM(has_delinquent_loan)                    AS delinquent_loans,
    ROUND(SUM(total_outstanding_balance)::NUMERIC, 2) AS total_exposure
FROM (
    SELECT
        customer_id,
        full_name,
        risk_tier,
        risk_score,
        has_defaulted_loan,
        has_delinquent_loan,
        total_outstanding_balance
    FROM (
        SELECT
            c.customer_id,
            c.full_name,
            c.has_defaulted_loan,
            c.has_delinquent_loan,
            c.total_outstanding_balance,
            CASE
                WHEN c.has_defaulted_loan = 1                     THEN 'High Risk'
                WHEN c.has_delinquent_loan = 1
                 AND c.days_since_last_tx >= 180                  THEN 'High Risk'
                WHEN c.has_delinquent_loan = 1                    THEN 'Medium Risk'
                WHEN c.days_since_last_tx >= 365                  THEN 'Medium Risk'
                WHEN c.loan_to_asset_ratio >= 200                 THEN 'Medium Risk'
                WHEN c.large_tx_count >= 5                        THEN 'Medium Risk'
                ELSE 'Low Risk'
            END                                                   AS risk_tier,
            LEAST(
                (c.has_defaulted_loan                   * 40)
              + (c.has_delinquent_loan                  * 25)
              + (CASE WHEN c.days_since_last_tx >= 365  THEN 15 ELSE 0 END)
              + (CASE WHEN c.days_since_last_tx >= 180
                       AND c.days_since_last_tx <  365  THEN 5  ELSE 0 END)
              + (CASE WHEN c.loan_to_asset_ratio >= 200 THEN 10 ELSE 0 END)
              + (CASE WHEN c.large_tx_count >= 5        THEN 5  ELSE 0 END),
                100
            )                                                     AS risk_score
        FROM customer_360_view AS c
    ) AS scored
) AS tier_summary
GROUP  BY risk_tier
ORDER  BY avg_risk_score DESC;


-- 2. High Risk customer detail — the watchlist
SELECT
    customer_id,
    full_name,
    customer_tier,
    risk_tier,
    risk_score,
    flag_loan_default,
    flag_loan_delinquent,
    flag_dormant_365d,
    days_since_last_tx,
    total_outstanding_balance,
    total_balance,
    loan_to_asset_ratio
FROM (
    -- Re-run main query inline for validation
    SELECT
        c.customer_id,
        c.full_name,
        c.customer_tier,
        c.days_since_last_tx,
        c.total_outstanding_balance,
        c.total_balance,
        c.loan_to_asset_ratio,
        c.has_defaulted_loan    AS flag_loan_default,
        c.has_delinquent_loan   AS flag_loan_delinquent,
        CASE WHEN c.days_since_last_tx >= 365 THEN 1 ELSE 0 END AS flag_dormant_365d,
        CASE
            WHEN c.has_defaulted_loan = 1                        THEN 'High Risk'
            WHEN c.has_delinquent_loan = 1
             AND c.days_since_last_tx >= 180                     THEN 'High Risk'
            WHEN c.has_delinquent_loan = 1                       THEN 'Medium Risk'
            WHEN c.days_since_last_tx >= 365                     THEN 'Medium Risk'
            WHEN c.loan_to_asset_ratio >= 200                    THEN 'Medium Risk'
            WHEN c.large_tx_count >= 5                           THEN 'Medium Risk'
            ELSE 'Low Risk'
        END                                                      AS risk_tier,
        LEAST(
            (c.has_defaulted_loan                   * 40)
          + (c.has_delinquent_loan                  * 25)
          + (CASE WHEN c.days_since_last_tx >= 365  THEN 15 ELSE 0 END)
          + (CASE WHEN c.days_since_last_tx >= 180
                   AND c.days_since_last_tx <  365  THEN 5  ELSE 0 END)
          + (CASE WHEN c.loan_to_asset_ratio >= 200 THEN 10 ELSE 0 END)
          + (CASE WHEN c.large_tx_count >= 5        THEN 5  ELSE 0 END),
            100
        )                                                        AS risk_score
    FROM customer_360_view AS c
) AS tagged
WHERE risk_tier = 'High Risk'
ORDER BY risk_score DESC;
