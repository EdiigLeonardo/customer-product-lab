-- =============================================================================
-- Lab 4 - Data generation (deterministic: same seed = same answers)
-- Takes ~10-20 seconds.
-- =============================================================================
SET search_path = risk;
SELECT setseed(0.42);

-- ---------------------------------------------------------------- books
INSERT INTO books VALUES
 (1, 'EUR_RATES',   'Rates Lisbon',  'Europe/Lisbon'),
 (2, 'FX_SPOT',     'FX London',     'Europe/London'),
 (3, 'CREDIT_EU',   'Credit Paris',  'Europe/Paris'),
 (4, 'EQ_DERIV',    'Equity Paris',  'Europe/Paris'),
 (5, 'LATAM_RATES', 'LatAm Rates',   'America/Sao_Paulo'),
 (6, 'US_RATES',    'Rates New York','America/New_York');

-- ---------------------------------------------------------------- counterparties (with hierarchy)
INSERT INTO counterparties (counterparty_id, code, legal_name, country, rating, parent_id) VALUES
 (1,  'ATLANTIC-GRP',  'Atlantic Financial Group SA', 'PT', 'A',   NULL),
 (10, 'NORDIC-FIN',    'Nordic Finance Holding AB',   'SE', 'AA-', NULL),
 (20, 'IBERIA-HOLD',   'Iberia Holding SL',           'ES', 'BBB+',NULL),
 (39, 'HOLDCO-NL',     'Holdco Netherlands BV',       'NL', 'BBB', NULL);   -- parent fixed below

INSERT INTO counterparties (counterparty_id, code, legal_name, country, rating, parent_id)
SELECT id,
       CASE WHEN id BETWEEN 2 AND 9   THEN 'ATLANTIC-' || id
            WHEN id BETWEEN 11 AND 19 THEN 'NORDIC-'   || id
            WHEN id BETWEEN 21 AND 29 THEN 'IBERIA-'   || id
            ELSE 'CPTY-' || id END,
       'Legal entity ' || id,
       (ARRAY['PT','ES','FR','DE','SE','GB','US','BR'])[1 + (id % 8)],
       (ARRAY['AA','A+','A','A-','BBB+','BBB','BB'])[1 + (id % 7)],
       CASE WHEN id IN (5, 6)          THEN 2      -- grandchildren of ATLANTIC-GRP
            WHEN id BETWEEN 2 AND 9    THEN 1
            WHEN id BETWEEN 11 AND 19  THEN 10
            WHEN id BETWEEN 21 AND 29  THEN 20
            ELSE NULL END
FROM generate_series(2, 37) id
WHERE id NOT IN (10, 20);

INSERT INTO counterparties (counterparty_id, code, legal_name, country, rating, parent_id) VALUES
 (38, 'HOLDCO-LUX',    'Holdco Luxembourg SARL', 'LU', 'BBB', 39),
 (40, 'ORION-TRADING', 'Orion Trading Ltd',      'GB', 'BB+', 38);
-- Data quality incident from a bad hierarchy import: HOLDCO-NL now points back to HOLDCO-LUX (a cycle)
UPDATE counterparties SET parent_id = 38 WHERE counterparty_id = 39;

INSERT INTO counterparty_aliases (alias, counterparty_id, source_system)
SELECT 'MX_' || code, counterparty_id, 'MUREX' FROM counterparties;
INSERT INTO counterparty_aliases (alias, counterparty_id, source_system)
SELECT 'CAL_' || code, counterparty_id, 'CALYPSO' FROM counterparties WHERE counterparty_id IN (3, 12, 22, 31, 40);

INSERT INTO blocked_counterparties (counterparty_id, reason, blocked_at) VALUES
 (33,   'Sanctions screening hit',          '2026-09-10 09:12:00+00'),
 (35,   'Credit limit breach - frozen',     '2026-09-18 14:40:00+00'),
 (NULL, 'test entry - please ignore',       '2026-10-05 17:03:00+00');

-- ---------------------------------------------------------------- instruments (80 per currency)
INSERT INTO instruments (isin, asset_type, currency, maturity)
SELECT c.prefix || lpad((c.n * 1000 + g)::text, 10, '0'),
       (ARRAY['BOND','BOND','SWAP','FUTURE','OPTION'])[1 + (g % 5)],
       c.ccy,
       date '2027-01-01' + (g * 37 % 3650)
FROM (VALUES ('EUR','XS',1), ('USD','US',2), ('GBP','GB',3), ('BRL','BR',4), ('JPY','JP',5)) AS c(ccy, prefix, n),
     generate_series(1, 80) g;

-- ---------------------------------------------------------------- FX fixings (business days per currency)
WITH days AS (
    SELECT d::date AS d FROM generate_series(date '2026-08-31', date '2026-10-12', interval '1 day') d
    WHERE extract(isodow FROM d) < 6
), base(ccy, r0) AS (VALUES ('EUR', 1.0), ('USD', 0.92), ('GBP', 1.17), ('BRL', 0.168), ('JPY', 0.0061))
INSERT INTO fx_rates (rate_date, currency, rate_to_eur)
SELECT d, ccy,
       CASE WHEN ccy = 'EUR' THEN 1
            ELSE round((r0 * (1 + (random() - 0.5) * 0.02))::numeric, 8) END
FROM days CROSS JOIN base
WHERE NOT (ccy = 'BRL' AND d = date '2026-10-12')                          -- Brazil holiday: no BRL fixing
  AND NOT (ccy = 'JPY' AND d IN (date '2026-09-21', date '2026-09-23'));   -- Japan holidays: no JPY fixing

-- ---------------------------------------------------------------- trades
-- 120,000 trades (version 1), booked on business days from 1 Sep to 12 Oct 2026
CREATE TEMP TABLE tmp_days AS
SELECT row_number() OVER (ORDER BY d) AS n, d::date AS d
FROM generate_series(date '2026-09-01', date '2026-10-12', interval '1 day') d
WHERE extract(isodow FROM d) < 6;

CREATE TEMP TABLE tmp_trades AS
SELECT t AS trade_id,
       1 + floor(random() * 6)::int                        AS book_id,
       1 + floor(random() * 40)::int                       AS counterparty_id,
       1 + floor(random() * 30)::int                       AS day_n,   -- 30 business days in tmp_days
       random()                                            AS r_isin,
       random()                                            AS r_time,
       round((1000 + random() * 999000)::numeric, 0)       AS quantity,
       round((50 + random() * 100)::numeric, 6)            AS price
FROM generate_series(1, 120000) t;

-- counterparty ids 10 and 20 are holdings without trading activity: remap
UPDATE tmp_trades SET counterparty_id = counterparty_id + 1 WHERE counterparty_id IN (10, 20);
ALTER TABLE tmp_trades ADD COLUMN trade_date date;
UPDATE tmp_trades t SET trade_date = d.d FROM tmp_days d WHERE d.n = t.day_n;

INSERT INTO trades (trade_id, version, book_id, counterparty_id, isin, currency, quantity, price, notional,
                    trade_date, booked_at, status)
SELECT t.trade_id, 1, t.book_id, t.counterparty_id, i.isin, i.currency, t.quantity, t.price,
       round(t.quantity * t.price, 2), t.trade_date,
       -- booked between 08:00 and 21:30 in the desk's local time, stored as timestamptz (UTC)
       ((t.trade_date + time '08:00' + (t.r_time * interval '13 hours 30 minutes')) AT TIME ZONE b.desk_tz),
       'LIVE'
FROM tmp_trades t
JOIN books b USING (book_id)
JOIN LATERAL (
    SELECT isin, currency FROM instruments
    WHERE currency = CASE b.book_code
                         WHEN 'EUR_RATES'   THEN 'EUR'
                         WHEN 'FX_SPOT'     THEN (ARRAY['USD','GBP','JPY'])[1 + floor(t.r_isin * 3)::int]
                         WHEN 'CREDIT_EU'   THEN (ARRAY['EUR','GBP'])[1 + floor(t.r_isin * 2)::int]
                         WHEN 'EQ_DERIV'    THEN (ARRAY['EUR','USD'])[1 + floor(t.r_isin * 2)::int]
                         WHEN 'LATAM_RATES' THEN 'BRL'
                         ELSE 'USD' END
    ORDER BY isin OFFSET floor(t.r_isin * 80)::int LIMIT 1
) i ON true;

-- Amendments: ~10% of trades get a version 2 with a new quantity
INSERT INTO trades (trade_id, version, book_id, counterparty_id, isin, currency, quantity, price, notional,
                    trade_date, booked_at, status)
SELECT trade_id, 2, book_id, counterparty_id, isin, currency, q, price, round(q * price, 2),
       trade_date, booked_at + interval '2 hours', 'AMENDED'
FROM (SELECT t.*, round(t.quantity * (0.5 + random())::numeric, 0) AS q FROM trades t WHERE version = 1) x
WHERE trade_id % 10 = 3;

-- Cancellations: ~3% of trades get a final CANCELLED version
INSERT INTO trades (trade_id, version, book_id, counterparty_id, isin, currency, quantity, price, notional,
                    trade_date, booked_at, status)
SELECT trade_id, max_v + 1, book_id, counterparty_id, isin, currency, quantity, price, notional,
       trade_date, booked_at + interval '1 day', 'CANCELLED'
FROM (SELECT DISTINCT ON (trade_id) t.*, version AS max_v FROM trades t
      WHERE trade_id % 33 = 7 ORDER BY trade_id, version DESC) x;

ANALYZE trades;

-- ---------------------------------------------------------------- batch runs (EOD_RISK)
CREATE TEMP TABLE tmp_runs (run_id serial, as_of_date date, started_at timestamptz, finished_at timestamptz, status text);
-- normal: one successful run per business day at 20:00 UTC
INSERT INTO tmp_runs (as_of_date, started_at, finished_at, status)
SELECT d, d + time '20:00', d + time '20:00' + interval '47 minutes' + (random() * interval '20 minutes'), 'SUCCESS'
FROM tmp_days
WHERE d NOT IN (date '2026-09-15',                                         -- scheduler outage: no run at all
                date '2026-09-29', date '2026-09-30', date '2026-10-01', date '2026-10-02');
-- failures followed by successful reruns
INSERT INTO tmp_runs (as_of_date, started_at, finished_at, status) VALUES
 ('2026-09-29', '2026-09-29 20:00+00', '2026-09-29 20:12+00', 'FAILED'),
 ('2026-09-29', '2026-09-30 07:30+00', '2026-09-30 08:21+00', 'SUCCESS'),
 ('2026-09-30', '2026-09-30 20:00+00', '2026-09-30 20:09+00', 'FAILED'),
 ('2026-09-30', '2026-10-01 07:45+00', '2026-10-01 08:39+00', 'SUCCESS'),
 ('2026-10-01', '2026-10-01 20:00+00', '2026-10-01 20:15+00', 'FAILED'),
 ('2026-10-01', '2026-10-02 08:10+00', '2026-10-02 09:02+00', 'SUCCESS'),
 ('2026-10-02', '2026-10-02 20:00+00', '2026-10-02 20:11+00', 'FAILED'),
 ('2026-10-02', '2026-10-03 09:00+00', NULL,                  'FAILED');
-- 7 Oct: the batch was rerun after a market data correction; both runs say SUCCESS
INSERT INTO tmp_runs (as_of_date, started_at, finished_at, status) VALUES
 ('2026-10-07', '2026-10-08 06:30+00', '2026-10-08 07:24+00', 'SUCCESS');

INSERT INTO batch_runs (run_id, job_name, as_of_date, started_at, finished_at, status)
SELECT row_number() OVER (ORDER BY started_at) + 1000, 'EOD_RISK', as_of_date, started_at, finished_at, status
FROM tmp_runs;

-- ---------------------------------------------------------------- risk results (only successful runs)
INSERT INTO risk_results (run_id, book_id, as_of_date, measure, value_eur)
SELECT r.run_id, b.book_id, r.as_of_date, m.measure,
       round((m.base * (1 + b.book_id * 0.37) * (1 + (random() - 0.5) * 0.06))::numeric, 2)
FROM batch_runs r
CROSS JOIN books b
CROSS JOIN (VALUES ('PV', 250000000.0), ('DELTA', 1800000.0), ('VAR_99', 4200000.0)) m(measure, base)
WHERE r.status = 'SUCCESS';

-- ---------------------------------------------------------------- EOD positions from custody (as of 9 Oct)
INSERT INTO eod_positions (as_of_date, book_id, isin, quantity)
SELECT date '2026-10-09', book_id, isin, sum(quantity)
FROM (SELECT DISTINCT ON (trade_id) * FROM trades ORDER BY trade_id, version DESC) latest
WHERE status <> 'CANCELLED' AND trade_date <= date '2026-10-09'
GROUP BY book_id, isin;

-- Breaks between custody and our trades:
-- 3 positions missing in custody
DELETE FROM eod_positions WHERE (book_id, isin) IN (
    SELECT book_id, isin FROM eod_positions WHERE book_id = 3 ORDER BY isin LIMIT 2)
   OR (book_id, isin) IN (SELECT book_id, isin FROM eod_positions WHERE book_id = 5 ORDER BY isin DESC LIMIT 1);
-- 2 positions in custody we don't know about
INSERT INTO eod_positions VALUES
 ('2026-10-09', 2, 'GB0000003999', 250000),
 ('2026-10-09', 6, 'US0000002999', 1000000);
-- 4 quantity differences
UPDATE eod_positions SET quantity = quantity + 10000
WHERE (book_id, isin) IN (SELECT book_id, isin FROM eod_positions WHERE book_id = 1 ORDER BY isin LIMIT 3 OFFSET 10);
UPDATE eod_positions SET quantity = quantity - 1
WHERE (book_id, isin) IN (SELECT book_id, isin FROM eod_positions WHERE book_id = 4 ORDER BY isin LIMIT 1 OFFSET 5);

-- ---------------------------------------------------------------- cash flows (legacy float import)
INSERT INTO cash_flows (trade_id, pay_date, amount, amount_exact)
SELECT 1 + (g * 7) % 120000,
       date '2026-10-15' + (g % 60),
       x::real,
       x
FROM (SELECT g, round((random() * 2000000 - 1000000)::numeric, 2) AS x
      FROM generate_series(1, 60000) g) s;

ANALYZE;
SELECT 'trades' AS tbl, count(*) FROM trades
UNION ALL SELECT 'fx_rates', count(*) FROM fx_rates
UNION ALL SELECT 'batch_runs', count(*) FROM batch_runs
UNION ALL SELECT 'risk_results', count(*) FROM risk_results
UNION ALL SELECT 'eod_positions', count(*) FROM eod_positions
UNION ALL SELECT 'cash_flows', count(*) FROM cash_flows;
