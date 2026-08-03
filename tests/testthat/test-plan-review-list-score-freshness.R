# Reported 2026-08-04: a plan's row in the review queue/publishing/approval
# list pages showed its overall_score exactly as of the last full
# refresh_app_data() -- scoring a plan, then navigating back to a list
# page, still showed the pre-save score. Autosave writes a fresh snapshot
# into a non-reactive review_snapshot_cache (deliberately not into
# app_data(), to avoid collapsing open goal/service scoring drawers on
# every keystroke -- see save_plan_review_scores() callers), and only the
# single plan_id actively open in the detail view ever got merged back in
# at render time. List pages read review_plan_review directly with no
# single plan_id to key off of, so they never picked up the fresher
# snapshot at all. Fixed by merging every outstanding cached snapshot, not
# just one.

test_that("merge_cached_review_snapshots updates every cached plan, not just one", {
  data <- list(
    review_plan_review = data.frame(review_id = c(101L, 102L), plan_id = c(1L, 2L), overall_score = c(40, 50)),
    review_section_score = data.frame(review_id = c(101L, 102L), section_code = c("S1", "S1"), score = c(2, 2))
  )
  cache <- new.env(parent = emptyenv())
  cache[["1"]] <- list(
    review = data.frame(review_id = 101L, plan_id = 1L, overall_score = 85),
    scores = data.frame(review_id = 101L, section_code = "S1", score = 4)
  )
  cache[["2"]] <- list(
    review = data.frame(review_id = 102L, plan_id = 2L, overall_score = 60),
    scores = data.frame(review_id = 102L, section_code = "S1", score = 3)
  )

  merged <- merge_cached_review_snapshots(data, cache)

  expect_equal(merged$review_plan_review$overall_score[merged$review_plan_review$plan_id == 1L], 85)
  expect_equal(merged$review_plan_review$overall_score[merged$review_plan_review$plan_id == 2L], 60)
  expect_equal(merged$review_section_score$score[merged$review_section_score$review_id == 101L], 4)
  expect_equal(merged$review_section_score$score[merged$review_section_score$review_id == 102L], 3)
})

test_that("merge_cached_review_snapshots is a no-op when nothing is cached", {
  data <- list(review_plan_review = data.frame(review_id = 101L, plan_id = 1L, overall_score = 40))
  cache <- new.env(parent = emptyenv())
  expect_equal(merge_cached_review_snapshots(data, cache), data)
})
