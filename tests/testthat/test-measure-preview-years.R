# Regression guard for the duplicated fiscal-year column bug reported
# 2026-07-27: actual_years and target_years overlapped at current_fy - 1,
# so a measure's history table rendered two identical "FY26" columns
# (see kpi-history-table in app.R). The budget-book convention is the four
# most recently completed actual years, then the current and upcoming
# budget year's targets -- e.g. for a FY28 budget book: FY23-FY26 Actual,
# FY27-FY28 Target.

test_that("measure_preview_years produces six non-overlapping years matching the budget-book layout", {
  years <- measure_preview_years(2028)
  expect_equal(years$actual_years, 2023:2026)
  expect_equal(years$target_years, 2027:2028)
  expect_length(intersect(years$actual_years, years$target_years), 0)
})

test_that("measure_preview_years scales with the fiscal year instead of hardcoding one", {
  years_2027 <- measure_preview_years(2027)
  years_2029 <- measure_preview_years(2029)
  expect_equal(years_2027$actual_years, 2022:2025)
  expect_equal(years_2027$target_years, 2026:2027)
  expect_equal(years_2029$actual_years, 2024:2027)
  expect_equal(years_2029$target_years, 2028:2029)
})

test_that("measure_preview_years defaults to current_fiscal_year(), not a hardcoded year", {
  expect_equal(measure_preview_years()$target_years[[2]], current_fiscal_year())
})
