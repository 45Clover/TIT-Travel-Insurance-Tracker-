PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS sources (
    source_id TEXT PRIMARY KEY,
    source_name TEXT NOT NULL,
    source_url TEXT,
    license_notes TEXT,
    retrieved_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS coverage_plans (
    coverage_plan_id TEXT PRIMARY KEY,
    plan_name TEXT NOT NULL,
    medical_limit REAL NOT NULL DEFAULT 0 CHECK (medical_limit >= 0),
    deductible REAL NOT NULL DEFAULT 0 CHECK (deductible >= 0),
    cancellation_limit REAL NOT NULL DEFAULT 0 CHECK (cancellation_limit >= 0),
    baggage_limit REAL NOT NULL DEFAULT 0 CHECK (baggage_limit >= 0),
    pre_existing_conditions_covered INTEGER NOT NULL DEFAULT 0
        CHECK (pre_existing_conditions_covered IN (0, 1))
);

CREATE TABLE IF NOT EXISTS trips (
    trip_id TEXT PRIMARY KEY,
    origin_country_code TEXT NOT NULL,
    destination_country_code TEXT NOT NULL,
    departure_date TEXT NOT NULL,
    return_date TEXT NOT NULL,
    travelers_count INTEGER NOT NULL CHECK (travelers_count > 0),
    age_band TEXT NOT NULL DEFAULT 'unknown',
    CHECK (date(departure_date) IS NOT NULL),
    CHECK (date(return_date) IS NOT NULL),
    CHECK (date(return_date) > date(departure_date))
);

CREATE TABLE IF NOT EXISTS quotes (
    quote_id TEXT PRIMARY KEY,
    trip_id TEXT NOT NULL REFERENCES trips(trip_id),
    coverage_plan_id TEXT NOT NULL REFERENCES coverage_plans(coverage_plan_id),
    source_id TEXT NOT NULL REFERENCES sources(source_id),
    quoted_at TEXT NOT NULL,
    premium_amount REAL NOT NULL CHECK (premium_amount > 0),
    currency TEXT NOT NULL CHECK (currency GLOB '[A-Z][A-Z][A-Z]'),
    premium_scope TEXT NOT NULL CHECK (premium_scope IN ('per_traveler', 'party')),
    CHECK (datetime(quoted_at) IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS country_events (
    event_id TEXT PRIMARY KEY,
    source_id TEXT NOT NULL REFERENCES sources(source_id),
    external_event_id TEXT NOT NULL,
    country_code TEXT NOT NULL,
    category TEXT NOT NULL,
    severity REAL NOT NULL CHECK (severity >= 0 AND severity <= 10),
    starts_on TEXT NOT NULL,
    ends_on TEXT,
    observed_at TEXT NOT NULL,
    CHECK (length(external_event_id) > 0),
    CHECK (date(starts_on) IS NOT NULL),
    CHECK (ends_on IS NULL OR date(ends_on) >= date(starts_on)),
    CHECK (datetime(observed_at) IS NOT NULL),
    UNIQUE (source_id, external_event_id, country_code, observed_at)
);

CREATE TABLE IF NOT EXISTS exchange_rates (
    from_currency TEXT NOT NULL CHECK (from_currency GLOB '[A-Z][A-Z][A-Z]'),
    to_currency TEXT NOT NULL CHECK (to_currency GLOB '[A-Z][A-Z][A-Z]'),
    effective_date TEXT NOT NULL,
    rate REAL NOT NULL CHECK (rate > 0),
    source_id TEXT NOT NULL REFERENCES sources(source_id),
    PRIMARY KEY (from_currency, to_currency, effective_date)
);

CREATE TABLE IF NOT EXISTS model_runs (
    model_run_id TEXT PRIMARY KEY,
    trained_at TEXT NOT NULL,
    training_cutoff TEXT NOT NULL,
    target_currency TEXT NOT NULL,
    train_rows INTEGER NOT NULL,
    test_rows INTEGER NOT NULL,
    mae REAL NOT NULL,
    mape REAL NOT NULL,
    baseline_mae REAL NOT NULL,
    baseline_mape REAL NOT NULL,
    error_band_90 REAL NOT NULL,
    model_path TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_quotes_quoted_at ON quotes(quoted_at);
CREATE INDEX IF NOT EXISTS idx_quotes_trip_id ON quotes(trip_id);
CREATE INDEX IF NOT EXISTS idx_events_country_dates
    ON country_events(country_code, starts_on, ends_on, observed_at);
CREATE INDEX IF NOT EXISTS idx_events_source_key_time
    ON country_events(source_id, external_event_id, country_code, observed_at);

CREATE VIEW IF NOT EXISTS quote_training_rows AS
SELECT
    q.quote_id,
    t.trip_id,
    q.quoted_at,
    q.currency,
    CASE
        WHEN q.premium_scope = 'party'
            THEN q.premium_amount / t.travelers_count
        ELSE q.premium_amount
    END AS premium_per_traveler,
    CAST(julianday(t.return_date) - julianday(t.departure_date) AS INTEGER) AS trip_days,
    t.age_band,
    t.origin_country_code,
    t.destination_country_code,
    cp.coverage_plan_id,
    cp.medical_limit,
    cp.deductible,
    cp.cancellation_limit,
    cp.baggage_limit,
    cp.pre_existing_conditions_covered,
    COALESCE((
        SELECT COUNT(*)
        FROM country_events e
        WHERE e.country_code = t.destination_country_code
          AND e.observed_at <= q.quoted_at
          AND date(e.starts_on) <= date(q.quoted_at)
          AND COALESCE(date(e.ends_on), '9999-12-31') >= date(q.quoted_at, '-90 days')
          AND NOT EXISTS (
              SELECT 1
              FROM country_events newer
              WHERE newer.source_id = e.source_id
                AND newer.external_event_id = e.external_event_id
                AND newer.country_code = e.country_code
                AND newer.observed_at <= q.quoted_at
                AND newer.observed_at > e.observed_at
          )
    ), 0) AS event_count_90d,
    COALESCE((
        SELECT MAX(e.severity)
        FROM country_events e
        WHERE e.country_code = t.destination_country_code
          AND e.observed_at <= q.quoted_at
          AND date(e.starts_on) <= date(q.quoted_at)
          AND COALESCE(date(e.ends_on), '9999-12-31') >= date(q.quoted_at, '-90 days')
          AND NOT EXISTS (
              SELECT 1
              FROM country_events newer
              WHERE newer.source_id = e.source_id
                AND newer.external_event_id = e.external_event_id
                AND newer.country_code = e.country_code
                AND newer.observed_at <= q.quoted_at
                AND newer.observed_at > e.observed_at
          )
    ), 0) AS max_event_severity_90d,
    COALESCE((
        SELECT group_concat(category, '|')
        FROM (
            SELECT DISTINCT e.category
            FROM country_events e
            WHERE e.country_code = t.destination_country_code
              AND e.observed_at <= q.quoted_at
              AND date(e.starts_on) <= date(q.quoted_at)
              AND COALESCE(date(e.ends_on), '9999-12-31') >= date(q.quoted_at, '-90 days')
              AND NOT EXISTS (
                  SELECT 1
                  FROM country_events newer
                  WHERE newer.source_id = e.source_id
                    AND newer.external_event_id = e.external_event_id
                    AND newer.country_code = e.country_code
                    AND newer.observed_at <= q.quoted_at
                    AND newer.observed_at > e.observed_at
              )
            ORDER BY e.category
        )
    ), '') AS event_categories_90d
FROM quotes q
JOIN trips t ON t.trip_id = q.trip_id
JOIN coverage_plans cp ON cp.coverage_plan_id = q.coverage_plan_id;
