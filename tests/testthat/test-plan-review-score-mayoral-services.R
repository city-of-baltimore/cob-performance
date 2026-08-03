# Reported 2026-08-03: Mayoral Office plans are structurally exempt from
# the Services section (submitter_is_mayoral_service() hides it entirely),
# but save_plan_review_scores()'s S3 branch capped the plan-level Family of
# Measures score at 5/20 and simply dropped the other 15 points whenever a
# plan had zero services -- meaning a flawless Mayoral Office plan could
# never score above 85/100. Fixed by folding the full S3 allocation (20)
# into the plan-level score whenever there are no services to average in,
# instead of leaving 15 points structurally unreachable.

test_that("S3 folds the full 20-point allocation into Family of Measures when a plan has no services", {
  skip_if_no_test_database()
  connection <- connect_app_database()

  cycle_id <- DBI::dbGetQuery(connection, "SELECT cycle_id FROM planning.plan_cycle LIMIT 1")$cycle_id[[1]]
  user_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]
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

  # No target_type == "service" rows at all -- mirrors a Mayoral Office plan,
  # which never has services to score.
  no_services <- list(
    list(section_code = "S3", criterion_code = "FAMMEAS", target_type = "plan", target_id = NA_integer_, score = 4, weight = 5, justification = "")
  )
  save_plan_review_scores(connection, plan_id, user_id, no_services, "")

  review <- DBI::dbGetQuery(connection, "SELECT overall_score FROM review.plan_review WHERE plan_id = $1", params = list(plan_id))
  expect_equal(review$overall_score[[1]], 20)
})

test_that("S3 still splits 5/15 between Family of Measures and Services when services exist", {
  skip_if_no_test_database()
  connection <- connect_app_database()

  cycle_id <- DBI::dbGetQuery(connection, "SELECT cycle_id FROM planning.plan_cycle LIMIT 1")$cycle_id[[1]]
  user_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]
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

  with_service <- list(
    list(section_code = "S3", criterion_code = "FAMMEAS", target_type = "plan", target_id = NA_integer_, score = 4, weight = 5, justification = ""),
    list(section_code = "S3", criterion_code = "SVC1", target_type = "service", target_id = 1L, score = 4, weight = 15, justification = "")
  )
  save_plan_review_scores(connection, plan_id, user_id, with_service, "")

  review <- DBI::dbGetQuery(connection, "SELECT overall_score FROM review.plan_review WHERE plan_id = $1", params = list(plan_id))
  expect_equal(review$overall_score[[1]], 20)
})
