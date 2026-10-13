# Lab 3 — Spring Boot Observability: Actuator, Micrometer, Prometheus, Grafana

**Goal:** use the signals a Spring Boot app exposes (health, metrics, logs with trace IDs, runtime log levels)
to detect, locate and explain production problems — without reading the code.
**Time:** 3–4 hours · **Stack (all open source):** Spring Boot 3, Actuator, Micrometer, Micrometer Tracing (Brave), H2, Prometheus, Grafana.

## Setup

```bash
# 1. Start the app (JDK 21 + Maven)
cd position-service
mvn spring-boot:run

# 2. In another terminal: monitoring stack (Docker or Podman)
docker compose up -d
#   Prometheus  http://localhost:9090        (Status → Targets must show the app UP)
#   Grafana     http://localhost:3000        admin/admin → Dashboards → Lab → "Position Service - Production Support"

# 3. In a third terminal: simulated users
./load.sh
```

The app is a small "position valuation" API: `GET /api/books/{book}/summary` loads the positions of a book from the DB,
converts them to EUR and returns the market value. Books: `EUR_RATES FX_SPOT CREDIT_EU EQ_DERIV LATAM_RATES`.

There is also a `/chaos` API to inject problems. **Work in pairs if you can:** one person injects, the other investigates blind.
Alone: inject, then close the terminal and investigate as if you didn't know.

> Install `jq` to make JSON readable: `curl -s localhost:8080/actuator/health | jq`

---

## Part A — Tour of Actuator (30 min)

Answer with the exact `curl` command each time.

1. `GET /actuator` — list the exposed endpoints.
2. `GET /actuator/health` — which components contribute to health? What is `marketData`?
3. `GET /actuator/health/liveness` and `/actuator/health/readiness` — what is the difference, and what does **Kubernetes** do when each one fails?
4. `GET /actuator/info` — what information is there? Why is the build/version info useful in an incident?
5. `GET /actuator/metrics` — how many metrics? Then:
   - `/actuator/metrics/http.server.requests` — what are the available tags?
   - `/actuator/metrics/http.server.requests?tag=status:200&tag=uri:/api/books/{book}/summary`
   - `/actuator/metrics/hikaricp.connections.max` and `.active`
   - `/actuator/metrics/jvm.memory.used?tag=area:heap`
6. `GET /actuator/prometheus | grep positions_summary` — find the custom timer. What does the `book` tag give you that `http.server.requests` doesn't? Why is the `uri` tag a **template** and not the real URL? (hint: cardinality)
7. `GET /actuator/loggers/com.lab.positions` — current level?
8. Look at a log line from a request. Find the **traceId/spanId** in brackets (the exact format depends on the Spring Boot version, e.g. `[<traceId>-<spanId>]`). What is it for?

---

## Part B — Incidents

Before each incident: `curl -s -XPOST localhost:8080/chaos/reset`, check Grafana is "calm" for 1 minute.
For each one, write: **What alerted you → What you checked (with evidence) → Root cause hypothesis → What you'd tell the customer → What you'd escalate.**

### Incident 1 — "Valuation of one book is very slow, and now everything is slow"
Inject (don't look at the values afterwards):
```bash
curl -s -XPOST "localhost:8080/chaos/latency?book=CREDIT_EU&ms=4000"
```
1. In Grafana, which panels change first? Which change after 1–2 minutes?
2. The global p95 is high. Find **which book** is slow, using only metrics (panel 4, or PromQL).
   ```promql
   histogram_quantile(0.95, sum by (le, book) (rate(positions_summary_seconds_bucket[1m])))
   ```
3. Look at the DB pool panel. Why do **other books** start failing too? Read `hikaricp.connections.pending`.
4. Find the errors in the app log. What exception appears, and after how many ms? (link it to `connection-timeout` in `application.yml`)
5. Take a thread dump through HTTP: `curl -s localhost:8080/actuator/threaddump -H 'Accept: text/plain' > td.txt`.
   How many `http-nio` threads are inside `ValuationService.summarize`? How many are waiting for a connection (`HikariPool.getConnection`)?
6. Check Prometheus → Alerts. Which alerts fired, and in what order?
7. Same pattern as Lab 1 and Lab 2 scenario 4. Write the 3-line explanation.

### Incident 2 — "Customers say LATAM valuation fails sometimes"
```bash
curl -s -XPOST "localhost:8080/chaos/errors?book=LATAM_RATES&rate=0.3"
```
1. What's the error rate overall, and for LATAM only? Which metric gives you the per-book failure count?
2. Find an error line in the log. Copy its **traceId**. Find **all** log lines of that request with `grep <traceId>`.
3. The ERROR log says "missing FX rate", but not *why*. **Without restarting**, switch the package to DEBUG:
   ```bash
   curl -s -XPOST localhost:8080/actuator/loggers/com.lab.positions -H 'Content-Type: application/json' -d '{"configuredLevel":"DEBUG"}'
   ```
   What extra detail appears now? Which currency, which provider?
4. **Put it back to INFO** afterwards. Why is leaving DEBUG on in production a problem? (volume, cost, sensitive data)
5. Is this a bug in our app or a data/feed problem? Who would you escalate to?

### Incident 3 — "Kubernetes keeps removing the pod from the load balancer"
```bash
curl -s -XPOST localhost:8080/chaos/feed/down
```
1. Compare `/actuator/health`, `/actuator/health/liveness` and `/actuator/health/readiness`.
2. Readiness is DOWN but liveness is UP. What does Kubernetes do in each case? Why is it **wrong** to put an external dependency in the liveness probe?
3. What does `lagSeconds` show over time? Suggest an alert based on it.
4. `curl -s -XPOST localhost:8080/chaos/feed/up` — how long until readiness recovers?

### Incident 4 — "Memory keeps going up"
Restart the app with a small heap so the effect is visible:
`mvn spring-boot:run -Dspring-boot.run.jvmArguments="-Xmx384m"`
```bash
for i in 1 2 3 4 5 6; do curl -s -XPOST "localhost:8080/chaos/leak?mb=40" > /dev/null; sleep 20; done
```
1. Watch the heap panel. How is it different from the normal saw-tooth?
2. Check `jvm.gc.pause` in Grafana or `/actuator/metrics/jvm.gc.pause`. What happens to GC as heap fills?
3. Get a heap dump over HTTP: `curl -s localhost:8080/actuator/heapdump -o heap.hprof`. Open it in Eclipse MAT (Lab 2). What retains the memory?
4. Which alert fires? At what threshold would you set it in production, and why not 99%?

### Incident 5 — Mixed (ask a colleague to inject, or run this)
```bash
curl -s -XPOST "localhost:8080/chaos/latency?book=EQ_DERIV&ms=1500"
curl -s -XPOST "localhost:8080/chaos/errors?book=FX_SPOT&rate=0.1"
```
Write a full incident summary (impact, timeline, root causes, actions) using **only** Grafana, Prometheus, logs and Actuator.

---

## Part C — Build your own signal (30–45 min)

1. Add a `Counter` `positions.summary.requests` tagged by `book`, and see it in `/actuator/prometheus`.
2. Add a Grafana panel "Requests per book".
3. Add a Prometheus alert: "LATAM failures > 0.1/s for 2 minutes".
4. Add a `HealthIndicator` that reports `DOWN` if fewer than 1,000 positions are loaded.
5. Add `@Timed` support (needs `TimedAspect` bean + `spring-boot-starter-aop`) and time `findByBook`.

## Part D — Security review (you have the cyber background — use it)

The app exposes `env`, `heapdump`, `configprops`, `loggers`, `threaddump` and `/chaos` without authentication.
1. What could an attacker do with each one? (hint: a heap dump contains passwords and tokens in memory; `loggers` POST can flood the disk)
2. Propose a production config: separate management port (`management.server.port`), exposure list, Spring Security on `/actuator/**`, network policy.

---

## Reference

| Signal | Where | Question it answers |
|---|---|---|
| Health / liveness / readiness | `/actuator/health/*` | Is it alive? Can it take traffic? |
| RED metrics (Rate, Errors, Duration) | `http_server_requests_*` | Are users affected? |
| USE metrics (Utilization, Saturation, Errors) | hikaricp, tomcat threads, jvm memory | Which resource is the bottleneck? |
| Logs + traceId | stdout | What exactly happened to *this* request? |
| Thread dump / heap dump | `/actuator/threaddump`, `/actuator/heapdump` | Where are threads stuck? What fills memory? |
| Runtime log level | `/actuator/loggers` | More detail now, without a restart |

Useful PromQL:
```promql
sum by (status) (rate(http_server_requests_seconds_count{uri!~"/actuator.*"}[1m]))
histogram_quantile(0.99, sum by (le) (rate(http_server_requests_seconds_bucket[1m])))
max(hikaricp_connections_pending)
sum(jvm_memory_used_bytes{area="heap"}) / sum(jvm_memory_max_bytes{area="heap"})
```

Solutions: `SOLUTIONS.md`.
