# AGC4317 (M-R Consumer Protection and Business Licensing) already existed as
# a reference.agency/reference.service/reference.plan_entity row, but never
# got a planning.agency_plan row for FY2027 (cycle_id 4) -- so it never
# actually showed up as a usable working plan in the app. This creates that
# one missing plan record, matching the Draft/Draft/version-1 pattern used
# for every other agency in database/seed/performance_plan_seed.sql, with
# the reviewer assignment from database/seed/reviewer_assignments.csv
# (Darren Lu) applied directly.

source("R/database.R", local = TRUE)

connection <- connect_app_database()
on.exit(DBI::dbDisconnect(connection), add = TRUE)

existing <- DBI::dbGetQuery(connection, "SELECT plan_id FROM planning.agency_plan WHERE agency_id = 'AGC4317'")
if (nrow(existing)) {
  cat("AGC4317 already has plan_id(s):", paste(existing$plan_id, collapse = ", "), "-- nothing to do.\n")
} else {
  reviewer <- DBI::dbGetQuery(connection, "SELECT user_id FROM access.\"user\" WHERE email = 'darren.lu@baltimorecity.gov'")
  reviewer_id <- if (nrow(reviewer)) reviewer$user_id[[1]] else NA_integer_

  DBI::dbWithTransaction(connection, {
    DBI::dbExecute(connection, "SELECT setval(pg_get_serial_sequence('planning.agency_plan', 'plan_id'), COALESCE((SELECT MAX(plan_id) FROM planning.agency_plan), 1), (SELECT COUNT(*) > 0 FROM planning.agency_plan))")
    result <- DBI::dbGetQuery(
      connection,
      paste(
        "INSERT INTO planning.agency_plan",
        "(agency_id, entity_id, cycle_id, plan_status, budget_status, version, assigned_reviewer)",
        "VALUES ('AGC4317', NULL, 4, 'Draft', 'Draft', 1, $1)",
        "RETURNING plan_id"
      ),
      params = list(reviewer_id)
    )
    cat("Created plan_id:", result$plan_id[[1]], "for AGC4317, cycle 4 (FY2027), reviewer_id:", reviewer_id, "\n")
  })
}
