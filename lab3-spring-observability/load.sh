#!/usr/bin/env bash
# Simulates users of the risk UI: ~10 requests/second across all books.
# Usage: ./load.sh            (Ctrl+C to stop)
BASE=${BASE:-http://localhost:8080}
BOOKS=(EUR_RATES FX_SPOT CREDIT_EU EQ_DERIV LATAM_RATES)
echo "Generating load on $BASE ... Ctrl+C to stop"
while true; do
  for i in 1 2 3 4 5; do
    book=${BOOKS[$RANDOM % ${#BOOKS[@]}]}
    curl -s -o /dev/null -w "%{http_code} %{time_total}s $book\n" "$BASE/api/books/$book/summary" &
  done
  sleep 0.5
done
