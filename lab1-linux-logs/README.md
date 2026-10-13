# Lab 1 — Linux for Production Support: logs, processes, disk

**Goal:** investigate a production incident using only the command line, the way you would on a server you SSH into.
**Time:** 2–3 hours · **Tools:** bash, grep, awk, sed, sort, uniq, less, zgrep, find, du, df, ps, top/htop, lsof, ss (all open source, already on any Linux / WSL2)

```bash
python3 generate_logs.py       # creates ./server with a snapshot of the "risk-engine" host
cd server
```

---

## Part A — The incident ticket

> **INC-48213 · Priority P1 · Opened 12 Oct 2026 14:41 UTC**
> *From: Market Risk desk (bank client)*
> "Between roughly 14:00 and 14:40 the risk dashboards were timing out and then the application went down
> for about a minute. We need the root cause and a timeline before tomorrow's 9:00 risk committee."

You have:

| Path | What it is |
|---|---|
| `var/log/risk-engine/risk-engine.log` | Today's application log (Spring Boot format) |
| `var/log/risk-engine/risk-engine.log.1.gz` | Yesterday's log (rotated, compressed) |
| `var/log/risk-engine/gc.log` | JVM garbage collector log |
| `var/log/nginx/access.log` | Reverse-proxy access log, last field `rt=` is response time in seconds |
| `opt/risk-engine/config/application.yml` | App configuration |
| `opt/risk-engine/dumps/` | Heap dumps |

Answer each question **with the command you used**. Write the commands in a `notes.md` — in the real job, your commands become the ticket's evidence.

### A1. Orientation
1. How many lines does each log have? What time range does the application log cover? (`wc`, `head`, `tail`)
2. How many lines are `ERROR`, `WARN`, `INFO`, `DEBUG`? (one command, with `awk` + `sort` + `uniq -c`)

### A2. Build the timeline
3. In which **minute** did the most ERRORs happen? Show the top 5 minutes. (hint: `cut -c1-16`)
4. Which exception types appear and how many times each? Stack traces start at column 0 — use a regex like `^[a-z.]+\.[A-Z][A-Za-z]+(Exception|Error)`.
5. When was the **first** `Connection is not available` error, and the **last**? (`grep -m1`, `-B`, `tail`)
6. The pool message says `total=10, active=10, idle=0, waiting=37`. Explain in one sentence what it means.
7. Find what happened at **14:03** just before the errors started. Who triggered it? (`grep '14:03:0'`)
8. Find the `OutOfMemoryError`. Show **10 lines of context after** it. What happened next, and how long was the app down?

### A3. Rule out the noise
9. There is a `NullPointerException` in today's log. Is it related to the incident? Compare with **yesterday's** log without decompressing it (`zgrep -c`). What would you do with this finding?
10. Using the access log, which IP received HTTP `429 Too Many Requests`? Which user agent is it? Between what times was it active? Is it the cause or a side effect?

### A4. Quantify the customer impact (access log)
11. Count requests by HTTP status code.
12. Count `5xx` responses **per minute** and find the first and last minute with 5xx.
13. Calculate the **average**, **p95** and **p99** response time of `/query` requests. (`awk` + `sort -n`)
14. Show the 10 slowest requests with time, path and status.

### A5. Correlate with the JVM
15. In `gc.log`, when does the first `Pause Full` appear? How many are there? What's the longest pause?
16. Look at the heap numbers (`before->after(max)`) for Full GCs. What do they tell you?
17. Open `application.yml`. Which **two settings** made this incident possible?

### A6. Housekeeping
18. The disk is 92% full. Find the largest files under `opt/` (`du -ah | sort -h`, `find -size +100M`).
19. Compare `ls -lh` with `du -h` for the dumps. Why are the numbers different?
20. Find heap dumps **older than 30 days** with `find -mtime`. Write (don't run) the command that would delete them.

### A7. Write the summary
Write a 6–8 line incident summary in English, as you would post in the ticket:
**impact, timeline, root cause, contributing factors, immediate action, follow-ups.**

---

## Part B — Live box: "the app won't start and the server is slow"

```bash
./chaos.sh start      # starts 5 misbehaving processes (as your user, safe)
# ... investigate ...
./chaos.sh stop       # always clean up at the end
```

> **INC-48299** "After the restart, risk-engine fails with `Port 8080 already in use`. Also the server feels slow
> and monitoring says disk space didn't come back after someone deleted a big log."

Find, **with evidence**:

1. Which process is using the most CPU? (`top`, `ps -eo pid,pcpu,rss,args --sort=-pcpu`)
2. Which process is using the most memory (RSS)? How much?
3. Who is listening on port 8080? (`ss -ltnp`, or `lsof -i :8080`)
4. One process keeps opening files without closing them. Find it by counting its file descriptors
   (`ls /proc/<pid>/fd | wc -l`, run it twice a few seconds apart). What error would it eventually hit?
5. A 150 MB file was deleted but disk space wasn't freed. Prove it (`lsof +L1`, or `ls -l /proc/<pid>/fd | grep deleted`).
   How do you free the space **without** restarting the process? (hint: truncate through `/proc/<pid>/fd/<n>`)
6. Kill the right processes **in the right order**, using `kill` (SIGTERM) before `kill -9`. Explain the difference.

---

## Cheat sheet (keep it)

```bash
tail -f app.log | grep --line-buffered ERROR        # live follow, filtered
grep -c / -n / -m1 / -A5 -B5 / -E / -v              # count, line numbers, first match, context, regex, invert
zgrep / zcat / zless                                # read .gz without extracting
awk '{print $1}' | sort | uniq -c | sort -rn | head # "top N" pattern — the most useful line in support
awk '$9>=500'                                       # filter by column value
cut -c1-16                                          # truncate timestamps to the minute
sed -n '/14:03:00/,/14:05:00/p' app.log             # print a time window
journalctl -u myapp --since "1 hour ago"            # systemd services
df -h ; du -sh * | sort -h ; find . -size +100M     # disk
ps -eo pid,pcpu,pmem,rss,etime,args --sort=-pcpu    # processes
ss -ltnp ; lsof -i :8080 ; lsof -p <pid> ; lsof +L1 # ports & files
free -h ; uptime ; vmstat 1 5 ; iostat -x 1 5       # memory, load, IO
```

Solutions: `SOLUTIONS.md` (try first!).
