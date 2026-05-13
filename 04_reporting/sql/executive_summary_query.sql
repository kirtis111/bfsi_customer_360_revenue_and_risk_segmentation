-- =============================================================
-- executive_summary_query.sql
-- Layer   : 04_reporting/sql/

-- Purpose : Seven clean aggregation queries that produce the
--           executive dashboard in Power BI. Each query maps
--           to a specific visual or KPI card section.
--
-- =============================================================


-- =============================================================
-- QUERY 1: PORTFOLIO KPI CARDS
-- =============================================================

SELECT

    -- Volume
    COUNT(DISTINCT customer_id)                         AS total_customers,
    SUM(total_accounts)                                 AS total_accounts,
    SUM(active_account_count)                           AS active_accounts,

    -- Balance and wealth
    ROUND(SUM(total_balance)::NUMERIC,               2) AS total_aum_cad,
    ROUND(AVG(total_balance)::NUMERIC,               2) AS avg_balance_per_customer,
    ROUND(MAX(total_balance)::NUMERIC,               2) AS largest_single_customer_balance,

    -- Loan book
    ROUND(SUM(total_outstanding_balance)::NUMERIC,   2) AS total_loan_book_cad,
    ROUND(AVG(total_outstanding_balance)::NUMERIC,   2) AS avg_loan_per_customer,
    SUM(has_any_loan)                                   AS customers_with_loans,
    SUM(has_defaulted_loan)                             AS customers_defaulted,
    SUM(has_delinquent_loan)                            AS customers_delinquent,

    -- Revenue
    ROUND(SUM(est_annual_interest_revenue)::NUMERIC, 2) AS est_total_annual_interest_cad,
    ROUND(AVG(est_annual_interest_revenue)::NUMERIC, 2) AS avg_interest_revenue_per_customer,

    -- Transactions
    SUM(total_tx_count)                                 AS total_lifetime_transactions,
    ROUND(SUM(spend_90d)::NUMERIC,                   2) AS total_spend_last_90d_cad,
    SUM(is_investment_cross_sell_target)                AS cross_sell_targets,

    -- Snapshot
    MAX(snapshot_date)                                  AS report_date

FROM customer_360_view;


-- =============================================================
-- QUERY 2: CUSTOMER TIER SUMMARY
-- =============================================================

WITH tier_totals AS (
    SELECT
        customer_tier,
        COUNT(*)                                        AS customer_count,
        ROUND(SUM(total_balance)::NUMERIC,          2)  AS tier_total_balance,
        ROUND(AVG(total_balance)::NUMERIC,          2)  AS tier_avg_balance,
        ROUND(MIN(total_balance)::NUMERIC,          2)  AS tier_min_balance,
        ROUND(MAX(total_balance)::NUMERIC,          2)  AS tier_max_balance,
        ROUND(AVG(product_count)::NUMERIC,          1)  AS avg_products_held,
        ROUND(AVG(total_tx_count)::NUMERIC,         1)  AS avg_lifetime_transactions,
        ROUND(SUM(est_annual_interest_revenue)::NUMERIC, 2) AS tier_interest_revenue,
        SUM(has_any_loan)                               AS customers_with_loans,
        SUM(has_risk_loan)                              AS customers_at_risk,
        SUM(is_investment_cross_sell_target)            AS cross_sell_targets,
        -- Grand total for share calculation
        SUM(SUM(total_balance)) OVER ()                 AS portfolio_total
    FROM customer_360_view
    GROUP BY customer_tier
)

SELECT
    customer_tier,
    customer_count,
    tier_total_balance,
    tier_avg_balance,
    tier_min_balance,
    tier_max_balance,
    avg_products_held,
    avg_lifetime_transactions,
    tier_interest_revenue,
    customers_with_loans,
    customers_at_risk,
    cross_sell_targets,
    -- Concentration: % of total portfolio balance
    ROUND(
        (tier_total_balance / NULLIF(portfolio_total, 0))::NUMERIC * 100, 1
    )                                                   AS pct_of_total_balance
FROM tier_totals
ORDER BY tier_total_balance DESC;


-- =============================================================
-- QUERY 3: RISK DISTRIBUTION
-- =============================================================

WITH risk_tagged AS (
    SELECT
        customer_id,
        customer_tier,
        total_balance,
        total_outstanding_balance,
        est_annual_interest_revenue,
        has_defaulted_loan,
        has_delinquent_loan,
        days_since_last_tx,
        CASE
            WHEN has_defaulted_loan = 1                        THEN 'High Risk'
            WHEN has_delinquent_loan = 1
             AND days_since_last_tx >= 180                     THEN 'High Risk'
            WHEN has_delinquent_loan = 1                       THEN 'Medium Risk'
            WHEN days_since_last_tx  >= 365                    THEN 'Medium Risk'
            WHEN loan_to_asset_ratio >= 200                    THEN 'Medium Risk'
            WHEN large_tx_count      >= 5                      THEN 'Medium Risk'
            ELSE                                                    'Low Risk'
        END                                                    AS risk_tier
    FROM customer_360_view
)

SELECT
    risk_tier,
    COUNT(*)                                            AS customer_count,
    ROUND(SUM(total_balance)::NUMERIC,              2)  AS total_balance_at_risk,
    ROUND(AVG(total_balance)::NUMERIC,              2)  AS avg_balance,
    ROUND(SUM(total_outstanding_balance)::NUMERIC,  2)  AS total_loan_exposure,
    ROUND(AVG(total_outstanding_balance)::NUMERIC,  2)  AS avg_loan_exposure,
    ROUND(SUM(est_annual_interest_revenue)::NUMERIC,2)  AS est_interest_revenue,
    SUM(has_defaulted_loan)                             AS defaulted_count,
    SUM(has_delinquent_loan)                            AS delinquent_count,
    -- Portfolio share
    ROUND(
        COUNT(*)::NUMERIC
        / NULLIF(SUM(COUNT(*)) OVER (), 0) * 100, 1
    )                                                   AS pct_of_customers,
    ROUND(
        SUM(total_outstanding_balance)::NUMERIC
        / NULLIF(SUM(SUM(total_outstanding_balance)) OVER (), 0) * 100, 1
    )                                                   AS pct_of_loan_book
FROM risk_tagged
GROUP BY risk_tier
ORDER BY
    CASE risk_tier
        WHEN 'High Risk'   THEN 1
        WHEN 'Medium Risk' THEN 2
        ELSE                    3
    END ASC;


-- =============================================================
-- QUERY 4: REVENUE SUMMARY BY TIER
-- =============================================================

SELECT
    customer_tier,
    COUNT(*)                                            AS customers,
    -- Deposit revenue proxy: balance held (opportunity cost)
    ROUND(SUM(total_balance)::NUMERIC,               2) AS total_deposits,
    -- Loan revenue: actual interest income
    ROUND(SUM(est_annual_interest_revenue)::NUMERIC, 2) AS total_interest_revenue,
    ROUND(AVG(est_annual_interest_revenue)::NUMERIC, 2) AS avg_interest_revenue,
    -- Top earner in each tier
    ROUND(MAX(est_annual_interest_revenue)::NUMERIC, 2) AS max_interest_revenue,
    -- Loan penetration rate
    ROUND(
        SUM(has_any_loan)::NUMERIC
        / NULLIF(COUNT(*), 0) * 100, 1
    )                                                   AS loan_penetration_pct,
    -- Cross-sell revenue opportunity (customers with no investment product)
    SUM(is_investment_cross_sell_target)                AS investment_gap_count,
    -- 90-day spend = fee and transaction revenue indicator
    ROUND(SUM(spend_90d)::NUMERIC,                   2) AS total_spend_90d,
    ROUND(AVG(spend_to_balance_ratio)::NUMERIC,      2) AS avg_spend_to_balance_ratio
FROM customer_360_view
GROUP BY customer_tier
ORDER BY total_interest_revenue DESC;


-- =============================================================
-- QUERY 5: BRANCH PERFORMANCE
-- =============================================================

SELECT
    branch_id,
    COUNT(DISTINCT customer_id)                         AS customer_count,
    ROUND(SUM(total_balance)::NUMERIC,               2) AS total_deposits,
    ROUND(AVG(total_balance)::NUMERIC,               2) AS avg_customer_balance,
    ROUND(SUM(total_outstanding_balance)::NUMERIC,   2) AS total_loan_book,
    ROUND(SUM(est_annual_interest_revenue)::NUMERIC, 2) AS est_annual_interest,
    SUM(has_any_loan)                                   AS customers_with_loans,
    SUM(has_defaulted_loan)                             AS defaulted_loans,
    SUM(has_risk_loan)                                  AS at_risk_customers,
    SUM(is_investment_cross_sell_target)                AS cross_sell_targets,
    ROUND(AVG(product_count)::NUMERIC,               1) AS avg_products_per_customer,
    ROUND(AVG(total_tx_count)::NUMERIC,              1) AS avg_lifetime_transactions,
    -- Primary tier at this branch (most common tier)
    MODE() WITHIN GROUP (ORDER BY customer_tier)        AS dominant_tier
FROM customer_360_view
GROUP BY branch_id
ORDER BY total_deposits DESC;


-- =============================================================
-- QUERY 6: PROVINCE SUMMARY
-- One row per province (8 provinces). No window functions.
-- Maps to a Canada choropleth map and province bar chart.
-- Note: province codes (ON, BC etc.) map to Power BI's
-- Canada map shape if the column is tagged as Province.
-- =============================================================

SELECT
    province,
    COUNT(DISTINCT customer_id)                         AS customer_count,
    ROUND(SUM(total_balance)::NUMERIC,               2) AS total_deposits,
    ROUND(AVG(total_balance)::NUMERIC,               2) AS avg_balance,
    ROUND(SUM(total_outstanding_balance)::NUMERIC,   2) AS total_loan_book,
    ROUND(SUM(est_annual_interest_revenue)::NUMERIC, 2) AS est_annual_interest,
    -- Tier mix
    SUM(CASE WHEN customer_tier = 'High Value' THEN 1 ELSE 0 END)
                                                        AS high_value_customers,
    SUM(CASE WHEN customer_tier = 'Medium'     THEN 1 ELSE 0 END)
                                                        AS medium_customers,
    SUM(CASE WHEN customer_tier = 'Low'        THEN 1 ELSE 0 END)
                                                        AS low_customers,
    -- Risk mix
    SUM(has_defaulted_loan)                             AS defaulted_loans,
    SUM(has_risk_loan)                                  AS at_risk_customers,
    -- Opportunity
    SUM(is_investment_cross_sell_target)                AS cross_sell_targets,
    ROUND(AVG(product_count)::NUMERIC,               1) AS avg_products
FROM customer_360_view
GROUP BY province
ORDER BY total_deposits DESC;


-- =============================================================
-- QUERY 7: MONTHLY TREND -- LAST 12 MONTHS
-- =============================================================

SELECT
    month_start,
    month_label,
    tx_year,
    tx_quarter,
    quarter_label,
    tx_count,
    ROUND(total_volume::NUMERIC,           2)           AS total_volume,
    ROUND(total_inflow::NUMERIC,           2)           AS total_inflow,
    ROUND(total_outflow::NUMERIC,          2)           AS total_outflow,
    ROUND(net_flow::NUMERIC,               2)           AS net_flow,
    active_customers,
    ROUND(avg_tx_amount::NUMERIC,          2)           AS avg_tx_amount,
    -- Tier volume split
    ROUND(high_value_volume::NUMERIC,      2)           AS high_value_volume,
    ROUND(medium_volume::NUMERIC,          2)           AS medium_volume,
    ROUND(low_volume::NUMERIC,             2)           AS low_volume,
    -- MoM change
    tx_count_mom_change,
    ROUND(volume_mom_change::NUMERIC,      2)           AS volume_mom_change,
    ROUND(volume_mom_pct_change::NUMERIC,  2)           AS volume_mom_pct_change,
    -- Smoothed trend
    ROUND(rolling_3m_avg_volume::NUMERIC,  2)           AS rolling_3m_avg_volume,
    -- YTD
    ROUND(ytd_volume::NUMERIC,             2)           AS ytd_volume,
    ROUND(ytd_inflow::NUMERIC,             2)           AS ytd_inflow
FROM monthly_trends_view
-- Last 12 calendar months from the most recent month in the data
WHERE month_start >= (
    SELECT MAX(sub.month_start) - INTERVAL '11 months'
    FROM   monthly_trends_view AS sub
)
ORDER BY month_start ASC;
