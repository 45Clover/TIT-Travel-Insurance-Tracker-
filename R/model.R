event_category_codes <- c(
  "weather", "natural_disaster", "conflict",
  "political_unrest", "public_health", "other"
)

prepare_event_category_features <- function(data) {
  if (!"event_categories_90d" %in% names(data)) {
    stop("Feature data is missing event_categories_90d.", call. = FALSE)
  }
  categories <- as.character(data$event_categories_90d)
  categories[is.na(categories)] <- ""
  parsed <- strsplit(categories, "|", fixed = TRUE)
  parsed <- lapply(parsed, function(values) unique(tolower(trimws(values))))

  known <- event_category_codes[event_category_codes != "other"]
  for (category in event_category_codes) {
    column <- paste0("event_", category, "_90d")
    data[[column]] <- vapply(
      parsed,
      function(values) {
        present <- category %in% values
        if (category == "other") {
          present <- present || any(nzchar(values) & !(values %in% known))
        }
        as.integer(present)
      },
      integer(1)
    )
  }
  data$event_categories_90d <- NULL
  data
}

collapse_training_categories <- function(data, min_count = 5L) {
  categorical <- c(
    "age_band", "origin_country_code",
    "destination_country_code", "coverage_plan_id"
  )
  kept <- list()
  other_supported <- list()

  for (column in categorical) {
    values <- as.character(data[[column]])
    values[is.na(values) | !nzchar(values)] <- "unknown"
    counts <- table(values)
    kept[[column]] <- names(counts[counts >= min_count])
    other_supported[[column]] <- any(!(values %in% kept[[column]]))
    values[!(values %in% kept[[column]])] <- "__OTHER__"
    levels <- kept[[column]]
    if (other_supported[[column]]) {
      levels <- c(levels, "__OTHER__")
    }
    data[[column]] <- factor(values, levels = levels)
  }

  list(data = data, kept = kept, other_supported = other_supported)
}

build_model_formula <- function(data) {
  numeric_terms <- c(
    trip_days = "log1p(trip_days)",
    medical_limit = "log1p(medical_limit)",
    deductible = "log1p(deductible)",
    event_count_90d = "event_count_90d",
    max_event_severity_90d = "max_event_severity_90d"
  )
  event_terms <- paste0("event_", event_category_codes, "_90d")
  names(event_terms) <- event_terms
  numeric_terms <- c(numeric_terms, event_terms)
  numeric_terms <- numeric_terms[vapply(
    names(numeric_terms),
    function(column) length(unique(data[[column]])) > 1L,
    logical(1)
  )]

  categorical <- c(
    "age_band", "origin_country_code",
    "destination_country_code", "coverage_plan_id"
  )
  categorical <- categorical[vapply(
    categorical,
    function(column) length(unique(as.character(data[[column]]))) > 1L,
    logical(1)
  )]
  terms <- c(unname(numeric_terms), categorical)
  if (length(terms) == 0L) {
    stop("Training data has no varying predictors.", call. = FALSE)
  }
  stats::as.formula(
    paste("premium_per_traveler ~", paste(terms, collapse = " + "))
  )
}

apply_model_categories <- function(data, kept, other_supported) {
  categorical <- names(kept)
  for (column in categorical) {
    values <- as.character(data[[column]])
    values[is.na(values) | !nzchar(values)] <- "unknown"
    unsupported <- !(values %in% kept[[column]])
    if (any(unsupported) && !other_supported[[column]]) {
      stop(
        "No pooled training examples for unseen ", column,
        " value(s): ", paste(unique(values[unsupported]), collapse = ", "),
        call. = FALSE
      )
    }
    values[unsupported] <- "__OTHER__"
    levels <- kept[[column]]
    if (other_supported[[column]]) {
      levels <- c(levels, "__OTHER__")
    }
    data[[column]] <- factor(values, levels = levels)
  }
  data
}

train_tracker_model <- function(data, target_currency, model_path) {
  required <- c(
    "trip_id", "quoted_at", "currency", "premium_per_traveler", "trip_days",
    "age_band", "origin_country_code", "destination_country_code",
    "coverage_plan_id", "medical_limit", "deductible",
    "event_count_90d", "max_event_severity_90d",
    "event_categories_90d"
  )
  missing <- setdiff(required, names(data))
  if (length(missing) > 0L) {
    stop("Training data is missing columns: ", paste(missing, collapse = ", "),
         call. = FALSE)
  }

  data <- data[data$currency == target_currency, , drop = FALSE]
  if (nrow(data) == 0L) {
    stop("No quotes found in target currency ", target_currency, ".", call. = FALSE)
  }
  if (anyNA(data[, required, drop = FALSE])) {
    stop("Training data contains missing required values; clean or complete it first.",
         call. = FALSE)
  }
  if (any(!is.finite(data$premium_per_traveler)) ||
      any(data$premium_per_traveler <= 0)) {
    stop("Premiums per traveler must be finite and greater than zero.",
         call. = FALSE)
  }
  data <- prepare_event_category_features(data)

  quote_times <- as.POSIXct(data$quoted_at, tz = "UTC")
  if (anyNA(quote_times)) {
    stop("quoted_at must contain ISO-8601 timestamps.", call. = FALSE)
  }
  time_levels <- sort(unique(quote_times))
  if (length(time_levels) < 2L) {
    stop("At least two distinct quote timestamps are required for a time split.",
         call. = FALSE)
  }
  cutoff_index <- max(1L, floor(length(time_levels) * 0.8))
  cutoff <- time_levels[[cutoff_index]]
  train_rows <- quote_times <= cutoff
  test_rows <- quote_times > cutoff
  test_trip_ids <- unique(data$trip_id[test_rows])
  train_rows <- train_rows & !(data$trip_id %in% test_trip_ids)
  if (sum(train_rows) < 30L || sum(test_rows) < 10L) {
    stop(paste(
      "Need at least 30 earlier training and 10 later test quotes",
      "in the target currency after keeping each trip in one split."
    ),
         call. = FALSE)
  }
  training_cutoff <- max(quote_times[train_rows])

  training <- collapse_training_categories(data[train_rows, , drop = FALSE])
  test <- apply_model_categories(
    data[test_rows, , drop = FALSE],
    training$kept,
    training$other_supported
  )
  formula <- build_model_formula(training$data)

  fit <- stats::glm(
    formula,
    data = training$data,
    family = stats::Gamma(link = "log")
  )
  predictions <- stats::predict(fit, newdata = test, type = "response")
  if (any(!is.finite(predictions))) {
    stop("Model produced invalid holdout predictions.", call. = FALSE)
  }

  actual <- test$premium_per_traveler
  absolute_errors <- abs(actual - predictions)
  baseline <- rep(stats::median(training$data$premium_per_traveler), length(actual))
  baseline_errors <- abs(actual - baseline)
  metrics <- list(
    mae = mean(absolute_errors),
    mape = mean(absolute_errors / actual) * 100,
    baseline_mae = mean(baseline_errors),
    baseline_mape = mean(baseline_errors / actual) * 100,
    error_band_90 = unname(stats::quantile(absolute_errors, 0.9)),
    train_rows = nrow(training$data),
    test_rows = nrow(test),
    training_cutoff = format(
      training_cutoff, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"
    )
  )

  final_data <- collapse_training_categories(data)
  final_fit <- stats::glm(
    formula,
    data = final_data$data,
    family = stats::Gamma(link = "log")
  )

  parent <- dirname(model_path)
  if (!dir.exists(parent)) {
    dir.create(parent, recursive = TRUE)
  }
  artifact <- list(
    fit = final_fit,
    kept_categories = final_data$kept,
    other_supported = final_data$other_supported,
    target_currency = target_currency,
    trained_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    metrics = metrics
  )
  saveRDS(artifact, model_path)
  artifact
}

predict_tracker_model <- function(artifact, data) {
  features <- c(
    "trip_days", "age_band", "origin_country_code",
    "destination_country_code", "coverage_plan_id",
    "medical_limit", "deductible", "event_count_90d",
    "max_event_severity_90d", "event_categories_90d"
  )
  missing <- setdiff(features, names(data))
  if (length(missing) > 0L) {
    stop("Prediction data is missing columns: ", paste(missing, collapse = ", "),
         call. = FALSE)
  }
  if (anyNA(data[, features, drop = FALSE])) {
    stop("Prediction data contains missing required feature values.",
         call. = FALSE)
  }

  data <- prepare_event_category_features(data)
  data <- apply_model_categories(
    data,
    artifact$kept_categories,
    artifact$other_supported
  )
  estimate <- stats::predict(artifact$fit, newdata = data, type = "response")
  if (any(!is.finite(estimate)) || any(estimate <= 0)) {
    stop("Model produced invalid premium estimates.", call. = FALSE)
  }

  data$estimated_premium_per_traveler <- estimate
  data$lower_estimate <- pmax(0, estimate - artifact$metrics$error_band_90)
  data$upper_estimate <- estimate + artifact$metrics$error_band_90
  data$currency <- artifact$target_currency
  data$model_trained_at <- artifact$trained_at
  data
}
