-- =============================================================
-- powerbi_prep_query.sql
-- Layer   : 04_reporting/sql/
--
-- Two tables produced:
--
--   TABLE 1: pbi_customer_master
--     Grain: one row per customer (200 rows)
--     Use:   Customer table in Power BI data model.
--            Drives all customer-level visuals, slicers,
--            KPI cards, and the customer detail tooltip.
--
--   TABLE 2: pbi_monthly_trends
--     Grain: one row per calendar month (~166 rows)
--     Use:   Date table + trend metrics in Power BI.
--            Drives all line charts, area charts,
--            MoM comparison cards, and YTD totals.
--
-- =============================================================


-- =============================================================
-- TABLE 1: pbi_customer_master
-- One row per customer. Flat. No window functions.
-- All risk and segmentation fields included so Power BI
-- can slice any visual by tier, risk, province, channel.
--
-- =============================================================

SELECT

    -- ==========================================================
    -- DIMENSION: CUSTOMER IDENTITY
    -- These are the slicer and filter fields in Power BI.
    -- Keep as VARCHAR -- no casting needed.
    -- ==========================================================

    c.customer_id,
    c.full_name,
    c.first_name,
    c.last_name,
    c.gender,
    c.province,
    c.city,
    c.branch_id,
    c.age_band,
    c.tenure_band,
    c.customer_tier,

    -- ==========================================================
    -- DIMENSION: CUSTOMER LIFECYCLE
    -- Date columns must be DATE type (not VARCHAR) for Power BI
    -- to recognise them as date fields and enable time slicers.
    -- ==========================================================

    c.date_of_birth,
    c.join_date,
    c.last_tx_date,
    c.age_years,
    c.tenure_years,
    c.days_since_last_tx,
    c.recency_label,

    -- ==========================================================
    -- METRIC: BALANCE AND PRODUCT DEPTH
    -- Prefixed bal_ so all balance fields group together
    -- in the Power BI field list panel.
    -- ==========================================================

    ROUND(c.total_balance::NUMERIC,          2)  AS bal_total,
    ROUND(c.net_financial_position::NUMERIC, 2)  AS bal_net_position,
    c.total_accounts                             AS bal_account_count,
    c.active_account_count                       AS bal_active_accounts,
    c.product_count                              AS bal_product_count,
    c.is_multi_product                           AS bal_is_multi_product,
    c.has_chequing                               AS bal_has_chequing,
    c.has_investment_account                     AS bal_has_investment,

    -- ==========================================================
    -- METRIC: TRANSACTION BEHAVIOUR
    -- Prefixed tx_ for grouping in the field list.
    -- avg_monthly_tx_count kept as-is -- already NUMERIC.
    -- ==========================================================

    c.total_tx_count                             AS tx_lifetime_count,
    c.tx_count_90d                               AS tx_count_last_90d,
    ROUND(c.spend_90d::NUMERIC,              2)  AS tx_spend_last_90d,
    ROUND(c.total_inflow::NUMERIC,           2)  AS tx_total_inflow,
    ROUND(c.total_outflow::NUMERIC,          2)  AS tx_total_outflow,
    ROUND(c.spend_to_balance_ratio::NUMERIC, 2)  AS tx_spend_to_balance_ratio,
    c.avg_monthly_tx_count                       AS tx_avg_monthly_count,
    c.large_tx_count                             AS tx_large_count,
    c.preferred_channel                          AS tx_preferred_channel,

    -- ==========================================================
    -- METRIC: LOAN EXPOSURE
    -- Prefixed loan_ for grouping.
    -- Binary flags (0/1) kept as INTEGER for DAX SUM() measures.
    -- ==========================================================

    c.loan_count,
    c.has_any_loan                               AS loan_has_any,
    c.has_active_loan                            AS loan_has_active,
    c.has_defaulted_loan                         AS loan_has_defaulted,
    c.has_delinquent_loan                        AS loan_has_delinquent,
    c.has_risk_loan                              AS loan_has_risk,
    ROUND(c.total_outstanding_balance::NUMERIC, 2) AS loan_outstanding_balance,
    ROUND(c.total_principal_borrowed::NUMERIC,  2) AS loan_principal_borrowed,
    ROUND(c.total_monthly_loan_payment::NUMERIC,2) AS loan_monthly_payment,
    ROUND(c.loan_to_asset_ratio::NUMERIC,       2) AS loan_to_asset_ratio,
    c.loan_types_held,

    -- ==========================================================
    -- METRIC: REVENUE
    -- The bank's estimated annual income from this customer.
    -- ==========================================================

    ROUND(c.est_annual_interest_revenue::NUMERIC, 2) AS revenue_est_annual_interest,

    -- ==========================================================
    -- METRIC: RISK (inline computation)
    -- ==========================================================

	CASE
	    WHEN c.has_defaulted_loan = 1 THEN 'High Risk'

    	WHEN c.has_delinquent_loan = 1
         	AND c.days_since_last_tx >= 180 THEN 'High Risk'

    	WHEN c.has_delinquent_loan = 1 THEN 'Medium Risk'

    	WHEN c.days_since_last_tx >= 540 THEN 'Medium Risk'

    	WHEN c.loan_to_asset_ratio >= 300 THEN 'Medium Risk'

    	WHEN c.large_tx_count >= 10 THEN 'Medium Risk'

    	ELSE 'Low Risk'
	END AS risk_tier,

    -- Numeric risk score (0-100) for heatmap and sorting
    LEAST(
        (c.has_defaulted_loan                        * 40)
      + (c.has_delinquent_loan                       * 25)
      + (CASE WHEN c.days_since_last_tx >= 365 THEN 15 ELSE 0 END)
      + (CASE WHEN c.days_since_last_tx >= 180
               AND c.days_since_last_tx <  365 THEN  5 ELSE 0 END)
      + (CASE WHEN c.loan_to_asset_ratio >= 200 THEN 10 ELSE 0 END)
      + (CASE WHEN c.large_tx_count >= 5        THEN  5 ELSE 0 END),
        100
    )                                                          AS risk_score,

    -- ==========================================================
    -- METRIC: CROSS-SELL
    -- ==========================================================

    c.is_investment_cross_sell_target            AS cross_sell_investment_flag,

    -- ==========================================================
    -- METADATA
    -- ==========================================================

    c.snapshot_date

FROM customer_360_view AS c
ORDER BY c.customer_tier ASC, c.total_balance DESC;


-- =============================================================
-- TABLE 2: pbi_monthly_trends
--
-- Key Power BI usage notes:
--   month_start  -> mark as Date table on this column
--   tx_year      -> use for year slicer
--   tx_quarter   -> use for quarter slicer
--   quarter_label -> use as axis label (Q1 2023 etc.)
--   month_label   -> use as short x-axis label (Jan 2023)
-- =============================================================

SELECT

    -- ==========================================================
    -- DIMENSION: TIME
    -- ==========================================================

    m.month_start,
    m.month_label,
    m.tx_year,
    m.tx_quarter,
    m.tx_month,
    m.quarter_label,

    -- ==========================================================
    -- METRIC: TRANSACTION VOLUME
    -- Core metrics for the monthly activity line charts.
    -- ==========================================================

    m.tx_count,
    ROUND(m.total_volume::NUMERIC,          2)   AS total_volume,
    ROUND(m.total_inflow::NUMERIC,          2)   AS total_inflow,
    ROUND(m.total_outflow::NUMERIC,         2)   AS total_outflow,
    ROUND(m.net_flow::NUMERIC,              2)   AS net_flow,
    m.active_customers,
    ROUND(m.avg_volume_per_customer::NUMERIC, 2) AS avg_volume_per_customer,
    ROUND(m.avg_tx_amount::NUMERIC,         2)   AS avg_tx_amount,

    -- ==========================================================
    -- METRIC: TRANSACTION TYPE BREAKDOWN
    -- Used in stacked bar charts by transaction type.
    -- ==========================================================

    m.deposit_count,
    m.withdrawal_count,
    m.transfer_count,
    m.payment_count,
    m.fee_count,

    -- ==========================================================
    -- METRIC: CHANNEL BREAKDOWN
    -- Used in channel mix donut/bar charts.
    -- ==========================================================

    m.online_tx_count,
    m.mobile_tx_count,
    m.branch_tx_count,
    m.atm_tx_count,

    -- ==========================================================
    -- METRIC: TIER VOLUME SPLIT
    -- Used in stacked area charts showing tier contribution
    -- to monthly volume over time.
    -- ==========================================================

    ROUND(m.high_value_volume::NUMERIC, 2)       AS tier_high_value_volume,
    ROUND(m.medium_volume::NUMERIC,     2)       AS tier_medium_volume,
    ROUND(m.low_volume::NUMERIC,        2)       AS tier_low_volume,
    m.high_value_active_customers                AS tier_high_value_customers,
    m.medium_active_customers                    AS tier_medium_customers,
    m.low_active_customers                       AS tier_low_customers,

    -- ==========================================================
    -- METRIC: MONTH-OVER-MONTH CHANGE
    -- Used in MoM comparison KPI cards and waterfall charts.
    -- NULL for the first month (no previous month to compare).
    -- ==========================================================

    m.tx_count_mom_change,
    ROUND(m.volume_mom_change::NUMERIC,     2)   AS volume_mom_change,
    ROUND(m.volume_mom_pct_change::NUMERIC, 2)   AS volume_mom_pct_change,
    ROUND(m.inflow_mom_change::NUMERIC,     2)   AS inflow_mom_change,
    m.active_customers_mom_change,

    -- ==========================================================
    -- METRIC: CUMULATIVE AND ROLLING AVERAGES
    -- Used in area charts showing portfolio growth over time
    -- and in smoothed trend lines.
    -- ==========================================================

    ROUND(m.cumulative_volume::NUMERIC,      2)  AS cumulative_volume,
    ROUND(m.cumulative_inflow::NUMERIC,      2)  AS cumulative_inflow,
    ROUND(m.cumulative_net_flow::NUMERIC,    2)  AS cumulative_net_flow,
    ROUND(m.rolling_3m_avg_volume::NUMERIC,  2)  AS rolling_3m_avg_volume,
    ROUND(m.rolling_3m_avg_tx_count::NUMERIC,2)  AS rolling_3m_avg_tx_count,

    -- ==========================================================
    -- METRIC: YEAR-TO-DATE TOTALS
    -- Resets to zero every January.
    -- Used in YTD KPI cards on the executive page.
    -- ==========================================================

    ROUND(m.ytd_volume::NUMERIC,  2)             AS ytd_volume,
    ROUND(m.ytd_inflow::NUMERIC,  2)             AS ytd_inflow,

    -- ==========================================================
    -- METADATA
    -- ==========================================================

    m.snapshot_date

FROM monthly_trends_view AS m
ORDER BY m.month_start ASC;
