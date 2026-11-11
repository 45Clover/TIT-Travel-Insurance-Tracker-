local({
  Sys.setenv(TZ = "UTC")
  library(shiny)
  source("R/db.R")
  source("R/features.R")
  source("R/model.R")

  connection <- connect_tracker_db()
  initialize_tracker_db(connection)
  onStop(function() DBI::dbDisconnect(connection))

  ui <- fluidPage(
    tags$head(
      tags$meta(name = "viewport", content = "width=device-width, initial-scale=1"),
      tags$title("RoamCover | Travel insurance explorer"),
      tags$link(rel = "stylesheet", type = "text/css", href = "styles.css"),
      tags$link(
        rel = "stylesheet",
        href = "https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"
      ),
      tags$script(src = "https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"),
      tags$script(src = "map.js")
    ),
    div(
      class = "app-shell",
      tags$header(
        class = "topbar",
        div(
          class = "brand",
          div(class = "brand-mark", "R"),
          div(
            tags$strong("ROAMCOVER"),
            tags$span("TRAVEL PRICE EXPLORER")
          )
        ),
        div(class = "topbar-note", span(class = "status-dot"), "Historical data explorer")
      ),
      div(
        class = "page-heading",
        div(
          tags$div(class = "eyebrow", "TRAVEL INSURANCE INTELLIGENCE"),
          tags$h1("Explore the world. Understand the price."),
          tags$p("Select a destination to explore historical quotes and recent events.")
        ),
        tags$div(class = "currency-badge", "ESTIMATES · NOT LIVE OFFERS")
      ),
      div(
        class = "dashboard-grid",
        div(
          class = "map-column",
          div(
            class = "map-toolbar",
            div(
              class = "search-wrap",
              tags$span(class = "search-icon", HTML("&#9906;")),
              tags$input(
                id = "country-search",
                type = "search",
                list = "country-options",
                placeholder = "Search a country...",
                autocomplete = "off"
              ),
              tags$datalist(id = "country-options")
            ),
            div(class = "map-help", "PAN TO EXPLORE  ·  CLICK TO SELECT  ·  SCROLL TO ZOOM")
          ),
          div(
            class = "map-card",
            div(id = "world-map"),
            div(id = "map-loading", "Loading the map..."),
            div(id = "map-error", style = "display:none")
          ),
          div(
            class = "map-legend",
            span(class = "legend-dot selected-dot"),
            span("Selected destination"),
            span(class = "legend-note", "Country boundaries and search require an internet connection.")
          )
        ),
        tags$aside(
          class = "insights-column",
          div(
            class = "panel destination-panel",
            div(class = "panel-kicker", "DESTINATION OVERVIEW"),
            uiOutput("country_summary"),
            div(class = "subsection-heading", "RECENT EVENT SIGNALS"),
            uiOutput("event_summary"),
            div(class = "subsection-heading", "RECENT QUOTE HISTORY"),
            tableOutput("history_table")
          ),
          div(
            class = "panel estimate-panel",
            div(class = "panel-kicker", "TRIP ESTIMATE"),
            tags$p(class = "panel-description", "Choose trip details to estimate a per-traveler premium."),
            selectInput("origin_country_code", "Origin country code", choices = character()),
            fluidRow(
              column(6, dateInput("departure_date", "Departure", value = Sys.Date() + 30)),
              column(6, dateInput("return_date", "Return", value = Sys.Date() + 37))
            ),
            selectInput(
              "age_band",
              "Traveler age band",
              choices = c("Unknown" = "unknown", "Under 18" = "under_18",
                          "18-29" = "18-29", "30-39" = "30-39",
                          "40-49" = "40-49", "50-59" = "50-59",
                          "60-69" = "60-69", "70+" = "70_plus")
            ),
            selectInput("coverage_plan_id", "Coverage plan", choices = character()),
            actionButton("estimate_trip", "Estimate this trip", class = "estimate-button"),
            uiOutput("estimate_result")
          )
        )
      ),
      tags$footer(
        "Prices are indicative estimates from imported historical quotes. They are not insurer offers or guarantees."
      )
    )
  )

  server <- function(input, output, session) {
    country_choices <- DBI::dbGetQuery(
      connection,
      paste(
        "SELECT DISTINCT origin_country_code AS country_code FROM trips",
        "UNION SELECT DISTINCT destination_country_code FROM trips",
        "ORDER BY country_code"
      )
    )$country_code
    plan_choices <- DBI::dbGetQuery(
      connection,
      "SELECT coverage_plan_id, plan_name FROM coverage_plans ORDER BY plan_name"
    )

    updateSelectInput(
      session,
      "origin_country_code",
      choices = if (length(country_choices)) country_choices else c("Import trip data first" = "")
    )
    updateSelectInput(
      session,
      "coverage_plan_id",
      choices = if (nrow(plan_choices)) {
        stats::setNames(plan_choices$coverage_plan_id, plan_choices$plan_name)
      } else {
        c("Import coverage plans first" = "")
      }
    )

    selected_country <- reactiveVal(NULL)
    estimate_state <- reactiveVal(NULL)

    observeEvent(input$selected_country, {
      country <- input$selected_country
      if (is.list(country) && !is.null(country$name)) {
        selected_country(country)
        estimate_state(NULL)
      }
    }, ignoreInit = TRUE)

    country_codes <- function(country) {
      codes <- unique(toupper(as.character(c(country$code3, country$code2))))
      codes <- codes[!is.na(codes) & nzchar(codes) & codes != "-99"]
      if (length(codes) == 1L) {
        codes <- c(codes, "")
      }
      if (length(codes) == 0L) {
        codes <- c("", "")
      }
      codes[1:2]
    }

    country_snapshot <- reactive({
      country <- selected_country()
      if (is.null(country)) {
        return(NULL)
      }
      codes <- country_codes(country)
      prices <- DBI::dbGetQuery(
        connection,
        paste(
          "SELECT currency, premium_per_traveler, quoted_at",
          "FROM quote_training_rows",
          "WHERE upper(destination_country_code) IN (?, ?)"
        ),
        params = as.list(codes)
      )

      now <- format_utc_timestamp(Sys.time())
      today <- format(Sys.Date(), "%Y-%m-%d")
      events <- DBI::dbGetQuery(
        connection,
        paste(
          "WITH latest AS (",
          "SELECT source_id, external_event_id, country_code, MAX(observed_at) AS observed_at",
          "FROM country_events",
          "WHERE upper(country_code) IN (?, ?) AND observed_at <= ?",
          "GROUP BY source_id, external_event_id, country_code",
          "), eligible AS (",
          "SELECT e.event_id, e.category, e.severity",
          "FROM latest l JOIN country_events e",
          "ON e.source_id = l.source_id",
          "AND e.external_event_id = l.external_event_id",
          "AND e.country_code = l.country_code",
          "AND e.observed_at = l.observed_at",
          "WHERE date(e.starts_on) <= date(?)",
          "AND COALESCE(date(e.ends_on), '9999-12-31') >= date(?, '-90 days')",
          ")",
          "SELECT category, COUNT(*) AS event_count, MAX(severity) AS max_severity",
          "FROM eligible GROUP BY category ORDER BY category"
        ),
        params = as.list(c(codes, now, today, today))
      )

      history <- data.frame()
      if (nrow(prices)) {
        prices$month <- substr(prices$quoted_at, 1, 7)
        history <- stats::aggregate(
          premium_per_traveler ~ month + currency,
          data = prices,
          FUN = stats::median
        )
        names(history)[names(history) == "premium_per_traveler"] <- "median_per_traveler"
        history <- utils::tail(history[order(history$month, decreasing = TRUE), ], 8)
      }
      list(
        country = country,
        quotes = prices,
        events = events,
        history = history
      )
    })

    output$country_summary <- renderUI({
      country <- selected_country()
      snapshot <- country_snapshot()
      if (is.null(country) || is.null(snapshot)) {
        return(div(
          class = "empty-state",
          div(class = "empty-map", HTML("&#9678;")),
          tags$strong("Choose a destination"),
          tags$p("Search above or click a country on the map.")
        ))
      }

      quote_count <- nrow(snapshot$quotes)
      currency_groups <- split(
        snapshot$quotes$premium_per_traveler,
        snapshot$quotes$currency
      )
      div(
        tags$h2(country$name),
        tags$div(class = "country-code", paste(country$code3, country$code2)),
        if (quote_count == 0L) {
          div(class = "no-data-note", "No historical quotes for this destination yet.")
        } else {
          div(
            class = "metric-grid",
            div(
              class = "metric-tile",
              tags$span("RECORDED QUOTES"),
              tags$strong(quote_count)
            ),
            lapply(names(currency_groups), function(currency) {
              div(
                class = "metric-tile",
                tags$span(paste("MEDIAN", currency)),
                tags$strong(format(
                  round(stats::median(currency_groups[[currency]]), 2),
                  nsmall = 2
                ))
              )
            })
          )
        }
      )
    })

    output$event_summary <- renderUI({
      snapshot <- country_snapshot()
      if (is.null(snapshot)) {
        return(tags$p(class = "muted-copy", "Select a country to see event information."))
      }
      if (nrow(snapshot$events) == 0L) {
        return(tags$p(class = "muted-copy", "No recent country events are recorded."))
      }
      div(
        class = "event-list",
        lapply(seq_len(nrow(snapshot$events)), function(i) {
          event <- snapshot$events[i, ]
          div(
            class = "event-row",
            div(
              class = "event-name",
              tags$span(class = "event-indicator"),
              gsub("_", " ", event$category)
            ),
            tags$span(
              class = "event-value",
              paste0(event$event_count, " · severity ", format(event$max_severity, trim = TRUE))
            )
          )
        })
      )
    })

    output$history_table <- renderTable({
      snapshot <- country_snapshot()
      if (is.null(snapshot) || nrow(snapshot$history) == 0L) {
        return(NULL)
      }
      snapshot$history
    }, striped = TRUE, bordered = FALSE, spacing = "s", digits = 2)

    supported_model_value <- function(artifact, field, value) {
      value <- as.character(value)
      value %in% artifact$kept_categories[[field]] ||
        isTRUE(artifact$other_supported[[field]])
    }

    observeEvent(input$estimate_trip, {
      estimate_state(NULL)
      country <- selected_country()
      if (is.null(country)) {
        estimate_state(list(error = "Select a destination on the map first."))
        return()
      }
      model_path <- "models/travel_price_model.rds"
      if (!file.exists(model_path)) {
        estimate_state(list(error = "Train a model after importing enough historical quotes."))
        return()
      }
      if (is.null(input$origin_country_code) || !nzchar(input$origin_country_code) ||
          is.null(input$coverage_plan_id) || !nzchar(input$coverage_plan_id)) {
        estimate_state(list(error = "Import trip and coverage-plan data before estimating."))
        return()
      }
      if (is.null(input$departure_date) || is.null(input$return_date) ||
          input$return_date <= input$departure_date) {
        estimate_state(list(error = "Return date must be after departure date."))
        return()
      }

      destination_codes <- country_codes(country)
      known_codes <- DBI::dbGetQuery(
        connection,
        "SELECT DISTINCT destination_country_code FROM trips"
      )$destination_country_code
      matched_codes <- destination_codes[destination_codes %in% known_codes]
      destination_code <- if (length(matched_codes)) {
        matched_codes[[1]]
      } else {
        destination_codes[[1]]
      }
      artifact <- readRDS(model_path)
      model_values <- list(
        destination_country_code = destination_code,
        origin_country_code = input$origin_country_code,
        coverage_plan_id = input$coverage_plan_id,
        age_band = input$age_band
      )
      unsupported <- names(model_values)[!vapply(
        names(model_values),
        function(field) supported_model_value(artifact, field, model_values[[field]]),
        logical(1)
      )]
      if (length(unsupported)) {
        estimate_state(list(
          error = paste(
            "The trained model has too little history to estimate this",
            paste(unsupported, collapse = ", "),
            "value. Add comparable quotes and retrain."
          )
        ))
        return()
      }

      prediction_input <- data.frame(
        prediction_id = "ui-estimate",
        as_of = format_utc_timestamp(Sys.time()),
        origin_country_code = input$origin_country_code,
        destination_country_code = destination_code,
        departure_date = as.character(input$departure_date),
        return_date = as.character(input$return_date),
        age_band = input$age_band,
        coverage_plan_id = input$coverage_plan_id,
        stringsAsFactors = FALSE
      )
      features <- build_prediction_features(connection, prediction_input)
      prediction <- predict_tracker_model(artifact, features)
      estimate_state(list(
        estimate = prediction$estimated_premium_per_traveler[[1]],
        lower = prediction$lower_estimate[[1]],
        upper = prediction$upper_estimate[[1]],
        currency = prediction$currency[[1]],
        error_band = artifact$metrics$error_band_90
      ))
    })

    output$estimate_result <- renderUI({
      result <- estimate_state()
      if (is.null(result)) {
        return(tags$p(class = "muted-copy", "Your estimate will appear here."))
      }
      if (!is.null(result$error)) {
        return(div(class = "estimate-message", result$error))
      }
      div(
        class = "estimate-result",
        tags$span("ESTIMATED PREMIUM / TRAVELER"),
        tags$strong(paste(
          result$currency,
          format(round(result$estimate, 2), nsmall = 2)
        )),
        tags$p(paste(
          "Indicative range:",
          result$currency,
          format(round(result$lower, 2), nsmall = 2),
          "–",
          format(round(result$upper, 2), nsmall = 2)
        )),
        tags$small("Range uses historical holdout error; it is not a guaranteed quote.")
      )
    })
  }

  shinyApp(ui, server)
})
