# Regression guard for the audit history feature added 2026-07-24: Melanie
# wants to be able to revive past plan-builder data if needed (e.g. a
# service description reference.service.service_description is a *shared*
# table -- a single plan's approval can silently overwrite it for every
# other agency using that service, with no way to see what it was before or
# revert). These tests confirm the application.log_row_change() trigger and
# application.audit_log table actually capture the old row and attribute it
# correctly, not just that the schema objects exist.

test_that("ensure_review_schema creates the audit_log table and all five triggers", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)
  ensure_review_schema(connection)

  triggers <- DBI::dbGetQuery(
    connection,
    "SELECT tgname, tgrelid::regclass::text AS on_table FROM pg_trigger WHERE tgname LIKE 'trg_audit_%' ORDER BY tgname"
  )
  expect_setequal(
    triggers$on_table,
    c(
      "planning.plan_section_draft", "reference.service", "performance.agency_goal",
      "performance.overview_vision", "performance.service_risk"
    )
  )

  columns <- DBI::dbGetQuery(
    connection,
    "SELECT column_name FROM information_schema.columns WHERE table_schema = 'application' AND table_name = 'audit_log'"
  )
  expect_setequal(columns$column_name, c("audit_id", "table_name", "row_pk", "operation", "old_data", "changed_by", "changed_at"))
})

test_that("updating reference.service logs the prior description and the acting user", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)
  ensure_review_schema(connection)

  with_rollback(connection, {
    service_id <- DBI::dbGetQuery(connection, "SELECT service_id FROM reference.service LIMIT 1")$service_id[[1]]
    original <- DBI::dbGetQuery(connection, "SELECT service_description FROM reference.service WHERE service_id = $1", params = list(service_id))$service_description[[1]]
    actor_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]

    set_audit_actor(connection, actor_id)
    DBI::dbExecute(
      connection,
      "UPDATE reference.service SET service_description = $2 WHERE service_id = $1",
      params = list(service_id, "Changed for the audit-log regression test.")
    )

    logged <- DBI::dbGetQuery(
      connection,
      "SELECT row_pk, changed_by, old_data ->> 'service_description' AS old_description FROM application.audit_log WHERE table_name = 'reference.service' ORDER BY audit_id DESC LIMIT 1"
    )
    expect_equal(logged$row_pk[[1]], service_id)
    expect_equal(logged$changed_by[[1]], actor_id)
    expect_equal(logged$old_description[[1]], original)

    # Regression guard for a real 2026-07-24 production bug: a BEFORE UPDATE
    # trigger's return value becomes the row Postgres actually writes.
    # log_row_change() briefly returned OLD unconditionally (correct for
    # DELETE, wrong for UPDATE), which silently discarded every update to
    # this table -- the update "succeeded" with no error, but the row was
    # rewritten with its own pre-update value. The audit_log assertions
    # above would still pass under that bug, since old_data is captured
    # before the trigger returns anything -- only checking the live row
    # actually catches it.
    current_description <- DBI::dbGetQuery(
      connection,
      "SELECT service_description FROM reference.service WHERE service_id = $1",
      params = list(service_id)
    )$service_description[[1]]
    expect_equal(current_description, "Changed for the audit-log regression test.")
  })
})

test_that("save_service_risk attributes an edit to the acting user via changed_by", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  ensure_review_schema(connection)

  # save_service_risk() manages its own transaction (that's the fix from
  # earlier this session for the same nested-transaction issue), so this
  # can't be wrapped in with_rollback() -- clean up manually instead. Both
  # the cleanup queries and the disconnect must be in one on.exit (not two
  # separate calls) -- on.exit(add = TRUE) runs in registration order, so a
  # disconnect registered first would run before this cleanup and leave it
  # trying to query a dead connection. The row delete must come before the
  # audit_log delete, not after -- deleting the risk row is itself audited
  # (trg_audit_service_risk fires BEFORE DELETE too), so cleaning up
  # audit_log first just leaves that deletion's own new row behind.
  actor_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]
  risk_id <- DBI::dbGetQuery(connection, "INSERT INTO performance.service_risk (plan_id, risk_type, description) VALUES (1, 'technology', 'Original description for the audit-log regression test.') RETURNING risk_id")$risk_id[[1]]
  on.exit(
    {
      DBI::dbExecute(connection, "DELETE FROM performance.service_risk WHERE risk_id = $1", params = list(risk_id))
      DBI::dbExecute(connection, "DELETE FROM application.audit_log WHERE table_name = 'performance.service_risk' AND row_pk = $1", params = list(as.character(risk_id)))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )

  save_service_risk(connection, risk_id, 1L, "technology", "Updated description for the audit-log regression test.", changed_by = actor_id)

  logged <- DBI::dbGetQuery(
    connection,
    "SELECT row_pk, changed_by, old_data ->> 'description' AS old_description FROM application.audit_log WHERE table_name = 'performance.service_risk' ORDER BY audit_id DESC LIMIT 1"
  )
  expect_equal(logged$row_pk[[1]], as.character(risk_id))
  expect_equal(logged$changed_by[[1]], actor_id)
  expect_equal(logged$old_description[[1]], "Original description for the audit-log regression test.")

  current_description <- DBI::dbGetQuery(
    connection,
    "SELECT description FROM performance.service_risk WHERE risk_id = $1",
    params = list(risk_id)
  )$description[[1]]
  expect_equal(current_description, "Updated description for the audit-log regression test.")
})

test_that("updating planning.plan_section_draft actually persists the new payload", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)
  ensure_review_schema(connection)

  with_rollback(connection, {
    plan_id <- DBI::dbGetQuery(connection, "SELECT plan_id FROM planning.agency_plan LIMIT 1")$plan_id[[1]]
    DBI::dbExecute(connection, "DELETE FROM planning.plan_section_draft WHERE plan_id = $1 AND section_key = 'regression_test'", params = list(plan_id))

    first <- overwrite_section_draft(connection, plan_id, "regression_test", '{"values":{"a":"one"}}')
    expect_equal(first$revision[[1]], 1L)

    # The second write is the one that exercises the ON CONFLICT DO UPDATE
    # branch -- i.e. an actual UPDATE, which is exactly the path the
    # BEFORE UPDATE trigger bug above silently broke for every plan-builder
    # draft (Goals, Services) after its first-ever autosave.
    second <- overwrite_section_draft(connection, plan_id, "regression_test", '{"values":{"a":"two"}}')
    expect_equal(second$revision[[1]], 2L)

    stored <- get_section_draft(connection, plan_id, "regression_test")
    expect_equal(jsonlite::fromJSON(stored$payload[[1]])$values$a, "two")
  })
})
