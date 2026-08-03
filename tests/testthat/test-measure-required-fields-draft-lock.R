# Requested 2026-08-04: any measure missing a required field must be a
# Draft measure, but its historic fiscal-year data must stay locked --
# even if the measure was previously Validated and later gets forced back
# to Draft (e.g. a required field going missing). This is two mechanisms
# working together:
# - save_measure_record()'s required_fields_complete parameter forces
#   approval_status to "Draft" regardless of what the caller requested.
# - performance_measure.ever_validated_at is stamped once on first approval
#   (review_measure_record()) and never cleared by an ordinary Draft
#   downgrade, so measure_actual_is_locked()/measure_target_is_locked() --
#   which key off it, not the live approval_status -- keep historic data
#   locked through that downgrade. Only revert_measure_to_draft() (the
#   explicit SystemAdmin "undo, this was never really validated" action)
#   clears it, fully unlocking historic data again.
# Meanwhile measure_definition_is_locked() stays keyed on the LIVE status,
# not ever_validated_at -- a Draft-due-to-incomplete measure must still let
# its submitter fix the missing field.

test_that("measure_missing_required_fields flags every blank required field by label", {
  complete_values <- list(
    title = "A measure", description = "Definition", measure_type = "Output",
    desired_direction = "Increase", format_type = "Count", data_source = "Source",
    data_owner = "Owner", data_owner_role = "Role", update_frequency = "Monthly",
    formula = "Formula", data_location = "Location", collection_method = "Method",
    how_data_used = "Used", why_meaningful = "Meaningful"
  )
  expect_equal(measure_missing_required_fields(complete_values), character(0))

  incomplete_values <- complete_values
  incomplete_values$data_location <- ""
  incomplete_values$how_data_used <- NA_character_
  expect_equal(measure_missing_required_fields(incomplete_values), c("Data location", "How the data is used"))
})

test_that("measure_missing_required_fields does not flag a blank why_meaningful", {
  # Dropped 2026-08-04: 560 of 607 already-Validated measures in production
  # (92%) were blank on why_meaningful alone -- it was never actually
  # enforced in practice, so it's no longer required.
  values <- list(
    title = "A measure", description = "Definition", measure_type = "Output",
    desired_direction = "Increase", format_type = "Count", data_source = "Source",
    data_owner = "Owner", data_owner_role = "Role", update_frequency = "Monthly",
    formula = "Formula", data_location = "Location", collection_method = "Method",
    how_data_used = "Used", why_meaningful = ""
  )
  expect_equal(measure_missing_required_fields(values), character(0))
})

test_that("measure_ever_validated is TRUE only once a real timestamp is set", {
  expect_false(measure_ever_validated(NA))
  expect_false(measure_ever_validated(NA_real_))
  expect_false(measure_ever_validated(character(0)))
  expect_true(measure_ever_validated(Sys.time()))
})

test_that("save_measure_record forces Draft when required fields are incomplete, regardless of submit or prior status", {
  skip_if_no_test_database()
  connection <- connect_app_database()

  agency_id <- DBI::dbGetQuery(connection, "SELECT agency_id FROM reference.agency LIMIT 1")$agency_id[[1]]
  cycle_id <- DBI::dbGetQuery(connection, "SELECT cycle_id FROM planning.plan_cycle LIMIT 1")$cycle_id[[1]]
  user_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]
  fy <- current_fiscal_year()

  base_values <- list(
    measure_id = NULL, agency_id = agency_id, initial_cycle = cycle_id,
    title = "Required-fields test measure", measure_type = "Output", description = "Original description",
    data_source = "Original source", data_owner = "Owner A", data_owner_role = "Role A",
    update_frequency = "Monthly", formula = "Original formula", desired_direction = "Increase",
    baseline_value = 10, baseline_fy = fy - 4L, format_type = "Count", display_unit = NA_character_,
    context_required = "", replicability = TRUE, disaggregation = "", data_location = "somewhere",
    collection_method = "manual", how_data_used = "reporting", why_meaningful = "it matters", proxy_measure = "",
    improvement_notes = "", change_mapping = "New", pillar_id = NA_integer_, pillar_goal_id = NA_integer_,
    is_city = FALSE, is_agency = FALSE, is_service = TRUE,
    approval_status = "Draft", submitted_for_approval_at = as.POSIXct(NA)
  )
  yearly_values <- list(list(fiscal_year = fy - 1L, annual_actual = 100, annual_actual_notes = "", target_value = 90, target_value_notes = ""))

  measure_id <- save_measure_record(connection, base_values, yearly_values, user_id, submit = FALSE, is_admin = TRUE, required_fields_complete = TRUE)
  on.exit(
    {
      DBI::dbExecute(connection, "DELETE FROM performance.measure_actuals WHERE measure_id = $1", params = list(measure_id))
      DBI::dbExecute(connection, "DELETE FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )

  # A submit request with incomplete fields still lands on Draft, not
  # PendingApproval -- required_fields_complete overrides submit.
  incomplete_values <- base_values
  incomplete_values$measure_id <- measure_id
  incomplete_values$why_meaningful <- ""
  save_measure_record(connection, incomplete_values, yearly_values, user_id, submit = TRUE, is_admin = TRUE, required_fields_complete = FALSE)

  reloaded <- DBI::dbGetQuery(connection, "SELECT approval_status, submitted_for_approval_at FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
  expect_equal(reloaded$approval_status[[1]], "Draft")
  expect_true(is.na(reloaded$submitted_for_approval_at[[1]]))
})

test_that("historic fiscal-year data stays locked after a Validated measure is forced back to Draft, but the definition unlocks", {
  skip_if_no_test_database()
  connection <- connect_app_database()

  agency_id <- DBI::dbGetQuery(connection, "SELECT agency_id FROM reference.agency LIMIT 1")$agency_id[[1]]
  cycle_id <- DBI::dbGetQuery(connection, "SELECT cycle_id FROM planning.plan_cycle LIMIT 1")$cycle_id[[1]]
  user_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]
  fy <- current_fiscal_year()

  base_values <- list(
    measure_id = NULL, agency_id = agency_id, initial_cycle = cycle_id,
    title = "Ever-validated lock test measure", measure_type = "Output", description = "Original description",
    data_source = "Original source", data_owner = "Owner A", data_owner_role = "Role A",
    update_frequency = "Monthly", formula = "Original formula", desired_direction = "Increase",
    baseline_value = 10, baseline_fy = fy - 4L, format_type = "Count", display_unit = NA_character_,
    context_required = "", replicability = TRUE, disaggregation = "", data_location = "somewhere",
    collection_method = "manual", how_data_used = "reporting", why_meaningful = "it matters", proxy_measure = "",
    improvement_notes = "", change_mapping = "New", pillar_id = NA_integer_, pillar_goal_id = NA_integer_,
    is_city = FALSE, is_agency = FALSE, is_service = TRUE,
    approval_status = "Draft", submitted_for_approval_at = as.POSIXct(NA)
  )
  yearly_values <- list(
    list(fiscal_year = fy - 2L, annual_actual = 80, annual_actual_notes = "", target_value = 75, target_value_notes = "")
  )

  measure_id <- save_measure_record(connection, base_values, yearly_values, user_id, submit = FALSE, is_admin = TRUE)
  on.exit(
    {
      DBI::dbExecute(connection, "DELETE FROM review.measure_review WHERE measure_id = $1", params = list(measure_id))
      DBI::dbExecute(connection, "DELETE FROM performance.measure_actuals WHERE measure_id = $1", params = list(measure_id))
      DBI::dbExecute(connection, "DELETE FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )

  # Approve it -- stamps ever_validated_at.
  review_measure_record(connection, measure_id, "approve", reviewer_id = user_id)
  first_validation <- DBI::dbGetQuery(connection, "SELECT ever_validated_at, approval_status FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
  expect_equal(first_validation$approval_status[[1]], "Validated")
  expect_false(is.na(first_validation$ever_validated_at[[1]]))
  stamped_at <- first_validation$ever_validated_at[[1]]

  # An admin edit that leaves a required field blank forces it back to
  # Draft -- but ever_validated_at must NOT be cleared by this (only
  # revert_measure_to_draft() does that).
  admin_values <- base_values
  admin_values$measure_id <- measure_id
  admin_values$approval_status <- "Validated"
  admin_values$why_meaningful <- ""
  save_measure_record(connection, admin_values, yearly_values, user_id, submit = FALSE, is_admin = TRUE, required_fields_complete = FALSE)

  after_downgrade <- DBI::dbGetQuery(connection, "SELECT ever_validated_at, approval_status FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
  expect_equal(after_downgrade$approval_status[[1]], "Draft")
  expect_equal(after_downgrade$ever_validated_at[[1]], stamped_at)

  # A non-admin can now fix the definition (it's Draft, not Validated) --
  # but cannot rewrite the fully-historic actual, because ever_validated_at
  # is still set.
  non_admin_values <- admin_values
  # Reflects the measure's actual current status after the admin edit above
  # forced it to Draft -- collect_measure_form() always reads this fresh
  # from the DB in the real app, never a stale caller-supplied value.
  non_admin_values$approval_status <- "Draft"
  non_admin_values$why_meaningful <- "now filled in"
  non_admin_values$title <- "Edited by a non-admin while incomplete-Draft"
  tampered_yearly <- list(list(fiscal_year = fy - 2L, annual_actual = 999, annual_actual_notes = "tampered", target_value = 999, target_value_notes = "tampered"))
  save_measure_record(connection, non_admin_values, tampered_yearly, user_id, submit = FALSE, is_admin = FALSE, required_fields_complete = TRUE)

  reloaded <- DBI::dbGetQuery(connection, "SELECT title FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
  expect_equal(reloaded$title[[1]], "Edited by a non-admin while incomplete-Draft")

  actuals <- DBI::dbGetQuery(connection, "SELECT annual_actual, target_value FROM performance.measure_actuals WHERE measure_id = $1 AND fiscal_year = $2", params = list(measure_id, fy - 2L))
  expect_equal(actuals$annual_actual[[1]], 80)
  expect_equal(actuals$target_value[[1]], 75)
})

test_that("revert_measure_to_draft clears ever_validated_at, fully unlocking historic data again", {
  skip_if_no_test_database()
  connection <- connect_app_database()

  agency_id <- DBI::dbGetQuery(connection, "SELECT agency_id FROM reference.agency LIMIT 1")$agency_id[[1]]
  cycle_id <- DBI::dbGetQuery(connection, "SELECT cycle_id FROM planning.plan_cycle LIMIT 1")$cycle_id[[1]]
  user_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]
  fy <- current_fiscal_year()

  base_values <- list(
    measure_id = NULL, agency_id = agency_id, initial_cycle = cycle_id,
    title = "Revert-clears-lock test measure", measure_type = "Output", description = "Original description",
    data_source = "Original source", data_owner = "Owner A", data_owner_role = "Role A",
    update_frequency = "Monthly", formula = "Original formula", desired_direction = "Increase",
    baseline_value = 10, baseline_fy = fy - 4L, format_type = "Count", display_unit = NA_character_,
    context_required = "", replicability = TRUE, disaggregation = "", data_location = "somewhere",
    collection_method = "manual", how_data_used = "reporting", why_meaningful = "it matters", proxy_measure = "",
    improvement_notes = "", change_mapping = "New", pillar_id = NA_integer_, pillar_goal_id = NA_integer_,
    is_city = FALSE, is_agency = FALSE, is_service = TRUE,
    approval_status = "Draft", submitted_for_approval_at = as.POSIXct(NA)
  )
  yearly_values <- list(list(fiscal_year = fy - 2L, annual_actual = 80, annual_actual_notes = "", target_value = 75, target_value_notes = ""))

  measure_id <- save_measure_record(connection, base_values, yearly_values, user_id, submit = FALSE, is_admin = TRUE)
  on.exit(
    {
      DBI::dbExecute(connection, "DELETE FROM review.measure_review WHERE measure_id = $1", params = list(measure_id))
      DBI::dbExecute(connection, "DELETE FROM performance.measure_actuals WHERE measure_id = $1", params = list(measure_id))
      DBI::dbExecute(connection, "DELETE FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )

  review_measure_record(connection, measure_id, "approve", reviewer_id = user_id)
  revert_measure_to_draft(connection, measure_id)

  reloaded <- DBI::dbGetQuery(connection, "SELECT ever_validated_at, approval_status FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
  expect_equal(reloaded$approval_status[[1]], "Draft")
  expect_true(is.na(reloaded$ever_validated_at[[1]]))

  # Historic data is now fully unlocked for a non-admin too.
  reverted_values <- base_values
  reverted_values$measure_id <- measure_id
  reverted_values$approval_status <- "Draft"
  unlocked_yearly <- list(list(fiscal_year = fy - 2L, annual_actual = 500, annual_actual_notes = "corrected", target_value = 500, target_value_notes = "corrected"))
  save_measure_record(connection, reverted_values, unlocked_yearly, user_id, submit = FALSE, is_admin = FALSE, required_fields_complete = TRUE)

  actuals <- DBI::dbGetQuery(connection, "SELECT annual_actual FROM performance.measure_actuals WHERE measure_id = $1 AND fiscal_year = $2", params = list(measure_id, fy - 2L))
  expect_equal(actuals$annual_actual[[1]], 500)
})
