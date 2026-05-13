# Customer 360 + Revenue & Risk Segmentation

**Project:** Customer 360 + Revenue & Risk Segmentation
**Dataset:** 200 customers · 370 accounts · 4,949 transactions · 124 loans
**Tools:** PostgreSQL · Advanced SQL · Power BI

---

## Portfolio at a Glance

| Metric                       | Value          |
| ---------------------------- | -------------- |
| Total Deposits (AUM)         | CAD 996,871    |
| Total Loan Book              | CAD 19,864,433 |
| Est. Annual Interest Revenue | CAD 1,115,604  |
| Active Customers             | 200            |
| Active Accounts              | 288 of 370     |
| Clean Transactions           | 4,949          |

---

## Finding 1 - Concentration Risk: Top 20% Hold 75.8% of Deposits

The deposit base follows a strong Pareto distribution. Just **40 customers** - the top 20% by total balance - hold **75.8% of the bank's total deposits**. The top 10% (20 customers) alone account for **58.8%**.

| Tier                     | Customers | Deposits    | Share |
| ------------------------ | --------- | ----------- | ----- |
| High Value (80th pct+)   | 40        | CAD 755,808 | 75.8% |
| Medium (40th - 80th pct) | 80        | CAD 184,358 | 18.5% |
| Low (below 40th pct)     | 80        | CAD 55,805  | 5.6%  |

**Business implication:** The bank's deposit stability is disproportionately dependent on 40 relationships. Losing a single High Value customer removes more deposit value than losing 20 Low-tier customers combined. Retention programmes, dedicated relationship managers, and proactive outreach should prioritise this group first.

**SQL used:** `NTILE(5)` window function ordered by `total_balance`. Quintile 5 → High Value, quintiles 3–4 → Medium, quintiles 1–2 → Low. Concentration percentage computed using `SUM() OVER ()` as a global denominator, then `ROUND((segment_balance / grand_total)::NUMERIC * 100, 1)`.

---

## Finding 2 - Balance Alone Is a Misleading Value Proxy

When customers are ranked by a composite **Lifetime Value (LTV) score** - balance (40%) + transaction volume (30%) + estimated annual interest revenue (30%) - **only 4 of the top-20 by balance also appear in the top-20 by LTV**.

Two archetypes emerged from comparing `ltv_rank` vs `balance_rank`:

**Hidden Gems** (`rank_gap ≥ +20`) — modest deposits, large loan portfolios, high interest revenue. A customer with a CAD 1,600 balance generating CAD 70,000+ per year in interest revenue would rank in the bottom 40% on a balance-only dashboard but near the top 10% by LTV. A balance-only view would systematically misclassify this customer as Low-tier.

**Passive Depositors** (`rank_gap ≤ -20`) - large balances, low transaction frequency, no loans. They hold deposits but generate minimal fee or interest revenue. High attrition risk because they have no product depth anchoring the relationship.

**Business implication:** Segment performance reviews and relationship manager allocation should use LTV score, not balance alone. Hidden Gems are often poached by competitors who recognise their loan revenue potential.

**SQL used:** `MAX() OVER ()` global portfolio maximums for 0–100 normalisation. Weighted composite score with `LEAST(..., 100.0)` cap. `RANK()`, `DENSE_RANK()`, `PERCENT_RANK()`, and `NTILE(4)` applied in one CTE pass. `LAG(balance_rank, 1) OVER (ORDER BY ltv_rank)` to compute the rank divergence.

---

## Finding 3 - 15.7% of the Loan Book Is at Risk

Of the CAD 19,864,433 total loan book, **CAD 3,123,061 (15.7%)** is held by customers with defaulted or delinquent status - and at-risk customers carry above-average loan balances relative to their headcount.

| Status          | Customers | Outstanding Balance |
| --------------- | --------- | ------------------- |
| Defaulted       | 10        | ~CAD 1.4M           |
| Delinquent      | 13        | ~CAD 1.7M           |
| Active / Closed | 177       | ~CAD 16.7M          |

A multi-signal risk score (0–100) was built from four independent dimensions:

| Signal                | Weight | Rationale                       |
| --------------------- | ------ | ------------------------------- |
| Defaulted loan        | 40 pts | Borrower has stopped repaying   |
| Delinquent loan       | 25 pts | Behind on payments, recoverable |
| Dormant ≥ 365 days   | 15 pts | No activity in over a year      |
| Dormant 180–364 days | 5 pts  | Slowing activity, early warning |
| Loan-to-asset ≥ 200% | 10 pts | Owes 2× more than deposited    |
| 5+ large transactions | 5 pts  | Unusual cash movement pattern   |

**Business implication:** Credit team should contact the 10 defaulted-loan customers immediately. The 13 delinquent customers need a restructuring conversation before they migrate to defaulted status. Both groups must be excluded from cross-sell campaigns.

**SQL used:** `ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY transaction_date DESC)` to isolate each account's most recent transaction for dormancy analysis. Multi-condition `CASE` for tier assignment. `LEAST(weighted_sum, 100)` to cap the score. `PERCENT_RANK() OVER (ORDER BY risk_score ASC)` for portfolio-wide risk percentile.

---

## Finding 4 - 66 Customers Have No Retirement Product

**66 customers** - one-third of the portfolio - hold neither an RRSP nor a TFSA. This is the largest single product gap in the portfolio, ahead of the chequing-to-investment gap (25 customers) and investment-to-loan gap (37 customers).

| Cross-Sell Gap          | Target Customers | Priority                        |
| ----------------------- | ---------------- | ------------------------------- |
| No RRSP or TFSA         | 66               | Highest volume                  |
| Chequing, no investment | 25               | Highest value (High Tier first) |
| Savings, no chequing    | 49               | Primary banking acquisition     |
| Investment, no loan     | 37               | Secured lending                 |

RRSP and TFSA are Canadian tax-advantaged accounts every working adult should hold. A customer with a savings account and no RRSP is likely doing their retirement saving at another institution - a relationship depth risk.

**Business implication:** A targeted retirement planning campaign to the 66 gap customers - routed by `preferred_channel` and prioritised by tier × age band - is the highest-volume single cross-sell opportunity. Converting 20% of this group (13 customers) into RRSP holders would add immediate AUM.

**SQL used:** `NOT EXISTS (SELECT 1 FROM accounts WHERE account_type IN ('RRSP','TFSA'))` for gap detection. Three-component priority score (tier 50 pts + age band 20 pts + tenure 15 pts). `STRING_AGG(DISTINCT opportunity_type, ' | ' ORDER BY gap_code)` in Analysis 2 to show customers with multiple simultaneous gaps in one readable string.

---

## Finding 5 - Channel Distribution Is Perfectly Balanced

Transaction channel usage across 4,949 clean transactions:

| Channel | Transactions | Share |
| ------- | ------------ | ----- |
| Branch  | 1,258        | 25.4% |
| Online  | 1,252        | 25.3% |
| Mobile  | 1,237        | 25.0% |
| ATM     | 1,202        | 24.3% |

No channel dominates or cannibalises others. The bank has achieved genuine multi-channel engagement - a positive signal for relationship depth that is unusual in retail banking, where mobile typically claims 40 - 50% of transactions within 3 years of app launch.

**Business implication:** Cross-sell outreach should route by each customer's `preferred_channel` rather than defaulting to digital-only campaigns. Branch customers respond to advisor meeting invitations; online/mobile customers respond to in-app prompts. The channel-based outreach plan in `cross_sell_opportunities.sql` (Analysis 3) provides the exact routing table.

---

## Finding 6 - BC and NS Punch Above Their Weight

Despite equal customer headcount (31 each), **British Columbia generates 2.8× more deposits than Ontario**.

| Province | Customers | Total Deposits | Avg Balance |
| -------- | --------- | -------------- | ----------- |
| BC       | 31        | CAD 295,115    | CAD 9,520   |
| NS       | 25        | CAD 211,513    | CAD 8,461   |
| QC       | 28        | CAD 168,567    | CAD 6,020   |
| ON       | 31        | CAD 105,804    | CAD 3,413   |
| AB       | 23        | CAD 77,429     | CAD 3,367   |

Nova Scotia outperforms Alberta, Manitoba, and New Brunswick combined despite having fewer customers than all three.

**Business implication:** Branch staffing, relationship manager allocation, and marketing budget should reflect wealth concentration rather than headcount distribution. BC and NS branches each manage nearly 3× the average deposit per customer compared to Ontario branches - they should be resourced accordingly.

---

## Methodology Notes

**Data:** Synthetic, generated with `generate_data.py` (Faker + NumPy Pareto). Pareto `a=1.2` was tuned to produce the 75.8% top-quintile concentration. No real customer data used.

**Cleaning:** Six data quality issues were seeded in raw CSVs and resolved entirely in SQL: mixed date formats (3 formats per column), inconsistent gender casing (7 variants of 3 values), mixed account-type casing, null monetary values, trailing whitespace in names, and 5 duplicate customer rows. All cleaning uses `TO_DATE()`, `TRIM()`, `NULLIF()`, `COALESCE()`, and `ROW_NUMBER() PARTITION BY` - no Python post-processing.

**Tier thresholds:** `High Value` ≥ CAD 5,611 and `Low` < CAD 1,167 were derived from the actual 80th and 40th percentiles of the data via `NTILE(5)`, not hardcoded arbitrarily.

**Validation:** 53 automated checks across three files confirm data integrity at every layer before analysis runs.
