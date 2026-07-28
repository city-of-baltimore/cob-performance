# Reported 2026-07-28: percent measures used to be entered as decimal
# fractions (0.61 for 61%), but the app now requires whole numbers, and a
# stored value of exactly 1 displays as "1%" instead of the "100%" it was
# sometimes meant to be.
#
# Only a non-integer value is safe to convert automatically (*100) --
# confirmed against both local dev and production that zero Percent
# values >= 2 have any decimal precision, so any decimal-precision value
# unambiguously pre-dates the whole-number rule. A bare integer "1" is
# genuinely ambiguous (1% already correct, or 100% under the old
# convention) and is deliberately left untouched by this function --
# that call was made per-measure, per-row, by hand (see
# outputs/percent_*_review.xlsx, 2026-07-28), not by a blanket rule.
# See percent_value_scale_backfill() in R/database.R.

test_that("percent_value_scale_backfill scales non-integer values by 100 and leaves integers (including the ambiguous 1) untouched", {
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
      title = "Percent scale test measure", measure_type = "Output", description = "d",
      data_source = "s", data_owner = "o", data_owner_role = "r", update_frequency = "Monthly",
      formula = "f", desired_direction = "Increase", baseline_value = 10, baseline_fy = fy - 4L,
      format_type = "Percent", display_unit = NA_character_, context_required = "", replicability = TRUE,
      disaggregation = "", data_location = "", collection_method = "", how_data_used = "",
      why_meaningful = "", proxy_measure = "", improvement_notes = "", change_mapping = "New",
      pillar_id = NA_integer_, pillar_goal_id = NA_integer_, is_city = FALSE, is_agency = FALSE, is_service = TRUE,
      approval_status = "Draft", submitted_for_approval_at = as.POSIXct(NA)
    ),
    list(
      list(fiscal_year = fy - 3L, annual_actual = 0.61, annual_actual_notes = "", target_value = NA_real_, target_value_notes = ""),
      list(fiscal_year = fy - 2L, annual_actual = 1, annual_actual_notes = "", target_value = NA_real_, target_value_notes = ""),
      list(fiscal_year = fy - 1L, annual_actual = 45, annual_actual_notes = "", target_value = NA_real_, target_value_notes = ""),
      list(fiscal_year = fy, annual_actual = NA_real_, annual_actual_notes = "", target_value = 1.10, target_value_notes = "")
    ),
    user_id, submit = FALSE, is_admin = TRUE
  )
  # DELETEs must run before dbDisconnect() -- combined into one on.exit()
  # so registration order (which is exit order for add = TRUE) puts
  # disconnect last; otherwise a disconnect-then-query sequence corrupts
  # the RPostgres driver state badly enough to poison later tests' own
  # connections too.
  on.exit(
    {
      DBI::dbExecute(connection, "DELETE FROM performance.measure_actuals WHERE measure_id = $1", params = list(measure_id))
      DBI::dbExecute(connection, "DELETE FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )

  # Scoped to this one measure_id -- the shared dev database's real
  # percent data (and the seed-applied gate) are untouched by this test.
  percent_value_scale_backfill(connection, measure_ids = measure_id)

  actuals <- DBI::dbGetQuery(
    connection,
    "SELECT fiscal_year, annual_actual, target_value FROM performance.measure_actuals WHERE measure_id = $1 ORDER BY fiscal_year",
    params = list(measure_id)
  )
  # 0.61 -> 61 (non-integer, unambiguously a legacy fraction)
  expect_equal(actuals$annual_actual[actuals$fiscal_year == fy - 3L], 61)
  # 1 is a clean integer -- the ambiguous case -- left untouched
  expect_equal(actuals$annual_actual[actuals$fiscal_year == fy - 2L], 1)
  # 45 is already a whole number -- left untouched
  expect_equal(actuals$annual_actual[actuals$fiscal_year == fy - 1L], 45)
  # 1.10 is non-integer -- unambiguously a legacy fraction -- becomes 110
  expect_equal(actuals$target_value[actuals$fiscal_year == fy], 110)
})
