# Lab 2 — Solutions

## Scenario 1 — Deadlock
1. CPU ~0%. A hang with **low CPU** points to waiting (locks, I/O, pools). A hang with **high CPU** points to loops.
2. At the end of `Thread.print`: `Found one Java-level deadlock`. The JVM detects monitor deadlocks automatically.
3. `booking-worker-A` holds `EUR_RATES` and waits for `FX_SPOT`; `booking-worker-B` holds `FX_SPOT` and waits for `EUR_RATES`. Both are at `S1_Deadlock.transfer(...:21)`, the inner `synchronized (to)`.
4. **Root cause:** inconsistent lock ordering. Two transfers in opposite directions take the same two locks in reverse order.
   **Fixes:** (a) always lock in a global order (e.g., by book name / ID); (b) `ReentrantLock.tryLock(timeout)` with retry; (c) avoid holding a lock during slow calls (the `sleep` = validation call).
   **Workaround now:** restart. Data risk: a transfer is half-applied only if the code updated outside the locks (here it doesn't).
5. The health thread only reads fields, it doesn't need the locks. A good health check exercises the critical path, e.g. "a booking completed in the last N minutes" or a synthetic transaction.

## Scenario 2 — Memory leak
1. `O` climbs after each GC and never comes back down. Healthy pattern: a "saw-tooth" that returns to a stable baseline.
2. `[B` (byte arrays, the `rawFeedMessage`), `HashMap$Node`, `BigDecimal`, `S2_MemoryLeak$Price`, `S2_MemoryLeak$PriceKey`: all growing in sync.
3. `cacheSize` keeps growing past 5,000 (10,000, 20,000…). The design says max 5,000. **The app's own metrics already prove the bug**, so always read them first.
5. MAT Leak Suspects: one instance of `java.util.HashMap`, referenced from the static field `S2_MemoryLeak.PRICE_CACHE`, holds ~95% of the heap.
6. (a) `PriceKey` has no `equals()`/`hashCode()`, so every `new PriceKey(...)` is a different key and there are **zero cache hits**. Fix: make it a `record`, which gets equals/hashCode for free. (b) The cache has **no size limit or eviction**. Use Caffeine with `maximumSize` and `expireAfterWrite`. Also (c) keeping a 2 KB raw message per price multiplies the cost.
7. It captures the evidence at the exact moment of failure, so you don't need to reproduce it. Risk: the dump is the size of the heap (an 8 GB heap gives 8 GB on disk). Point `HeapDumpPath` to a volume with space, and clean up old dumps (Lab 1, A6).

## Scenario 3 — Infinite loop (high CPU)
1–2. `top -H -p <pid>` → one thread `schedule-+` at ~100%. In the dump: `"schedule-import-NN" ... nid=<same TID> ... cpu=<growing>`, state `RUNNABLE`.
3. Always `S3_HighCpu.countCoupons(S3_HighCpu.java:15)`, the `for` loop. Same frame in 3 dumps + RUNNABLE + growing `cpu=` means a loop.
4. Bond `XS2310118893`: issued 31 Aug, matures 31 Aug, 6-month coupons. `2021-08-31 + 6 months = 2022-02-28` (Feb has no 31st), and from then on the day stays 28: `2022-08-28`, `2023-02-28`… it **never equals** `2028-08-31`, so the loop never ends. Month-end date arithmetic is a classic financial bug.
5. Fix: loop with `isBefore`/`!isAfter` instead of `!equals`, and generate dates from the issue date (`issue.plusMonths(k * couponMonths)`) to keep the end-of-month convention. Protection: a max-iterations guard, a timeout per record (`future.get(30, SECONDS)` + cancel), and quarantine of bad records so one record doesn't block the batch.
   *Note:* in older Java versions and other languages, a famous cause of this symptom is **catastrophic regex backtracking** (ReDoS). Same diagnosis: hot thread, stuck in `java.util.regex.Pattern$...`.

## Scenario 4 — Thread pool exhaustion
1. No. `completed=0`: the process is alive, the service is dead. Liveness ≠ readiness.
2. `8 api-worker WAITING (parking)`, `2 enrichment TIMED_WAITING (sleeping)`.
3. `api-worker`: in `FutureTask.get()` called from `handleRequest`, waiting for enrichment with **no timeout**. `enrichment`: in `Thread.sleep` inside `callLegalEntityService` (the slow external call).
4. The external service went from 50 ms to 20 s → the 2 enrichment threads are busy for 20 s each → the 8 API workers wait forever on `get()` → new requests queue up → every client times out. One slow dependency took the whole API down.
5. (a) Timeouts everywhere: HTTP client connect/read timeouts and `get(2, SECONDS)`; (b) bulkhead: a bounded pool and queue per dependency, so it can't starve the others; (c) circuit breaker: fail fast when the dependency is slow; (d) fallback: return the position without LEI enrichment and flag it. In Spring: **Resilience4j** (`@TimeLimiter`, `@Bulkhead`, `@CircuitBreaker`). The health check should include the dependency or a queue-depth indicator (see Lab 3).
6. `newFixedThreadPool` uses an unbounded `LinkedBlockingQueue`. 10 req/s × 3,600 s = 36,000 queued tasks and growing, ending in an OOM. Prefer `new ThreadPoolExecutor(..., new ArrayBlockingQueue<>(100), new CallerRunsPolicy())` or reject with 503.

## Scenario 5 — JFR allocation profiling
3. JMC → Allocations: top frames are `String.format` / `Formatter`, `StringConcatHelper`, called from `S5_AllocationProfiling.auditLine` (line ~27).
4. `auditLine()` runs for **every trade on every aggregation**, even with `AUDIT_ENABLED = false`. Problems: (a) `String.format` is expensive (it parses the pattern with a regex every call); (b) `s += ...` in sequence creates a new String each time; (c) `Double` boxing in the map (`getOrDefault` + `put`). Fix: build the string only `if (AUDIT_ENABLED)` (or use SLF4J `log.debug("...{}", x)` with lazy args), and use `merge(book, notional, Double::sum)` or a `DoubleAdder`.
5. JFR is designed for always-on production use (~1% overhead, sampling, no stop-the-world). A heap dump stops the JVM for seconds (or minutes on big heaps) and writes GBs.
