# Regression guard for two fiscal-year column bugs in the measure history
# tables (kpi-history-table in app.R), both reported 2026-07-27:
#
# 1. actual_years and target_years overlapped at current_fy - 1, so a
#    measure's history table rendered two identical "FY26" columns.
# 2. The target window didn't look one fiscal year ahead of "today" --
#    while FY27 is executing, the org is already planning FY28, so the
#    target window must always reach current_fy + 1, not stop at current_fy.
#
# Convention: current_fy is the fiscal year currently executing (what
# current_fiscal_year() returns). The table always shows the four most
# recently completed actual years, then this year's and next year's
# target -- e.g. while FY27 is executing: FY23-FY26 Actual, FY27-FY28
# Target.

test_that("measure_preview_years produces six non-overlapping years, looking one fiscal year ahead", {
  years <- measure_preview_years(2027)
  expect_equal(years$actual_years, 2023:2026)
  expect_equal(years$target_years, 2027:2028)
  expect_length(intersect(years$actual_years, years$target_years), 0)
})

test_that("measure_preview_years scales with the fiscal year instead of hardcoding one", {
  years_2028 <- measure_preview_years(2028)
  years_2029 <- measure_preview_years(2029)
  expect_equal(years_2028$actual_years, 2024:2027)
  expect_equal(years_2028$target_years, 2028:2029)
  expect_equal(years_2029$actual_years, 2025:2028)
  expect_equal(years_2029$target_years, 2029:2030)
})

test_that("measure_preview_years defaults to current_fiscal_year(), not a hardcoded year", {
  expect_equal(measure_preview_years()$target_years[[1]], current_fiscal_year())
  expect_equal(measure_preview_years()$target_years[[2]], current_fiscal_year() + 1L)
})
