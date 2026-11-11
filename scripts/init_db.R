local({
  source("R/db.R")
  connection <- connect_tracker_db()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)
  initialize_tracker_db(connection)
  message("Database initialized at data/travel_tracker.sqlite")
})
