# Backlog item: bring Risks into the draft-then-publish pattern Goals/
# Services already use. Risks has no full-page snapshot collector (it's a
# per-row modal with explicit Save/Delete), so its draft payload is a diff
# -- edits/adds/deletes keyed by risk id -- rather than Goals' full-snapshot-
# plus-reconcile shape. See merge_risks_draft_payload() and
# save_risks_draft_upsert()/save_risks_draft_delete() in R/database.R.

test_that("merge_risks_draft_payload stages an edit to a real risk id", {
  merged <- merge_risks_draft_payload(NULL, list(op = "upsert", id = "42", risk_type = "technology", description = "Needs a new vendor.", savedAt = "t1"))
  expect_equal(merged$edits[["42"]]$risk_type, "technology")
  expect_equal(merged$edits[["42"]]$description, "Needs a new vendor.")
  expect_equal(merged$adds, list())
})

test_that("merge_risks_draft_payload stages a new (temp-id) risk under adds, not edits", {
  merged <- merge_risks_draft_payload(NULL, list(op = "upsert", id = "new-123", risk_type = "staffing", description = "Short-staffed.", savedAt = "t1"))
  expect_equal(merged$adds[["new-123"]]$risk_type, "staffing")
  expect_equal(merged$edits, list())
})

test_that("merge_risks_draft_payload deleting a real risk id records it in deletes", {
  existing <- list(savedAt = "t1", edits = list(`17` = list(risk_type = "legislation", description = "Old.")), adds = list(), deletes = list())
  merged <- merge_risks_draft_payload(existing, list(op = "delete", id = "17", savedAt = "t2"))
  expect_setequal(unlist(merged$deletes), "17")
  # Deleting also drops any pending edit for that same id -- no point
  # keeping a field-level edit for a row being removed entirely.
  expect_null(merged$edits[["17"]])
})

test_that("merge_risks_draft_payload deleting a not-yet-promoted add just drops it, with nothing to reconcile at publish time", {
  existing <- list(savedAt = "t1", edits = list(), adds = list(`new-123` = list(risk_type = "staffing", description = "Short-staffed.")), deletes = list())
  merged <- merge_risks_draft_payload(existing, list(op = "delete", id = "new-123", savedAt = "t2"))
  expect_null(merged$adds[["new-123"]])
  expect_equal(merged$deletes, list())
})

test_that("merge_risks_draft_payload editing a risk id that was just deleted un-deletes it (last write wins)", {
  existing <- list(savedAt = "t1", edits = list(), adds = list(), deletes = list("17"))
  merged <- merge_risks_draft_payload(existing, list(op = "upsert", id = "17", risk_type = "legislation", description = "Reopened.", savedAt = "t2"))
  expect_equal(merged$edits[["17"]]$description, "Reopened.")
  expect_equal(merged$deletes, list())
})

test_that("save_risks_draft_upsert/save_risks_draft_delete round-trip through the draft table and apply_plan_drafts_to_records promotes them correctly", {
  skip_if_no_test_database()
  connection <- connect_app_database()

  plan_id <- DBI::dbGetQuery(connection, "SELECT plan_id FROM planning.agency_plan LIMIT 1")$plan_id[[1]]
  # A real risk to edit, and another to delete -- both pre-existing, as if
  # created before this feature shipped.
  edit_risk_id <- DBI::dbGetQuery(connection, "INSERT INTO performance.service_risk (plan_id, risk_type, description) VALUES ($1, 'technology', 'Original description.') RETURNING risk_id", params = list(plan_id))$risk_id[[1]]
  delete_risk_id <- DBI::dbGetQuery(connection, "INSERT INTO performance.service_risk (plan_id, risk_type, description) VALUES ($1, 'staffing', 'To be deleted.') RETURNING risk_id", params = list(plan_id))$risk_id[[1]]

  # save_risks_draft_upsert()/save_risks_draft_delete() each manage their
  # own transaction (with_section_draft_lock() does), so this can't be
  # wrapped in with_rollback() -- clean up manually, same pattern as
  # test-goals-draft-merge.R.
  on.exit(
    {
      DBI::dbExecute(connection, "DELETE FROM planning.plan_section_draft WHERE plan_id = $1 AND section_key = 'risks'", params = list(plan_id))
      DBI::dbExecute(connection, "DELETE FROM performance.service_risk WHERE plan_id = $1 AND description = 'Brand new risk.'", params = list(plan_id))
      DBI::dbExecute(connection, "DELETE FROM performance.service_risk WHERE risk_id IN ($1, $2)", params = list(edit_risk_id, delete_risk_id))
      DBI::dbExecute(connection, "DELETE FROM application.audit_log WHERE table_name = 'performance.service_risk' AND (row_pk IN ($1, $2) OR old_data ->> 'description' = 'Brand new risk.')", params = list(as.character(edit_risk_id), as.character(delete_risk_id)))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )
  DBI::dbExecute(connection, "DELETE FROM planning.plan_section_draft WHERE plan_id = $1 AND section_key = 'risks'", params = list(plan_id))

  save_risks_draft_upsert(connection, plan_id, edit_risk_id, "technology", "Edited description.")
  new_id <- save_risks_draft_upsert(connection, plan_id, NULL, "staffing", "Brand new risk.")
  expect_match(new_id, "^new-")
  save_risks_draft_delete(connection, plan_id, delete_risk_id)

  # Nothing should have touched the real table yet -- it's still just a draft.
  expect_equal(
    DBI::dbGetQuery(connection, "SELECT description FROM performance.service_risk WHERE risk_id = $1", params = list(edit_risk_id))$description[[1]],
    "Original description."
  )
  expect_equal(DBI::dbGetQuery(connection, "SELECT count(*) AS n FROM performance.service_risk WHERE risk_id = $1", params = list(delete_risk_id))$n[[1]], 1)

  apply_plan_drafts_to_records(connection, plan_id)

  edited <- DBI::dbGetQuery(connection, "SELECT risk_type, description FROM performance.service_risk WHERE risk_id = $1", params = list(edit_risk_id))
  expect_equal(edited$description[[1]], "Edited description.")
  expect_equal(edited$risk_type[[1]], "technology")

  deleted_count <- DBI::dbGetQuery(connection, "SELECT count(*) AS n FROM performance.service_risk WHERE risk_id = $1", params = list(delete_risk_id))$n[[1]]
  expect_equal(deleted_count, 0)

  added <- DBI::dbGetQuery(connection, "SELECT risk_type, description FROM performance.service_risk WHERE plan_id = $1 AND description = 'Brand new risk.'", params = list(plan_id))
  expect_equal(nrow(added), 1)
  expect_equal(added$risk_type[[1]], "staffing")
  # The promoted "add" row now has a real risk_id the on.exit cleanup above
  # doesn't know in advance -- cleaned up there by description instead.
})
