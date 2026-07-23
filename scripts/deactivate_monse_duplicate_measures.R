# MONSE's services/measures were restructured for FY2027. The old
# measure_ids (312-329) belong to the prior service structure and were
# already marked inactive in an earlier pass -- they're kept for their
# historical actuals data, just hidden from active tracking.
#
# Separately, when MONSE's FY2027 plan documentation was imported, a batch
# of new-style measures (670-693 range) got created that either (a) don't
# correspond to any of MONSE's actual FY2027 services/measures at all, or
# (b) are empty duplicates of a correctly-worded measure that already
# exists (e.g. two "# of GVRS Direct Communications..." rows, one of which
# is the real one used by the current plan). None of these 18 have any
# actuals data, so deactivating them (not deleting) is a no-data-loss,
# reversible cleanup.
source("R/database.R", local = TRUE)

connection <- connect_app_database()
on.exit(DBI::dbDisconnect(connection), add = TRUE)

measure_ids <- c(
  670, 671, 672, 673, 674, 675, 676, 677, # not aligned with any FY2027 MONSE service
  678, 679, 681, 682,                     # empty duplicates (GVRS / SBVIP wording variants)
  686, 687,                               # empty, not part of the FY2027 canonical measure set
  688, 689,                               # empty duplicates (re-entry services wording variants)
  692, 693                                # empty duplicates (stabilization wording variants)
)

# RPostgres binds each params[[i]] to exactly one $i placeholder rather than
# serializing an R vector into a Postgres array literal -- = ANY($1) with a
# vector param fails with "malformed array literal" (confirmed against the
# local dev database). An IN clause with one placeholder per id is used
# instead.
placeholders <- paste0("$", seq_along(measure_ids), collapse = ", ")
measure_id_params <- as.list(as.integer(measure_ids))

DBI::dbWithTransaction(connection, {
  before <- DBI::dbGetQuery(
    connection,
    sprintf("SELECT measure_id, title, active FROM performance.performance_measure WHERE measure_id IN (%s)", placeholders),
    params = measure_id_params
  )
  data_rows <- DBI::dbGetQuery(
    connection,
    sprintf("SELECT measure_id, count(*) AS n FROM performance.measure_actuals WHERE measure_id IN (%s) AND annual_actual IS NOT NULL GROUP BY measure_id", placeholders),
    params = measure_id_params
  )
  if (nrow(data_rows)) {
    stop("Refusing to deactivate -- these measure_ids have real actuals data: ", paste(data_rows$measure_id, collapse = ", "))
  }

  updated <- DBI::dbExecute(
    connection,
    sprintf("UPDATE performance.performance_measure SET active = FALSE, last_updated = now() WHERE measure_id IN (%s)", placeholders),
    params = measure_id_params
  )
  cat("Rows updated:", updated, "(expected", length(measure_ids), ")\n")

  after <- DBI::dbGetQuery(
    connection,
    sprintf("SELECT measure_id, title, active FROM performance.performance_measure WHERE measure_id IN (%s) ORDER BY measure_id", placeholders),
    params = measure_id_params
  )
  print(after)
})
