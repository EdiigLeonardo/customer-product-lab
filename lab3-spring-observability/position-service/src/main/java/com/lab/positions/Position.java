package com.lab.positions;

import jakarta.persistence.*;
import java.math.BigDecimal;

@Entity
@Table(name = "positions", indexes = @Index(name = "ix_positions_book", columnList = "book"))
public class Position {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;
    private String book;
    private String isin;
    private long quantity;
    private BigDecimal price;
    private String currency;

    protected Position() { }

    public Position(String book, String isin, long quantity, BigDecimal price, String currency) {
        this.book = book;
        this.isin = isin;
        this.quantity = quantity;
        this.price = price;
        this.currency = currency;
    }

    public Long getId() { return id; }
    public String getBook() { return book; }
    public String getIsin() { return isin; }
    public long getQuantity() { return quantity; }
    public BigDecimal getPrice() { return price; }
    public String getCurrency() { return currency; }
}
