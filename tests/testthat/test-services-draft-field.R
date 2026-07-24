# Regression guard for the same class of bug fixed for Goals on 2026-07-24
# (see test-goals-draft-merge.R): Services autosave already saved one field
# or one service's metrics at a time (never a whole-page snapshot like
# Goals did), but its read-then-write wasn't atomic -- two concurrent saves
# could both read the draft before either wrote, and whichever committed
# second silently discarded the first's change. save_services_draft_field()
# now shares the same row-locked read-modify-write primitive
# (with_section_draft_lock()) that Goals uses.
#
# A genuine two-writer race is hard to exercise deterministically in a
# single-threaded test without spinning up a second process, so this
# doesn't attempt that. What it does cover: the refactor didn't regress the
# existing single-writer, multi-field/multi-service accumulation behavior
# that the old unlocked code also relied on.

test_that("save_services_draft_field accumulates fields and per-service metrics across separate calls", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  # save_services_draft_field() manages its own transaction (that's the
  # point of the fix), so this can't be wrapped in with_rollback() --
  # DBI/RPostgres doesn't support nested transactions on one connection.
  # Clean up manually, same pattern as the save_service_risk test in
  # test-audit-log.R.
  plan_id <- DBI::dbGetQuery(connection, "SELECT plan_id FROM planning.agency_plan LIMIT 1")$plan_id[[1]]
  on.exit(
    {
      DBI::dbExecute(connection, "DELETE FROM planning.plan_section_draft WHERE plan_id = $1 AND section_key = 'services'", params = list(plan_id))
      DBI::dbExecute(connection, "DELETE FROM application.audit_log WHERE table_name = 'planning.plan_section_draft'")
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )
  DBI::dbExecute(connection, "DELETE FROM planning.plan_section_draft WHERE plan_id = $1 AND section_key = 'services'", params = list(plan_id))

  save_services_draft_field(connection, plan_id, function(payload) {
    payload$values[["service_description_1"]] <- "First description"
    payload
  })
  save_services_draft_field(connection, plan_id, function(payload) {
    payload$serviceMetrics["SRV1"] <- list(list(101L, 102L))
    payload
  })
  # A second field save must not clobber the first field or the metrics
  # saved in between.
  save_services_draft_field(connection, plan_id, function(payload) {
    payload$values[["service_description_2"]] <- "Second description"
    payload
  })
  # A second service's metrics must not clobber SRV1's.
  save_services_draft_field(connection, plan_id, function(payload) {
    payload$serviceMetrics["SRV2"] <- list(list(201L))
    payload
  })

  final_payload <- jsonlite::fromJSON(get_section_draft(connection, plan_id, "services")$payload[[1]])
  expect_equal(final_payload$values$service_description_1, "First description")
  expect_equal(final_payload$values$service_description_2, "Second description")
  expect_equal(unlist(final_payload$serviceMetrics$SRV1), c(101, 102))
  expect_equal(unlist(final_payload$serviceMetrics$SRV2), 201)
})
