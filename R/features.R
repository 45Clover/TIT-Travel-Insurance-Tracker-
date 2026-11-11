build_prediction_features <- function(connection, input) {
  required <- c(
    "prediction_id", "as_of", "origin_country_code",
    "destination_country_code", "departure_date", "return_date",
    "age_band", "coverage_plan_id"
  )
  missing <- setdiff(required, names(input))
  if (length(missing) > 0L) {
    stop("Prediction input is missing columns: ", paste(missing, collapse = ", "),
         call. = FALSE)
  }
  if (anyNA(input[, required, drop = FALSE]) ||
      any(!nzchar(as.character(input$prediction_id)))) {
    stop("Prediction input has missing required values.", call. = FALSE)
  }
  if (anyDuplicated(input$prediction_id)) {
    stop("prediction_id values must be unique within the input file.",
         call. = FALSE)
  }

  as_of <- parse_iso_timestamp(input$as_of)
  departure <- as.Date(input$departure_date)
  return_date <- as.Date(input$return_date)
  if (anyNA(as_of) || anyNA(departure) || anyNA(return_date) ||
      any(return_date <= departure)) {
    stop("Use ISO-8601 as_of timestamps and valid departure/return dates.",
         call. = FALSE)
  }

  plans <- DBI::dbGetQuery(
    connection,
    paste(
      "SELECT coverage_plan_id, medical_limit, deductible, cancellation_limit,",
      "baggage_limit, pre_existing_conditions_covered FROM coverage_plans"
    )
  )
  plan_index <- match(input$coverage_plan_id, plans$coverage_plan_id)
  if (anyNA(plan_index)) {
    stop("Every prediction coverage_plan_id must exist in coverage_plans.",
         call. = FALSE)
  }

  event_count <- integer(nrow(input))
  max_severity <- numeric(nrow(input))
  event_categories <- character(nrow(input))
  event_query <- paste(
    "WITH latest AS (",
    "SELECT source_id, external_event_id, country_code, MAX(observed_at) AS observed_at",
    "FROM country_events",
    "WHERE country_code = ? AND observed_at <= ?",
    "GROUP BY source_id, external_event_id, country_code",
    ")",
    ", eligible AS (",
    "SELECT e.event_id, e.category, e.severity",
    "FROM latest l JOIN country_events e",
    "ON e.source_id = l.source_id",
    "AND e.external_event_id = l.external_event_id",
    "AND e.country_code = l.country_code",
    "AND e.observed_at = l.observed_at",
    "WHERE date(e.starts_on) <= date(?)",
    "AND COALESCE(date(e.ends_on), '9999-12-31') >= date(?, '-90 days')",
    ")",
    "SELECT COUNT(*) AS event_count,",
    "COALESCE(MAX(severity), 0) AS max_severity,",
    "COALESCE((SELECT group_concat(category, '|') FROM",
    "(SELECT DISTINCT category FROM eligible ORDER BY category)), '') AS categories",
    "FROM eligible"
  )
  for (i in seq_len(nrow(input))) {
    as_of_text <- format_utc_timestamp(as_of[[i]])
    event <- DBI::dbGetQuery(
      connection,
      event_query,
      params = list(
        input$destination_country_code[[i]],
        as_of_text,
        as_of_text,
        as_of_text
      )
    )
    event_count[[i]] <- event$event_count[[1]]
    max_severity[[i]] <- event$max_severity[[1]]
    event_categories[[i]] <- event$categories[[1]]
  }

  data.frame(
    prediction_id = input$prediction_id,
    trip_days = as.integer(return_date - departure),
    age_band = input$age_band,
    origin_country_code = input$origin_country_code,
    destination_country_code = input$destination_country_code,
    coverage_plan_id = input$coverage_plan_id,
    medical_limit = plans$medical_limit[plan_index],
    deductible = plans$deductible[plan_index],
    cancellation_limit = plans$cancellation_limit[plan_index],
    baggage_limit = plans$baggage_limit[plan_index],
    pre_existing_conditions_covered =
      plans$pre_existing_conditions_covered[plan_index],
    event_count_90d = event_count,
    max_event_severity_90d = max_severity,
    event_categories_90d = event_categories,
    stringsAsFactors = FALSE
  )
}
