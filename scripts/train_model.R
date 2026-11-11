local({
  source("R/db.R")
  source("R/model.R")

  args <- commandArgs(trailingOnly = TRUE)
  target_currency <- if (length(args) >= 1L) toupper(args[[1]]) else "USD"
  model_path <- if (length(args) >= 2L) args[[2]] else "models/travel_price_model.rds"

  if (!grepl("^[A-Z]{3}$", target_currency)) {
    stop("Target currency must be a three-letter uppercase code.", call. = FALSE)
  }

  connection <- connect_tracker_db()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)
  initialize_tracker_db(connection)
  data <- DBI::dbGetQuery(connection, "SELECT * FROM quote_training_rows")
  artifact <- train_tracker_model(data, target_currency, model_path)

  model_run_id <- paste0("run-", format(Sys.time(), "%Y%m%d%H%M%S", tz = "UTC"))
  DBI::dbExecute(
    connection,
    paste(
      "INSERT INTO model_runs",
      "(model_run_id, trained_at, training_cutoff, target_currency, train_rows,",
      "test_rows, mae, mape, baseline_mae, baseline_mape, error_band_90, model_path)",
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
    ),
    params = list(
      model_run_id, artifact$trained_at, artifact$metrics$training_cutoff,
      target_currency, artifact$metrics$train_rows, artifact$metrics$test_rows,
      artifact$metrics$mae, artifact$metrics$mape,
      artifact$metrics$baseline_mae, artifact$metrics$baseline_mape,
      artifact$metrics$error_band_90, model_path
    )
  )

  print(artifact$metrics)
  message("Saved model to ", model_path)
})
