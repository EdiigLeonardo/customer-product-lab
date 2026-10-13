package com.lab.positions;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;

public interface PositionRepository extends JpaRepository<Position, Long> {

    List<Position> findByBook(String book);

    @Query("select distinct p.book from Position p order by p.book")
    List<String> findAllBooks();

    @Query("select count(p) from Position p where p.book = :book")
    long countByBookName(@Param("book") String book);
}
