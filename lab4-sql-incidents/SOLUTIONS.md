# Lab 4 — Solutions

All queries are in `solutions/solutions.sql` (runnable: `psql -d riskdb -f solutions/solutions.sql`)
and the monitor in `solutions/dq_checks.sql`. Below: the explanation, the key numbers, and the message to the customer.

## T01 — Duplicated batch rerun
- **Evidence:** `2026-10-07` has two `SUCCESS` runs (1030 and 1031, the second one rerun on 8 Oct at 06:30). The report sums both → 12 rows instead of 6, PV ≈ 6.93 bn instead of ≈ 3.46 bn.
- **Fix:** `DISTINCT ON (as_of_date) ... ORDER BY as_of_date, started_at DESC`, or `row_number() OVER (PARTITION BY as_of_date ORDER BY started_at DESC) = 1`. The corrected value for 7 Oct is ≈ 3,464.1 M.
- **Prevention:** an `is_official` flag set by the batch (with a partial unique index `UNIQUE (job_name, as_of_date) WHERE is_official`), or a view `v_official_runs` that every report must use.
- **Customer:** "The 7 Oct batch was rerun after a market-data correction and the report counted both runs. The correct PV is 3.46 bn EUR. Your other dates are not affected."

## T02 — Versioned trades
- `SELECT trade_id, count(*) FROM trades GROUP BY 1 HAVING count(*) = 3 LIMIT 5;` then `SELECT * FROM trades WHERE trade_id = 73 ORDER BY version;` (LIVE → AMENDED → CANCELLED).
- Naive EUR_RATES 1,125.70 bn vs correct **962.69 bn** (matches the desk). Total live trades: **116,363**.
- The naive query counts amendments twice and includes cancelled trades.

## T03 — INNER JOIN drops rows
- Missing: JPY on **21 and 23 Sep** (Japanese holidays) and BRL on **12 Oct** (Brazilian holiday): 213 + 195 + 675 = **1,083 trades** silently gone (115,280 instead of 116,363).
- **Fix:** `LEFT JOIN LATERAL (... WHERE rate_date <= trade_date ORDER BY rate_date DESC LIMIT 1)`. All 116,363 trades appear, 1,083 valued with the previous fixing.
- **Lesson:** an `INNER JOIN` to reference data is a silent filter. After any join, compare row counts. Using a stale rate is a business decision: flag it, don't hide it.

## T04 — Join fan-out
- 5 counterparties (3, 12, 22, 31, 40) have both a `MX_` and a `CAL_` alias. Their trades are counted twice: 131,014 rows instead of 116,363.
- **Fix:** filter the alias table to one source (`source_system = 'MUREX'`) or aggregate first, then join.
- **Generic check:** `SELECT count(*), count(DISTINCT trade_id)` after the join. If they differ, there is fan-out. Or check that the join key is unique on the right side (`GROUP BY key HAVING count(*) > 1`).

## T05 — NOT IN with NULL
- On 5 Oct, someone inserted `(NULL, 'test entry - please ignore')` through the admin UI.
- `x NOT IN (33, 35, NULL)` means `x <> 33 AND x <> 35 AND x <> NULL`. `x <> NULL` is **UNKNOWN**, so the whole condition is never TRUE, and no rows are returned.
- **Fixes:** `NOT EXISTS (...)` (safe, NULL-proof) or `NOT IN (SELECT ... WHERE counterparty_id IS NOT NULL)` (works, but fragile). Prefer `NOT EXISTS`. Also apply rule 1: correct result **110,449 live trades, 5,534.13 bn**.
- **Permanent fix:** delete the row, add `NOT NULL` to the column, and validate in the UI. Escalate the UI bug.

## T06 — Time zones
- `booked_at::date` uses the **session** time zone. In UTC, trades booked in New York after 20:00 (EDT = UTC−4) fall on the next day: **634** instead of **663**. With `SET TimeZone = 'America/New_York'` you get 663, and the same report would then be wrong for the Paris books.
- **Session-independent:** `(booked_at AT TIME ZONE b.desk_tz)::date = '2026-10-09'`, or as a range: `booked_at >= timestamp '2026-10-09' AT TIME ZONE 'America/New_York' AND booked_at < timestamp '2026-10-10' AT TIME ZONE 'America/New_York'`.
- `trade_date` is a business concept → `date`. `booked_at` is an instant → `timestamptz`. Plain `timestamp` (without time zone) for instants is the root of many bugs.

## T07 — Gaps and islands
- No valid risk: **15 Sep** (no run at all, scheduler outage) and **2 Oct** (only failed runs).
- Longest failure streak (first attempt): **29 Sep → 2 Oct, 4 days**.
- Inconsistent run: **run 1027**, the 2 Oct rerun started on 3 Oct 09:00, is `FAILED` with `finished_at IS NULL`. It probably crashed without cleaning up.
- Trick explained: in a sequence of consecutive rows, `row_number()` overall minus `row_number()` per status is constant inside each streak, so it becomes the group key.

## T08 — Recursive CTE with a cycle
- HOLDCO-LUX (38) → HOLDCO-NL (39) → HOLDCO-LUX (38)… and ORION-TRADING (40) sits under it. `UNION ALL` recursion never ends.
- Detect: `CYCLE node SET is_cycle USING path` (PG 14+) shows paths `{38,39,38}`, `{39,38,39}`, `{40,38,39,38}`. Alternative: add `depth` and `WHERE depth < 20`, then look for rows at depth 20.
- Report: `!! BROKEN HIERARCHY` = **8,744 trades / 437.27 bn** that would otherwise vanish from group exposure.
- Ticket: reference-data team owns the hierarchy. Give them the ids, the path, the date of the import, and ask which parent is correct. Engineering: add cycle protection to the job and a check at import time.

## T09 — Float money
- `real` keeps ~7 significant digits: `571257.47` becomes `571257.5`. Over 60k rows: `sum(amount)` ≈ −149,672,190 (float4 accumulation, very wrong), `sum(amount::float8)` ≈ −149,671,368.76 (better, but the stored values are already wrong), exact −149,671,374.15. Difference ≈ **625.85 EUR**; up to ~0.53 EUR per row.
- `numeric` is exact decimal arithmetic. Floats are binary approximations, fine for physics, never for money. Fix: migrate the column to `numeric(18,2)` from the source file, not from the float values.

## T10 — Query performance
- Before: `Seq Scan`, ~135k rows removed by filter, ~1,940 buffers, ~16 ms here (in production, 400 M rows means seconds or minutes).
- `booked_at::date` depends on the session TimeZone, so it is not immutable and can't use an index on `booked_at`. The predicate is not *sargable*. `book_id` also has no index.
- After: range predicate + `CREATE INDEX ON trades (book_id, booked_at)` → `Bitmap Index Scan`, ~80 buffers, ~0.6 ms (25× faster). The range in NY time also returns the **business-correct** rows (731 vs 701), so you fixed T06 at the same time.
- `CONCURRENTLY` builds the index without blocking writes. Cost: slower, two table scans, can't run inside a transaction, and can leave an `INVALID` index if it fails (check `\d trades`).

## T11 — Locks
```sql
SELECT pid, application_name, state, wait_event_type, wait_event,
       pg_blocking_pids(pid) AS blocked_by,
       now() - xact_start AS xact_age, left(query, 60) AS query
FROM pg_stat_activity
WHERE datname = current_database() AND pid <> pg_backend_pid()
ORDER BY xact_start;
```
- The batch shows `wait_event_type = Lock`, `blocked_by = {<analyst pid>}`. The analyst session is `idle in transaction`: its last query finished, but the transaction is open and **holds row locks**. It also prevents VACUUM from cleaning dead rows (table bloat).
- `pg_cancel_backend(pid)` cancels the **current query** (does nothing useful on an idle session). `pg_terminate_backend(pid)` **kills the connection**, so the transaction rolls back. Here: terminate the analyst session, **but first** contact the person (their change will be lost) and follow your incident procedure. Never kill a session you can't identify.
- Prevention: `idle_in_transaction_session_timeout = '5min'` for human users, `lock_timeout` for the batch (fail fast and alert instead of hanging), read-only accounts for analysts.
- Deadlock: PostgreSQL detects it after `deadlock_timeout` (1 s) and aborts one transaction with `ERROR: deadlock detected`, showing both PIDs and queries.

## T12 — Reconciliation
- 9 breaks: 3 `MISSING_IN_CUSTODY` (book 3: GB…3041, GB…3042; book 5: BR…4080), 2 `MISSING_IN_OUR_BOOKS` (GB…3999, US…2999), 4 `QUANTITY_BREAK` (book 1: +10,000 ×3; book 4: −1).
- `<>` with a NULL side gives UNKNOWN, so the "missing" rows would disappear. `IS DISTINCT FROM` treats NULL as a value.
- A 1-unit break: rounding in a corporate action (split ratio), a partial fill, or a manual adjustment in custody. Ask for the custody transaction history of that ISIN.

## Final challenge
See `solutions/dq_checks.sql`: a view with 7 checks. Today all of them say FAIL. Schedule it (cron/Airflow/the batch itself) and send the result to the team channel every morning.
