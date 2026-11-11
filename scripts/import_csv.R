local({
  source("R/db.R")
  source("R/import.R")

  args <- commandArgs(trailingOnly = TRUE)
  input_dir <- if (length(args) >= 1L) args[[1]] else "data/input"

  connection <- connect_tracker_db()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)
  initialize_tracker_db(connection)
  import_csv_directory(connection, input_dir)
})
