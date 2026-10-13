#!/usr/bin/env python3
"""
Lab 1 - Generates a realistic "production server" snapshot to investigate.

Creates (inside ./server):
  var/log/risk-engine/risk-engine.log        current application log (Spring Boot style)
  var/log/risk-engine/risk-engine.log.1.gz   yesterday's rotated log
  var/log/nginx/access.log                   reverse-proxy access log with latency
  var/log/risk-engine/gc.log                 JVM GC log (unified logging format)
  opt/risk-engine/dumps/...                  forgotten heap dumps eating disk
  opt/risk-engine/config/application.yml     config with a subtle problem

Deterministic: same seed -> same data -> answers in SOLUTIONS.md stay valid.
Usage: python3 generate_logs.py
"""
import gzip
import os
import random
from datetime import datetime, timedelta

random.seed(42)
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "server")
APP_DIR = os.path.join(ROOT, "var/log/risk-engine")
NGINX_DIR = os.path.join(ROOT, "var/log/nginx")
DUMP_DIR = os.path.join(ROOT, "opt/risk-engine/dumps")
CONF_DIR = os.path.join(ROOT, "opt/risk-engine/config")
for d in (APP_DIR, NGINX_DIR, DUMP_DIR, CONF_DIR):
    os.makedirs(d, exist_ok=True)

DAY = datetime(2026, 10, 12, 0, 0, 0)
USERS = ["j.martin", "a.dubois", "k.tanaka", "m.rossi", "s.oliveira", "batch-svc", "p.schmidt"]
CUBES = ["MarketRiskCube", "PnLCube", "FRTB_SA_Cube", "LiquidityCube"]
CLIENT_IPS = ["10.20.1.11", "10.20.1.12", "10.20.1.15", "10.20.2.40", "10.20.2.41", "10.20.3.7"]
NOISY_IP = "10.20.9.99"  # the misbehaving dashboard
THREADS = ["http-nio-8080-exec-%d" % i for i in range(1, 21)]


def trace():
    return "%032x" % random.getrandbits(128)


def fmt(ts):
    return ts.strftime("%Y-%m-%d %H:%M:%S.") + "%03d" % (ts.microsecond // 1000)


def app_line(ts, level, thread, logger, msg, tid=None):
    tid = tid or trace()
    return f"{fmt(ts)} {level:<5} [risk-engine,{tid[:16]}] 4711 --- [{thread}] {logger:<40} : {msg}\n"


def normal_events(ts):
    """Background INFO/DEBUG noise."""
    r = random.random()
    u, c, t = random.choice(USERS), random.choice(CUBES), random.choice(THREADS)
    if r < 0.55:
        ms = int(random.gauss(180, 60)) if random.random() > 0.03 else random.randint(2000, 6000)
        ms = max(ms, 12)
        return app_line(ts, "INFO", t, "c.f.risk.query.QueryService",
                        f"Query executed cube={c} user={u} durationMs={ms} rows={random.randint(10, 50000)}")
    if r < 0.75:
        return app_line(ts, "INFO", t, "c.f.risk.api.CubeController",
                        f"GET /api/v1/cubes/{c}/query user={u} status=200")
    if r < 0.85:
        return app_line(ts, "DEBUG", t, "c.f.risk.cache.AggregateCache",
                        f"Cache hit ratio={random.uniform(0.80, 0.97):.2f} cube={c}")
    if r < 0.93:
        return app_line(ts, "WARN", t, "c.f.risk.query.QueryService",
                        f"Query close to timeout cube={c} user={u} durationMs={random.randint(8000, 9500)}")
    return app_line(ts, "INFO", "scheduling-1", "c.f.risk.load.MarketDataLoader",
                    f"Loaded {random.randint(1000, 9000)} fx rates from feed=REUTERS")


STACK_HIKARI = [
    "org.springframework.jdbc.CannotGetJdbcConnectionException: Failed to obtain JDBC Connection",
    "\tat org.springframework.jdbc.datasource.DataSourceUtils.getConnection(DataSourceUtils.java:84)",
    "\tat c.f.risk.repo.TradeRepository.findByBook(TradeRepository.java:57)",
    "\tat c.f.risk.query.QueryService.execute(QueryService.java:132)",
    "Caused by: java.sql.SQLTransientConnectionException: HikariPool-1 - Connection is not available, request timed out after 30000ms (total=10, active=10, idle=0, waiting=37)",
    "\tat com.zaxxer.hikari.pool.HikariPool.createTimeoutException(HikariPool.java:696)",
    "\t... 41 common frames omitted",
]
STACK_OOM = [
    "java.lang.OutOfMemoryError: Java heap space",
    "\tat java.base/java.util.Arrays.copyOf(Arrays.java:3512)",
    "\tat java.base/java.util.ArrayList.grow(ArrayList.java:237)",
    "\tat c.f.risk.export.CsvExportService.exportAll(CsvExportService.java:88)",
    "\tat c.f.risk.api.ExportController.export(ExportController.java:41)",
]
STACK_NPE = [
    "java.lang.NullPointerException: Cannot invoke \"java.math.BigDecimal.multiply(java.math.BigDecimal)\" because \"rate\" is null",
    "\tat c.f.risk.fx.FxConverter.toEur(FxConverter.java:64)",
    "\tat c.f.risk.pnl.PnLAggregator.aggregate(PnLAggregator.java:119)",
]


def build_app_log(day, incident=True):
    lines = []
    export_logged = False
    ts = day + timedelta(hours=6)
    lines.append(app_line(ts, "INFO", "main", "c.f.risk.RiskEngineApplication",
                          "Started RiskEngineApplication in 41.233 seconds (process running for 43.1)"))
    end = day + timedelta(hours=20)
    while ts < end:
        ts += timedelta(milliseconds=random.randint(150, 2600))
        h_m = ts.hour * 60 + ts.minute

        # Every day: the NPE when the EUR/BRL rate is missing (recurring, low volume)
        if random.random() < 0.0004:
            tid = trace()
            lines.append(app_line(ts, "ERROR", random.choice(THREADS), "c.f.risk.pnl.PnLAggregator",
                                  "Aggregation failed for book=LATAM_RATES ccy=BRL", tid))
            lines += [s + "\n" for s in STACK_NPE]
            continue

        if incident and 14 * 60 + 3 <= h_m < 14 * 60 + 37:
            # Incident window: connection pool exhaustion, triggered by export job
            if not export_logged:
                export_logged = True
                lines.append(app_line(ts, "INFO", "http-nio-8080-exec-7", "c.f.risk.export.CsvExportService",
                                      "Export started cube=PnLCube scope=ALL_BOOKS requestedBy=m.rossi"))
            if random.random() < 0.45:
                lines.append(app_line(ts, "ERROR", random.choice(THREADS), "o.a.c.c.C.[.[.[/].[dispatcherServlet]",
                                      "Servlet.service() for servlet [dispatcherServlet] threw exception"))
                lines += [s + "\n" for s in STACK_HIKARI]
                continue
            if random.random() < 0.3:
                lines.append(app_line(ts, "WARN", "HikariPool-1 housekeeper", "com.zaxxer.hikari.pool.HikariPool",
                                      "HikariPool-1 - Thread starvation or clock leap detected (housekeeper delta=1m2s)."))
                continue
        if incident and h_m == 14 * 60 + 37 and not any("OutOfMemoryError" in l for l in lines[-200:]):
            lines.append(app_line(ts, "ERROR", "http-nio-8080-exec-7", "c.f.risk.export.CsvExportService",
                                  "Export failed cube=PnLCube"))
            lines += [s + "\n" for s in STACK_OOM]
            lines.append(app_line(ts + timedelta(seconds=3), "WARN", "main", "c.f.risk.RiskEngineApplication",
                                  "Received SIGTERM, shutting down gracefully"))
            ts += timedelta(minutes=1, seconds=12)
            lines.append(app_line(ts, "INFO", "main", "c.f.risk.RiskEngineApplication",
                                  "Started RiskEngineApplication in 39.870 seconds (process running for 41.6)"))
            continue
        lines.append(normal_events(ts))
    return lines


def build_access_log(day, incident=True):
    out = []
    ts = day + timedelta(hours=6)
    end = day + timedelta(hours=20)
    while ts < end:
        ts += timedelta(milliseconds=random.randint(80, 1500))
        h_m = ts.hour * 60 + ts.minute
        in_incident = incident and 14 * 60 + 3 <= h_m < 14 * 60 + 38
        ip = random.choice(CLIENT_IPS)
        # Noisy dashboard polling aggressively from 13:50 onwards
        if 13 * 60 + 50 <= h_m < 15 * 60 and random.random() < 0.5:
            ip = NOISY_IP
        cube = random.choice(CUBES)
        path = random.choice([f"/api/v1/cubes/{cube}/query", f"/api/v1/cubes/{cube}/query",
                              "/api/v1/books", "/actuator/health", f"/api/v1/cubes/{cube}/members"])
        method = "POST" if "query" in path else "GET"
        status, rt = 200, max(random.gauss(0.22, 0.08), 0.004)
        if in_incident:
            status = random.choices([200, 500, 503, 504], [0.35, 0.3, 0.15, 0.2])[0]
            rt = random.uniform(5, 30.0) if status != 200 else random.uniform(1, 9)
        elif ip == NOISY_IP and random.random() < 0.4:
            status, rt = 429, 0.002
        elif random.random() < 0.01:
            status = 404
        if path == "/actuator/health" and in_incident:
            status, rt = 503, random.uniform(0.5, 2)
        size = random.randint(300, 90000) if status == 200 else random.randint(80, 400)
        ua = "Grafana/11.2" if ip == NOISY_IP else random.choice(["Mozilla/5.0", "python-requests/2.32", "Atoti-UI/6.1"])
        out.append(f'{ip} - - [{ts.strftime("%d/%b/%Y:%H:%M:%S")} +0000] "{method} {path} HTTP/1.1" '
                   f'{status} {size} "-" "{ua}" rt={rt:.3f}\n')
    return out


def build_gc_log(day):
    out, up = [], 0.0
    heap_max = 8192
    used = 2500
    ts = day + timedelta(hours=6)
    n = 0
    while ts < day + timedelta(hours=14, minutes=37):
        step = random.uniform(5, 40)
        ts += timedelta(seconds=step)
        up += step
        n += 1
        h_m = ts.hour * 60 + ts.minute
        leak = 14 * 60 + 3 <= h_m
        used += random.randint(300, 900) if not leak else random.randint(800, 1500)
        used = min(used, heap_max - 20)
        if used > heap_max * 0.75:
            after = used * (0.35 if not leak else 0.97)
            if leak and after > heap_max * 0.93:
                pause = random.uniform(1800, 4200)
                out.append(f"[{ts.isoformat()}+0000][{up:.3f}s][info][gc] GC({n}) Pause Full (G1 Compaction Pause) "
                           f"{int(used)}M->{int(after)}M({heap_max}M) {pause:.3f}ms\n")
            else:
                pause = random.uniform(8, 60) if not leak else random.uniform(150, 900)
                out.append(f"[{ts.isoformat()}+0000][{up:.3f}s][info][gc] GC({n}) Pause Young (Normal) (G1 Evacuation Pause) "
                           f"{int(used)}M->{int(after)}M({heap_max}M) {pause:.3f}ms\n")
            used = min(after, heap_max - 50)
    return out


# --- write files -----------------------------------------------------------
with open(os.path.join(APP_DIR, "risk-engine.log"), "w") as f:
    f.writelines(build_app_log(DAY, incident=True))
with gzip.open(os.path.join(APP_DIR, "risk-engine.log.1.gz"), "wt") as f:
    f.writelines(build_app_log(DAY - timedelta(days=1), incident=False))
with open(os.path.join(NGINX_DIR, "access.log"), "w") as f:
    f.writelines(build_access_log(DAY))
with open(os.path.join(APP_DIR, "gc.log"), "w") as f:
    f.writelines(build_gc_log(DAY))

# Forgotten heap dumps (sparse-ish files so the lab does not really eat your disk,
# but `du` and `ls -lh` will show the difference - that's part of the exercise)
for name, mb in [("java_pid4711_2026-09-02.hprof", 180), ("java_pid3920_2026-07-15.hprof", 120),
                 ("java_pid4711_2026-10-12.hprof", 240)]:
    p = os.path.join(DUMP_DIR, name)
    with open(p, "wb") as f:
        f.write(os.urandom(1024 * 1024 * 4))   # 4 MB real data
        f.truncate(mb * 1024 * 1024)            # apparent size
old = datetime(2026, 7, 15).timestamp()
os.utime(os.path.join(DUMP_DIR, "java_pid3920_2026-07-15.hprof"), (old, old))

with open(os.path.join(CONF_DIR, "application.yml"), "w") as f:
    f.write("""server:
  port: 8080
spring:
  datasource:
    url: jdbc:postgresql://risk-db.internal:5432/risk
    username: risk_app
    hikari:
      maximum-pool-size: 10
      connection-timeout: 30000
      leak-detection-threshold: 0
risk:
  export:
    # Loads the whole result in memory before writing the CSV
    streaming: false
    max-rows: -1
  query:
    timeout-ms: 10000
logging:
  level:
    root: INFO
    c.f.risk.cache: DEBUG
""")
print("Server snapshot generated in", ROOT)
