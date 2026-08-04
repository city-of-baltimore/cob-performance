# Reported 2026-08-03 as "the application is down". The app was in fact serving
# fine; what was real was a flood of "NAs introduced by coercion to integer
# range" warnings in the production log, a few every minute.
#
# Cause: cls_format_commas() used formatC(x, format = "d"), which coerces its
# argument to a 32-bit integer. Any amount above 2,147,483,647 therefore
# rendered as "$NA" and warned on every render. Production had a request of
# $23,232,322,322 (a test entry) hitting it.
#
# This is not an edge case for this app. Baltimore's budget runs to billions, so
# the citywide "Total requested" card -- which sums every request -- would have
# shown "$NA" as soon as real data arrived. The fix is format = "f" with
# digits = 0, which stays in double precision.
#
# These tests need no database.

test_that("cls_format_commas separates thousands", {
  expect_equal(cls_format_commas(0), "$0")
  expect_equal(cls_format_commas(999), "$999")
  expect_equal(cls_format_commas(1000), "$1,000")
  expect_equal(cls_format_commas(60000), "$60,000")
  expect_equal(cls_format_commas(4023000), "$4,023,000")
})

test_that("cls_format_commas survives past the 32-bit integer ceiling", {
  # The exact boundary that formatC(format = "d") could not cross.
  expect_equal(cls_format_commas(2147483647), "$2,147,483,647")
  expect_equal(cls_format_commas(2147483648), "$2,147,483,648")
  # A city-scale total, which is the realistic case.
  expect_equal(cls_format_commas(4.2e9), "$4,200,000,000")
  # The value that was actually in production when this surfaced.
  expect_equal(cls_format_commas(23232322322), "$23,232,322,322")
})

test_that("cls_format_commas does not warn on large values", {
  # The regression showed up in the logs before it showed up on screen, so the
  # absence of a warning is part of the contract.
  expect_no_warning(cls_format_commas(23232322322))
  expect_no_warning(cls_format_commas(4.2e9))
})

test_that("cls_format_commas rounds rather than truncating, and handles no value", {
  expect_equal(cls_format_commas(1000.4), "$1,000")
  expect_equal(cls_format_commas(1000.6), "$1,001")
  expect_equal(cls_format_commas(NA), "—")
  expect_equal(cls_format_commas(NULL), "—")
  expect_equal(cls_format_commas("not a number"), "—")
})

test_that("cls_format_dollars also survives past the ceiling", {
  # Same class of bug would apply here; confirm it does not.
  expect_no_warning(cls_format_dollars(23232322322))
  expect_equal(cls_format_dollars(2147483648), "$2,147,483,648.00")
})
