package com.lab.positions;

import org.springframework.boot.actuate.health.Health;
import org.springframework.boot.actuate.health.HealthIndicator;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.time.Instant;

/**
 * Custom health indicator. The bean name "marketDataHealthIndicator" becomes the
 * health component "marketData" (used in the readiness group in application.yml).
 */
@Component
public class MarketDataHealthIndicator implements HealthIndicator {

    private final Chaos chaos;
    private volatile Instant lastUpdate = Instant.now();

    public MarketDataHealthIndicator(Chaos chaos) {
        this.chaos = chaos;
    }

    @Override
    public Health health() {
        if (!chaos.marketDataFeedDown) {
            lastUpdate = Instant.now();
        }
        long lagSeconds = Duration.between(lastUpdate, Instant.now()).toSeconds();
        Health.Builder builder = chaos.marketDataFeedDown ? Health.down() : Health.up();
        return builder
                .withDetail("feed", "REUTERS-FX")
                .withDetail("lastUpdate", lastUpdate.toString())
                .withDetail("lagSeconds", lagSeconds)
                .build();
    }
}
