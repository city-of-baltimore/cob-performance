# Clarified 2026-07-27: "New" means a measure was established during the
# CURRENT fiscal year, not "was ever marked New." Before this fix, a
# fresh measure got change_mapping = "New" once and kept it forever (or,
# for older imported measures with a blank change_mapping, would ALSO
# become "New" the first time anyone edited an unrelated field and
# re-saved them) -- exempting it from the recent-actual/next-target
# publish requirement indefinitely, regardless of how old it actually was.
# See measure_change_mapping_for_date() in R/database.R and its use in
# app.R's collect_measure_form(), plus the one-time backfill in
# scripts/backfill_change_mapping_by_created_date.R.

test_that("fiscal_year_start_date returns July 1 of the calendar year before the given fiscal year", {
  expect_equal(fiscal_year_start_date(2027), as.Date("2026-07-01"))
  expect_equal(fiscal_year_start_date(2026), as.Date("2025-07-01"))
})

test_that("measure_change_mapping_for_date reclassifies an old 'New' measure to Unchanged once its fiscal year has passed", {
  fy_start <- fiscal_year_start_date(current_fiscal_year())

  # Created before the current fiscal year started -- should not stay New,
  # regardless of what it's currently marked.
  expect_equal(measure_change_mapping_for_date("New", fy_start - 1), "Unchanged")
  expect_equal(measure_change_mapping_for_date(NA_character_, fy_start - 1), "Unchanged")

  # Created on or after the current fiscal year's start -- genuinely new.
  expect_equal(measure_change_mapping_for_date("New", fy_start), "New")
  expect_equal(measure_change_mapping_for_date(NA_character_, fy_start), "New")
  expect_equal(measure_change_mapping_for_date(NA_character_, fy_start + 30), "New")
})

test_that("measure_change_mapping_for_date never touches a real classification", {
  fy_start <- fiscal_year_start_date(current_fiscal_year())
  for (status in c("Removed", "Replaced", "Modified", "Unchanged")) {
    expect_equal(measure_change_mapping_for_date(status, fy_start - 1000), status)
    expect_equal(measure_change_mapping_for_date(status, fy_start), status)
  }
})

test_that("measure_change_mapping_for_date treats a missing created_date as New rather than erroring", {
  expect_equal(measure_change_mapping_for_date(NA_character_, NA), "New")
})

test_that("save_measure_record reclassifies an existing 'New' measure to Unchanged once its fiscal year has passed", {
  skip_if_no_test_database()
  connection <- connect_app_database()

  agency_id <- DBI::dbGetQuery(connection, "SELECT agency_id FROM reference.agency LIMIT 1")$agency_id[[1]]
  cycle_id <- DBI::dbGetQuery(connection, "SELECT cycle_id FROM planning.plan_cycle LIMIT 1")$cycle_id[[1]]
  user_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]
  fy <- current_fiscal_year()

  base_values <- list(
    measure_id = NULL, agency_id = agency_id, initial_cycle = cycle_id,
    title = "Change-mapping test measure", measure_type = "Output", description = "d",
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
      DBI::dbExecute(connection, "DELETE FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )

  # Backdate created_date to before the current fiscal year, simulating a
  # measure that was "New" last cycle and never got touched since.
  DBI::dbExecute(
    connection,
    "UPDATE performance.performance_measure SET created_date = $2 WHERE measure_id = $1",
    params = list(measure_id, fiscal_year_start_date(fy) - 1)
  )

  reloaded_existing <- DBI::dbGetQuery(
    connection,
    "SELECT change_mapping, created_date FROM performance.performance_measure WHERE measure_id = $1",
    params = list(measure_id)
  )
  recomputed <- measure_change_mapping_for_date(reloaded_existing$change_mapping[[1]], reloaded_existing$created_date[[1]])
  expect_equal(recomputed, "Unchanged")

  # Mirrors what collect_measure_form() does on save: recompute from the
  # existing row before writing.
  base_values$measure_id <- measure_id
  base_values$change_mapping <- recomputed
  save_measure_record(connection, base_values, list(), user_id, submit = FALSE, is_admin = TRUE)

  reloaded <- DBI::dbGetQuery(connection, "SELECT change_mapping FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
  expect_equal(reloaded$change_mapping[[1]], "Unchanged")
})
