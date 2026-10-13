# Lab 4 — Advanced SQL for Production Support: data incidents in a risk platform

**Goal:** investigate 12 realistic data tickets from a bank's risk platform. Each ticket comes with the
**query the report uses today** (which is wrong). Your job: prove what's wrong with evidence, explain it to the
customer, and write the corrected query.
**Time:** 4–6 hours (do it over several days) · **Stack (open source):** PostgreSQL 16, psql, DBeaver Community (optional GUI).

Topics: window functions, `DISTINCT ON`, `LATERAL`, recursive CTEs with cycles, gaps & islands, anti-joins,
`NULL` semantics, time zones, numeric vs float, `EXPLAIN ANALYZE`, locks, reconciliation with `FULL OUTER JOIN`.

## Setup

**Option A — Docker**
```bash
docker compose up -d                       # first start loads the data (~20 s)
docker exec -it lab-riskdb psql -U support -d riskdb
```
**Option B — local PostgreSQL 14+**
```bash
createdb riskdb
psql -d riskdb -f sql/01_schema.sql
psql -d riskdb -f sql/02_data.sql
psql -d riskdb
```
The data is generated with a fixed seed, so everyone gets the same numbers.
Sessions default to `TimeZone = UTC` and `search_path = risk`.

## The data model

```
books ──< trades >── counterparties ──< counterparty_aliases
            │               └── parent_id (legal hierarchy, self-reference)
            │
            ├── instruments            fx_rates (rate_date, currency → rate_to_eur)
            └── cash_flows (legacy)
batch_runs ──< risk_results             eod_positions (custody snapshot)
blocked_counterparties
```

Key business rules (read them — most bugs break one of these):
1. **Trades are versioned.** An amendment inserts version N+1. A cancellation inserts a final version with `status = 'CANCELLED'`.
   **The truth is the latest version of each `trade_id`.** Cancelled trades must be excluded.
2. **FX fixings** exist only on business days of each currency (holidays have no fixing).
3. The **EOD_RISK** batch can be rerun. Only the **latest successful run** of a date is valid.
4. `booked_at` is a `timestamptz` (stored in UTC). Desks think in **their local time** (`books.desk_tz`).
5. Money is `numeric`. Never `real`/`double precision`.

Start by exploring: `\dt`, `\d trades`, `SELECT * FROM batch_runs ORDER BY started_at;` …

## How to work each ticket
1. **Reproduce** — run the report query, see the symptom.
2. **Prove** — write a query that shows the root cause (evidence you would paste in the ticket).
3. **Fix** — write the corrected query.
4. **Communicate** — one paragraph for the customer (no jargon), and one line for engineering.

---

## Level 1 — Warm-up

### T01 · "PV doubled on 7 October in the trend report"
> *Market Risk:* "The PV trend chart shows a spike to ~6.9 bn EUR on 7 Oct. The day before and after are ~3.4 bn. Nothing happened in the market."
```sql
SELECT as_of_date, sum(value_eur) AS pv_eur
FROM risk_results
WHERE measure = 'PV' AND as_of_date BETWEEN '2026-10-05' AND '2026-10-09'
GROUP BY as_of_date ORDER BY as_of_date;
```
- Find the evidence in `batch_runs`. What happened on 7 Oct?
- Fix: use only the latest successful run per date (try both `DISTINCT ON` and `row_number()`).
- Bonus: which constraint or design change would prevent this permanently?

### T02 · "Our notional is 15% higher than the front-office system"
> *Rates desk:* "Your report says 1,125 bn EUR notional for EUR_RATES. Murex says ~963 bn."
```sql
SELECT b.book_code, count(*) AS trades, sum(t.notional) AS notional
FROM trades t JOIN books b USING (book_id)
GROUP BY b.book_code ORDER BY 1;
```
- How many rows exist per `trade_id`? Find a trade with 3 versions and show its history.
- Correct the report (latest version, no cancelled). How many live trades are there in total?

### T03 · "Trades missing from the EUR-converted report"
> *Product Control:* "The EUR report has fewer trades than the trade blotter. It's random: some days are complete, some aren't."
```sql
WITH latest AS (SELECT DISTINCT ON (trade_id) * FROM trades ORDER BY trade_id, version DESC)
SELECT count(*) AS trades, sum(l.notional * f.rate_to_eur) AS notional_eur
FROM latest l
JOIN fx_rates f ON f.rate_date = l.trade_date AND f.currency = l.currency
WHERE l.status <> 'CANCELLED';
```
- Which trades disappear? Group them by date and currency. Why those dates? (hint: look at the calendar)
- Fix it with `LEFT JOIN LATERAL` to use the **last available fixing** on or before the trade date.
- Add a column that **flags** how many trades used a stale fixing. Why is silently using a stale rate also a risk?

## Level 2 — Classic traps

### T04 · "Total exposure doesn't match the sum of the books"
> *Credit Risk:* "The counterparty report total is 6,565 bn, but the sum of the book reports is 5,829 bn."
```sql
WITH latest AS (SELECT DISTINCT ON (trade_id) * FROM trades ORDER BY trade_id, version DESC)
SELECT a.alias AS counterparty, count(*) AS trades, sum(l.notional) AS notional
FROM latest l
JOIN counterparty_aliases a USING (counterparty_id)
WHERE l.status <> 'CANCELLED'
GROUP BY a.alias ORDER BY notional DESC;
```
- Compare `count(*)` before and after the join. Which counterparties are counted twice, and why?
- Fix it. Then write a generic **check** you could run after any join to detect fan-out.

### T05 · "The exposure report is empty since 5 October"
> *Credit Risk:* "The 'exposure excluding blocked counterparties' report returns nothing at all. It worked last week."
```sql
SELECT count(*), sum(notional)
FROM trades
WHERE counterparty_id NOT IN (SELECT counterparty_id FROM blocked_counterparties);
```
- Look at `blocked_counterparties`. What changed on 5 Oct?
- Explain **in SQL three-valued logic** why one row makes the whole result empty.
- Fix it two ways. Which one is safer and why? Also fix the other bug in this query (rule 1).

### T06 · "My trades from yesterday evening are missing"
> *US Rates desk, New York:* "In the 'trades booked on 9 Oct' report I count 634 trades. My blotter says 663."
```sql
SELECT count(*)
FROM trades t JOIN books b USING (book_id)
WHERE b.book_code = 'US_RATES' AND t.version = 1
  AND t.booked_at::date = '2026-10-09';
```
- Run `SHOW TimeZone;`. Then run the query again after `SET TimeZone = 'America/New_York';`. What changes and why?
- Show 5 trades that the desk sees as "9 Oct" but the report puts on "10 Oct" (show both UTC and NY time).
- Write the query so that it gives the right answer **regardless of the session time zone**.
- Discussion: `date` vs `timestamp` vs `timestamptz`. Which one would you use for `trade_date` and `booked_at`?

## Level 3 — Advanced

### T07 · "Which days have no valid risk numbers?"
> *Risk Committee:* "Audit asks for the list of business days in Sep–Oct without valid EOD risk, and our worst run of failures."
- List the business days from 1 Sep to 12 Oct with **no successful** `EOD_RISK` run, saying whether there was **no run at all** or **only failed runs**. (`generate_series` + anti-join)
- **Gaps & islands:** find the longest streak of consecutive business days where the **first attempt** failed. (hint: `row_number()` minus `row_number() OVER (PARTITION BY status ...)`)
- Which run is still in an inconsistent state? (look at `finished_at`)

### T08 · "The group exposure report hangs every night since the hierarchy import"
> *Credit Risk IT:* "The job that computes exposure by ultimate parent never finishes. We kill it after 2 hours."
```sql
-- ⚠️ Protect yourself first:
SET statement_timeout = '10s';

WITH RECURSIVE up AS (
    SELECT counterparty_id AS cp, counterparty_id AS node, parent_id FROM counterparties
    UNION ALL
    SELECT up.cp, c.counterparty_id, c.parent_id
    FROM up JOIN counterparties c ON c.counterparty_id = up.parent_id
)
SELECT cp, node AS ultimate_parent FROM up WHERE parent_id IS NULL;
```
- Why does it never end? Find the bad data **with a query** (PostgreSQL 14+: `CYCLE ... SET ... USING ...`, or a `depth` column with a limit).
- Write the report "notional by ultimate parent" that **finishes** and shows the broken entities as a separate line (`'!! BROKEN HIERARCHY'`) instead of dropping them. How much notional is affected?
- Who should fix the data, and what would you put in the ticket?

### T09 · "Cash flow total is off by a few hundred euros"
> *Treasury:* "The sum of upcoming cash flows in your system differs from the source file total (-149,671,374.15 EUR)."
```sql
SELECT sum(amount) FROM cash_flows;
```
- Compare `sum(amount)`, `sum(amount::float8)` and `sum(amount_exact)`. Explain each result.
- Find the rows where the stored value is not the original one. What's the largest error per row?
- Why does `real` (float4) keep only ~7 significant digits? Why is `numeric` mandatory for money?

### T10 · "The 'book activity' screen takes 8 seconds in production"
```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT trade_id, version, isin, notional, booked_at
FROM trades
WHERE book_id = 6 AND booked_at::date = '2026-10-09'
ORDER BY booked_at;
```
- Read the plan: scan type, rows removed by filter, buffers. Why is the index `ix_trades_booked_at` **not** used?
- Rewrite the predicate as a **range** on `booked_at` (in the desk's time zone) and create the right **composite index**. Compare execution time and buffers.
- In production the table has 400 M rows. Why would you use `CREATE INDEX CONCURRENTLY`? What does it cost?

### T11 · "The EOD batch is stuck since 20:00" (interactive — 3 terminals)
Open three `psql` sessions:
```sql
-- Terminal A  (an analyst doing a "quick manual fix" and going to lunch)
\set PROMPT1 'ANALYST> '
BEGIN;
UPDATE batch_runs SET status = 'FAILED' WHERE run_id = 1034;
-- do NOT commit

-- Terminal B  (the batch)
SET application_name = 'eod-batch';
UPDATE batch_runs SET finished_at = now() WHERE run_id = 1034;   -- hangs

-- Terminal C  (you, on support)
```
In terminal C:
- Find who is blocked and who is blocking: `pg_stat_activity` + `pg_blocking_pids()`. Show pid, application, state, wait event, transaction age and query.
- What does `state = 'idle in transaction'` mean, and why is it dangerous (locks, VACUUM)?
- Resolve it: first `pg_cancel_backend`, then `pg_terminate_backend`. What's the difference? Which one would you use here, and **who would you ask first**?
- Which settings prevent this? (`lock_timeout`, `idle_in_transaction_session_timeout`, `statement_timeout`)
- Bonus: create a **deadlock** with two sessions updating two rows in opposite order. Read the error and the server log.

### T12 · "Custody reconciliation breaks on 9 October"
> *Operations:* "Please reconcile our positions as of 9 Oct against the custody file (`eod_positions`) and list every break."
- Build our positions from trades (rule 1, `trade_date <= '2026-10-09'`), compare with `eod_positions` using a `FULL OUTER JOIN`.
- Classify each break: `MISSING_IN_CUSTODY`, `MISSING_IN_OUR_BOOKS`, `QUANTITY_BREAK`, with the difference.
- Why `IS DISTINCT FROM` instead of `<>`?
- One break is a difference of exactly **1 unit**. What could cause that in real life?

---

## Final challenge — a data-quality monitor
Write **one query** (or a view `dq_checks`) that returns one row per check with `check_name, failed_rows, status (OK/FAIL)`:
duplicate successful runs per date, business days without valid risk, trades without FX, aliases fan-out, `NULL`s in
`blocked_counterparties`, hierarchy cycles, reconciliation breaks. In a real support team, this runs every morning before the users arrive.

Solutions: `SOLUTIONS.md` and `solutions/solutions.sql` (runnable).
