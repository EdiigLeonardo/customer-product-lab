# Production Support Labs — Java / Spring / Linux / SQL

Four hands-on labs to prepare for a **Technical Customer Success / Application Support** role on a Java
financial-analytics platform. Each lab simulates real incidents: you get **symptoms and tickets**, not instructions.
All tools are **open source**.

| # | Lab | What you practice | Time | Needs |
|---|---|---|---|---|
| 1 | `lab1-linux-logs` | Incident timeline from logs, `grep/awk/sort/uniq`, percentiles, GC log, disk, processes, ports, deleted-but-open files | 2–3 h | Linux/WSL2, Python 3 |
| 2 | `lab2-jvm-troubleshooting` | Deadlock, memory leak, infinite loop, thread-pool starvation, allocation profiling with `jcmd`, `jstack`, `jstat`, JFR, Eclipse MAT, JMC | 3–4 h | JDK 17/21 |
| 3 | `lab3-spring-observability` | Actuator, health/liveness/readiness, Micrometer, Prometheus, Grafana, alerts, trace IDs, runtime log levels, Actuator security | 3–4 h | JDK 21, Maven, Docker |
| 4 | `lab4-sql-incidents` | 12 data tickets: versioned trades, rerun duplicates, join fan-out, `NOT IN` + NULL, time zones, recursive CTE cycles, gaps & islands, float money, `EXPLAIN`, locks, reconciliation | 4–6 h | PostgreSQL 16 (Docker or local) |

Suggested order: **1 → 2 → 3 → 4** (same as the training plan from the team: Linux and Java troubleshooting first,
then Spring monitoring, then SQL).

## How to get the most out of it
- **Don't open `SOLUTIONS.md` until you've written your own answer.**
- Keep a `notes.md` per lab with the **commands you ran and their output**: that is exactly what goes into a real ticket.
- For every incident, practise writing the 5-line summary in English:
  **Impact → Evidence → Root cause → Workaround → Permanent fix / escalation.**
- The same root causes appear across labs on purpose (a slow dependency exhausting a pool shows up in Labs 1, 2 and 3).
  Recognising the pattern quickly is the real skill.

## Tested with
Lab 1: Python 3.13 / GNU coreutils. Lab 2: OpenJDK 21. Lab 4: PostgreSQL 16.
Lab 3 was written for Spring Boot 3.5 but not compiled in the authoring environment. If the parent version
in `pom.xml` isn't available, use the latest 3.x from start.spring.io.
