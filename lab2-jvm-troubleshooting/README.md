# Lab 2 — JVM Troubleshooting in Production

**Goal:** diagnose the 5 most common Java production problems using only the tools that ship with the JDK
plus open-source analyzers. No IDE debugger: in production you never have one.
**Time:** 3–4 hours · Based on the Oracle *Java SE Troubleshooting Guide* (diagnostic tools chapter).

## Setup

| Tool | License | Install |
|---|---|---|
| JDK 17 or 21 (Eclipse Temurin) | GPLv2+CE | <https://adoptium.net> — includes `jps`, `jcmd`, `jstack`, `jstat`, `jmap`, `jfr` |
| Eclipse MAT (heap dump analyzer) | EPL 2.0 | <https://eclipse.dev/mat/> |
| JDK Mission Control (JFR viewer) | UPL | <https://adoptium.net/jmc> |
| VisualVM (optional, live view) | GPLv2+CE | <https://visualvm.github.io> |

Each scenario is a single file. JDK 11+ runs it directly (`java File.java`), no build needed.
**Do not read the source code first.** In real support you get symptoms, not code. Open the source only at step "Root cause".

> Tip: when running from a single source file, `jps -l` shows the process as `jdk.compiler/com.sun.tools.javac.launcher.Main`. The app also prints its PID at startup.

## The toolbox (learn these by heart)

```bash
jps -l                                  # list Java processes
jcmd <pid> help                         # everything jcmd can do on this JVM
jcmd <pid> VM.flags / VM.system_properties / VM.uptime
jcmd <pid> Thread.print > td1.txt       # thread dump (same as jstack <pid>)
jcmd <pid> GC.class_histogram | head -20   # what objects fill the heap, live
jcmd <pid> GC.heap_info
jcmd <pid> GC.heap_dump /tmp/app.hprof  # heap dump (pauses the JVM! careful in prod)
jstat -gcutil <pid> 2000                # GC stats every 2s: O = old gen %, FGC = full GC count
jcmd <pid> JFR.start name=rec duration=60s filename=rec.jfr settings=profile
jfr summary rec.jfr ; jfr print --events jdk.ExecutionSample rec.jfr
top -H -p <pid>                         # CPU per THREAD (Linux)
kill -3 <pid>                           # thread dump to the app's stdout (when jcmd can't attach)
```

**Golden rule for hangs and CPU:** take **3 thread dumps, 5–10 seconds apart**. One dump is a photo; three dumps are a movie.
A thread in the same frame in all 3 is stuck (or looping).

---

## Scenario 1 — "Trade booking hangs forever"
```bash
java scenarios/S1_Deadlock.java
```
Symptoms: the service is running, health logs keep printing, but no booking completes.
1. Is the CPU high or low? (`top -p <pid>`) What does this tell you already?
2. Take a thread dump with `jcmd <pid> Thread.print`. Go to the **end** of the output. What does the JVM detect for you?
3. Which threads, which locks, which line of code?
4. Root cause + fix proposal (two options).
5. Why does `[health]` keep printing positions while the system is broken? What would a better health check verify?

## Scenario 2 — "Slower every hour, then OutOfMemoryError"
```bash
mkdir -p dumps
java -Xmx256m -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=./dumps -Xlog:gc:file=gc.log scenarios/S2_MemoryLeak.java
```
The cache is designed for **5,000** instruments (one price per instrument per day).
1. Watch `jstat -gcutil <pid> 2000`. What happens to the `O` column (old gen) after each GC? What would a healthy app look like?
2. Run `jcmd <pid> GC.class_histogram | head -15` twice, one minute apart. Which classes grow?
3. Look at the `[metrics]` log. Which number proves the bug, without any tool?
4. Wait for the OOM (about 2–3 min) or take a dump manually: `jcmd <pid> GC.heap_dump $PWD/dumps/manual.hprof`.
5. Open the `.hprof` in **Eclipse MAT** → *Leak Suspects Report*. Then *Dominator Tree*. What holds most of the memory?
6. Root cause: open the source now. Why does the cache never get a hit? (2 reasons the memory grows)
7. Why does `-XX:+HeapDumpOnOutOfMemoryError` belong in **every** production JVM? What is the risk (disk)?

## Scenario 3 — "One core at 100%, the import never finishes"
```bash
java scenarios/S3_HighCpu.java
```
1. `top` shows the Java process using ~100%. Now find **which thread**: `top -H -p <pid>`. Note the thread ID (TID).
2. Take a thread dump. Find the thread whose `nid` matches your TID.
   - JDK 17/21 prints `nid=1040` (decimal) and also `cpu=7145ms`. JDK 8 prints hex: `printf '0x%x\n' <tid>`.
3. Take 2 more dumps. Is the thread always in the same method? Which line?
4. 4 of 5 bonds imported in 0 ms. What is special about the 5th one? Root cause (hint: `LocalDate.plusMonths` and month-end).
5. Fix proposal. Then: how would you protect the **import job** against any infinite loop? (timeouts, max iterations, `Future.get(timeout)`)

## Scenario 4 — "API is UP, but every request times out"
```bash
java scenarios/S4_PoolExhaustion.java
```
1. The health check says `UP`. Is the service healthy? What does `completed` tell you?
2. Take a thread dump. Group threads by name prefix and state:
   ```bash
   jcmd <pid> Thread.print | awk '/^"/{split($0,a,"\""); n=a[2]; sub(/-[0-9]+$/,"",n)} /java.lang.Thread.State/{print n, $2, $3}' | sort | uniq -c | sort -rn
   ```
3. Where are the 8 `api-worker` threads waiting? Where are the 2 `enrichment` threads?
4. This is a **cascading failure**: one slow dependency took the whole API down. Explain the chain in 3 lines.
5. List 4 fixes (hint: timeouts, bulkheads, circuit breaker, bounded queue). Which libraries do this in Spring? (Resilience4j)
6. Bonus: the request queue (`LinkedBlockingQueue`) is unbounded. What happens to memory if this runs for 1 hour?

## Scenario 5 — "Latency spikes, GC is busy, logs show nothing"
```bash
java -Xmx512m scenarios/S5_AllocationProfiling.java
```
1. Record 30 seconds with JFR:
   `jcmd <pid> JFR.start name=lab duration=30s filename=$PWD/lab.jfr settings=profile`
2. Command-line analysis:
   ```bash
   jfr summary lab.jfr
   jfr print --events jdk.ObjectAllocationSample lab.jfr | grep 'line:' | sed 's/^ *//' | sort | uniq -c | sort -rn | head
   jfr print --events jdk.GarbageCollection lab.jfr | grep -E 'name|duration' | head
   ```
3. Open `lab.jfr` in **JDK Mission Control** → *Memory → Allocations* and *Method Profiling*. Which method in **our** code allocates the most?
4. Root cause: what is computed for every trade even though it is never used? Name 3 allocation problems in that method.
5. JFR overhead is ~1–2%. Why is it acceptable to run it in production, unlike a heap dump?

---

## Final deliverable
For each scenario, write a ticket-style note (5 lines max):
**Symptom → Evidence (tool + output excerpt) → Root cause → Workaround now → Permanent fix.**
That format is exactly what the engineering team expects in an L2 → L3 escalation.

Solutions: `SOLUTIONS.md`.
