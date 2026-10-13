package com.lab.positions;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;

@Service
public class ValuationService {

    private static final Logger log = LoggerFactory.getLogger(ValuationService.class);

    // Simplified FX table (rates to EUR)
    private static final Map<String, BigDecimal> FX_TO_EUR = Map.of(
            "EUR", BigDecimal.ONE,
            "USD", new BigDecimal("0.92"),
            "GBP", new BigDecimal("1.17"),
            "BRL", new BigDecimal("0.17"));

    private final PositionRepository repository;
    private final Chaos chaos;
    private final MeterRegistry registry;

    public ValuationService(PositionRepository repository, Chaos chaos, MeterRegistry registry) {
        this.repository = repository;
        this.chaos = chaos;
        this.registry = registry;
        // Custom gauge: visible in /actuator/metrics/lab.chaos.leaked.megabytes
        Gauge.builder("lab.chaos.leaked.megabytes", chaos, Chaos::leakedMegabytes)
                .description("Memory retained by the leak injector")
                .register(registry);
    }

    public record BookSummary(String book, long positions, BigDecimal marketValueEur) { }

    @Transactional(readOnly = true)   // holds one DB connection for the whole method
    public BookSummary summarize(String book) {
        Timer.Sample sample = Timer.start(registry);
        String outcome = "success";
        try {
            List<Position> positions = repository.findByBook(book);
            log.debug("Loaded {} positions for book={}", positions.size(), book);

            long extraLatency = chaos.latencyMsByBook.getOrDefault(book, 0L);
            if (extraLatency > 0) {
                sleep(extraLatency);  // e.g. a slow stored procedure / lock wait on the DB side
            }

            BigDecimal total = BigDecimal.ZERO;
            for (Position p : positions) {
                BigDecimal rate = fxRate(book, p.getCurrency());
                total = total.add(p.getPrice().multiply(BigDecimal.valueOf(p.getQuantity())).multiply(rate));
            }
            return new BookSummary(book, positions.size(), total.setScale(2, RoundingMode.HALF_UP));
        } catch (RuntimeException e) {
            outcome = "error";
            Counter.builder("positions.valuation.failures")
                    .tag("book", book)
                    .tag("exception", e.getClass().getSimpleName())
                    .register(registry).increment();
            throw e;
        } finally {
            // Custom timer with a BOUNDED "book" tag (5 values), so we can see latency per book
            sample.stop(Timer.builder("positions.summary")
                    .description("Time to value one book")
                    .tag("book", book)
                    .tag("outcome", outcome)
                    .register(registry));
        }
    }

    private BigDecimal fxRate(String book, String ccy) {
        double errorRate = chaos.errorRateByBook.getOrDefault(book, 0.0);
        if (errorRate > 0 && ThreadLocalRandom.current().nextDouble() < errorRate) {
            log.debug("FX rate lookup failed: provider returned no fixing for ccy={} book={} (stale feed?)", ccy, book);
            throw new IllegalStateException("Cannot value book " + book + ": missing FX rate");
        }
        return FX_TO_EUR.get(ccy);
    }

    private static void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
