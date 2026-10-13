import java.util.*;

/**
 * Scenario 5 - "Latency spikes every few seconds, GC is busy, nothing obvious in the logs"
 * Use Java Flight Recorder (built into the JDK, open source) to find the allocation hotspot.
 * Run:  java -Xmx512m S5_AllocationProfiling.java
 */
public class S5_AllocationProfiling {

    record Trade(String id, String book, double notional, String ccy) {}

    static List<Trade> loadTrades() {
        List<Trade> trades = new ArrayList<>();
        Random r = new Random(7);
        String[] books = {"EUR_RATES", "FX_SPOT", "CREDIT", "EQ_DERIV"};
        String[] ccys = {"EUR", "USD", "GBP", "BRL", "JPY"};
        for (int i = 0; i < 50_000; i++)
            trades.add(new Trade("T" + i, books[r.nextInt(4)], r.nextDouble() * 1e6, ccys[r.nextInt(5)]));
        return trades;
    }

    // Builds the audit line for each trade - called for every aggregation, even when audit logging is OFF
    static String auditLine(Trade t) {
        String s = "";
        s += "trade=" + t.id();
        s += ";book=" + t.book();
        s += ";notional=" + String.format("%.2f", t.notional());
        s += ";ccy=" + t.ccy();
        return s;
    }

    static final boolean AUDIT_ENABLED = false;

    static Map<String, Double> aggregateByBook(List<Trade> trades) {
        Map<String, Double> totals = new HashMap<>();
        for (Trade t : trades) {
            String audit = auditLine(t);                     // computed even if never used
            if (AUDIT_ENABLED) System.out.println(audit);
            Double boxed = totals.getOrDefault(t.book(), 0.0);
            totals.put(t.book(), boxed + t.notional());
        }
        return totals;
    }

    public static void main(String[] args) throws Exception {
        System.out.println("PID " + ProcessHandle.current().pid() + " - aggregation service started");
        List<Trade> trades = loadTrades();
        for (int run = 1; ; run++) {
            long t0 = System.nanoTime();
            aggregateByBook(trades);
            if (run % 20 == 0)
                System.out.printf("[metrics] run=%d lastAggregationMs=%d%n", run, (System.nanoTime() - t0) / 1_000_000);
        }
    }
}
