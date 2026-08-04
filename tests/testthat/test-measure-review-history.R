# Reported 2026-08-04: a measure returned more than once only ever showed
# the latest round's reviewer feedback (latest_measure_review()'s [1,]
# slice) in the agency-side measure editor modal, losing earlier rounds'
# comments even though every row was already loaded into
# db$review_measure_review. Fixed by adding measure_reviews_for() (full
# history, newest first) and measure_review_history_blocks() (renders every
# entry that actually has feedback), and wiring the modal's "Reviewer
# Feedback" section to those instead of the single-row helper.

review_rows_fixture <- function() {
  data.frame(
    measure_review_id = 1:4,
    measure_id = c(10L, 10L, 10L, 20L),
    reviewer_id = 1L,
    reviewer_name = "Reviewer One",
    decision = c("Returned", "Returned", "Approved", "Returned"),
    feedback = c("First round: fix the data source.", "Second round: still missing a formula.", NA_character_, "Different measure entirely."),
    reviewed_at = as.POSIXct(c("2026-07-01 10:00:00", "2026-07-15 10:00:00", "2026-07-20 10:00:00", "2026-07-10 10:00:00"), tz = "UTC"),
    created_at = as.POSIXct(c("2026-07-01 10:00:00", "2026-07-15 10:00:00", "2026-07-20 10:00:00", "2026-07-10 10:00:00"), tz = "UTC"),
    stringsAsFactors = FALSE
  )
}

test_that("measure_reviews_for returns every row for a measure, newest first", {
  db <- list(review_measure_review = review_rows_fixture())
  result <- measure_reviews_for(db, 10L)
  expect_equal(nrow(result), 3)
  expect_equal(result$measure_review_id, c(3, 2, 1))
})

test_that("measure_reviews_for returns an empty data frame when there's no history", {
  db <- list(review_measure_review = review_rows_fixture())
  result <- measure_reviews_for(db, 999L)
  expect_equal(nrow(result), 0)
})

test_that("latest_measure_review still returns only the single newest row", {
  db <- list(review_measure_review = review_rows_fixture())
  result <- latest_measure_review(db, 10L)
  expect_equal(nrow(result), 1)
  expect_equal(result$measure_review_id[[1]], 3)
})

test_that("measure_review_history_blocks renders every entry with feedback, newest first, skipping blank ones", {
  reviews <- measure_reviews_for(list(review_measure_review = review_rows_fixture()), 10L)
  blocks <- measure_review_history_blocks(reviews)
  # The Approved row (measure_review_id 3) has NA feedback and must be skipped,
  # leaving the two Returned rows -- newest (second round) first.
  expect_equal(length(blocks), 2)
  html <- vapply(blocks, function(b) as.character(b), character(1))
  expect_true(grepl("still missing a formula", html[[1]], fixed = TRUE))
  expect_true(grepl("fix the data source", html[[2]], fixed = TRUE))
  # Only the first (newest) entry should be missing the "past" styling class.
  expect_false(grepl("measure-review-history-entry-past", html[[1]], fixed = TRUE))
  expect_true(grepl("measure-review-history-entry-past", html[[2]], fixed = TRUE))
})

test_that("measure_review_history_blocks returns NULL when there's no feedback at all", {
  reviews <- data.frame(
    measure_review_id = 1L,
    measure_id = 10L,
    reviewer_id = 1L,
    reviewer_name = "Reviewer One",
    decision = "Approved",
    feedback = NA_character_,
    reviewed_at = Sys.time(),
    created_at = Sys.time(),
    stringsAsFactors = FALSE
  )
  expect_null(measure_review_history_blocks(reviews))
  expect_null(measure_review_history_blocks(data.frame()))
})
