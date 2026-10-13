-- =============================================================================
-- Lab 4 - Solution queries (run with: psql ... -f solutions/solutions.sql)
-- =============================================================================
SET search_path = risk;
SET TimeZone = 'UTC';
\pset footer off

\echo '=== T01 - Duplicated batch rerun ================================'
-- Evidence: more than one successful run for the same date
SELECT as_of_date, array_agg(run_id ORDER BY started_at) AS runs, count(*)
FROM batch_runs WHERE job_name = 'EOD_RISK' AND status = 'SUCCESS'
GROUP BY as_of_date HAVING count(*) > 1;

-- Fix: keep only the LATEST successful run per date
WITH latest_run AS (
    SELECT DISTINCT ON (as_of_date) run_id, as_of_date
    FROM batch_runs
    WHERE job_name = 'EOD_RISK' AND status = 'SUCCESS'
    ORDER BY as_of_date, started_at DESC
)
SELECT r.as_of_date, round(sum(r.value_eur) / 1e6, 1) AS pv_eur_m
FROM risk_results r JOIN latest_run lr USING (run_id)
WHERE r.measure = 'PV' AND r.as_of_date BETWEEN '2026-10-05' AND '2026-10-09'
GROUP BY r.as_of_date ORDER BY 1;

\echo '=== T02 - Versioned trades counted several times ================'
WITH latest AS (
    SELECT DISTINCT ON (trade_id) *
    FROM trades ORDER BY trade_id, version DESC
)
SELECT b.book_code,
       (SELECT round(sum(notional)/1e9, 2) FROM trades t WHERE t.book_id = b.book_id)              AS naive_bn,
       round(sum(l.notional) FILTER (WHERE l.status <> 'CANCELLED') / 1e9, 2)                       AS correct_bn,
       count(*) FILTER (WHERE l.status <> 'CANCELLED')                                               AS live_trades
FROM latest l JOIN books b USING (book_id)
GROUP BY b.book_id, b.book_code ORDER BY b.book_id;

-- Same thing with a window function (works in every database)
SELECT count(*) AS live_trades
FROM (SELECT t.*, row_number() OVER (PARTITION BY trade_id ORDER BY version DESC) AS rn FROM trades t) x
WHERE rn = 1 AND status <> 'CANCELLED';

\echo '=== T03 - Trades silently dropped by an INNER JOIN on FX =========='
WITH latest AS (SELECT DISTINCT ON (trade_id) * FROM trades ORDER BY trade_id, version DESC)
SELECT l.trade_date, l.currency, count(*) AS trades_without_fx
FROM latest l
LEFT JOIN fx_rates f ON f.rate_date = l.trade_date AND f.currency = l.currency
WHERE l.status <> 'CANCELLED' AND f.currency IS NULL
GROUP BY 1, 2 ORDER BY 1;

-- Fix: last available fixing on or before the trade date, and FLAG it
WITH latest AS (SELECT DISTINCT ON (trade_id) * FROM trades ORDER BY trade_id, version DESC)
SELECT count(*) AS trades_in_report,
       count(*) FILTER (WHERE fx.rate_date < l.trade_date) AS valued_with_previous_fixing,
       round(sum(l.notional * fx.rate_to_eur) / 1e9, 2) AS notional_eur_bn
FROM latest l
LEFT JOIN LATERAL (
    SELECT f.rate_date, f.rate_to_eur FROM fx_rates f
    WHERE f.currency = l.currency AND f.rate_date <= l.trade_date
    ORDER BY f.rate_date DESC LIMIT 1
) fx ON true
WHERE l.status <> 'CANCELLED';

\echo '=== T04 - Join fan-out through aliases ============================'
SELECT counterparty_id, count(*) AS aliases, string_agg(alias, ', ') AS names
FROM counterparty_aliases GROUP BY counterparty_id HAVING count(*) > 1 ORDER BY 1;

-- Fix: pick ONE alias per counterparty (the one of the reporting source system) before joining
WITH latest AS (SELECT DISTINCT ON (trade_id) * FROM trades ORDER BY trade_id, version DESC),
     murex_name AS (SELECT counterparty_id, alias FROM counterparty_aliases WHERE source_system = 'MUREX')
SELECT count(*) AS rows_, round(sum(l.notional)/1e9, 2) AS notional_bn
FROM latest l JOIN murex_name m USING (counterparty_id)
WHERE l.status <> 'CANCELLED';

\echo '=== T05 - NOT IN with a NULL ======================================'
SELECT * FROM blocked_counterparties WHERE counterparty_id IS NULL;

WITH latest AS (SELECT DISTINCT ON (trade_id) * FROM trades ORDER BY trade_id, version DESC)
SELECT count(*) AS trades_not_blocked, round(sum(notional)/1e9, 2) AS notional_bn
FROM latest l
WHERE l.status <> 'CANCELLED'
  AND NOT EXISTS (SELECT 1 FROM blocked_counterparties bc WHERE bc.counterparty_id = l.counterparty_id);

\echo '=== T06 - Time zones ==============================================='
SELECT count(*) FILTER (WHERE booked_at::date = '2026-10-09')                                AS utc_day,
       count(*) FILTER (WHERE (booked_at AT TIME ZONE b.desk_tz)::date = '2026-10-09')       AS desk_local_day,
       count(*) FILTER (WHERE trade_date = '2026-10-09')                                       AS trade_date_col
FROM trades t JOIN books b USING (book_id)
WHERE b.book_code = 'US_RATES' AND t.version = 1;

-- The "missing" trades: booked on 9 Oct New York time, after 20:00
SELECT trade_id, booked_at AS booked_utc, booked_at AT TIME ZONE 'America/New_York' AS booked_ny
FROM trades t JOIN books b USING (book_id)
WHERE b.book_code = 'US_RATES' AND version = 1
  AND (booked_at AT TIME ZONE b.desk_tz)::date = '2026-10-09' AND booked_at::date <> '2026-10-09'
ORDER BY booked_at LIMIT 5;

\echo '=== T07 - Batch gaps and failure streaks ==========================='
WITH bdays AS (
    SELECT d::date AS d FROM generate_series(date '2026-09-01', date '2026-10-12', interval '1 day') d
    WHERE extract(isodow FROM d) < 6
)
SELECT d AS date_without_valid_risk,
       CASE WHEN EXISTS (SELECT 1 FROM batch_runs r WHERE r.as_of_date = d) THEN 'only failed runs' ELSE 'no run at all' END AS why
FROM bdays
WHERE NOT EXISTS (SELECT 1 FROM batch_runs r WHERE r.as_of_date = d AND r.status = 'SUCCESS')
ORDER BY d;

-- Gaps & islands: streaks of consecutive days whose FIRST attempt failed
WITH first_attempt AS (
    SELECT DISTINCT ON (as_of_date) as_of_date, status
    FROM batch_runs ORDER BY as_of_date, started_at
), numbered AS (
    SELECT as_of_date, status,
           row_number() OVER (ORDER BY as_of_date)
         - row_number() OVER (PARTITION BY status ORDER BY as_of_date) AS grp
    FROM first_attempt
)
SELECT min(as_of_date) AS streak_start, max(as_of_date) AS streak_end, count(*) AS days
FROM numbered WHERE status = 'FAILED'
GROUP BY grp ORDER BY days DESC;

\echo '=== T08 - Hierarchy with a cycle ==================================='
WITH RECURSIVE up AS (
    SELECT counterparty_id AS cp, counterparty_id AS node, parent_id
    FROM counterparties
    UNION ALL
    SELECT up.cp, c.counterparty_id, c.parent_id
    FROM up JOIN counterparties c ON c.counterparty_id = up.parent_id
) CYCLE node SET is_cycle USING path
SELECT cp, path FROM up WHERE is_cycle;

-- Report by ultimate parent, making the broken entities visible instead of hanging
WITH RECURSIVE up AS (
    SELECT counterparty_id AS cp, counterparty_id AS node, parent_id, 0 AS depth
    FROM counterparties
    UNION ALL
    SELECT up.cp, c.counterparty_id, c.parent_id, up.depth + 1
    FROM up JOIN counterparties c ON c.counterparty_id = up.parent_id
    WHERE up.depth < 20                                   -- belt and braces
) CYCLE node SET is_cycle USING path,
ultimate AS (SELECT cp, node AS ultimate_id FROM up WHERE parent_id IS NULL AND NOT is_cycle),
latest AS (SELECT DISTINCT ON (trade_id) * FROM trades ORDER BY trade_id, version DESC)
SELECT coalesce(p.code, '!! BROKEN HIERARCHY') AS ultimate_parent, count(*) AS trades,
       round(sum(l.notional)/1e9, 2) AS notional_bn
FROM latest l
LEFT JOIN ultimate u ON u.cp = l.counterparty_id
LEFT JOIN counterparties p ON p.counterparty_id = u.ultimate_id
WHERE l.status <> 'CANCELLED'
GROUP BY 1 ORDER BY 3 DESC LIMIT 6;

\echo '=== T09 - Floating point money ====================================='
SELECT sum(amount)               AS sum_real,
       sum(amount::float8)       AS sum_float8,
       sum(amount_exact)         AS sum_numeric,
       sum(amount_exact) - sum(amount)::numeric AS difference
FROM cash_flows;

SELECT amount_exact, amount, amount::numeric(18,2) AS real_rounded, amount_exact - amount::numeric(18,2) AS error
FROM cash_flows WHERE amount::numeric(18,2) <> amount_exact
ORDER BY abs(amount_exact - amount::numeric(18,2)) DESC LIMIT 5;

\echo '=== T10 - Slow query ==============================================='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT trade_id, version, isin, notional, booked_at FROM trades
WHERE book_id = 6 AND booked_at::date = '2026-10-09' ORDER BY booked_at;

CREATE INDEX IF NOT EXISTS ix_trades_book_booked ON trades (book_id, booked_at);
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT trade_id, version, isin, notional, booked_at FROM trades
WHERE book_id = 6
  AND booked_at >= timestamp '2026-10-09 00:00' AT TIME ZONE 'America/New_York'
  AND booked_at <  timestamp '2026-10-10 00:00' AT TIME ZONE 'America/New_York'
ORDER BY booked_at;
DROP INDEX ix_trades_book_booked;   -- keep the lab repeatable

\echo '=== T11 - see SOLUTIONS.md (interactive) ==========================='

\echo '=== T12 - Reconciliation vs custody ================================'
WITH ours AS (
    SELECT book_id, isin, sum(quantity) AS qty
    FROM (SELECT DISTINCT ON (trade_id) * FROM trades ORDER BY trade_id, version DESC) l
    WHERE status <> 'CANCELLED' AND trade_date <= '2026-10-09'
    GROUP BY book_id, isin
), custody AS (
    SELECT book_id, isin, quantity AS qty FROM eod_positions WHERE as_of_date = '2026-10-09'
)
SELECT coalesce(o.book_id, c.book_id) AS book_id,
       coalesce(o.isin, c.isin)       AS isin,
       o.qty AS our_qty, c.qty AS custody_qty,
       coalesce(c.qty, 0) - coalesce(o.qty, 0) AS difference,
       CASE WHEN o.isin IS NULL THEN 'MISSING_IN_OUR_BOOKS'
            WHEN c.isin IS NULL THEN 'MISSING_IN_CUSTODY'
            ELSE 'QUANTITY_BREAK' END AS break_type
FROM ours o
FULL OUTER JOIN custody c ON c.book_id = o.book_id AND c.isin = o.isin
WHERE o.qty IS DISTINCT FROM c.qty
ORDER BY break_type, book_id, isin;
