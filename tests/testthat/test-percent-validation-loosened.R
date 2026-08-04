# Reported 2026-08-04: auditing production for the "Average QA score"
# decimal-display bug found several measures storing a percent as a 0-1
# fraction under a non-Percent format_type. Fixing those surfaced that the
# app's own whole-numbers-only rule for Percent measures (added 2026-07-28,
# see test-percent-value-scale.R) would have blocked the corrected values
# (e.g. 96.66 rounds to 97, but 0.9666 * 100 = 96.66 exactly, non-whole) --
# and worse, several EXISTING Percent measures already had legitimate
# decimal values (an interest rate, a forecast accuracy rate) that were
# already silently non-compliant and would trip the rule on their next
# save. The whole-numbers rule never actually caught the 0-1-vs-0-100
# mistake anyway (97 and 9.7 both pass it) -- loosened to the same
# two-decimal precision as Currency/Count, with a new non-blocking warning
# (measure_values_with_suspicious_fraction()) that targets the real
# mistake directly.

test_that("validate_measure_values allows decimal precision on Percent, same as Currency/Count", {
  yearly_values <- list(
    list(fiscal_year = 2026L, annual_actual = 96.66, target_value = 97.5)
  )
  expect_null(validate_measure_values("Percent", yearly_values))
})

test_that("validate_measure_values still rejects out-of-range or over-precise Percent values", {
  expect_match(
    validate_measure_values("Percent", list(list(fiscal_year = 2026L, annual_actual = 105, target_value = NA_real_))),
    "from 0 to 100"
  )
  expect_match(
    validate_measure_values("Percent", list(list(fiscal_year = 2026L, annual_actual = 33.333, target_value = NA_real_))),
    "no more than two decimal places"
  )
})

test_that("validate_measure_values is unaffected for Currency/Count (unchanged precision rule)", {
  expect_null(validate_measure_values("Count", list(list(fiscal_year = 2026L, annual_actual = 4.25, target_value = NA_real_))))
  expect_match(
    validate_measure_values("Count", list(list(fiscal_year = 2026L, annual_actual = 4.256, target_value = NA_real_))),
    "no more than two decimal places"
  )
})

test_that("measure_values_with_suspicious_fraction flags a 0-1 value on a Percent measure by fiscal year and field", {
  yearly_values <- list(
    list(fiscal_year = 2024L, annual_actual = 0.97, target_value = 0.99),
    list(fiscal_year = 2025L, annual_actual = 45, target_value = NA_real_)
  )
  flagged <- measure_values_with_suspicious_fraction("Percent", yearly_values)
  expect_equal(flagged, c(paste0(fy_label(2024L), " actual"), paste0(fy_label(2024L), " target")))
})

test_that("measure_values_with_suspicious_fraction ignores 0, 1, and non-Percent measures", {
  yearly_values <- list(list(fiscal_year = 2024L, annual_actual = 0, target_value = 1))
  expect_equal(measure_values_with_suspicious_fraction("Percent", yearly_values), character(0))
  expect_equal(measure_values_with_suspicious_fraction("Count", list(list(fiscal_year = 2024L, annual_actual = 0.5, target_value = NA_real_))), character(0))
})
