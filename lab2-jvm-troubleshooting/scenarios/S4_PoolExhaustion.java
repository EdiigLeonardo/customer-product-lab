import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Scenario 4 - "The API is up, health check is green, but every request times out"
 * Run:  java S4_PoolExhaustion.java
 */
public class S4_PoolExhaustion {

    static final ExecutorService REQUEST_POOL = Executors.newFixedThreadPool(8, named("api-worker"));
    static final ExecutorService ENRICHMENT_POOL = Executors.newFixedThreadPool(2, named("enrichment"));
    static final AtomicLong completed = new AtomicLong();

    // Calls an external "legal entity" service. Its latency went from 50 ms to 20 s this morning.
    static String callLegalEntityService(String id) throws InterruptedException {
        Thread.sleep(20_000);
        return "LEI-" + id;
    }

    static String handleRequest(int id) throws Exception {
        Future<String> lei = ENRICHMENT_POOL.submit(() -> callLegalEntityService(String.valueOf(id)));
        return lei.get();     // no timeout
    }

    public static void main(String[] args) throws Exception {
        System.out.println("PID " + ProcessHandle.current().pid() + " - position API started");
        Executors.newSingleThreadScheduledExecutor(named("health")).scheduleAtFixedRate(() -> {
            System.out.printf("[health] status=UP completed=%d%n", completed.get());
        }, 0, 5, TimeUnit.SECONDS);

        for (int i = 0; ; i++) {          // ~10 requests per second arriving
            final int id = i;
            REQUEST_POOL.submit(() -> { handleRequest(id); completed.incrementAndGet(); return null; });
            Thread.sleep(100);
        }
    }

    static ThreadFactory named(String prefix) {
        AtomicLong n = new AtomicLong();
        return r -> { Thread t = new Thread(r, prefix + "-" + n.incrementAndGet()); t.setDaemon(false); return t; };
    }
}
