local({
  source("R/db.R")
  source("R/model.R")
  source("R/features.R")

  args <- commandArgs(trailingOnly = TRUE)
  input_path <- if (length(args) >= 1L) args[[1]] else "data/prediction_input.csv"
  output_path <- if (length(args) >= 2L) args[[2]] else "output/predictions.csv"
  model_path <- if (length(args) >= 3L) args[[3]] else "models/travel_price_model.rds"

  if (!file.exists(input_path)) {
    stop("Prediction input not found: ", input_path, call. = FALSE)
  }
  if (!file.exists(model_path)) {
    stop("Trained model not found: ", model_path, call. = FALSE)
  }

  input <- utils::read.csv(
    input_path,
    stringsAsFactors = FALSE,
    check.names = FALSE,
    na.strings = c("")
  )
  if (nrow(input) == 0L) {
    stop("Prediction input contains no rows.", call. = FALSE)
  }

  connection <- connect_tracker_db()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)
  initialize_tracker_db(connection)
  features <- build_prediction_features(connection, input)
  artifact <- readRDS(model_path)
  predictions <- predict_tracker_model(artifact, features)

  parent <- dirname(output_path)
  if (!dir.exists(parent)) {
    dir.create(parent, recursive = TRUE)
  }
  utils::write.csv(predictions, output_path, row.names = FALSE, na = "")
  message("Wrote predictions to ", output_path)
})
