# Lab 3 — Solutions

## Part A
1. `curl -s localhost:8080/actuator | jq '._links | keys'`
2. `db`, `diskSpace`, `livenessState`, `readinessState`, `ping`, `marketData` (our custom `MarketDataHealthIndicator`; the bean name minus "HealthIndicator").
3. **Liveness** = "is the process stuck beyond recovery?" If it fails, Kubernetes **restarts** the container. **Readiness** = "can I take traffic now?" If it fails, Kubernetes **removes the pod from the Service endpoints** (no traffic) but doesn't restart it.
4. App info, Java version, and build info if you add `build-info` to the Maven plugin. In an incident, the first question is often "what version is running, and what changed?"
5. `curl -s localhost:8080/actuator/metrics | jq '.names | length'`. Tags of `http.server.requests`: `uri`, `method`, `status`, `outcome`, `exception`, `error`.
6. `book` lets you see latency **per business entity**. `uri` uses the template `/api/books/{book}/summary` because one time series per real URL (IDs, dates…) would explode Prometheus memory (**high cardinality**). Only tag with values from a small, known set: 5 books is fine, 50,000 trade IDs is not.
7. `{"configuredLevel":null,"effectiveLevel":"INFO"}` (INFO set in `application.yml`).
8. The trace ID is shared by every log line (and every downstream service call) of one request. `grep <traceId>` reconstructs the full story of one request among thousands.

## Incident 1 — Slow book → pool starvation
1. First: p95/p99 latency and "Valuation p95 by book" (CREDIT_EU ~4 s). Then DB pool `pending > 0`, errors (5xx) rise, Tomcat busy threads rise.
2. `positions_summary` p95 by book → only **CREDIT_EU** at ~4 s at first.
3. CREDIT_EU requests hold a DB connection for 4 s (`@Transactional` around the slow work). ~2 req/s × 4 s ≈ 8 connections needed, but the pool has **5**. Other books queue for a connection, so everyone is slow. One slow book starves the shared pool.
4. `SQLTransientConnectionException: positions-pool - Connection is not available, request timed out after 3000ms` (= `connection-timeout: 3000`).
5. In `td.txt`: ~5 threads `TIMED_WAITING` inside `ValuationService.summarize` → `Thread.sleep` (they hold the connections). Many others are in `HikariPool.getConnection` → `ConcurrentBag.borrow` (waiting).
6. Usually `SlowP95` and `DbPoolStarvation` first, then `HighErrorRate`.
7. One book became slow while holding DB connections → the small shared pool filled up → all other requests waited 3 s and failed. Fixes: find why CREDIT_EU is slow (DB side: locks, plan, data volume); don't hold a connection during non-DB work; timeouts; separate pool or rate limit for heavy books.

## Incident 2 — Intermittent errors
1. Overall ~6% (1 book of 5 × 30%). Per book: `sum by (book) (rate(positions_valuation_failures_total[1m]))`, or `positions_summary_seconds_count{outcome="error"}`.
2. `grep <traceId> app.log` shows the request lines including the ERROR. With DEBUG on, you'd also see "Loaded N positions".
3. DEBUG adds `FX rate lookup failed: provider returned no fixing for ccy=BRL book=LATAM_RATES (stale feed?)`.
4. Reset: `-d '{"configuredLevel":null}'` (or `"INFO"`). DEBUG multiplies log volume (disk, ingestion cost in ELK/Datadog), slows the app, and may log personal or sensitive data.
5. The evidence points to **market data / FX provider data**, not app code. Escalate to the market-data / data team, with the trace IDs, timestamps, the currency and the error rate. Ask engineering for a fallback (use the previous day's fixing and flag it) so one missing rate doesn't fail the whole book.

## Incident 3 — Readiness vs liveness
1. `health` DOWN (aggregate), `liveness` UP, `readiness` DOWN (because `marketData` is in the readiness group).
2. Readiness DOWN → no traffic to this pod, which is correct: it can't value without market data. If the feed check were in **liveness**, Kubernetes would restart **all pods** in a loop because of an external outage. A restart can't fix the feed, and it causes startup storms.
3. `lagSeconds` grows. Alert e.g. "feed lag > 300 s during market hours". To make it a metric, expose it as a Gauge (Part C).
4. Immediately on the next health call.

## Incident 4 — Memory
1. The baseline after each GC goes **up** in steps (+40 MB) instead of returning to the same level.
2. More frequent GCs and longer pauses as free heap shrinks. Near the max: back-to-back GCs (CPU high, latency high), then `OutOfMemoryError`.
3. MAT Dominator Tree: `com.lab.positions.Chaos` → `ArrayList leaked` → `byte[]`.
4. `HeapAlmostFull` (> 85% for 1 min). Alert early enough to act before the OOM: GC thrashing starts well before 99%.

## Part D — Security
- `env` / `configprops`: config values. Spring masks keys like `password`, but custom names may leak.
- `heapdump`: **everything in memory**: DB passwords, tokens, customer data. Critical.
- `loggers` (POST): set DEBUG/TRACE on everything → disk full, sensitive data logged.
- `threaddump`: internal structure, class names, sometimes data in thread names.
- `/chaos`: denial of service by design.

Production config: `management.server.port: 8081` (internal network only); expose only `health,info,prometheus`; protect the rest with Spring Security (role `OPS`) or a NetworkPolicy; `show-details: when_authorized`; remove `/chaos` with a `@Profile("lab")`.
