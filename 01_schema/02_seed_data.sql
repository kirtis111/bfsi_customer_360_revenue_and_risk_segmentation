-- =============================================================
-- 02_seed_data.sql

-- Prerequisite : 01_create_tables.sql must be run first.
-- =============================================================


-- =============================================================
-- STEP 1: CLEAR STAGING TABLES
-- Truncate before loading so re-runs don't double the data.
-- RESTART IDENTITY resets any sequences (not used here but
-- is good practice). CASCADE clears dependent tables too.
-- =============================================================

TRUNCATE TABLE stg_customers    RESTART IDENTITY CASCADE;
TRUNCATE TABLE stg_accounts     RESTART IDENTITY CASCADE;
TRUNCATE TABLE stg_transactions RESTART IDENTITY CASCADE;
TRUNCATE TABLE stg_loans        RESTART IDENTITY CASCADE;


-- =============================================================
-- STEP 2: LOAD RAW CSVs INTO STAGING
-- =============================================================

COPY stg_customers (
    customer_id,
    first_name,
    last_name,
    email,
    phone_number,
    dob,
    gender,
    province,
    city,
    postal_code,
    join_date,
    branch_id,
    customer_segment
)
FROM 'C:/Users/kirti/Downloads/Customer 360 + Revenue & Risk Segmentation/00_data/raw_customers.csv'
WITH (
    FORMAT   csv,
    HEADER   TRUE,
    NULL     '',
    ENCODING 'utf8'
);


-- ── stg_accounts ──────────────────────────────────────────────
-- CSV headers : AccountID, CustomerID, Account_Type, Balance,
--               Currency, Status, OpenedDate, Branch_ID
-- Known issues: mixed case in Account_Type, mixed date formats
--               in OpenedDate, ~5% null Balance values

COPY stg_accounts (
    account_id,
    customer_id,
    account_type,
    balance,
    currency,
    status,
    opened_date,
    branch_id
)
FROM 'C:/Users/kirti/Downloads/Customer 360 + Revenue & Risk Segmentation/00_data/raw_accounts.csv'
WITH (
    FORMAT   csv,
    HEADER   TRUE,
    NULL     '',
    ENCODING 'utf8'
);


-- ── stg_transactions ──────────────────────────────────────────
-- CSV headers : TransactionID, AccountID, CustomerID, TxType,
--               Amount, TxDate, Channel, Description
-- Known issues: mixed case in TxType (deposit/DEPOSIT),
--               mixed date formats (YYYY-MM-DD vs MM-DD-YYYY),
--               ~3% null Amount values

COPY stg_transactions (
    transaction_id,
    account_id,
    customer_id,
    tx_type,
    amount,
    tx_date,
    channel,
    description
)
FROM 'C:/Users/kirti/Downloads/Customer 360 + Revenue & Risk Segmentation/00_data/raw_transactions.csv'
WITH (
    FORMAT   csv,
    HEADER   TRUE,
    NULL     '',
    ENCODING 'utf8'
);


-- ── stg_loans ─────────────────────────────────────────────────
-- CSV headers : LoanID, CustomerID, LoanType, PrincipalAmount,
--               OutstandingBalance, InterestRate, StartDate,
--               EndDate, Status, MonthlyPayment
-- Known issues: mixed date formats in StartDate + EndDate
--               (YYYY-MM-DD, DD-Mon-YYYY, DD/MM/YYYY),
--               ~4% null OutstandingBalance values

COPY stg_loans (
    loan_id,
    customer_id,
    loan_type,
    principal_amount,
    outstanding_balance,
    interest_rate,
    start_date,
    end_date,
    status,
    monthly_payment
)
FROM 'C:/Users/kirti/Downloads/Customer 360 + Revenue & Risk Segmentation/00_data/raw_loans.csv'
WITH (
    FORMAT   csv,
    HEADER   TRUE,
    NULL     '',
    ENCODING 'utf8'
);


-- =============================================================
-- STEP 3: ROW COUNT VERIFICATION

-- Expected (matches generate_data.py output):
--   stg_customers    : 205  (200 real + 5 deliberate duplicates)
--   stg_accounts     : 370
--   stg_transactions : 5102
--   stg_loans        : 124
-- =============================================================

SELECT
    'stg_customers'    AS table_name,
    COUNT(*)           AS loaded_rows,
    205                AS expected_rows,
    CASE
        WHEN COUNT(*) = 205 THEN 'PASS'
        ELSE 'FAIL — recheck file path or CSV'
    END                AS status
FROM stg_customers

UNION ALL

SELECT
    'stg_accounts'                                                  AS table_name,
    COUNT(*)                                                        AS loaded_rows,
    370                                                             AS expected_rows,
    CASE WHEN COUNT(*) = 370 THEN 'PASS' ELSE 'FAIL — recheck file path or CSV' END AS status
FROM stg_accounts

UNION ALL

SELECT
    'stg_transactions'                                              AS table_name,
    COUNT(*)                                                        AS loaded_rows,
    5102                                                            AS expected_rows,
    CASE WHEN COUNT(*) = 5102 THEN 'PASS' ELSE 'FAIL — recheck file path or CSV' END AS status
FROM stg_transactions

UNION ALL

SELECT
    'stg_loans'                                                     AS table_name,
    COUNT(*)                                                        AS loaded_rows,
    124                                                             AS expected_rows,
    CASE WHEN COUNT(*) = 124 THEN 'PASS' ELSE 'FAIL — recheck file path or CSV' END AS status
FROM stg_loans;


-- =============================================================
-- STEP 4: SPOT-CHECK SAMPLES
-- =============================================================

-- Confirm mixed date formats survived intact
SELECT customer_id, first_name, dob, join_date, gender
FROM   stg_customers
ORDER BY customer_id
LIMIT  10;

-- Confirm null balances are present
SELECT account_id, customer_id, account_type, balance, status
FROM   stg_accounts
WHERE  balance IS NULL
ORDER BY account_id
LIMIT  5;

-- Confirm mixed-case transaction types are present
SELECT transaction_id, tx_type, amount, tx_date
FROM   stg_transactions
WHERE  tx_type != LOWER(tx_type)
ORDER BY transaction_id
LIMIT  5;

-- Confirm null outstanding balances in loans
SELECT loan_id, customer_id, loan_type, outstanding_balance, status
FROM   stg_loans
WHERE  outstanding_balance IS NULL
ORDER BY loan_id
LIMIT  5;
