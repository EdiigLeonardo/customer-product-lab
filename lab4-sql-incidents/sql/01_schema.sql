-- =============================================================================
SET client_min_messages = warning;
-- Lab 4 - Risk data warehouse (simplified) - PostgreSQL 16
-- A bank's risk platform: trades are booked by the front office, an end-of-day
-- (EOD) batch values them and stores risk results, reports read from here.
-- =============================================================================
DROP SCHEMA IF EXISTS risk CASCADE;
CREATE SCHEMA risk;
SET search_path = risk;

CREATE TABLE books (
    book_id     int PRIMARY KEY,
    book_code   text NOT NULL UNIQUE,
    desk        text NOT NULL,
    desk_tz     text NOT NULL            -- time zone where the desk books trades
);

CREATE TABLE counterparties (
    counterparty_id int PRIMARY KEY,
    code            text NOT NULL UNIQUE,
    legal_name      text NOT NULL,
    country         char(2) NOT NULL,
    rating          text,
    parent_id       int REFERENCES counterparties(counterparty_id)   -- legal entity hierarchy
);

-- Names used by upstream systems (one counterparty can have several aliases)
CREATE TABLE counterparty_aliases (
    alias            text PRIMARY KEY,
    counterparty_id  int NOT NULL REFERENCES counterparties(counterparty_id),
    source_system    text NOT NULL
);

-- Counterparties under sanctions / credit block (maintained by an admin UI)
CREATE TABLE blocked_counterparties (
    block_id         serial PRIMARY KEY,
    counterparty_id  int,                 -- nullable: the UI does not validate it...
    reason           text NOT NULL,
    blocked_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE instruments (
    isin       char(12) PRIMARY KEY,
    asset_type text NOT NULL,
    currency   char(3) NOT NULL,
    maturity   date
);

-- Trades are versioned: an amendment inserts a new version, a cancellation
-- inserts a new version with status CANCELLED. Previous versions are kept.
CREATE TABLE trades (
    trade_id        bigint NOT NULL,
    version         int    NOT NULL,
    book_id         int    NOT NULL REFERENCES books(book_id),
    counterparty_id int    NOT NULL REFERENCES counterparties(counterparty_id),
    isin            char(12) NOT NULL REFERENCES instruments(isin),
    currency        char(3) NOT NULL,
    quantity        numeric(18,2) NOT NULL,
    price           numeric(18,6) NOT NULL,
    notional        numeric(20,2) NOT NULL,
    trade_date      date   NOT NULL,
    booked_at       timestamptz NOT NULL,
    status          text   NOT NULL CHECK (status IN ('LIVE','AMENDED','CANCELLED')),
    PRIMARY KEY (trade_id, version)
);
CREATE INDEX ix_trades_booked_at ON trades (booked_at);
CREATE INDEX ix_trades_cpty      ON trades (counterparty_id);

-- Daily FX fixings, published on the business days of each currency
CREATE TABLE fx_rates (
    rate_date    date    NOT NULL,
    currency     char(3) NOT NULL,
    rate_to_eur  numeric(18,8) NOT NULL,
    PRIMARY KEY (rate_date, currency)
);

-- One row per execution of a batch job
CREATE TABLE batch_runs (
    run_id       int PRIMARY KEY,
    job_name     text NOT NULL,
    as_of_date   date NOT NULL,
    started_at   timestamptz NOT NULL,
    finished_at  timestamptz,
    status       text NOT NULL CHECK (status IN ('RUNNING','SUCCESS','FAILED'))
);

-- Output of the EOD risk batch
CREATE TABLE risk_results (
    run_id     int  NOT NULL REFERENCES batch_runs(run_id),
    book_id    int  NOT NULL REFERENCES books(book_id),
    as_of_date date NOT NULL,
    measure    text NOT NULL,            -- PV, DELTA, VAR_99
    value_eur  numeric(20,2) NOT NULL,
    PRIMARY KEY (run_id, book_id, measure)
);

-- Position snapshot sent by the custody / back-office system (to reconcile against trades)
CREATE TABLE eod_positions (
    as_of_date date NOT NULL,
    book_id    int  NOT NULL,
    isin       char(12) NOT NULL,
    quantity   numeric(18,2) NOT NULL,
    PRIMARY KEY (as_of_date, book_id, isin)
);

-- Cash flows imported from a legacy system. Note the column type.
CREATE TABLE cash_flows (
    cash_flow_id bigserial PRIMARY KEY,
    trade_id     bigint NOT NULL,
    pay_date     date NOT NULL,
    amount       real NOT NULL,           -- legacy import, "it was always like this"
    amount_exact numeric(18,2) NOT NULL   -- value from the source file, for comparison
);

-- Reporting connections run in UTC (like most servers). New sessions inherit it.
DO $$ BEGIN
  EXECUTE format('ALTER DATABASE %I SET timezone = %L', current_database(), 'UTC');
  EXECUTE format('ALTER DATABASE %I SET search_path = risk, public', current_database());
END $$;
