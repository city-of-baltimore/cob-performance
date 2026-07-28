# Manual, immediate trigger for apply_percent_value_scale_backfill_once()
# in R/database.R -- that function also runs automatically (gated by
# application.seed_applied, so it's a no-op after the first run) the next
# time ensure_review_schema() executes, i.e. the next time this app boots
# in any environment, including production once deployed. This script
# just lets you apply it to a database right now instead of waiting for
# the next restart.
source("R/database.R", local = TRUE)

connection <- connect_app_database()
on.exit(DBI::dbDisconnect(connection), add = TRUE)

before <- DBI::dbGetQuery(
  connection,
  paste(
    "SELECT COUNT(*) FILTER (WHERE ma.annual_actual != round(ma.annual_actual)) AS actual_to_convert,",
    "COUNT(*) FILTER (WHERE ma.target_value != round(ma.target_value)) AS target_to_convert,",
    "COUNT(*) FILTER (WHERE ma.annual_actual = round(ma.annual_actual)) AS actual_left_alone_integer,",
    "COUNT(*) FILTER (WHERE ma.target_value = round(ma.target_value)) AS target_left_alone_integer",
    "FROM performance.measure_actuals ma",
    "JOIN performance.performance_measure pm ON pm.measure_id = ma.measure_id",
    "WHERE pm.format_type = 'Percent'"
  )
)
cat("Before:\n")
print(before)

applied <- apply_percent_value_scale_backfill_once(connection)
cat(if (applied) "Applied.\n" else "Already applied on this database -- no-op.\n")

after <- DBI::dbGetQuery(
  connection,
  paste(
    "SELECT MIN(ma.annual_actual) AS min_actual, MAX(ma.annual_actual) AS max_actual,",
    "MIN(ma.target_value) AS min_target, MAX(ma.target_value) AS max_target",
    "FROM performance.measure_actuals ma",
    "JOIN performance.performance_measure pm ON pm.measure_id = ma.measure_id",
    "WHERE pm.format_type = 'Percent'"
  )
)
cat("After:\n")
print(after)
