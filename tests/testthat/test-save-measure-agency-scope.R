# Reported 2026-07-31: "Average Age of Fleet" (a DGS measure) ended up
# displayed as owned by OPI after a SystemAdmin checked "Citywide measure"
# on it. Root cause, in save_measure_record(): the UPDATE's WHERE clause
# required agency_id=$1, where $1 is values$agency_id -- for an EXISTING
# measure, that's current_agency_id() (whatever agency the CURRENT VIEWER
# happens to be acting as), not the measure's own agency_id. A SystemAdmin
# editing a measure from a different agency's context -- e.g. via the
# Action Plan Measures admin page, which deliberately lets an admin open
# any Citywide measure regardless of current context -- matched zero rows
# and silently saved nothing, with NO error surfaced. The caller went on to
# call ensure_measure_current_entity_link() anyway (since dbExecute matching
# 0 rows doesn't raise an error), which is how the measure ended up linked
# to the viewer's agency's entity while its own agency_id/is_city never
# actually changed. See also the ensure_measure_current_entity_link() fix
# in app.R, which independently guards against creating a cross-agency
# link even when a save DOES succeed.

test_that("save_measure_record lets an admin edit a measure regardless of the agency_id passed in, without touching the measure's own agency_id", {
  skip_if_no_test_database()
  connection <- connect_app_database()

  agencies <- DBI::dbGetQuery(connection, "SELECT agency_id FROM reference.agency LIMIT 2")$agency_id
  owning_agency_id <- agencies[[1]]
  viewer_agency_id <- agencies[[2]]
  cycle_id <- DBI::dbGetQuery(connection, "SELECT cycle_id FROM planning.plan_cycle LIMIT 1")$cycle_id[[1]]
  user_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]
  fy <- current_fiscal_year()

  base_values <- list(
    measure_id = NULL, agency_id = owning_agency_id, initial_cycle = cycle_id,
    title = "Agency scope test measure", measure_type = "Output", description = "d",
    data_source = "s", data_owner = "o", data_owner_role = "r", update_frequency = "Monthly",
    formula = "f", desired_direction = "Increase", baseline_value = 10, baseline_fy = fy - 4L,
    format_type = "Count", display_unit = NA_character_, context_required = "", replicability = TRUE,
    disaggregation = "", data_location = "", collection_method = "", how_data_used = "",
    why_meaningful = "", proxy_measure = "", improvement_notes = "", change_mapping = "New",
    pillar_id = NA_integer_, pillar_goal_id = NA_integer_, is_city = FALSE, is_agency = FALSE, is_service = TRUE,
    approval_status = "Draft", submitted_for_approval_at = as.POSIXct(NA)
  )
  measure_id <- save_measure_record(connection, base_values, list(), user_id, submit = FALSE, is_admin = TRUE)
  on.exit(
    {
      DBI::dbExecute(connection, "DELETE FROM performance.measure_actuals WHERE measure_id = $1", params = list(measure_id))
      DBI::dbExecute(connection, "DELETE FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )

  # An admin "viewing as" a different agency (values$agency_id reflects the
  # viewer, not the measure) still successfully edits the measure -- and
  # its own agency_id must NOT be silently changed to the viewer's agency.
  admin_edit <- base_values
  admin_edit$measure_id <- measure_id
  admin_edit$agency_id <- viewer_agency_id
  admin_edit$is_city <- TRUE
  save_measure_record(connection, admin_edit, list(), user_id, submit = FALSE, is_admin = TRUE)

  reloaded <- DBI::dbGetQuery(connection, "SELECT agency_id, is_city FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
  expect_equal(reloaded$agency_id[[1]], owning_agency_id)
  expect_true(reloaded$is_city[[1]])
})

test_that("save_measure_record errors instead of silently no-op-ing when a non-admin's agency_id doesn't match the measure's own", {
  skip_if_no_test_database()
  connection <- connect_app_database()

  agencies <- DBI::dbGetQuery(connection, "SELECT agency_id FROM reference.agency LIMIT 2")$agency_id
  owning_agency_id <- agencies[[1]]
  viewer_agency_id <- agencies[[2]]
  cycle_id <- DBI::dbGetQuery(connection, "SELECT cycle_id FROM planning.plan_cycle LIMIT 1")$cycle_id[[1]]
  user_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]
  fy <- current_fiscal_year()

  base_values <- list(
    measure_id = NULL, agency_id = owning_agency_id, initial_cycle = cycle_id,
    title = "Non-admin agency mismatch test measure", measure_type = "Output", description = "d",
    data_source = "s", data_owner = "o", data_owner_role = "r", update_frequency = "Monthly",
    formula = "f", desired_direction = "Increase", baseline_value = 10, baseline_fy = fy - 4L,
    format_type = "Count", display_unit = NA_character_, context_required = "", replicability = TRUE,
    disaggregation = "", data_location = "", collection_method = "", how_data_used = "",
    why_meaningful = "", proxy_measure = "", improvement_notes = "", change_mapping = "New",
    pillar_id = NA_integer_, pillar_goal_id = NA_integer_, is_city = FALSE, is_agency = FALSE, is_service = TRUE,
    approval_status = "Draft", submitted_for_approval_at = as.POSIXct(NA)
  )
  measure_id <- save_measure_record(connection, base_values, list(), user_id, submit = FALSE, is_admin = TRUE)
  on.exit(
    {
      DBI::dbExecute(connection, "DELETE FROM performance.measure_actuals WHERE measure_id = $1", params = list(measure_id))
      DBI::dbExecute(connection, "DELETE FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )

  non_admin_edit <- base_values
  non_admin_edit$measure_id <- measure_id
  non_admin_edit$agency_id <- viewer_agency_id

  expect_error(
    save_measure_record(connection, non_admin_edit, list(), user_id, submit = FALSE, is_admin = FALSE),
    "not found|permission"
  )
})
