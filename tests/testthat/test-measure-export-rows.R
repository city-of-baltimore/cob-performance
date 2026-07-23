# Covers the two CSV export buttons on the Measure Review page
# (measure_validation_export_rows / measure_data_export_rows). Both were
# verified against real data before shipping; these fixtures pin that
# verified shape (columns, sort order, NA handling) so a future change can't
# silently drop a column or break the export without a test failing.

fake_db_with_measures <- function() {
  list(
    reference_agency = data.frame(
      agency_id = c("AGC0001", "AGC0002"),
      agency_name = c("Zebra Agency", "Apple Agency"),
      public_name = c(NA_character_, NA_character_),
      stringsAsFactors = FALSE
    ),
    performance_performance_measure = data.frame(
      measure_id = c(1L, 2L, 3L),
      title = c("Zebra measure", "Apple measure", "Another apple measure"),
      agency_id = c("AGC0001", "AGC0002", "AGC0002"),
      approval_status = c("Approved", "Draft", "Approved"),
      validated = c(TRUE, FALSE, TRUE),
      active = c(TRUE, TRUE, FALSE),
      format_type = c("Number", "Percent", "Number"),
      display_unit = c("visits", "%", "cases"),
      submitted_for_approval_at = as.POSIXct(c("2027-01-01", NA, "2027-02-01"), tz = "UTC"),
      last_updated = as.POSIXct(c("2027-01-02", "2027-01-03", "2027-02-02"), tz = "UTC"),
      stringsAsFactors = FALSE
    ),
    performance_measure_actuals = data.frame(
      measure_id = c(1L, 2L, 2L),
      fiscal_year = c(2026L, 2025L, 2026L),
      annual_actual = c(100, NA, 50),
      annual_actual_notes = c("note a", NA, "note b"),
      target_value = c(90, 40, 55),
      target_value_notes = c(NA, "target note", NA),
      stringsAsFactors = FALSE
    )
  )
}

test_that("measure_validation_export_rows includes every expected column", {
  rows <- measure_validation_export_rows(fake_db_with_measures())
  expect_setequal(
    names(rows),
    c("measure_id", "title", "agency_id", "agency_name", "approval_status", "validated", "active", "submitted_for_approval_at", "last_updated")
  )
  expect_equal(nrow(rows), 3)
})

test_that("measure_validation_export_rows sorts by agency_name then title", {
  rows <- measure_validation_export_rows(fake_db_with_measures())
  expect_equal(rows$agency_name, c("Apple Agency", "Apple Agency", "Zebra Agency"))
  expect_equal(rows$title, c("Another apple measure", "Apple measure", "Zebra measure"))
})

test_that("measure_validation_export_rows resolves agency_name via agency_name()", {
  rows <- measure_validation_export_rows(fake_db_with_measures())
  expect_true(all(rows$agency_name %in% c("Zebra Agency", "Apple Agency")))
})

test_that("measure_data_export_rows does not include validation history columns", {
  rows <- measure_data_export_rows(fake_db_with_measures())
  expect_false(any(c("approval_status", "validated") %in% names(rows)))
  expect_setequal(
    names(rows),
    c("measure_id", "title", "agency_id", "agency_name", "format_type", "display_unit", "fiscal_year", "annual_actual", "annual_actual_notes", "target_value", "target_value_notes")
  )
})

test_that("measure_data_export_rows produces one row per measure x fiscal year and sorts by agency_name, title, fiscal_year", {
  rows <- measure_data_export_rows(fake_db_with_measures())
  expect_equal(nrow(rows), 3)
  expect_equal(rows$measure_id, c(2L, 2L, 1L))
  expect_equal(rows$fiscal_year, c(2025L, 2026L, 2026L))
})

test_that("measure_data_export_rows preserves NA actuals rather than dropping them", {
  rows <- measure_data_export_rows(fake_db_with_measures())
  na_actual_row <- rows[rows$measure_id == 2 & rows$fiscal_year == 2025, ]
  expect_equal(nrow(na_actual_row), 1)
  expect_true(is.na(na_actual_row$annual_actual))
})
