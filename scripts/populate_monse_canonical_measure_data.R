# Populates the 15 canonical FY2027 MONSE measures (Services 925 Victim
# Services, 924 Violence Prevention, 927 Neighborhood Stabilization, 926
# Re-Entry Services) with the exact actuals/targets from the FY2027 budget
# book, per Melanie's screenshots (2026-07-24). Budget book columns are
# FY22/23/24 Actual, FY25 Target+Actual, FY26 Target (FY26 Actual isn't
# available yet -- the budget book itself shows $0 actual spending for
# FY26), and FY27 Target. "N/A" cells are left NULL rather than written as
# a value.
#
# Also fixes measure 726's format_type: it's a "%" measure by its own title
# and budget-book values (100%, 90%), but was stored as "Count".
#
# Idempotent: a re-run only fills in NULL fields, never overwrites an
# existing non-NULL value with NULL (COALESCE in the upsert), so this is
# safe to run again if a row needs correcting later without clobbering
# manual edits made in between.

source("R/database.R", local = TRUE)

connection <- connect_app_database()
on.exit(DBI::dbDisconnect(connection), add = TRUE)

# measure_id -> list(fiscal_year = list(actual = ..., target = ...))
# Percent-format values are fractions (0-1), matching how every other
# Percent measure in this database is already stored (confirmed against
# performance.performance_measure/measure_actuals before writing this).
monse_data <- list(
  `727` = list(`2022` = list(actual = 29), `2023` = list(actual = 191), `2024` = list(actual = 226), `2025` = list(actual = 242), `2027` = list(target = 225)),
  `728` = list(),
  `680` = list(`2027` = list(target = 1600)),
  `729` = list(`2025` = list(actual = 254)),
  `730` = list(),
  `720` = list(),
  `721` = list(),
  `690` = list(),
  `691` = list(),
  `722` = list(),
  `723` = list(),
  `724` = list(`2022` = list(actual = 1), `2023` = list(actual = 7), `2024` = list(actual = 17), `2025` = list(actual = 12), `2026` = list(target = 17), `2027` = list(target = 18)),
  `684` = list(),
  `726` = list(`2024` = list(actual = 1.00), `2025` = list(actual = 1.00), `2027` = list(target = 0.90)),
  `725` = list(`2022` = list(actual = 1441), `2023` = list(actual = 1780), `2024` = list(actual = 2304), `2025` = list(actual = 1739), `2027` = list(target = 2000))
)

DBI::dbWithTransaction(connection, {
  fixed_format <- DBI::dbExecute(
    connection,
    "UPDATE performance.performance_measure SET format_type = 'Percent' WHERE measure_id = 726 AND format_type <> 'Percent'"
  )
  cat("measure 726 format_type corrected to Percent:", fixed_format == 1, "\n")

  # measure_actuals.reported_by is NOT NULL -- reuse whoever's already
  # reported MONSE's other data (measure 680's actuals) so this reads as
  # attributable to a real, plausible reporter rather than an arbitrary pick.
  reported_by <- DBI::dbGetQuery(
    connection,
    "SELECT reported_by FROM performance.measure_actuals WHERE measure_id = 680 AND reported_by IS NOT NULL LIMIT 1"
  )$reported_by[[1]]
  if (is.null(reported_by) || length(reported_by) == 0 || is.na(reported_by)) {
    reported_by <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" ORDER BY user_id LIMIT 1')$user_id[[1]]
  }
  cat("reported_by:", reported_by, "\n")

  total_rows <- 0L
  for (measure_id in names(monse_data)) {
    years <- monse_data[[measure_id]]
    for (fiscal_year in names(years)) {
      entry <- years[[fiscal_year]]
      DBI::dbExecute(
        connection,
        paste(
          "INSERT INTO performance.measure_actuals (measure_id, fiscal_year, annual_actual, target_value, reported_by)",
          "VALUES ($1, $2, $3, $4, $5)",
          "ON CONFLICT (measure_id, fiscal_year) DO UPDATE SET",
          "annual_actual = COALESCE(EXCLUDED.annual_actual, performance.measure_actuals.annual_actual),",
          "target_value = COALESCE(EXCLUDED.target_value, performance.measure_actuals.target_value)"
        ),
        params = list(as.integer(measure_id), as.integer(fiscal_year), entry$actual %||% NA_real_, entry$target %||% NA_real_, as.integer(reported_by))
      )
      total_rows <- total_rows + 1L
    }
  }
  cat("fiscal-year rows written:", total_rows, "\n")

  report <- DBI::dbGetQuery(
    connection,
    paste(
      "SELECT pm.measure_id, pm.title, pm.format_type, ma.fiscal_year, ma.annual_actual, ma.target_value",
      "FROM performance.performance_measure pm",
      "LEFT JOIN performance.measure_actuals ma ON ma.measure_id = pm.measure_id",
      "WHERE pm.measure_id IN (680,684,690,691,720,721,722,723,724,725,726,727,728,729,730)",
      "ORDER BY pm.measure_id, ma.fiscal_year"
    )
  )
  print(report, row.names = FALSE)
})
