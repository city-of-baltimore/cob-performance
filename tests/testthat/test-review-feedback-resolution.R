# Reported 2026-08-05: review.section_feedback has a resolved_at column
# that nothing in the app ever wrote to, so a plan reviewed/returned/
# resubmitted more than once kept surfacing the SAME feedback from its
# very first review round forever -- confirmed in production (Tiny
# Triumphs had 3 real feedback rows a full month stale, still at the top
# of every export). Fixed by having submit_agency_plan() (the one
# function that already knows a plan is re-entering review) stamp
# resolved_at on anything still outstanding, and by having
# review_notes_summary() actually exclude resolved rows instead of just
# sorting them last.

test_that("review_notes_summary excludes resolved feedback but still shows unresolved feedback", {
  feedback <- data.frame(
    feedback_id = 1:2,
    review_id = 11L,
    section_code = "Goals",
    feedback_text = c("Resolved in a prior round.", "Still outstanding."),
    return_required = TRUE,
    resolved_at = as.POSIXct(c("2026-07-06 10:00:00", NA), tz = "UTC"),
    stringsAsFactors = FALSE
  )
  review_bits <- list(feedback = feedback, scores = data.frame())
  notes <- review_notes_summary(review_bits)
  expect_equal(notes, "Still outstanding.")
})

test_that("review_notes_summary falls back to low-score justifications once resolved feedback is excluded", {
  feedback <- data.frame(
    feedback_id = 1L, review_id = 11L, section_code = "Goals",
    feedback_text = "Resolved in a prior round.", return_required = TRUE,
    resolved_at = as.POSIXct("2026-07-06 10:00:00", tz = "UTC"),
    stringsAsFactors = FALSE
  )
  scores <- data.frame(
    section_code = "S3", criterion_code = "FAMMEAS", score = 2L, weighted_score = 2.5,
    justification = "Needs more variety in measure types.", stringsAsFactors = FALSE
  )
  review_bits <- list(feedback = feedback, scores = scores)
  notes <- review_notes_summary(review_bits)
  expect_equal(notes, "S3 FAMMEAS - Needs more variety in measure types.")
})

test_that("review_notes_summary reports no notes once everything is resolved and nothing scored low", {
  feedback <- data.frame(
    feedback_id = 1L, review_id = 11L, section_code = "Goals",
    feedback_text = "Resolved in a prior round.", return_required = TRUE,
    resolved_at = as.POSIXct("2026-07-06 10:00:00", tz = "UTC"),
    stringsAsFactors = FALSE
  )
  review_bits <- list(feedback = feedback, scores = data.frame())
  notes <- review_notes_summary(review_bits)
  expect_equal(notes, "No improvement notes have been released.")
})

test_that("submit_agency_plan resolves outstanding feedback on the plan's current review", {
  skip_if_no_test_database()
  connection <- connect_app_database()

  plan_row <- DBI::dbGetQuery(connection, "SELECT plan_id, plan_status FROM planning.agency_plan LIMIT 1")
  plan_id <- plan_row$plan_id[[1]]
  original_status <- plan_row$plan_status[[1]]
  user_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]

  review_id <- DBI::dbGetQuery(
    connection,
    "INSERT INTO review.plan_review (plan_id, reviewer_id, review_started_at, overall_score, review_complete) VALUES ($1, $2, now(), 50, false) RETURNING review_id",
    params = list(plan_id, user_id)
  )$review_id[[1]]
  feedback_ids <- DBI::dbGetQuery(
    connection,
    "INSERT INTO review.section_feedback (review_id, section_code, feedback_text, return_required) VALUES ($1, 'Goals', 'Fix this before resubmitting.', true) RETURNING feedback_id",
    params = list(review_id)
  )$feedback_id[[1]]

  DBI::dbExecute(connection, "UPDATE planning.agency_plan SET plan_status = 'Returned' WHERE plan_id = $1", params = list(plan_id))
  on.exit(
    {
      DBI::dbExecute(connection, "UPDATE planning.agency_plan SET plan_status = $2 WHERE plan_id = $1", params = list(plan_id, original_status))
      DBI::dbExecute(connection, "DELETE FROM review.section_feedback WHERE feedback_id = $1", params = list(feedback_ids))
      DBI::dbExecute(connection, "DELETE FROM review.plan_review WHERE review_id = $1", params = list(review_id))
      DBI::dbExecute(connection, "DELETE FROM workflow.plan_status_history WHERE plan_id = $1 AND to_status = 'Submitted' AND notes = 'Submitted from agency workspace.'", params = list(plan_id))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )

  before <- DBI::dbGetQuery(connection, "SELECT resolved_at FROM review.section_feedback WHERE feedback_id = $1", params = list(feedback_ids))
  expect_true(is.na(before$resolved_at[[1]]))

  submit_agency_plan(connection, plan_id, submitted_by = user_id)

  after <- DBI::dbGetQuery(connection, "SELECT resolved_at FROM review.section_feedback WHERE feedback_id = $1", params = list(feedback_ids))
  expect_false(is.na(after$resolved_at[[1]]))
})

test_that("submit_agency_plan does not touch another plan's feedback", {
  skip_if_no_test_database()
  connection <- connect_app_database()

  plans <- DBI::dbGetQuery(connection, "SELECT plan_id, plan_status FROM planning.agency_plan LIMIT 2")
  skip_if(nrow(plans) < 2, "Needs at least two plans in the test database")
  plan_id <- plans$plan_id[[1]]
  other_plan_id <- plans$plan_id[[2]]
  original_status <- plans$plan_status[[1]]
  user_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]

  other_review_id <- DBI::dbGetQuery(
    connection,
    "INSERT INTO review.plan_review (plan_id, reviewer_id, review_started_at, overall_score, review_complete) VALUES ($1, $2, now(), 50, false) RETURNING review_id",
    params = list(other_plan_id, user_id)
  )$review_id[[1]]
  other_feedback_id <- DBI::dbGetQuery(
    connection,
    "INSERT INTO review.section_feedback (review_id, section_code, feedback_text, return_required) VALUES ($1, 'Goals', 'Belongs to a different plan entirely.', true) RETURNING feedback_id",
    params = list(other_review_id)
  )$feedback_id[[1]]

  DBI::dbExecute(connection, "UPDATE planning.agency_plan SET plan_status = 'Returned' WHERE plan_id = $1", params = list(plan_id))
  on.exit(
    {
      DBI::dbExecute(connection, "UPDATE planning.agency_plan SET plan_status = $2 WHERE plan_id = $1", params = list(plan_id, original_status))
      DBI::dbExecute(connection, "DELETE FROM review.section_feedback WHERE feedback_id = $1", params = list(other_feedback_id))
      DBI::dbExecute(connection, "DELETE FROM review.plan_review WHERE review_id = $1", params = list(other_review_id))
      DBI::dbExecute(connection, "DELETE FROM workflow.plan_status_history WHERE plan_id = $1 AND to_status = 'Submitted' AND notes = 'Submitted from agency workspace.'", params = list(plan_id))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )

  submit_agency_plan(connection, plan_id, submitted_by = user_id)

  other_after <- DBI::dbGetQuery(connection, "SELECT resolved_at FROM review.section_feedback WHERE feedback_id = $1", params = list(other_feedback_id))
  expect_true(is.na(other_after$resolved_at[[1]]))
})
