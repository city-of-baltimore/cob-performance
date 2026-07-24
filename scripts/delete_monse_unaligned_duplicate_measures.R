# Deletes the 18 MONSE (AGC4346) measures deactivated in
# scripts/deactivate_monse_duplicate_measures.R: measures that either don't
# correspond to any real FY2027 MONSE service/goal at all, or are empty
# duplicates of a correctly-worded measure that already exists. Confirmed
# empty of actuals data before deactivation, and reconfirmed empty here.
#
# Melanie's direction (2026-07-24): keep the FY21-25 historical measures
# (measure_id 312-329) inactive rather than delete them -- they hold real
# data. This script only removes measures that were already confirmed to
# have zero data, not those.
#
# Each of these measures is linked into either performance.pm_service_link
# or performance.pm_goal_link (from the original FY2027 plan documentation
# import), so those links have to go first or the measure delete would
# leave orphaned rows (both tables reference measure_id without ON DELETE
# CASCADE).

source("R/database.R", local = TRUE)

connection <- connect_app_database()
on.exit(DBI::dbDisconnect(connection), add = TRUE)

measure_ids <- c(
  670, 671, 672, 673, 674, 675, 676, 677,
  678, 679, 681, 682,
  686, 687,
  688, 689,
  692, 693
)
placeholders <- paste0("$", seq_along(measure_ids), collapse = ", ")
measure_id_params <- as.list(as.integer(measure_ids))

DBI::dbWithTransaction(connection, {
  data_rows <- DBI::dbGetQuery(
    connection,
    sprintf("SELECT measure_id FROM performance.measure_actuals WHERE measure_id IN (%s) AND annual_actual IS NOT NULL", placeholders),
    params = measure_id_params
  )
  if (nrow(data_rows)) {
    stop("Refusing to delete -- these measure_ids have real actuals data: ", paste(data_rows$measure_id, collapse = ", "))
  }

  before <- DBI::dbGetQuery(
    connection,
    sprintf("SELECT measure_id, title, active FROM performance.performance_measure WHERE measure_id IN (%s) ORDER BY measure_id", placeholders),
    params = measure_id_params
  )
  cat("Deleting", nrow(before), "measures (expected", length(measure_ids), "):\n")
  print(before)

  deleted_actuals <- DBI::dbExecute(connection, sprintf("DELETE FROM performance.measure_actuals WHERE measure_id IN (%s)", placeholders), params = measure_id_params)
  deleted_service_links <- DBI::dbExecute(connection, sprintf("DELETE FROM performance.pm_service_link WHERE measure_id IN (%s)", placeholders), params = measure_id_params)
  deleted_goal_links <- DBI::dbExecute(connection, sprintf("DELETE FROM performance.pm_goal_link WHERE measure_id IN (%s)", placeholders), params = measure_id_params)
  deleted_entity_links <- DBI::dbExecute(connection, sprintf("DELETE FROM performance.measure_entity_link WHERE measure_id IN (%s)", placeholders), params = measure_id_params)
  deleted_measures <- DBI::dbExecute(connection, sprintf("DELETE FROM performance.performance_measure WHERE measure_id IN (%s)", placeholders), params = measure_id_params)

  cat("deleted_actuals_rows:", deleted_actuals, "\n")
  cat("deleted_service_links:", deleted_service_links, "(expected 10)\n")
  cat("deleted_goal_links:", deleted_goal_links, "(expected 8)\n")
  cat("deleted_entity_links:", deleted_entity_links, "(expected 0)\n")
  cat("deleted_measures:", deleted_measures, "(expected", length(measure_ids), ")\n")

  remaining <- DBI::dbGetQuery(
    connection,
    sprintf("SELECT measure_id FROM performance.performance_measure WHERE measure_id IN (%s)", placeholders),
    params = measure_id_params
  )
  if (nrow(remaining)) stop("Some measure_ids were not deleted: ", paste(remaining$measure_id, collapse = ", "))
})
