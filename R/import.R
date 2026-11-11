import_csv_directory <- function(connection, input_dir = "data/input") {
  table_files <- c(
    sources = "sources.csv",
    coverage_plans = "coverage_plans.csv",
    trips = "trips.csv",
    quotes = "quotes.csv",
    country_events = "country_events.csv",
    exchange_rates = "exchange_rates.csv"
  )

  imported <- character()
  DBI::dbWithTransaction(connection, {
    for (table_name in names(table_files)) {
      path <- file.path(input_dir, table_files[[table_name]])
      if (!file.exists(path)) {
        next
      }

      data <- utils::read.csv(
        path,
        stringsAsFactors = FALSE,
        check.names = FALSE,
        na.strings = c("")
      )
      if (nrow(data) == 0L) {
        next
      }

      expected <- DBI::dbListFields(connection, table_name)
      if (!setequal(names(data), expected)) {
        missing <- setdiff(expected, names(data))
        extra <- setdiff(names(data), expected)
        stop(
          "Columns in ", path, " do not match table ", table_name,
          ". Missing: ", paste(missing, collapse = ", "),
          ". Unexpected: ", paste(extra, collapse = ", "),
          call. = FALSE
        )
      }
      timestamp_column <- switch(
        table_name,
        sources = "retrieved_at",
        quotes = "quoted_at",
        country_events = "observed_at",
        NULL
      )
      if (!is.null(timestamp_column)) {
        timestamps <- parse_iso_timestamp(data[[timestamp_column]])
        if (anyNA(timestamps)) {
          stop(
            "Invalid ISO-8601 timestamp in ", path, " column ",
            timestamp_column, ".",
            call. = FALSE
          )
        }
        data[[timestamp_column]] <- format_utc_timestamp(timestamps)
      }
      country_columns <- switch(
        table_name,
        trips = c("origin_country_code", "destination_country_code"),
        country_events = "country_code",
        character()
      )
      for (column in country_columns) {
        data[[column]] <- toupper(trimws(data[[column]]))
      }
      data <- data[, expected, drop = FALSE]
      DBI::dbAppendTable(connection, table_name, data)
      imported <- c(imported, paste0(table_name, " (", nrow(data), ")"))
    }
  })

  if (length(imported) == 0L) {
    message("No non-empty CSV files found in ", input_dir, ".")
  } else {
    message("Imported: ", paste(imported, collapse = ", "))
  }
  invisible(imported)
}
