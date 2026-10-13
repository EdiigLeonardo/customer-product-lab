package com.lab.positions;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.CommandLineRunner;
import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;

@Component
public class DataLoader implements CommandLineRunner {

    private static final Logger log = LoggerFactory.getLogger(DataLoader.class);
    static final String[] BOOKS = {"EUR_RATES", "FX_SPOT", "CREDIT_EU", "EQ_DERIV", "LATAM_RATES"};
    private static final String[] CCY = {"EUR", "EUR", "USD", "GBP", "BRL"};

    private final PositionRepository repository;

    public DataLoader(PositionRepository repository) {
        this.repository = repository;
    }

    @Override
    public void run(String... args) {
        Random r = new Random(42);
        List<Position> batch = new ArrayList<>();
        for (int i = 0; i < 20_000; i++) {
            int b = r.nextInt(BOOKS.length);
            String ccy = BOOKS[b].equals("LATAM_RATES") ? "BRL" : CCY[r.nextInt(4)];
            batch.add(new Position(BOOKS[b], String.format("XS%010d", i), r.nextInt(1_000, 1_000_000),
                    BigDecimal.valueOf(50 + r.nextDouble() * 100).setScale(4, RoundingMode.HALF_UP), ccy));
        }
        repository.saveAll(batch);
        log.info("Loaded {} positions into {} books", batch.size(), BOOKS.length);
    }
}
