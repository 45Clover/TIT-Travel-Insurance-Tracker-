# TIT Travel Insurance Tracker

An R and SQLite project for estimating the price of a travel-insurance policy using historical quotes and information available when the estimate is made.

## What the estimate means

Start by predicting the **quoted premium for one traveler for one trip**, in a stated currency and for a clearly defined coverage package. A quote is not the same as an insurer's eventual claim cost or the traveler's total out-of-pocket loss. Keep those measures separate if they are added later.

For comparisons across trips, also calculate a normalized measure such as premium per traveler-day. Keep the original total premium as the primary outcome: per-day normalization is useful for analysis, but should not replace the price a traveler would actually pay.

## Project structure

```text
R/
  db.R                 SQLite connection and schema initialization
  import.R             Transactional CSV imports
  features.R           Point-in-time prediction features
  model.R              Time split, Gamma model, metrics, and prediction
sql/
  schema.sql           Tables, indexes, and quote_training_rows view
scripts/
  init_db.R            Create the local database
  import_csv.R         Load CSVs from data/input/
  train_model.R        Train and evaluate a model
  predict.R            Estimate prices from prediction input CSV
app.R                 Shiny map and country-insights UI
www/
  map.js               Map interaction, search, hover, and selection
  styles.css           Dashboard layout and theme
data/
  templates/           CSV headers matching the database schema
  input/                Local input data (not committed)
models/                 Saved model files (not committed)
output/                 Prediction output (not committed)
```

The database stores sources, coverage plans, trips, quotes, country-event observations, exchange rates, and model-run metrics. Event observations are versioned by source event and observation timestamp; historical features use only the latest event version known by each quote timestamp. Map event sources to the category codes `weather`, `natural_disaster`, `conflict`, `political_unrest`, `public_health`, or `other`. The model uses recent event presence, count, and severity, trains in a single currency, and normalizes party-level quote totals to a per-traveler target.

## Run the pipeline

Install R, then install the two required packages:

```r
install.packages(c("DBI", "RSQLite"))
```

From the project root in a terminal:

```text
Rscript scripts/init_db.R
```

To verify the complete pipeline without changing your database or using real pricing data, run the isolated synthetic smoke test:

```text
Rscript scripts/smoke_test.R
```

It creates and removes a temporary database, imports synthetic rows, trains a test model, and checks a prediction. Its estimate is only a wiring check, not an accuracy result.

Copy the CSV headers from `data/templates/` into `data/input/`, then populate the corresponding files. Import and train (the example uses USD; change it to the currency represented in your quotes):

```text
Rscript scripts/import_csv.R
Rscript scripts/train_model.R USD
```

Training requires at least 30 earlier and 10 later quotes in the selected currency, and at least two distinct quote timestamps. The split is chronological, and quotes for the same trip are kept together to reduce leakage. Quotes, trips, plans, and sources are imported in foreign-key order; invalid rows or duplicate IDs stop the import transaction.

For predictions, copy `data/templates/prediction_input.csv` to `data/prediction_input.csv`, fill in one row per trip, and use a `coverage_plan_id` already present in the database. `as_of` must be an ISO-8601 timestamp (for example `2026-11-11T12:00:00Z`). Then run:

```text
Rscript scripts/predict.R
```

The output includes the estimated premium per traveler in the model currency and a rough error band derived from the temporal holdout's 90th-percentile absolute error. This band is not a calibrated guarantee; assess it on more data before using estimates for decisions. Event severity is an input feature, not evidence that an event caused a price change.

The training report compares the Gamma model with a training-period median-price baseline. Unknown categories are pooled only when the training data contains examples for that pooled group; otherwise prediction stops rather than silently inventing a country- or plan-specific estimate.

Use the CSV templates as the import contract: IDs must be stable, country codes ISO alpha-2 or alpha-3 (imports are trimmed and uppercased), timestamps ISO-8601 (imports are normalized to UTC), and currencies three-letter uppercase codes. Keep raw quote and event data private and out of version control.

## Launch the UI

Install Shiny once, then start the app from the project root:

```text
Rscript -e "install.packages('shiny', repos='https://cloud.r-project.org')"
Rscript -e "shiny::runApp('.', host='127.0.0.1', port=3838)"
```

The map uses public country-boundary and basemap assets, so the browser needs internet access. With no imported quotes or trained model, map search and country selection still work, while price and event panels explain that data is unavailable.

## Candidate prediction inputs

Capture only fields that are available when the estimate is requested, and avoid collecting personal details that are not needed.

- **Trip:** destination country, origin country, departure and return dates, trip duration, and number of travelers.
- **Traveler:** age band rather than exact birth date, if age is needed and appropriate for the intended product.
- **Coverage:** plan/tier, medical-expense limit, deductible/excess, cancellation coverage, baggage coverage, and pre-existing-condition option. Compare like-for-like coverage wherever possible.
- **Price context:** currency, quote date, insurer or source, and whether the price is per person or for the whole party.
- **Destination conditions:** dated event category, start/end dates, severity or a documented proxy, and the affected geography. Potential categories include severe weather, natural disasters, conflict, political unrest, and public-health disruptions.

Do not assume that a headline event changes insurance prices. The model needs enough dated quotes before and after comparable events to learn whether an association exists. Event records should be treated as predictors, not proof of cause.

## Data foundation

A useful initial SQLite design has these logical tables:

- `quotes`: one row per observed quote, including the total premium, currency, quote timestamp, source, and trip or coverage identifiers.
- `trips`: destination and origin, travel dates, duration, and traveler count.
- `coverage_plans`: the covered benefits, limits, and deductible/excess associated with a quote.
- `country_events`: source event identifier, country or geography, category, severity, event dates, source, and retrieval timestamp.
- `exchange_rates` (if needed): dated currency rates and source, used to convert premiums to one modeling currency without losing the original amount.

Use primary keys and foreign keys, store dates in a consistent ISO-8601 format, and keep source provenance. Define how duplicates, missing fields, quote revisions, refunds, and multi-traveler prices are handled before training. Do not combine currencies without a dated conversion rate.

## Evaluation and safeguards

- Split train and test data by **time**, not by random rows, so the test represents future estimates. The scaffold also keeps quotes for the same trip together.
- The training script reports MAE and MAPE alongside a median-price baseline. Further evaluation should break results down by destination, coverage type, and time period, and disclose groups with too little data.
- Check that event features are available as of the quote date. Avoid using later event severity assessments, future travel outcomes, or fields derived from the price being predicted.
- For destinations with little history, prefer a pooled estimate with a wider uncertainty range over a confident country-specific result.
- Track model version, training cutoff, feature definitions, and prediction time. Retrain only when there is enough new, quality-checked data.
- Treat estimates as informational. Actual premiums vary by insurer, underwriting rules, traveler eligibility, and product terms.

## First implementation milestones

1. Choose permitted quote and event data sources, and populate the CSV templates.
2. Run the pipeline on a small sample to validate IDs, units, dates, and joins.
3. Collect enough quotes in one currency to meet the chronological training and holdout minimums.
4. Review error metrics by destination, coverage, and time period before relying on estimates.
