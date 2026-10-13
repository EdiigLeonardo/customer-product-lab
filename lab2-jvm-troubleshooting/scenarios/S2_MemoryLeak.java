import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;

/**
 * Scenario 2 - "The app gets slower every hour and dies with OutOfMemoryError"
 * A price cache that is supposed to hold ~5,000 entries.
 * Run:  java -Xmx256m -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=./dumps -Xlog:gc:file=gc.log S2_MemoryLeak.java
 */
public class S2_MemoryLeak {

    // "Key" for an instrument price on a given date
    static final class PriceKey {
        final String isin;
        final LocalDate date;
        PriceKey(String isin, LocalDate date) { this.isin = isin; this.date = date; }
        // NOTE: no equals()/hashCode() ... "it works in the unit tests"
    }

    static final class Price {
        final BigDecimal value;
        final byte[] rawFeedMessage = new byte[2048];   // original message kept "for audit"
        Price(BigDecimal value) { this.value = value; }
    }

    static final Map<PriceKey, Price> PRICE_CACHE = new HashMap<>();

    static Price getPrice(String isin, LocalDate date) {
        PriceKey key = new PriceKey(isin, date);
        return PRICE_CACHE.computeIfAbsent(key, k -> new Price(BigDecimal.valueOf(Math.random() * 100)));
    }

    public static void main(String[] args) throws Exception {
        System.out.println("PID " + ProcessHandle.current().pid() + " - pricing service started");
        String[] isins = new String[5000];
        for (int i = 0; i < isins.length; i++) isins[i] = String.format("PT%010d", i);
        LocalDate today = LocalDate.of(2026, 10, 12);
        Random rnd = new Random(1);
        long requests = 0;
        while (true) {
            getPrice(isins[rnd.nextInt(isins.length)], today);   // same 5,000 instruments, same day
            Thread.sleep(1);                                      // ~1,000 price requests per second
            if (++requests % 10_000 == 0) {
                System.out.printf("[metrics] requests=%,d cacheSize=%,d usedHeapMB=%d%n", requests, PRICE_CACHE.size(),
                        (Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory()) / 1024 / 1024);
            }
        }
    }
}
