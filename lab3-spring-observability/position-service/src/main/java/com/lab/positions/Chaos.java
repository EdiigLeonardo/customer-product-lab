package com.lab.positions;

import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Holds the "production problems" you can switch on with the /chaos endpoints.
 * In the exercises, pretend this class does not exist: you only see the symptoms.
 */
@Component
public class Chaos {

    /** Extra latency per book, applied while a DB connection is held. */
    final Map<String, Long> latencyMsByBook = new ConcurrentHashMap<>();
    /** Error rate (0..1) per book. */
    final Map<String, Double> errorRateByBook = new ConcurrentHashMap<>();
    /** Market data feed status. */
    volatile boolean marketDataFeedDown = false;
    /** Memory retained "by mistake". */
    final List<byte[]> leaked = new ArrayList<>();

    public synchronized void leakMegabytes(int mb) {
        for (int i = 0; i < mb; i++) leaked.add(new byte[1024 * 1024]);
    }

    public synchronized int leakedMegabytes() {
        return leaked.size();
    }

    public synchronized void reset() {
        latencyMsByBook.clear();
        errorRateByBook.clear();
        marketDataFeedDown = false;
        leaked.clear();
    }

    public Map<String, Object> describe() {
        return Map.of(
                "latencyMsByBook", Map.copyOf(latencyMsByBook),
                "errorRateByBook", Map.copyOf(errorRateByBook),
                "marketDataFeedDown", marketDataFeedDown,
                "leakedMegabytes", leakedMegabytes());
    }
}
