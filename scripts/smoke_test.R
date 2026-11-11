local({
  source("R/db.R")
  source("R/import.R")
  source("R/features.R")
  source("R/model.R")

  test_dir <- tempfile("travel-insurance-smoke-")
  input_dir <- file.path(test_dir, "input")
  dir.create(input_dir, recursive = TRUE)
  on.exit(unlink(test_dir, recursive = TRUE), add = TRUE)

  connection <- connect_tracker_db(file.path(test_dir, "smoke.sqlite"))
  on.exit(DBI::dbDisconnect(connection), add = TRUE)
  initialize_tracker_db(connection)

  row_count <- 50L
  quote_dates <- as.Date("2024-01-01") + seq_len(row_count) - 1L
  trip_days <- 3L + seq_len(row_count) %% 12L
  event_count <- as.integer(quote_dates >= as.Date("2024-01-20")) +
    as.integer(quote_dates >= as.Date("2024-02-05"))
  event_severity <- ifelse(
    quote_dates >= as.Date("2024-02-05"),
    7,
    ifelse(quote_dates >= as.Date("2024-01-20"), 4, 0)
  )
  age_band <- ifelse(seq_len(row_count) %% 2L == 0L, "30-39", "40-49")
  premium_per_traveler <- 80 + trip_days * 1.5 +
    ifelse(age_band == "40-49", 12, 0) +
    event_count * 8 + event_severity

  write.csv(
    data.frame(
      source_id = "demo-source",
      source_name = "Synthetic smoke-test data",
      source_url = NA_character_,
      license_notes = "Synthetic data; not for pricing decisions",
      retrieved_at = "2024-03-01T00:00:00Z"
    ),
    file.path(input_dir, "sources.csv"),
    row.names = FALSE,
    na = ""
  )
  write.csv(
    data.frame(
      coverage_plan_id = "demo-plan",
      plan_name = "Synthetic plan",
      medical_limit = 100000,
      deductible = 100,
      cancellation_limit = 5000,
      baggage_limit = 1000,
      pre_existing_conditions_covered = 0L
    ),
    file.path(input_dir, "coverage_plans.csv"),
    row.names = FALSE
  )
  write.csv(
    data.frame(
      trip_id = sprintf("trip-%03d", seq_len(row_count)),
      origin_country_code = "US",
      destination_country_code = "JP",
      departure_date = as.character(as.Date("2024-04-01") + trip_days),
      return_date = as.character(as.Date("2024-04-01") + trip_days + trip_days),
      travelers_count = 2L,
      age_band = age_band
    ),
    file.path(input_dir, "trips.csv"),
    row.names = FALSE
  )
  write.csv(
    data.frame(
      quote_id = sprintf("quote-%03d", seq_len(row_count)),
      trip_id = sprintf("trip-%03d", seq_len(row_count)),
      coverage_plan_id = "demo-plan",
      source_id = "demo-source",
      quoted_at = paste0(quote_dates, "T12:00:00Z"),
      premium_amount = premium_per_traveler * 2,
      currency = "USD",
      premium_scope = "party"
    ),
    file.path(input_dir, "quotes.csv"),
    row.names = FALSE
  )
  write.csv(
    data.frame(
      event_id = c("event-weather", "event-conflict"),
      source_id = "demo-source",
      external_event_id = c("demo-weather", "demo-conflict"),
      country_code = "JP",
      category = c("weather", "conflict"),
      severity = c(4, 7),
      starts_on = c("2024-01-20", "2024-02-05"),
      ends_on = c("2024-03-01", "2024-02-10"),
      observed_at = c("2024-01-20T00:00:00Z", "2024-02-05T00:00:00Z")
    ),
    file.path(input_dir, "country_events.csv"),
    row.names = FALSE
  )

  import_csv_directory(connection, input_dir)
  quote_count <- DBI::dbGetQuery(
    connection,
    "SELECT COUNT(*) AS n FROM quote_training_rows"
  )$n[[1]]
  if (quote_count != row_count) {
    stop("Smoke test expected 50 imported training rows.", call. = FALSE)
  }

  model_path <- file.path(test_dir, "model.rds")
  artifact <- train_tracker_model(
    DBI::dbGetQuery(connection, "SELECT * FROM quote_training_rows"),
    "USD",
    model_path
  )

  prediction_input <- data.frame(
    prediction_id = "smoke-prediction",
    as_of = "2024-02-15T12:00:00Z",
    origin_country_code = "US",
    destination_country_code = "JP",
    departure_date = "2024-04-15",
    return_date = "2024-04-22",
    age_band = "30-39",
    coverage_plan_id = "demo-plan",
    stringsAsFactors = FALSE
  )
  features <- build_prediction_features(connection, prediction_input)
  if (features$event_count_90d[[1]] != 2L) {
    stop("Smoke test did not retrieve both eligible event records.",
         call. = FALSE)
  }
  prediction <- predict_tracker_model(artifact, features)
  if (!is.finite(prediction$estimated_premium_per_traveler[[1]]) ||
      prediction$estimated_premium_per_traveler[[1]] <= 0) {
    stop("Smoke test produced an invalid prediction.", call. = FALSE)
  }

  message(
    "Smoke test passed: database, import, temporal model evaluation, and prediction. ",
    "Synthetic estimate: ",
    round(prediction$estimated_premium_per_traveler[[1]], 2), " USD per traveler."
  )
})
