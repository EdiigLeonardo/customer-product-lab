import java.time.LocalDate;
import java.util.concurrent.*;

/**
 * Scenario 3 - "One CPU core at 100% and the bond schedule import never finishes"
 * Run:  java S3_HighCpu.java
 */
public class S3_HighCpu {

    record Bond(String isin, LocalDate issue, LocalDate maturity, int couponMonths) {}

    // Counts coupon payment dates between issue and maturity
    static int countCoupons(Bond b) {
        int n = 0;
        for (LocalDate d = b.issue(); !d.equals(b.maturity()); d = d.plusMonths(b.couponMonths())) {
            n++;
        }
        return n;
    }

    public static void main(String[] args) throws Exception {
        System.out.println("PID " + ProcessHandle.current().pid() + " - bond schedule import started");
        ExecutorService importers = Executors.newFixedThreadPool(3, r -> {
            Thread t = new Thread(r);
            t.setName("schedule-import-" + t.threadId());
            return t;
        });
        Bond[] batch = {
            new Bond("PTOTEKOE0011", LocalDate.of(2020, 1, 15), LocalDate.of(2030, 1, 15), 12),
            new Bond("FR0013508470", LocalDate.of(2021, 5, 25), LocalDate.of(2031, 5, 25), 6),
            new Bond("DE0001102580", LocalDate.of(2022, 2, 15), LocalDate.of(2032, 2, 15), 12),
            new Bond("XS2310118893", LocalDate.of(2021, 8, 31), LocalDate.of(2028, 8, 31), 6),  // end-of-month bond
            new Bond("IT0005436693", LocalDate.of(2021, 3, 1), LocalDate.of(2031, 3, 1), 6),
        };
        for (Bond b : batch) {
            importers.submit(() -> {
                long t0 = System.nanoTime();
                int coupons = countCoupons(b);
                System.out.printf("imported %s coupons=%d in %d ms%n", b.isin(), coupons, (System.nanoTime() - t0) / 1_000_000);
            });
        }
        // Heartbeat so the app "looks alive"
        Executors.newSingleThreadScheduledExecutor().scheduleAtFixedRate(
            () -> System.out.println("[heartbeat] import running..."), 0, 10, TimeUnit.SECONDS);
    }
}
