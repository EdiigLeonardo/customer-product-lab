-- Final challenge - data-quality monitor (one row per check)
SET search_path = risk;
CREATE OR REPLACE VIEW dq_checks AS
WITH latest AS (SELECT DISTINCT ON (trade_id) * FROM trades ORDER BY trade_id, version DESC),
bdays AS (SELECT d::date AS d FROM generate_series(date '2026-09-01', (SELECT max(as_of_date) FROM batch_runs), interval '1 day') d
          WHERE extract(isodow FROM d) < 6),
checks(check_name, failed_rows) AS (
    SELECT 'duplicate successful EOD runs per date',
           (SELECT count(*) FROM (SELECT as_of_date FROM batch_runs WHERE status = 'SUCCESS'
                                  GROUP BY job_name, as_of_date HAVING count(*) > 1) x)
    UNION ALL
    SELECT 'business days without valid EOD risk',
           (SELECT count(*) FROM bdays WHERE NOT EXISTS
               (SELECT 1 FROM batch_runs r WHERE r.as_of_date = bdays.d AND r.status = 'SUCCESS'))
    UNION ALL
    SELECT 'live trades without FX fixing on trade date',
           (SELECT count(*) FROM latest l WHERE l.status <> 'CANCELLED' AND NOT EXISTS
               (SELECT 1 FROM fx_rates f WHERE f.rate_date = l.trade_date AND f.currency = l.currency))
    UNION ALL
    SELECT 'counterparties with more than one alias (join fan-out risk)',
           (SELECT count(*) FROM (SELECT counterparty_id FROM counterparty_aliases
                                  GROUP BY counterparty_id HAVING count(*) > 1) x)
    UNION ALL
    SELECT 'NULL counterparty in blocked list',
           (SELECT count(*) FROM blocked_counterparties WHERE counterparty_id IS NULL)
    UNION ALL
    SELECT 'counterparties in a hierarchy cycle',
           (WITH RECURSIVE up AS (
                SELECT counterparty_id AS cp, counterparty_id AS node, parent_id FROM counterparties
                UNION ALL
                SELECT up.cp, c.counterparty_id, c.parent_id FROM up
                JOIN counterparties c ON c.counterparty_id = up.parent_id
            ) CYCLE node SET is_cycle USING path
            SELECT count(DISTINCT cp) FROM up WHERE is_cycle)
    UNION ALL
    SELECT 'runs FAILED/RUNNING without finished_at',
           (SELECT count(*) FROM batch_runs WHERE finished_at IS NULL)
)
SELECT check_name, failed_rows, CASE WHEN failed_rows = 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM checks;

SELECT * FROM dq_checks;
