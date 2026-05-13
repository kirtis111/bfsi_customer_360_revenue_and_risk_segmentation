"""
generate_data.py
Customer 360 + Revenue & Risk Segmentation
Generates synthetic banking data for 4 tables:
  customers, accounts, transactions, loans
Outputs raw (messy) CSVs only.
Cleaning is handled in SQL: 01_schema/03_clean_raw_data.sql
"""

import pandas as pd
import numpy as np
from faker import Faker
import random
from datetime import datetime, timedelta
import os

# ── Reproducibility ──────────────────────────────────────────
SEED = 42
random.seed(SEED)
np.random.seed(SEED)
Faker.seed(SEED)
fake = Faker("en_CA")

OUTPUT_DIR = "00_data"
os.makedirs(OUTPUT_DIR, exist_ok=True)

# ── Volume ────────────────────────────────────────────────────
N_CUSTOMERS = 200

# ── Reference data ────────────────────────────────────────────
PROVINCES = ["ON", "BC", "AB", "QC", "MB", "SK", "NS", "NB"]
CITIES = {
    "ON": ["Toronto", "Ottawa", "Mississauga", "Brampton", "Hamilton"],
    "BC": ["Vancouver", "Victoria", "Burnaby", "Surrey", "Richmond"],
    "AB": ["Calgary", "Edmonton", "Red Deer", "Lethbridge"],
    "QC": ["Montreal", "Quebec City", "Laval", "Gatineau"],
    "MB": ["Winnipeg", "Brandon"],
    "SK": ["Saskatoon", "Regina"],
    "NS": ["Halifax", "Dartmouth"],
    "NB": ["Fredericton", "Moncton", "Saint John"],
}
BRANCHES = [f"BR{str(i).zfill(3)}" for i in range(1, 21)]
ACCOUNT_TYPES = ["chequing", "savings", "investment", "TFSA", "RRSP"]
ACCOUNT_STATUS = ["active", "inactive", "closed"]
ACCOUNT_STATUS_W = [0.78, 0.12, 0.10]
TX_TYPES = ["deposit", "withdrawal", "transfer", "payment", "fee"]
TX_CHANNELS = ["online", "branch", "atm", "mobile"]
LOAN_TYPES = ["mortgage", "personal", "auto", "business"]
LOAN_STATUSES = ["active", "closed", "defaulted", "delinquent"]
LOAN_STATUS_W = [0.65, 0.20, 0.08, 0.07]

# ── Helpers ───────────────────────────────────────────────────

def rand_date(start: str, end: str) -> datetime:
    s = datetime.strptime(start, "%Y-%m-%d")
    e = datetime.strptime(end, "%Y-%m-%d")
    return s + timedelta(days=random.randint(0, (e - s).days))


def pareto_balances(n: int, low: float, high: float) -> np.ndarray:
    """
    Power-law distribution so top ~20% hold ~65% of total balance.
    Uses Pareto shape parameter tuned to produce that concentration.
    """
    raw = np.random.pareto(a=1.2, size=n) + 1
    raw = raw / raw.max()
    return np.round(low + raw * (high - low), 2)


# ════════════════════════════════════════════════════════════════
# 1. CUSTOMERS
# ════════════════════════════════════════════════════════════════

def build_customers() -> pd.DataFrame:
    rows = []
    for cid in range(1, N_CUSTOMERS + 1):
        province = random.choice(PROVINCES)
        city = random.choice(CITIES[province])
        dob = rand_date("1950-01-01", "2000-12-31")
        join = rand_date("2010-01-01", "2023-12-31")
        rows.append({
            "customer_id":  f"C{str(cid).zfill(4)}",
            "first_name":   fake.first_name(),
            "last_name":    fake.last_name(),
            "email":        fake.email(),
            "phone":        fake.phone_number(),
            "date_of_birth": dob.strftime("%Y-%m-%d"),
            "gender":       random.choice(["M", "F", "Non-binary"]),
            "province":     province,
            "city":         city,
            "postal_code":  fake.postcode(),
            "join_date":    join.strftime("%Y-%m-%d"),
            "branch_id":    random.choice(BRANCHES),
            "customer_segment": None,   # derived later in SQL
        })
    return pd.DataFrame(rows)


# ════════════════════════════════════════════════════════════════
# 2. ACCOUNTS
# ════════════════════════════════════════════════════════════════

def build_accounts(customers: pd.DataFrame) -> pd.DataFrame:
    """
    Each customer gets 1-3 accounts.
    Balances follow a Pareto distribution to ensure
    top 20% of customers own ~65% of total deposits.
    """
    rows = []
    aid = 1

    # Pre-generate Pareto balances for all accounts we'll create
    total_accounts_estimate = N_CUSTOMERS * 2
    all_balances = pareto_balances(total_accounts_estimate * 2, 100, 250_000)
    bal_idx = 0

    for _, cust in customers.iterrows():
        n_acc = random.choices([1, 2, 3], weights=[0.35, 0.45, 0.20])[0]
        join_dt = datetime.strptime(cust["join_date"], "%Y-%m-%d")

        acc_types_chosen = random.sample(ACCOUNT_TYPES, n_acc)
        for atype in acc_types_chosen:
            open_dt = join_dt + timedelta(days=random.randint(0, 365))
            status  = random.choices(ACCOUNT_STATUS, ACCOUNT_STATUS_W)[0]
            balance = float(all_balances[bal_idx]); bal_idx += 1

            # High-value boost: top-segment customers get much higher balances
            if cust["customer_id"] in [f"C{str(i).zfill(4)}" for i in range(1, 41)]:
                balance *= random.uniform(5, 15)
                balance = round(min(balance, 2_000_000), 2)

            rows.append({
                "account_id":    f"A{str(aid).zfill(5)}",
                "customer_id":   cust["customer_id"],
                "account_type":  atype,
                "balance":       round(balance, 2),
                "currency":      "CAD",
                "status":        status,
                "opened_date":   open_dt.strftime("%Y-%m-%d"),
                "branch_id":     cust["branch_id"],
            })
            aid += 1

    return pd.DataFrame(rows)


# ════════════════════════════════════════════════════════════════
# 3. TRANSACTIONS
# ════════════════════════════════════════════════════════════════

def build_transactions(accounts: pd.DataFrame) -> pd.DataFrame:
    rows = []
    tid = 1

    for _, acc in accounts.iterrows():
        # Active accounts get more transactions
        n_tx = random.randint(8, 25) if acc["status"] == "active" else random.randint(1, 6)
        open_dt = datetime.strptime(acc["opened_date"], "%Y-%m-%d")

        for _ in range(n_tx):
            tx_date = open_dt + timedelta(
                days=random.randint(1, max(1, (datetime(2024, 12, 31) - open_dt).days))
            )
            tx_type = random.choices(TX_TYPES, weights=[0.30, 0.28, 0.20, 0.17, 0.05])[0]

            # Amount varies by type
            if tx_type == "deposit":
                amount = round(random.uniform(50, 15_000), 2)
            elif tx_type in ("withdrawal", "transfer"):
                amount = round(random.uniform(20, 8_000), 2)
            elif tx_type == "payment":
                amount = round(random.uniform(10, 3_000), 2)
            else:  # fee
                amount = round(random.uniform(5, 50), 2)

            rows.append({
                "transaction_id":   f"T{str(tid).zfill(7)}",
                "account_id":       acc["account_id"],
                "customer_id":      acc["customer_id"],
                "transaction_type": tx_type,
                "amount":           amount,
                "transaction_date": tx_date.strftime("%Y-%m-%d"),
                "channel":          random.choice(TX_CHANNELS),
                "description":      fake.bs().title()[:60],
            })
            tid += 1

    return pd.DataFrame(rows)


# ════════════════════════════════════════════════════════════════
# 4. LOANS
# ════════════════════════════════════════════════════════════════

def build_loans(customers: pd.DataFrame) -> pd.DataFrame:
    rows = []
    lid = 1

    # ~50% of customers have at least one loan
    loan_customers = customers.sample(frac=0.50, random_state=SEED)

    for _, cust in loan_customers.iterrows():
        n_loans = random.choices([1, 2], weights=[0.80, 0.20])[0]
        join_dt = datetime.strptime(cust["join_date"], "%Y-%m-%d")

        for _ in range(n_loans):
            ltype   = random.choice(LOAN_TYPES)
            status  = random.choices(LOAN_STATUSES, LOAN_STATUS_W)[0]

            if ltype == "mortgage":
                principal = round(random.uniform(150_000, 900_000), 2)
                rate      = round(random.uniform(3.5, 6.5), 2)
                term_yrs  = random.choice([15, 20, 25, 30])
            elif ltype == "business":
                principal = round(random.uniform(20_000, 500_000), 2)
                rate      = round(random.uniform(5.0, 9.0), 2)
                term_yrs  = random.choice([3, 5, 10])
            elif ltype == "auto":
                principal = round(random.uniform(8_000, 60_000), 2)
                rate      = round(random.uniform(4.0, 8.5), 2)
                term_yrs  = random.choice([3, 4, 5, 6])
            else:  # personal
                principal = round(random.uniform(2_000, 50_000), 2)
                rate      = round(random.uniform(6.5, 14.0), 2)
                term_yrs  = random.choice([1, 2, 3, 5])

            start_dt = join_dt + timedelta(days=random.randint(30, 730))
            end_dt   = start_dt + timedelta(days=term_yrs * 365)

            paid_pct = 0.0 if status == "active" else (
                1.0 if status == "closed" else random.uniform(0.05, 0.60)
            )
            outstanding = round(principal * (1 - paid_pct), 2)
            monthly_pmt = round((principal * (rate / 100 / 12)) /
                                (1 - (1 + rate / 100 / 12) ** (-term_yrs * 12)), 2)

            rows.append({
                "loan_id":            f"L{str(lid).zfill(5)}",
                "customer_id":        cust["customer_id"],
                "loan_type":          ltype,
                "principal_amount":   principal,
                "outstanding_balance": outstanding,
                "interest_rate":      rate,
                "start_date":         start_dt.strftime("%Y-%m-%d"),
                "end_date":           end_dt.strftime("%Y-%m-%d"),
                "status":             status,
                "monthly_payment":    monthly_pmt,
            })
            lid += 1

    return pd.DataFrame(rows)


# ════════════════════════════════════════════════════════════════
# 5. INTRODUCE RAW-DATA MESS
# ════════════════════════════════════════════════════════════════

def messify_customers(df: pd.DataFrame) -> pd.DataFrame:
    raw = df.copy()
    raw.columns = ["CustomerID", "First Name", "Last Name", "EMAIL",
                   "Phone_Number", "DOB", "Gender", "Province", "City",
                   "PostalCode", "JoinDate", "BranchID", "CustomerSegment"]

    # Mixed date formats
    def rand_date_fmt(d):
        if random.random() < 0.33:
            return datetime.strptime(d, "%Y-%m-%d").strftime("%d/%m/%Y")
        elif random.random() < 0.5:
            return datetime.strptime(d, "%Y-%m-%d").strftime("%d-%b-%Y")
        return d

    raw["DOB"]      = raw["DOB"].apply(rand_date_fmt)
    raw["JoinDate"] = raw["JoinDate"].apply(rand_date_fmt)

    # Inconsistent gender values
    raw["Gender"] = raw["Gender"].apply(
        lambda g: random.choice(["Male", "male", "M"]) if g == "M"
        else (random.choice(["Female", "female", "F"]) if g == "F" else g)
    )

    # Inject ~8% nulls in non-critical columns
    for col in ["Phone_Number", "EMAIL", "PostalCode"]:
        null_idx = raw.sample(frac=0.08, random_state=SEED).index
        raw.loc[null_idx, col] = np.nan

    # Trailing whitespace in names
    raw["First Name"] = raw["First Name"].apply(
        lambda x: x + "  " if random.random() < 0.15 else x
    )

    # 5 duplicate rows
    dupes = raw.sample(5, random_state=SEED)
    raw = pd.concat([raw, dupes], ignore_index=True)

    return raw


def messify_accounts(df: pd.DataFrame) -> pd.DataFrame:
    raw = df.copy()
    raw.columns = ["AccountID", "CustomerID", "Account_Type", "Balance",
                   "Currency", "Status", "OpenedDate", "Branch_ID"]

    raw["OpenedDate"] = raw["OpenedDate"].apply(
        lambda d: datetime.strptime(d, "%Y-%m-%d").strftime("%d/%m/%Y")
        if random.random() < 0.4 else d
    )

    # Inconsistent account type casing
    raw["Account_Type"] = raw["Account_Type"].apply(
        lambda x: x.upper() if random.random() < 0.25 else x
    )

    # ~5% null balances
    null_idx = raw.sample(frac=0.05, random_state=SEED).index
    raw.loc[null_idx, "Balance"] = np.nan

    return raw


def messify_transactions(df: pd.DataFrame) -> pd.DataFrame:
    raw = df.copy()
    raw.columns = ["TransactionID", "AccountID", "CustomerID", "TxType",
                   "Amount", "TxDate", "Channel", "Description"]

    raw["TxDate"] = raw["TxDate"].apply(
        lambda d: datetime.strptime(d, "%Y-%m-%d").strftime("%m-%d-%Y")
        if random.random() < 0.3 else d
    )

    # ~3% null amounts (failed/pending transactions)
    null_idx = raw.sample(frac=0.03, random_state=SEED).index
    raw.loc[null_idx, "Amount"] = np.nan

    # Inconsistent tx type
    raw["TxType"] = raw["TxType"].apply(
        lambda x: x.upper() if random.random() < 0.20 else x
    )

    return raw


def messify_loans(df: pd.DataFrame) -> pd.DataFrame:
    raw = df.copy()
    raw.columns = ["LoanID", "CustomerID", "LoanType", "PrincipalAmount",
                   "OutstandingBalance", "InterestRate", "StartDate",
                   "EndDate", "Status", "MonthlyPayment"]

    raw["StartDate"] = raw["StartDate"].apply(
        lambda d: datetime.strptime(d, "%Y-%m-%d").strftime("%d-%b-%Y")
        if random.random() < 0.35 else d
    )
    raw["EndDate"] = raw["EndDate"].apply(
        lambda d: datetime.strptime(d, "%Y-%m-%d").strftime("%d/%m/%Y")
        if random.random() < 0.35 else d
    )

    # ~4% null outstanding balances
    null_idx = raw.sample(frac=0.04, random_state=SEED).index
    raw.loc[null_idx, "OutstandingBalance"] = np.nan

    return raw


# ════════════════════════════════════════════════════════════════
# 6. MAIN
# ════════════════════════════════════════════════════════════════

def main():
    print("Generating customers...")
    customers    = build_customers()

    print("Generating accounts...")
    accounts     = build_accounts(customers)

    print("Generating transactions...")
    transactions = build_transactions(accounts)

    print("Generating loans...")
    loans        = build_loans(customers)

    # ── Verify the 80/20 balance concentration ──────────────────
    merged    = accounts.merge(customers[["customer_id"]], on="customer_id")
    total_bal = merged["balance"].sum()
    top20_bal = (merged.groupby("customer_id")["balance"]
                       .sum()
                       .sort_values(ascending=False)
                       .head(int(N_CUSTOMERS * 0.20))
                       .sum())
    pct = round(top20_bal / total_bal * 100, 1)
    print(f"  Top 20% customers hold {pct}% of total balances  (target ~65%)")

    # ── Write raw (messy) CSVs only ──────────────────────────────
    # Cleaning is handled downstream in SQL: 01_schema/03_clean_raw_data.sql
    print("\nWriting raw CSVs...")
    messify_customers(customers).to_csv(      f"{OUTPUT_DIR}/raw_customers.csv",    index=False)
    messify_accounts(accounts).to_csv(        f"{OUTPUT_DIR}/raw_accounts.csv",     index=False)
    messify_transactions(transactions).to_csv(f"{OUTPUT_DIR}/raw_transactions.csv", index=False)
    messify_loans(loans).to_csv(              f"{OUTPUT_DIR}/raw_loans.csv",        index=False)

    # ── Summary ──────────────────────────────────────────────────
    raw_c = pd.read_csv(f"{OUTPUT_DIR}/raw_customers.csv")
    print("\n── Dataset Summary ──────────────────────────────")
    print(f"  Customers    : {len(customers):>6,}  (raw rows incl. dupes: {len(raw_c):,})")
    print(f"  Accounts     : {len(accounts):>6,}")
    print(f"  Transactions : {len(transactions):>6,}")
    print(f"  Loans        : {len(loans):>6,}")
    print(f"\n  Issues seeded for SQL cleaning:")
    print(f"    Mixed date formats   : DOB, JoinDate, StartDate, TxDate")
    print(f"    Inconsistent casing  : Gender, Account_Type, TxType")
    print(f"    Null values          : EMAIL, Phone, PostalCode, Balance, Amount")
    print(f"    Duplicate rows       : 5 duplicate customers")
    print(f"\n  Loan status breakdown:")
    print(loans["status"].value_counts().to_string())
    print(f"\n  Files written to ./{OUTPUT_DIR}/")
    print("    raw_customers.csv | raw_accounts.csv")
    print("    raw_transactions.csv | raw_loans.csv")
    print("\n  Next step: 01_schema/01_create_tables.sql")


if __name__ == "__main__":
    main()
