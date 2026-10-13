package com.lab.positions;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.web.bind.annotation.*;

import java.util.Map;

@RestController
@RequestMapping("/chaos")
public class ChaosController {

    private static final Logger log = LoggerFactory.getLogger(ChaosController.class);
    private final Chaos chaos;

    public ChaosController(Chaos chaos) {
        this.chaos = chaos;
    }

    @GetMapping
    public Map<String, Object> status() {
        return chaos.describe();
    }

    @PostMapping("/latency")
    public Map<String, Object> latency(@RequestParam String book, @RequestParam long ms) {
        chaos.latencyMsByBook.put(book, ms);
        return chaos.describe();
    }

    @PostMapping("/errors")
    public Map<String, Object> errors(@RequestParam String book, @RequestParam double rate) {
        chaos.errorRateByBook.put(book, rate);
        return chaos.describe();
    }

    @PostMapping("/feed/{state}")
    public Map<String, Object> feed(@PathVariable String state) {
        chaos.marketDataFeedDown = "down".equalsIgnoreCase(state);
        return chaos.describe();
    }

    @PostMapping("/leak")
    public Map<String, Object> leak(@RequestParam(defaultValue = "50") int mb) {
        chaos.leakMegabytes(mb);
        return chaos.describe();
    }

    @PostMapping("/reset")
    public Map<String, Object> reset() {
        chaos.reset();
        log.info("Chaos reset");
        return chaos.describe();
    }
}
