# Regression guard for the 2026-08-06 production incident: renaming an
# agency (reference.agency.public_name) silently emptied its Team & Roles
# page on the next deploy. ensure_review_schema()'s own reference.agency ->
# reference.plan_entity sync used to key the INSERT's ON CONFLICT target on
# (parent_agency_id, public_name) -- treating the *pair* as an entity's
# identity, not the agency alone -- so a rename didn't match any existing
# row and silently created a second, empty plan_entity row under the new
# name instead of updating the existing one. Everything keyed to the old
# row's entity_id (every access.user_entity_access row for that agency)
# was orphaned. Two real agencies hit this in production before it was
# caught. See the comment on the fix in R/database.R, right above the
# INSERT this guards.

test_that("ensure_review_schema syncs an agency rename onto its existing plan_entity row instead of creating a duplicate", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  agency_id <- "AGCTEST_ENTITY_SYNC"
  on.exit(
    {
      DBI::dbExecute(connection, "DELETE FROM reference.plan_entity WHERE parent_agency_id = $1", params = list(agency_id))
      DBI::dbExecute(connection, "DELETE FROM reference.agency WHERE agency_id = $1", params = list(agency_id))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )
  DBI::dbExecute(connection, "DELETE FROM reference.plan_entity WHERE parent_agency_id = $1", params = list(agency_id))
  DBI::dbExecute(connection, "DELETE FROM reference.agency WHERE agency_id = $1", params = list(agency_id))
  DBI::dbExecute(
    connection,
    "INSERT INTO reference.agency (agency_id, agency_name, submit_plan, active) VALUES ($1, 'Test Entity Sync Agency', true, true)",
    params = list(agency_id)
  )

  ensure_review_schema(connection)
  before <- DBI::dbGetQuery(
    connection,
    "SELECT entity_id, public_name, active FROM reference.plan_entity WHERE parent_agency_id = $1 AND entity_type = 'Agency'",
    params = list(agency_id)
  )
  expect_equal(nrow(before), 1)
  expect_equal(before$public_name[[1]], "Test Entity Sync Agency")
  expect_true(before$active[[1]])

  # The exact action that triggered the production incident: rename the
  # agency directly, then let the next "deploy" (another
  # ensure_review_schema() call) apply.
  DBI::dbExecute(
    connection,
    "UPDATE reference.agency SET agency_name = 'Test Entity Sync Agency Renamed' WHERE agency_id = $1",
    params = list(agency_id)
  )
  ensure_review_schema(connection)

  after <- DBI::dbGetQuery(
    connection,
    "SELECT entity_id, public_name, active FROM reference.plan_entity WHERE parent_agency_id = $1 AND entity_type = 'Agency'",
    params = list(agency_id)
  )
  expect_equal(nrow(after), 1, info = "must still be exactly one Agency-type row, not a duplicate")
  expect_equal(after$entity_id[[1]], before$entity_id[[1]], info = "must be the SAME row, not a new one")
  expect_equal(after$public_name[[1]], "Test Entity Sync Agency Renamed")
  expect_true(after$active[[1]])
})

test_that("ensure_review_schema never reactivates a plan_entity row that was manually deactivated", {
  # Simulates the cleanup step taken for the two real agencies this
  # incident affected: an orphaned duplicate is deactivated by hand, and
  # must stay that way through any number of future ensure_review_schema()
  # runs, even though it still matches on parent_agency_id + entity_type.
  skip_if_no_test_database()
  connection <- connect_app_database()
  agency_id <- "AGCTEST_DEAD_DUP"
  on.exit(
    {
      DBI::dbExecute(connection, "DELETE FROM reference.plan_entity WHERE parent_agency_id = $1", params = list(agency_id))
      DBI::dbExecute(connection, "DELETE FROM reference.agency WHERE agency_id = $1", params = list(agency_id))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )
  DBI::dbExecute(connection, "DELETE FROM reference.plan_entity WHERE parent_agency_id = $1", params = list(agency_id))
  DBI::dbExecute(connection, "DELETE FROM reference.agency WHERE agency_id = $1", params = list(agency_id))
  DBI::dbExecute(
    connection,
    "INSERT INTO reference.agency (agency_id, agency_name, submit_plan, active) VALUES ($1, 'Live Name', true, true)",
    params = list(agency_id)
  )
  ensure_review_schema(connection)
  live_id <- DBI::dbGetQuery(
    connection,
    "SELECT entity_id FROM reference.plan_entity WHERE parent_agency_id = $1 AND entity_type = 'Agency'",
    params = list(agency_id)
  )$entity_id[[1]]
  # Leave behind a dead, manually-deactivated duplicate under its own
  # stale name -- the same shape as the two real production incidents
  # (the old and new names never coincide; the table's own unique
  # constraint on (parent_agency_id, public_name) wouldn't allow it to
  # anyway).
  dead_id <- DBI::dbGetQuery(
    connection,
    "INSERT INTO reference.plan_entity (parent_agency_id, public_name, entity_type, has_own_plan, active) VALUES ($1, 'Old Dead Name', 'Agency', false, false) RETURNING entity_id",
    params = list(agency_id)
  )$entity_id[[1]]

  ensure_review_schema(connection)

  rows <- DBI::dbGetQuery(
    connection,
    "SELECT entity_id, active FROM reference.plan_entity WHERE entity_id IN ($1, $2)",
    params = list(live_id, dead_id)
  )
  expect_true(rows$active[rows$entity_id == live_id])
  expect_false(rows$active[rows$entity_id == dead_id])
})
