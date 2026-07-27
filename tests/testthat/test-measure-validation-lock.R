# Once a performance measure is validated, it locks to SystemAdmin-only
# editing -- including all historic fiscal-year data and every definition
# field -- except the current fiscal year's actual (still being actively
# reported) and the following fiscal year's target (still being actively
# planned). See current_fiscal_year()/measure_actual_is_locked()/
# measure_target_is_locked()/measure_definition_is_locked() in
# R/database.R, enforced in app.R's collect_measure_form()/
# collect_measure_years() and again in save_measure_record() itself.

test_that("current_fiscal_year() rolls over on July 1, named by the ending calendar year", {
  expect_equal(current_fiscal_year(as.Date("2026-06-30")), 2026L)
  expect_equal(current_fiscal_year(as.Date("2026-07-01")), 2027L)
  expect_equal(current_fiscal_year(as.Date("2027-01-15")), 2027L)
  expect_equal(current_fiscal_year(as.Date("2027-06-30")), 2027L)
})

test_that("measure lock functions are validation- and date-driven, not static fiscal-year thresholds", {
  fy <- current_fiscal_year()

  expect_false(measure_actual_is_locked(fy - 5L, FALSE))
  expect_true(measure_actual_is_locked(fy - 5L, TRUE))
  expect_true(measure_actual_is_locked(fy - 1L, TRUE))
  expect_false(measure_actual_is_locked(fy, TRUE))

  expect_false(measure_target_is_locked(fy - 1L, FALSE))
  expect_true(measure_target_is_locked(fy - 1L, TRUE))
  expect_true(measure_target_is_locked(fy, TRUE))
  expect_false(measure_target_is_locked(fy + 1L, TRUE))

  expect_false(measure_definition_is_locked(FALSE))
  expect_true(measure_definition_is_locked(TRUE))
})

test_that("save_measure_record locks a validated measure's definition and historic data from non-admins, keeping the two open windows editable and the status intact", {
  skip_if_no_test_database()
  connection <- connect_app_database()

  agency_id <- DBI::dbGetQuery(connection, "SELECT agency_id FROM reference.agency LIMIT 1")$agency_id[[1]]
  cycle_id <- DBI::dbGetQuery(connection, "SELECT cycle_id FROM planning.plan_cycle LIMIT 1")$cycle_id[[1]]
  user_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]
  fy <- current_fiscal_year()

  base_values <- list(
    measure_id = NULL, agency_id = agency_id, initial_cycle = cycle_id,
    title = "Lock test measure", measure_type = "Output", description = "Original description",
    data_source = "Original source", data_owner = "Owner A", data_owner_role = "Role A",
    update_frequency = "Monthly", formula = "Original formula", desired_direction = "Increase",
    baseline_value = 10, baseline_fy = fy - 4L, format_type = "Count", display_unit = NA_character_,
    context_required = "", replicability = TRUE, disaggregation = "", data_location = "",
    collection_method = "", how_data_used = "", why_meaningful = "", proxy_measure = "",
    improvement_notes = "", change_mapping = "New", pillar_id = NA_integer_, pillar_goal_id = NA_integer_,
    is_city = FALSE, is_agency = FALSE, is_service = TRUE,
    approval_status = "Draft", submitted_for_approval_at = as.POSIXct(NA)
  )
  yearly_values <- list(
    list(fiscal_year = fy - 1L, annual_actual = 100, annual_actual_notes = "", target_value = 90, target_value_notes = ""),
    list(fiscal_year = fy, annual_actual = 50, annual_actual_notes = "", target_value = 95, target_value_notes = ""),
    list(fiscal_year = fy + 1L, annual_actual = NA_real_, annual_actual_notes = "", target_value = 120, target_value_notes = "")
  )

  measure_id <- save_measure_record(connection, base_values, yearly_values, user_id, submit = FALSE, is_admin = TRUE)
  # Cleanup queries and the disconnect must be in one on.exit (not two
  # separate calls) -- on.exit(add = TRUE) runs in registration order, so
  # a disconnect registered first would run before this cleanup and leave
  # it trying to query a dead connection (see the same note on the
  # save_service_risk test in test-audit-log.R).
  on.exit(
    {
      DBI::dbExecute(connection, "DELETE FROM performance.measure_actuals WHERE measure_id = $1", params = list(measure_id))
      DBI::dbExecute(connection, "DELETE FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )
  DBI::dbExecute(connection, "UPDATE performance.performance_measure SET approval_status = 'Validated', validated = true WHERE measure_id = $1", params = list(measure_id))

  # A non-admin's request tries to change everything: title/formula/scope
  # (definition), the historic year, and the current year's own target --
  # plus the two things that should genuinely be allowed to change.
  tampered_values <- base_values
  tampered_values$measure_id <- measure_id
  tampered_values$title <- "TAMPERED TITLE"
  tampered_values$formula <- "TAMPERED FORMULA"
  tampered_values$is_city <- TRUE
  tampered_values$approval_status <- "Validated"
  tampered_values$submitted_for_approval_at <- as.POSIXct(NA)
  tampered_yearly <- list(
    list(fiscal_year = fy - 1L, annual_actual = 999, annual_actual_notes = "tampered", target_value = 999, target_value_notes = "tampered"),
    list(fiscal_year = fy, annual_actual = 60, annual_actual_notes = "real update", target_value = 999, target_value_notes = "tampered"),
    list(fiscal_year = fy + 1L, annual_actual = NA_real_, annual_actual_notes = "", target_value = 130, target_value_notes = "planned")
  )

  save_measure_record(connection, tampered_values, tampered_yearly, user_id, submit = FALSE, is_admin = FALSE)

  reloaded <- DBI::dbGetQuery(connection, "SELECT title, formula, is_city, approval_status FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
  expect_equal(reloaded$title[[1]], "Lock test measure")
  expect_equal(reloaded$formula[[1]], "Original formula")
  expect_false(reloaded$is_city[[1]])
  # A non-admin's save on a validated measure can only ever touch the two
  # open windows -- it must not knock the measure back to Draft the way a
  # genuine content edit would.
  expect_equal(reloaded$approval_status[[1]], "Validated")

  actuals <- DBI::dbGetQuery(connection, "SELECT fiscal_year, annual_actual, target_value FROM performance.measure_actuals WHERE measure_id = $1 ORDER BY fiscal_year", params = list(measure_id))
  past <- actuals[actuals$fiscal_year == fy - 1L, , drop = FALSE]
  expect_equal(past$annual_actual[[1]], 100)
  expect_equal(past$target_value[[1]], 90)

  current <- actuals[actuals$fiscal_year == fy, , drop = FALSE]
  expect_equal(current$annual_actual[[1]], 60)
  expect_equal(current$target_value[[1]], 95)

  next_year <- actuals[actuals$fiscal_year == fy + 1L, , drop = FALSE]
  expect_equal(next_year$target_value[[1]], 130)
})

test_that("save_measure_record lets a SystemAdmin edit locked content on a validated measure, and re-requires validation", {
  skip_if_no_test_database()
  connection <- connect_app_database()

  agency_id <- DBI::dbGetQuery(connection, "SELECT agency_id FROM reference.agency LIMIT 1")$agency_id[[1]]
  cycle_id <- DBI::dbGetQuery(connection, "SELECT cycle_id FROM planning.plan_cycle LIMIT 1")$cycle_id[[1]]
  user_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]
  fy <- current_fiscal_year()

  base_values <- list(
    measure_id = NULL, agency_id = agency_id, initial_cycle = cycle_id,
    title = "Admin edit test measure", measure_type = "Output", description = "Original description",
    data_source = "Original source", data_owner = "Owner A", data_owner_role = "Role A",
    update_frequency = "Monthly", formula = "Original formula", desired_direction = "Increase",
    baseline_value = 10, baseline_fy = fy - 4L, format_type = "Count", display_unit = NA_character_,
    context_required = "", replicability = TRUE, disaggregation = "", data_location = "",
    collection_method = "", how_data_used = "", why_meaningful = "", proxy_measure = "",
    improvement_notes = "", change_mapping = "New", pillar_id = NA_integer_, pillar_goal_id = NA_integer_,
    is_city = FALSE, is_agency = FALSE, is_service = TRUE,
    approval_status = "Draft", submitted_for_approval_at = as.POSIXct(NA)
  )
  yearly_values <- list(list(fiscal_year = fy - 1L, annual_actual = 100, annual_actual_notes = "", target_value = 90, target_value_notes = ""))

  measure_id <- save_measure_record(connection, base_values, yearly_values, user_id, submit = FALSE, is_admin = TRUE)
  on.exit(
    {
      DBI::dbExecute(connection, "DELETE FROM performance.measure_actuals WHERE measure_id = $1", params = list(measure_id))
      DBI::dbExecute(connection, "DELETE FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )
  DBI::dbExecute(connection, "UPDATE performance.performance_measure SET approval_status = 'Validated', validated = true WHERE measure_id = $1", params = list(measure_id))

  admin_values <- base_values
  admin_values$measure_id <- measure_id
  admin_values$title <- "Admin-edited title"
  admin_values$approval_status <- "Validated"
  admin_values$submitted_for_approval_at <- as.POSIXct(NA)
  admin_yearly <- list(list(fiscal_year = fy - 1L, annual_actual = 150, annual_actual_notes = "corrected per admin review", target_value = 90, target_value_notes = ""))

  save_measure_record(connection, admin_values, admin_yearly, user_id, submit = FALSE, is_admin = TRUE)

  reloaded <- DBI::dbGetQuery(connection, "SELECT title, approval_status FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
  expect_equal(reloaded$title[[1]], "Admin-edited title")
  expect_equal(reloaded$approval_status[[1]], "Draft")

  actuals <- DBI::dbGetQuery(connection, "SELECT annual_actual FROM performance.measure_actuals WHERE measure_id = $1 AND fiscal_year = $2", params = list(measure_id, fy - 1L))
  expect_equal(actuals$annual_actual[[1]], 150)
})

test_that("a not-yet-validated measure is fully editable regardless of fiscal year", {
  skip_if_no_test_database()
  connection <- connect_app_database()

  agency_id <- DBI::dbGetQuery(connection, "SELECT agency_id FROM reference.agency LIMIT 1")$agency_id[[1]]
  cycle_id <- DBI::dbGetQuery(connection, "SELECT cycle_id FROM planning.plan_cycle LIMIT 1")$cycle_id[[1]]
  user_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]
  fy <- current_fiscal_year()

  base_values <- list(
    measure_id = NULL, agency_id = agency_id, initial_cycle = cycle_id,
    title = "Draft measure", measure_type = "Output", description = "Original description",
    data_source = "Original source", data_owner = "Owner A", data_owner_role = "Role A",
    update_frequency = "Monthly", formula = "Original formula", desired_direction = "Increase",
    baseline_value = 10, baseline_fy = fy - 4L, format_type = "Count", display_unit = NA_character_,
    context_required = "", replicability = FALSE, disaggregation = "", data_location = "",
    collection_method = "", how_data_used = "", why_meaningful = "", proxy_measure = "",
    improvement_notes = "", change_mapping = "New", pillar_id = NA_integer_, pillar_goal_id = NA_integer_,
    is_city = FALSE, is_agency = FALSE, is_service = TRUE,
    approval_status = "Draft", submitted_for_approval_at = as.POSIXct(NA)
  )
  yearly_values <- list(list(fiscal_year = fy - 1L, annual_actual = 100, annual_actual_notes = "", target_value = 90, target_value_notes = ""))

  measure_id <- save_measure_record(connection, base_values, yearly_values, user_id, submit = FALSE, is_admin = FALSE)
  on.exit(
    {
      DBI::dbExecute(connection, "DELETE FROM performance.measure_actuals WHERE measure_id = $1", params = list(measure_id))
      DBI::dbExecute(connection, "DELETE FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )

  edited_values <- base_values
  edited_values$measure_id <- measure_id
  edited_values$title <- "Edited by a regular user"
  edited_yearly <- list(list(fiscal_year = fy - 1L, annual_actual = 200, annual_actual_notes = "", target_value = 190, target_value_notes = ""))

  save_measure_record(connection, edited_values, edited_yearly, user_id, submit = FALSE, is_admin = FALSE)

  reloaded <- DBI::dbGetQuery(connection, "SELECT title FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
  expect_equal(reloaded$title[[1]], "Edited by a regular user")
  actuals <- DBI::dbGetQuery(connection, "SELECT annual_actual FROM performance.measure_actuals WHERE measure_id = $1 AND fiscal_year = $2", params = list(measure_id, fy - 1L))
  expect_equal(actuals$annual_actual[[1]], 200)
})
