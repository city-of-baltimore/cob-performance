# Reported 2026-07-31 on a test plan ("Tiny Triumphs"): the review page
# showed two different overall scores at once -- "OVERALL SCORE: 0/100" in
# the summary card vs. "Current score: 81/100" in the autosave status
# line, both claiming the plan was fully scored (36 of 36). The autosave
# observer (plan_review_save_request) deliberately skips a server
# re-render on every scoring tick to avoid collapsing open goal/service
# drawers, patching only the non-reactive review_snapshot_cache -- but
# the summary card's "Overall score" text was never wired to update from
# that same save result, so it stayed frozen at whatever it showed on
# page load. Fixed in app.js (handlePlanReviewSaveResult) by patching the
# #review_overall_score_value element directly from the same message that
# already updates the status line.
#
# Separately, score_out_of_100() had a "score <= 4 means it's still on an
# old 1-4 scale, multiply by 25" heuristic left over from before the
# current weighted 0-100 rubric existed. overall_score has exactly one
# writer (save_plan_review_scores()) and it's always already 0-100, so
# this heuristic could only misfire -- a genuinely, correctly low score
# (e.g. 1.25 out of 100) was displayed as "31/100" instead of "1/100".

test_that("score_out_of_100 does not inflate a genuinely low current-scale score", {
  expect_equal(score_out_of_100(1.25), "1/100")
  expect_equal(score_out_of_100(3), "3/100")
  expect_equal(score_out_of_100(4), "4/100")
})

test_that("score_out_of_100 passes through ordinary and high scores unchanged", {
  expect_equal(score_out_of_100(0), "0/100")
  expect_equal(score_out_of_100(56.75), "57/100")
  expect_equal(score_out_of_100(100), "100/100")
})

test_that("score_out_of_100 reports 'Not scored' for NA", {
  expect_equal(score_out_of_100(NA_real_), "Not scored")
})
