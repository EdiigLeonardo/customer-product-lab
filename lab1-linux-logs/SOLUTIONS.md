# Lab 1 — Solutions

All commands run from `./server`. Set shortcuts first:

```bash
L=var/log/risk-engine/risk-engine.log; A=var/log/nginx/access.log; G=var/log/risk-engine/gc.log
```

## Part A

**1.** `wc -l $L $A $G` → ~41.5k / ~63.7k / ~281 lines. `head -1 $L; tail -1 $L` → 06:00 to 20:00 on 12 Oct.

**2.** `awk '$3 ~ /^(ERROR|WARN|INFO|DEBUG)$/ {print $3}' $L | sort | uniq -c`
→ ERROR ≈ 724, WARN ≈ 3053, INFO ≈ 29k, DEBUG ≈ 3.6k.
Note: `grep -c ERROR` gives a different number — it also matches words inside messages. Filtering on the level **column** is more reliable.

**3.** `grep ' ERROR ' $L | cut -c1-16 | sort | uniq -c | sort -rn | head -5` → all top minutes are between 14:07 and 14:32.

**4.** `grep -E '^[a-z.]+\.[A-Z][A-Za-z]+(Exception|Error)' $L | cut -d: -f1 | sort | uniq -c | sort -rn`
→ `CannotGetJdbcConnectionException` ×708, `NullPointerException` ×15, `OutOfMemoryError` ×1.

**5.** First: `grep -m1 -B5 'Connection is not available' $L | head -1` → **14:03:02**. Last: `grep -B5 'Connection is not available' $L | grep ' ERROR ' | tail -1` → **14:36:56**.

**6.** All 10 connections in the pool are busy, none free, and 37 threads are queued waiting for one. After 30 s (`connection-timeout`) each waiting request fails. The database is probably fine; the **pool** is exhausted.

**7.** `grep '14:03:0' $L | grep -v Query` → `Export started cube=PnLCube scope=ALL_BOOKS requestedBy=m.rossi`. A full export of every book, holding connections and memory.

**8.** `grep -A10 OutOfMemoryError $L` → OOM in `CsvExportService.exportAll` (building the whole export in an `ArrayList`). SIGTERM at 14:37:04, `Started` again at 14:38:13 → **about 70 seconds down** (plus ~40 s startup that was already inside that window).

**9.** `grep -c NullPointerException $L` → 15, `zgrep -c NullPointerException var/log/risk-engine/risk-engine.log.1.gz` → 15. Same rate yesterday, so **not related**. It is a separate, recurring bug (missing BRL FX rate → `FxConverter`). Open a separate low-priority ticket. Don't mix it into the P1, but don't ignore it either.

**10.** `awk '$9==429{print $1}' $A | sort | uniq -c` → only `10.20.9.99`. `grep -m1 10.20.9.99 $A | awk -F'"' '{print $6}'` → `Grafana/11.2`. Active 13:50–14:59 (`awk '$1=="10.20.9.99"{print substr($4,14,5)}' $A | sort -u | sed -n '1p;$p'`). It started **before** the incident and was already rate-limited (429 is cheap). It's a **contributing factor / noise**, not the root cause. Still worth a follow-up: a dashboard refreshing too often.

**11.** `awk '{print $9}' $A | sort | uniq -c | sort -rn`

**12.** `awk '$9>=500{print substr($4,14,5)}' $A | sort | uniq -c` → 5xx from **14:03** to **14:37**.

**13.**
```bash
awk '$7 ~ /query/ {split($NF,a,"="); print a[2]}' $A | sort -n > /tmp/rt
awk '{s+=$1} END{print "avg", s/NR}' /tmp/rt
awk '{v[NR]=$1} END{print "p95", v[int(NR*.95)], "p99", v[int(NR*.99)]}' /tmp/rt
```
→ avg ≈ 0.75 s, p95 ≈ 0.41 s, **p99 ≈ 20 s**. Lesson: the average hides the incident; p99 shows it. Always report percentiles.

**14.** `awk '{split($NF,a,"="); print a[2], $4, $7, $9}' $A | sort -rn | head` → ~30 s requests (timeout) during the incident.

**15.** `grep -m1 'Pause Full' $G` → **14:04:18**. `grep -c 'Pause Full' $G` → ~92. Longest: `awk '/Pause Full/{print $NF}' $G | sort -n | tail -1` → ~4.2 s.

**16.** `8172M->7926M(8192M)`: the heap is full and a Full GC frees almost nothing. Memory is **retained**, not garbage: a leak, or one huge in-memory operation (the export). Every Full GC stops the whole JVM for 3–4 s, so requests pile up and hold DB connections longer, which feeds the pool exhaustion.

**17.** `risk.export.streaming: false` + `max-rows: -1` → an unbounded export loaded fully in memory. Also worth mentioning: `leak-detection-threshold: 0` (disabled, so Hikari never warned which code held connections), and a pool of 10 with no isolation between long exports and interactive queries.

**18.** `du -ah opt | sort -h | tail` / `find opt -type f -size +100M -exec ls -lh {} \;`

**19.** `ls -lh` shows **apparent size** (120–240 MB); `du -h` shows **blocks actually used** (~4 MB each). These are sparse files. On a real server they would be full size. Interviewers like this question.

**20.** `find opt/risk-engine/dumps -name '*.hprof' -mtime +30 -print` → review first. Then: `find opt/risk-engine/dumps -name '*.hprof' -mtime +30 -delete`. Always run with `-print` before `-delete`. And the 12 Oct dump is **evidence**: copy it to the developers before any cleanup.

**A7. Example summary**
> **Impact:** risk dashboards degraded 14:03–14:37 UTC (5xx and 30 s timeouts, p99 = 20 s), full outage ~70 s at 14:37.
> **Root cause:** a full `PnLCube` export (`scope=ALL_BOOKS`, user m.rossi, 14:03) loaded all rows in memory (`streaming=false`, `max-rows=-1`). Heap filled, causing repeated 3–4 s Full GC pauses; requests piled up and exhausted the 10-connection DB pool; the export finally failed with `OutOfMemoryError` and the app restarted at 14:38.
> **Not related:** the recurring BRL `NullPointerException` (same rate the day before), and a Grafana dashboard polling at high rate (already rate-limited).
> **Immediate action:** restore service (done by auto-restart); preserve the 12 Oct heap dump for engineering.
> **Follow-ups:** enable streaming export and a row limit; separate connection pool or rate limit for exports; enable Hikari leak detection; fix the BRL FX NPE; reduce the Grafana refresh rate.

## Part B

1. `ps -eo pid,pcpu,rss,args --sort=-pcpu | head` → `report-worker` at ~100% of one core.
2. `ps -eo pid,rss,args --sort=-rss | head` → `nightly-recon`, ~600 MB RSS.
3. `ss -ltnp | grep 8080` (or `lsof -i :8080`) → `legacy-admin` (a Python `http.server`).
4. `P=$(pgrep -f '^feed-listener'); ls /proc/$P/fd | wc -l; sleep 5; ls /proc/$P/fd | wc -l` → grows by 1/s. It would end with `Too many open files` (`EMFILE`) at the `ulimit -n` limit. Java shows it as `java.io.IOException: Too many open files`.
5. `lsof +L1` or `ls -l /proc/$(pgrep -f '^audit-writer')/fd | grep deleted` → `audit.log (deleted)`, 150 MB. Free it without restart: `: > /proc/<pid>/fd/<n>` (truncate through the open descriptor). Then confirm with `df -h`.
6. `kill <pid>` sends **SIGTERM**: the process can clean up (close connections, flush files, Spring's graceful shutdown). `kill -9` (**SIGKILL**) cannot be caught: no cleanup, possible corrupted state. Use -9 only if SIGTERM doesn't work after a few seconds. Order: confirm with the owner / ticket first, then free port 8080 (legacy-admin), stop the CPU and FD hogs, and finally `./chaos.sh stop`.
