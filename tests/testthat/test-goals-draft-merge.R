# Regression guard for the 2026-07-24 bug report: "team members added stuff
# to goals and it's not saving when they navigate away or refresh." Each
# team member's autosave sends a full snapshot of their own (possibly
# stale) browser tab; without merging, whichever snapshot lands last
# silently erased anything another team member had added since this
# browser's copy last synced with the server. See merge_goals_draft_payload()
# and save_goals_draft_merged() in R/database.R.

test_that("merge_goals_draft_payload keeps a goal the incoming payload doesn't mention", {
  existing <- list(
    values = list(goal_statement_1 = "Old goal 1", goal_statement_2 = "Teammate's goal 2"),
    kpis = list(`1` = list("kpi-a"), `2` = list("kpi-b")),
    initiatives = list(`1` = list("init A"), `2` = list("init B (teammate's)")),
    goalIds = list("1", "2")
  )
  incoming <- list(
    savedAt = "2026-07-24T12:00:00Z",
    values = list(goal_statement_1 = "Old goal 1 edited by me"),
    kpis = list(`1` = list("kpi-a-edited")),
    initiatives = list(`1` = list("init A edited")),
    goalIds = list("1")
  )

  merged <- merge_goals_draft_payload(existing, incoming)

  expect_equal(merged$values$goal_statement_1, "Old goal 1 edited by me")
  expect_equal(merged$values$goal_statement_2, "Teammate's goal 2")
  expect_equal(merged$initiatives[["2"]], list("init B (teammate's)"))
  expect_setequal(unlist(merged$goalIds), c("1", "2"))
})

# Regression guard for the 2026-08-06 bug report: "every time I delete a
# goal, it comes back." A plain union of goalIds can never shrink -- the
# very save that deletes a goal gets unioned right back against whatever
# was already stored, which still has it. Fixed by sending which ids were
# explicitly deleted and subtracting them after the union.
test_that("merge_goals_draft_payload lets an explicit deletion actually remove a goal", {
  existing <- list(
    values = list(goal_statement_1 = "Goal 1", goal_statement_2 = "Goal 2"),
    kpis = list(), initiatives = list(),
    goalIds = list("1", "2")
  )
  incoming <- list(
    savedAt = "2026-08-06T12:00:00Z",
    values = list(),
    kpis = list(), initiatives = list(),
    goalIds = list("1"),
    deletedGoalIds = list("2")
  )

  merged <- merge_goals_draft_payload(existing, incoming)

  expect_setequal(unlist(merged$goalIds), "1")
  expect_setequal(unlist(merged$deletedGoalIds), "2")
})

test_that("a stale tab that still lists a previously-deleted goal cannot resurrect it", {
  existing <- list(
    values = list(goal_statement_1 = "Goal 1"),
    kpis = list(), initiatives = list(),
    goalIds = list("1"),
    deletedGoalIds = list("2")
  )
  # A stale tab's own DOM never learned about the deletion, so its next
  # autosave still lists goal 2 -- but it didn't delete anything itself.
  incoming <- list(
    savedAt = "2026-08-06T12:05:00Z",
    values = list(goal_statement_1 = "Goal 1 edited"),
    kpis = list(), initiatives = list(),
    goalIds = list("1", "2")
  )

  merged <- merge_goals_draft_payload(existing, incoming)

  expect_setequal(unlist(merged$goalIds), "1")
})

test_that("save_goals_draft_merged persists a goal deletion instead of unioning it back", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  plan_id <- DBI::dbGetQuery(connection, "SELECT plan_id FROM planning.agency_plan LIMIT 1")$plan_id[[1]]
  on.exit(
    {
      DBI::dbExecute(connection, "DELETE FROM planning.plan_section_draft WHERE plan_id = $1 AND section_key = 'goals'", params = list(plan_id))
      DBI::dbExecute(connection, "DELETE FROM application.audit_log WHERE table_name = 'planning.plan_section_draft'")
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )
  DBI::dbExecute(connection, "DELETE FROM planning.plan_section_draft WHERE plan_id = $1 AND section_key = 'goals'", params = list(plan_id))

  payload_a <- jsonlite::toJSON(list(savedAt = "t1", values = list(goal_statement_1 = "Goal one", goal_statement_2 = "Goal two"), kpis = list(), initiatives = list(), goalIds = list("1", "2")), auto_unbox = TRUE)
  save_goals_draft_merged(connection, plan_id, payload_a)

  # Delete goal 2 -- the exact save the bug report described.
  payload_delete <- jsonlite::toJSON(list(savedAt = "t2", values = list(), kpis = list(), initiatives = list(), goalIds = list("1"), deletedGoalIds = list("2")), auto_unbox = TRUE)
  save_goals_draft_merged(connection, plan_id, payload_delete)

  final_payload <- jsonlite::fromJSON(get_section_draft(connection, plan_id, "goals")$payload[[1]])
  expect_setequal(final_payload$goalIds, "1")
})

test_that("save_goals_draft_merged preserves a concurrent teammate's addition on a stale re-save", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  # save_goals_draft_merged() manages its own transaction (needed so the
  # read-merge-write is atomic against a concurrent save), so this can't be
  # wrapped in with_rollback() -- DBI/RPostgres doesn't support nested
  # transactions on one connection. Clean up manually instead, same pattern
  # as the save_service_risk test in test-audit-log.R.
  plan_id <- DBI::dbGetQuery(connection, "SELECT plan_id FROM planning.agency_plan LIMIT 1")$plan_id[[1]]
  on.exit(
    {
      DBI::dbExecute(connection, "DELETE FROM planning.plan_section_draft WHERE plan_id = $1 AND section_key = 'goals'", params = list(plan_id))
      DBI::dbExecute(connection, "DELETE FROM application.audit_log WHERE table_name = 'planning.plan_section_draft'")
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )
  DBI::dbExecute(connection, "DELETE FROM planning.plan_section_draft WHERE plan_id = $1 AND section_key = 'goals'", params = list(plan_id))

  payload_a <- jsonlite::toJSON(list(savedAt = "t1", values = list(goal_statement_1 = "A goal one"), kpis = list(), initiatives = list(), goalIds = list("1")), auto_unbox = TRUE)
  save_goals_draft_merged(connection, plan_id, payload_a)

  # Teammate adds a second goal -- this browser tab doesn't know about it.
  payload_b <- jsonlite::toJSON(list(savedAt = "t2", values = list(goal_statement_2 = "B goal two (new)"), kpis = list(), initiatives = list(), goalIds = list("1", "2")), auto_unbox = TRUE)
  save_goals_draft_merged(connection, plan_id, payload_b)

  # The original tab's stale autosave fires, mentioning only goal 1.
  payload_a2 <- jsonlite::toJSON(list(savedAt = "t3", values = list(goal_statement_1 = "A goal one edited"), kpis = list(), initiatives = list(), goalIds = list("1")), auto_unbox = TRUE)
  save_goals_draft_merged(connection, plan_id, payload_a2)

  final_payload <- jsonlite::fromJSON(get_section_draft(connection, plan_id, "goals")$payload[[1]])
  expect_equal(final_payload$values$goal_statement_1, "A goal one edited")
  expect_equal(final_payload$values$goal_statement_2, "B goal two (new)")
  expect_setequal(final_payload$goalIds, c("1", "2"))
})
