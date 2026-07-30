# Reported 2026-07-30: a reviewer cleared several plan review scores and
# notes, and when they clicked away (triggering the debounced autosave),
# the old values silently reappeared. Root cause, in
# save_plan_review_scores(): (1) it refused to save at all once every
# score ended up blank ("Enter at least one valid score before saving."),
# and (2) even when saving succeeded, its persistence loop only
# UPDATE/INSERTed criteria with a currently-valid (non-NA) score -- a
# criterion cleared back to blank was silently skipped, leaving its old
# review.section_score row untouched, so the stale score/justification
# was exactly what the form read back on the next render. Fixed by
# removing the all-blank guard and iterating every criterion
# collect_plan_review_scores() reports (not just the ones with a valid
# score), so an existing row is always brought in sync with the current
# (possibly now-blank) state.

test_that("save_plan_review_scores succeeds even when every score is blank", {
  skip_if_no_test_database()
  connection <- connect_app_database()

  cycle_id <- DBI::dbGetQuery(connection, "SELECT cycle_id FROM planning.plan_cycle LIMIT 1")$cycle_id[[1]]
  user_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]
  # An agency with no existing plan for this cycle -- (agency_id, cycle_id)
  # is unique, so reusing an agency that already has one would collide.
  agency_id <- DBI::dbGetQuery(
    connection,
    paste(
      "SELECT a.agency_id FROM reference.agency a",
      "WHERE NOT EXISTS (SELECT 1 FROM planning.agency_plan ap WHERE ap.agency_id = a.agency_id AND ap.cycle_id = $1)",
      "LIMIT 1"
    ),
    params = list(cycle_id)
  )$agency_id[[1]]

  plan <- DBI::dbGetQuery(
    connection,
    "INSERT INTO planning.agency_plan (agency_id, cycle_id, plan_status, budget_status) VALUES ($1, $2, 'Submitted', 'Draft') RETURNING plan_id",
    params = list(agency_id, cycle_id)
  )
  plan_id <- plan$plan_id[[1]]
  on.exit(
    {
      DBI::dbExecute(connection, "DELETE FROM review.section_score WHERE review_id IN (SELECT review_id FROM review.plan_review WHERE plan_id = $1)", params = list(plan_id))
      DBI::dbExecute(connection, "DELETE FROM review.plan_review WHERE plan_id = $1", params = list(plan_id))
      DBI::dbExecute(connection, "DELETE FROM planning.agency_plan WHERE plan_id = $1", params = list(plan_id))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )

  all_blank <- list(
    list(section_code = "S1", criterion_code = "C1", target_type = "plan", target_id = NA_integer_, score = NA_integer_, weight = 10, justification = "")
  )
  expect_no_error(save_plan_review_scores(connection, plan_id, user_id, all_blank, ""))
})

test_that("save_plan_review_scores clears a previously-saved score and justification, not just skips them", {
  skip_if_no_test_database()
  connection <- connect_app_database()

  cycle_id <- DBI::dbGetQuery(connection, "SELECT cycle_id FROM planning.plan_cycle LIMIT 1")$cycle_id[[1]]
  user_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]
  # An agency with no existing plan for this cycle -- (agency_id, cycle_id)
  # is unique, so reusing an agency that already has one would collide.
  agency_id <- DBI::dbGetQuery(
    connection,
    paste(
      "SELECT a.agency_id FROM reference.agency a",
      "WHERE NOT EXISTS (SELECT 1 FROM planning.agency_plan ap WHERE ap.agency_id = a.agency_id AND ap.cycle_id = $1)",
      "LIMIT 1"
    ),
    params = list(cycle_id)
  )$agency_id[[1]]

  plan <- DBI::dbGetQuery(
    connection,
    "INSERT INTO planning.agency_plan (agency_id, cycle_id, plan_status, budget_status) VALUES ($1, $2, 'Submitted', 'Draft') RETURNING plan_id",
    params = list(agency_id, cycle_id)
  )
  plan_id <- plan$plan_id[[1]]
  on.exit(
    {
      DBI::dbExecute(connection, "DELETE FROM review.section_score WHERE review_id IN (SELECT review_id FROM review.plan_review WHERE plan_id = $1)", params = list(plan_id))
      DBI::dbExecute(connection, "DELETE FROM review.plan_review WHERE plan_id = $1", params = list(plan_id))
      DBI::dbExecute(connection, "DELETE FROM planning.agency_plan WHERE plan_id = $1", params = list(plan_id))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )

  scored <- list(
    list(section_code = "S1", criterion_code = "C1", target_type = "plan", target_id = NA_integer_, score = 3, weight = 10, justification = "Solid overview")
  )
  save_plan_review_scores(connection, plan_id, user_id, scored, "notes")

  review_id <- DBI::dbGetQuery(connection, "SELECT review_id FROM review.plan_review WHERE plan_id = $1", params = list(plan_id))$review_id[[1]]
  saved <- DBI::dbGetQuery(
    connection,
    "SELECT score, justification FROM review.section_score WHERE review_id = $1 AND section_code = 'S1' AND criterion_code = 'C1'",
    params = list(review_id)
  )
  expect_equal(saved$score[[1]], 3)
  expect_equal(saved$justification[[1]], "Solid overview")

  # The reviewer clears the score and justification and the form re-saves
  # (autosave on blur) -- this must persist as cleared, not silently keep
  # the old row untouched.
  cleared <- list(
    list(section_code = "S1", criterion_code = "C1", target_type = "plan", target_id = NA_integer_, score = NA_integer_, weight = 10, justification = "")
  )
  save_plan_review_scores(connection, plan_id, user_id, cleared, "notes")

  saved_after_clear <- DBI::dbGetQuery(
    connection,
    "SELECT score, justification FROM review.section_score WHERE review_id = $1 AND section_code = 'S1' AND criterion_code = 'C1'",
    params = list(review_id)
  )
  expect_true(is.na(saved_after_clear$score[[1]]))
  expect_equal(saved_after_clear$justification[[1]], "")
})
