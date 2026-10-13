import java.util.concurrent.*;

/**
 * Scenario 1 - "Trade booking hangs forever"
 * Two booking threads transfer positions between books in opposite directions.
 * Run:  java S1_Deadlock.java
 */
public class S1_Deadlock {

    static class Book {
        final String name;
        long position;
        Book(String name, long position) { this.name = name; this.position = position; }
        public String toString() { return name; }
    }

    static void transfer(Book from, Book to, long qty) {
        synchronized (from) {                    // lock 1
            sleep(50);                           // e.g. validation call
            synchronized (to) {                  // lock 2
                from.position -= qty;
                to.position += qty;
            }
        }
    }

    public static void main(String[] args) throws Exception {
        Book rates = new Book("EUR_RATES", 1_000_000);
        Book fx = new Book("FX_SPOT", 500_000);
        System.out.println("PID " + ProcessHandle.current().pid() + " - booking service started");

        ExecutorService pool = Executors.newFixedThreadPool(2, r -> {
            Thread t = new Thread(r);
            t.setName("booking-worker-" + t.threadId());
            return t;
        });
        pool.submit(() -> { while (true) transfer(rates, fx, 100); });
        pool.submit(() -> { while (true) transfer(fx, rates, 50); });

        while (true) {
            sleep(5000);
            System.out.println("[health] positions: " + rates.position + " / " + fx.position);
        }
    }

    static void sleep(long ms) { try { Thread.sleep(ms); } catch (InterruptedException e) { Thread.currentThread().interrupt(); } }
}
