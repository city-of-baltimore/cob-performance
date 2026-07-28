# Requirement added 2026-07-27, clarified 2026-07-27: a plan's selected
# measures (goal KPIs and service metrics) must have reported BOTH the
# most recently completed fiscal year's actual value AND its explanatory
# note, AND the upcoming budget year's target value AND its note (e.g.
# FY26 actual/notes, FY28 target/notes while FY27 is executing) before
# the plan can be published -- enforced both in the "Plan readiness"
# checklist (plan_measures_missing_required_fiscal_data() in app.R) and
# as a hard server-side gate in publish_agency_plan()
# (measure_ids_missing_required_fiscal_data() in R/database.R). Measures
# marked change_mapping = "New" this cycle are exempt, since they have
# nothing prior to report yet.
#
# Important: neither of these is required to save or submit an
# individual measure for approval -- validate_measure_submit_requirements()
# (a closure inside app.R's server(), not unit-testable outside a running
# session) must not block on them. It used to take
# (values, yearly_values, target_fy) and reject submission if the next
# year's target was missing; that check was removed since the requirement
# belongs to plan publish, not measure submit -- see the plan-level checks
# exercised below instead.

test_that("measure_ids_missing_required_fiscal_data flags a measure missing either value and exempts a New one", {
  skip_if_no_test_database()
  connection <- connect_app_database()

  agency_id <- DBI::dbGetQuery(connection, "SELECT agency_id FROM reference.agency LIMIT 1")$agency_id[[1]]
  cycle_id <- DBI::dbGetQuery(connection, "SELECT cycle_id FROM planning.plan_cycle LIMIT 1")$cycle_id[[1]]
  user_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]
  fy <- current_fiscal_year()
  actual_fy <- fy - 1L
  next_target_fy <- fy + 1L

  base_values <- list(
    measure_id = NULL, agency_id = agency_id, initial_cycle = cycle_id,
    measure_type = "Output", description = "d", data_source = "s", data_owner = "o",
    data_owner_role = "r", update_frequency = "Monthly", formula = "f", desired_direction = "Increase",
    baseline_value = 10, baseline_fy = fy - 4L, format_type = "Count", display_unit = NA_character_,
    context_required = "", replicability = TRUE, disaggregation = "", data_location = "",
    collection_method = "", how_data_used = "", why_meaningful = "", proxy_measure = "",
    improvement_notes = "", pillar_id = NA_integer_, pillar_goal_id = NA_integer_,
    is_city = FALSE, is_agency = FALSE, is_service = TRUE,
    approval_status = "Validated", submitted_for_approval_at = as.POSIXct(NA)
  )
  missing_actual_id <- save_measure_record(
    connection,
    c(base_values, list(title = "Fiscal-data test: missing actual", change_mapping = "Unchanged")),
    list(list(fiscal_year = next_target_fy, annual_actual = NA_real_, annual_actual_notes = "", target_value = 10, target_value_notes = "target explanation")),
    user_id, submit = FALSE, is_admin = TRUE
  )
  missing_target_id <- save_measure_record(
    connection,
    c(base_values, list(title = "Fiscal-data test: missing target", change_mapping = "Unchanged")),
    list(list(fiscal_year = actual_fy, annual_actual = 42, annual_actual_notes = "actual explanation", target_value = NA_real_, target_value_notes = "")),
    user_id, submit = FALSE, is_admin = TRUE
  )
  new_id <- save_measure_record(
    connection,
    c(base_values, list(title = "Fiscal-data test: new this cycle", change_mapping = "New")),
    list(), user_id, submit = FALSE, is_admin = TRUE
  )
  complete_id <- save_measure_record(
    connection,
    c(base_values, list(title = "Fiscal-data test: complete", change_mapping = "Unchanged")),
    list(
      list(fiscal_year = actual_fy, annual_actual = 42, annual_actual_notes = "actual explanation", target_value = NA_real_, target_value_notes = ""),
      list(fiscal_year = next_target_fy, annual_actual = NA_real_, annual_actual_notes = "", target_value = 10, target_value_notes = "target explanation")
    ),
    user_id, submit = FALSE, is_admin = TRUE
  )
  # Regression guard: both values present but notes left blank must still
  # count as missing -- the notes are required alongside the values, not
  # merely optional accompaniments.
  missing_notes_id <- save_measure_record(
    connection,
    c(base_values, list(title = "Fiscal-data test: values present, notes blank", change_mapping = "Unchanged")),
    list(
      list(fiscal_year = actual_fy, annual_actual = 42, annual_actual_notes = "", target_value = NA_real_, target_value_notes = ""),
      list(fiscal_year = next_target_fy, annual_actual = NA_real_, annual_actual_notes = "", target_value = 10, target_value_notes = "")
    ),
    user_id, submit = FALSE, is_admin = TRUE
  )
  # DELETEs must run before dbDisconnect() -- combined into one on.exit() so
  # registration order (which is exit order for add = TRUE) puts disconnect
  # last; otherwise a disconnect-then-query sequence corrupts the RPostgres
  # driver state badly enough to poison later tests' own connections too.
  on.exit(
    {
      ids <- c(missing_actual_id, missing_target_id, new_id, complete_id, missing_notes_id)
      placeholders <- paste0("$", seq_along(ids), collapse = ", ")
      id_params <- as.list(as.integer(ids))
      DBI::dbExecute(connection, sprintf("DELETE FROM performance.measure_actuals WHERE measure_id IN (%s)", placeholders), params = id_params)
      DBI::dbExecute(connection, sprintf("DELETE FROM performance.performance_measure WHERE measure_id IN (%s)", placeholders), params = id_params)
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )

  missing <- measure_ids_missing_required_fiscal_data(
    connection, c(missing_actual_id, missing_target_id, new_id, complete_id, missing_notes_id), actual_fy, next_target_fy
  )
  expect_setequal(missing, c(missing_actual_id, missing_target_id, missing_notes_id))
})

test_that("publish_agency_plan rejects publishing when a required measure is missing its recent actual or next target", {
  skip_if_no_test_database()
  connection <- connect_app_database()

  agency_id <- DBI::dbGetQuery(connection, "SELECT agency_id FROM reference.agency LIMIT 1")$agency_id[[1]]
  cycle_id <- DBI::dbGetQuery(connection, "SELECT cycle_id FROM planning.plan_cycle LIMIT 1")$cycle_id[[1]]
  user_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]
  fy <- current_fiscal_year()
  actual_fy <- fy - 1L
  next_target_fy <- fy + 1L

  plan_row <- DBI::dbGetQuery(connection, "SELECT plan_id, plan_status FROM planning.agency_plan LIMIT 1")
  plan_id <- plan_row$plan_id[[1]]
  original_status <- plan_row$plan_status[[1]]

  missing_id <- save_measure_record(
    connection,
    list(
      measure_id = NULL, agency_id = agency_id, initial_cycle = cycle_id,
      title = "Recent-actual test: blocks publish", measure_type = "Output", description = "d",
      data_source = "s", data_owner = "o", data_owner_role = "r", update_frequency = "Monthly",
      formula = "f", desired_direction = "Increase", baseline_value = 10, baseline_fy = fy - 4L,
      format_type = "Count", display_unit = NA_character_, context_required = "", replicability = TRUE,
      disaggregation = "", data_location = "", collection_method = "", how_data_used = "",
      why_meaningful = "", proxy_measure = "", improvement_notes = "", change_mapping = "Unchanged",
      pillar_id = NA_integer_, pillar_goal_id = NA_integer_, is_city = FALSE, is_agency = FALSE, is_service = TRUE,
      approval_status = "Validated", submitted_for_approval_at = as.POSIXct(NA)
    ),
    list(), user_id, submit = FALSE, is_admin = TRUE
  )
  DBI::dbExecute(connection, "UPDATE planning.agency_plan SET plan_status = 'Approved' WHERE plan_id = $1", params = list(plan_id))
  on.exit(
    {
      DBI::dbExecute(connection, "UPDATE planning.agency_plan SET plan_status = $2 WHERE plan_id = $1", params = list(plan_id, original_status))
      DBI::dbExecute(connection, "DELETE FROM performance.performance_measure WHERE measure_id = $1", params = list(missing_id))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )

  expect_error(
    publish_agency_plan(connection, plan_id, user_id, required_measure_ids = missing_id, actual_fy = actual_fy, next_target_fy = next_target_fy),
    "Cannot publish"
  )

  # The plan must still be Approved, not Published -- the rejection happens
  # before any mutation, so a failed publish attempt is a no-op.
  status_after <- DBI::dbGetQuery(connection, "SELECT plan_status FROM planning.agency_plan WHERE plan_id = $1", params = list(plan_id))$plan_status[[1]]
  expect_equal(status_after, "Approved")
})

test_that("plan_measures_missing_required_fiscal_data (readiness checklist) surfaces a goal KPI missing its recent actual", {
  skip_if_no_test_database()
  connection <- connect_app_database()

  goal_row <- DBI::dbGetQuery(connection, "SELECT agency_goal_id, plan_id FROM performance.agency_goal LIMIT 1")
  agency_goal_id <- goal_row$agency_goal_id[[1]]
  plan_id <- goal_row$plan_id[[1]]
  agency_id <- DBI::dbGetQuery(connection, "SELECT agency_id FROM reference.agency LIMIT 1")$agency_id[[1]]
  cycle_id <- DBI::dbGetQuery(connection, "SELECT cycle_id FROM planning.plan_cycle LIMIT 1")$cycle_id[[1]]
  user_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]
  fy <- current_fiscal_year()

  measure_id <- save_measure_record(
    connection,
    list(
      measure_id = NULL, agency_id = agency_id, initial_cycle = cycle_id,
      title = "Recent-actual test: goal KPI missing actual", measure_type = "Output", description = "d",
      data_source = "s", data_owner = "o", data_owner_role = "r", update_frequency = "Monthly",
      formula = "f", desired_direction = "Increase", baseline_value = 10, baseline_fy = fy - 4L,
      format_type = "Count", display_unit = NA_character_, context_required = "", replicability = TRUE,
      disaggregation = "", data_location = "", collection_method = "", how_data_used = "",
      why_meaningful = "", proxy_measure = "", improvement_notes = "", change_mapping = "Unchanged",
      pillar_id = NA_integer_, pillar_goal_id = NA_integer_, is_city = FALSE, is_agency = FALSE, is_service = TRUE,
      approval_status = "Validated", submitted_for_approval_at = as.POSIXct(NA)
    ),
    list(), user_id, submit = FALSE, is_admin = TRUE
  )
  DBI::dbExecute(
    connection,
    "INSERT INTO performance.pm_goal_link (measure_id, agency_goal_id) VALUES ($1, $2)",
    params = list(measure_id, agency_goal_id)
  )
  on.exit(
    {
      DBI::dbExecute(connection, "DELETE FROM performance.pm_goal_link WHERE measure_id = $1", params = list(measure_id))
      DBI::dbExecute(connection, "DELETE FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )

  db <- load_app_data(connection)
  plan <- db$planning_agency_plan[db$planning_agency_plan$plan_id == plan_id, , drop = FALSE][1, , drop = FALSE]
  goals <- db$performance_agency_goal[db$performance_agency_goal$plan_id == plan_id, , drop = FALSE]
  services <- plan_service_rows(db, plan)

  missing <- plan_measures_missing_required_fiscal_data(db, plan, goals, services)
  expect_true(measure_id %in% missing$measure_id)
})
