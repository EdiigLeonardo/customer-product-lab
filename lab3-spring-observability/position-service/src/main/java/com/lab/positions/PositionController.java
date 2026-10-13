package com.lab.positions;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Map;

@RestController
@RequestMapping("/api")
public class PositionController {

    private static final Logger log = LoggerFactory.getLogger(PositionController.class);
    private final ValuationService valuationService;
    private final PositionRepository repository;

    public PositionController(ValuationService valuationService, PositionRepository repository) {
        this.valuationService = valuationService;
        this.repository = repository;
    }

    @GetMapping("/books")
    public List<String> books() {
        return repository.findAllBooks();
    }

    @GetMapping("/books/{book}/summary")
    public ValuationService.BookSummary summary(@PathVariable String book) {
        return valuationService.summarize(book);
    }

    @ExceptionHandler(IllegalStateException.class)
    public ResponseEntity<Map<String, String>> valuationError(IllegalStateException e) {
        log.error("Valuation failed: {}", e.getMessage());
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(Map.of("error", e.getMessage()));
    }
}
