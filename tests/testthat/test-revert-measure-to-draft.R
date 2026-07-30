# SystemAdmin escape hatch (2026-07-30): a measure Validated by mistake, or
# that needs further edits, previously had no way back except a direct DB
# edit -- once Validated, its definition locks (see
# measure_definition_is_locked() and test-measure-validation-lock.R).
# revert_measure_to_draft() unlocks it again by moving it back to Draft.
# See the "Revert to Draft" button in measure_modal_ui() (SystemAdmin-only,
# shown only when the measure is currently Validated) and its handler in
# app.R's observeEvent(input$confirm_measure_revert_to_draft, ...).

test_that("revert_measure_to_draft moves a Validated measure back to Draft and clears validated/submission state", {
  skip_if_no_test_database()
  connection <- connect_app_database()

  agency_id <- DBI::dbGetQuery(connection, "SELECT agency_id FROM reference.agency LIMIT 1")$agency_id[[1]]
  cycle_id <- DBI::dbGetQuery(connection, "SELECT cycle_id FROM planning.plan_cycle LIMIT 1")$cycle_id[[1]]
  user_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]
  fy <- current_fiscal_year()

  measure_id <- save_measure_record(
    connection,
    list(
      measure_id = NULL, agency_id = agency_id, initial_cycle = cycle_id,
      title = "Revert to draft test measure", measure_type = "Output", description = "d",
      data_source = "s", data_owner = "o", data_owner_role = "r", update_frequency = "Monthly",
      formula = "f", desired_direction = "Increase", baseline_value = 10, baseline_fy = fy - 4L,
      format_type = "Count", display_unit = NA_character_, context_required = "", replicability = TRUE,
      disaggregation = "", data_location = "", collection_method = "", how_data_used = "",
      why_meaningful = "", proxy_measure = "", improvement_notes = "", change_mapping = "New",
      pillar_id = NA_integer_, pillar_goal_id = NA_integer_, is_city = FALSE, is_agency = FALSE, is_service = TRUE,
      approval_status = "Draft", submitted_for_approval_at = as.POSIXct(NA)
    ),
    list(list(fiscal_year = fy - 1L, annual_actual = 100, annual_actual_notes = "", target_value = 90, target_value_notes = "")),
    user_id, submit = FALSE, is_admin = TRUE
  )
  on.exit(
    {
      DBI::dbExecute(connection, "DELETE FROM performance.measure_actuals WHERE measure_id = $1", params = list(measure_id))
      DBI::dbExecute(connection, "DELETE FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )
  DBI::dbExecute(
    connection,
    "UPDATE performance.performance_measure SET approval_status = 'Validated', validated = true, submitted_for_approval_at = now() WHERE measure_id = $1",
    params = list(measure_id)
  )

  revert_measure_to_draft(connection, measure_id)

  reloaded <- DBI::dbGetQuery(
    connection,
    "SELECT approval_status, validated, submitted_for_approval_at FROM performance.performance_measure WHERE measure_id = $1",
    params = list(measure_id)
  )
  expect_equal(reloaded$approval_status[[1]], "Draft")
  expect_false(reloaded$validated[[1]])
  expect_true(is.na(reloaded$submitted_for_approval_at[[1]]))
})

test_that("revert_measure_to_draft errors instead of silently no-op-ing on a measure that isn't currently Validated", {
  skip_if_no_test_database()
  connection <- connect_app_database()

  agency_id <- DBI::dbGetQuery(connection, "SELECT agency_id FROM reference.agency LIMIT 1")$agency_id[[1]]
  cycle_id <- DBI::dbGetQuery(connection, "SELECT cycle_id FROM planning.plan_cycle LIMIT 1")$cycle_id[[1]]
  user_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]
  fy <- current_fiscal_year()

  measure_id <- save_measure_record(
    connection,
    list(
      measure_id = NULL, agency_id = agency_id, initial_cycle = cycle_id,
      title = "Already draft test measure", measure_type = "Output", description = "d",
      data_source = "s", data_owner = "o", data_owner_role = "r", update_frequency = "Monthly",
      formula = "f", desired_direction = "Increase", baseline_value = 10, baseline_fy = fy - 4L,
      format_type = "Count", display_unit = NA_character_, context_required = "", replicability = TRUE,
      disaggregation = "", data_location = "", collection_method = "", how_data_used = "",
      why_meaningful = "", proxy_measure = "", improvement_notes = "", change_mapping = "New",
      pillar_id = NA_integer_, pillar_goal_id = NA_integer_, is_city = FALSE, is_agency = FALSE, is_service = TRUE,
      approval_status = "Draft", submitted_for_approval_at = as.POSIXct(NA)
    ),
    list(list(fiscal_year = fy - 1L, annual_actual = 100, annual_actual_notes = "", target_value = 90, target_value_notes = "")),
    user_id, submit = FALSE, is_admin = TRUE
  )
  on.exit(
    {
      DBI::dbExecute(connection, "DELETE FROM performance.measure_actuals WHERE measure_id = $1", params = list(measure_id))
      DBI::dbExecute(connection, "DELETE FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )

  expect_error(revert_measure_to_draft(connection, measure_id), "not currently Validated")
})
