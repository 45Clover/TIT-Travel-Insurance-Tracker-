Sys.setenv(TZ = "UTC")

connect_tracker_db <- function(path = "data/travel_tracker.sqlite") {
  if (!requireNamespace("DBI", quietly = TRUE) ||
      !requireNamespace("RSQLite", quietly = TRUE)) {
    stop("Install the required packages with install.packages(c('DBI', 'RSQLite')).",
         call. = FALSE)
  }

  parent <- dirname(path)
  if (!dir.exists(parent)) {
    dir.create(parent, recursive = TRUE)
  }

  connection <- DBI::dbConnect(RSQLite::SQLite(), dbname = path)
  DBI::dbExecute(connection, "PRAGMA foreign_keys = ON")
  connection
}

parse_iso_timestamp <- function(values) {
  values <- as.character(values)
  parsed <- as.POSIXct(
    rep(NA_real_, length(values)),
    origin = "1970-01-01",
    tz = "UTC"
  )
  formats <- c(
    "%Y-%m-%dT%H:%M:%OSZ",
    "%Y-%m-%dT%H:%M:%OS%z",
    "%Y-%m-%dT%H:%MZ",
    "%Y-%m-%dT%H:%M%z",
    "%Y-%m-%d %H:%M:%OS"
  )

  for (timestamp_format in formats) {
    pending <- which(is.na(parsed) & !is.na(values) & nzchar(values))
    if (length(pending) == 0L) {
      break
    }
    candidates <- as.POSIXct(
      strptime(values[pending], format = timestamp_format, tz = "UTC"),
      tz = "UTC"
    )
    valid <- !is.na(candidates)
    parsed[pending[valid]] <- candidates[valid]
  }
  parsed
}

format_utc_timestamp <- function(values) {
  format(values, "%Y-%m-%dT%H:%M:%OS6Z", tz = "UTC")
}

initialize_tracker_db <- function(connection, schema_path = "sql/schema.sql") {
  if (!file.exists(schema_path)) {
    stop("Schema file not found: ", schema_path, call. = FALSE)
  }

  statements <- strsplit(
    paste(readLines(schema_path, warn = FALSE), collapse = "\n"),
    ";",
    fixed = TRUE
  )[[1]]
  statements <- trimws(statements)
  statements <- statements[nzchar(statements)]

  DBI::dbWithTransaction(connection, {
    for (statement in statements) {
      DBI::dbExecute(connection, statement)
    }
  })
}
