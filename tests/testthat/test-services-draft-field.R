# Regression guard for the Services autosave data-loss bug found 2026-07-24
# while investigating backlog item #3 (silent JSON-parse error swallowing).
#
# An earlier same-day fix (PR #53) targeted service_description_draft_save/
# service_metrics_draft_save + save_services_draft_field(), believing those
# were the live Services autosave path. They turned out to be unreachable
# from the client -- app.js's flushServiceDescriptionAutosave()/
# flushServiceMetricsAutosave() are defined but never called -- so that fix
# never actually ran in production. The real live path is
# services_draft_quiet_save (app.R) / scheduleServicesQuietAutosave()
# (app.js), which sends a full-page snapshot via collectBuilderDraft() and
# was going through a blind overwrite_section_draft() -- the same bug class
# as the original Goals incident. save_services_draft_field() and its test
# have been removed; this file now covers the real fix,
# save_services_draft_quiet_merged()/merge_services_draft_payload().

test_that("merge_services_draft_payload keeps a service's data the incoming payload doesn't mention", {
  existing <- list(
    values = list(service_description_SRV1 = "Old SRV1 description", service_description_SRV2 = "Teammate's SRV2 description"),
    serviceMetrics = list(SRV1 = list("101"), SRV2 = list("201"))
  )
  incoming <- list(
    savedAt = "2026-07-24T12:00:00Z",
    values = list(service_description_SRV1 = "Old SRV1 description edited by me"),
    serviceMetrics = list(SRV1 = list("101", "102"))
  )

  merged <- merge_services_draft_payload(existing, incoming)

  expect_equal(merged$values$service_description_SRV1, "Old SRV1 description edited by me")
  expect_equal(merged$values$service_description_SRV2, "Teammate's SRV2 description")
  expect_equal(merged$serviceMetrics$SRV1, list("101", "102"))
  expect_equal(merged$serviceMetrics$SRV2, list("201"))
})

test_that("save_services_draft_quiet_merged preserves a concurrent teammate's addition on a stale re-save", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  # save_services_draft_quiet_merged() manages its own transaction (needed
  # so the read-merge-write is atomic against a concurrent save), so this
  # can't be wrapped in with_rollback() -- clean up manually instead, same
  # pattern as the Goals test in test-goals-draft-merge.R.
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

  payload_a <- jsonlite::toJSON(list(savedAt = "t1", values = list(service_description_SRV1 = "SRV1 description"), serviceMetrics = list(SRV1 = list("101"))), auto_unbox = TRUE)
  save_services_draft_quiet_merged(connection, plan_id, payload_a)

  # Teammate edits a second service -- this browser tab's page snapshot
  # doesn't know about it.
  payload_b <- jsonlite::toJSON(list(savedAt = "t2", values = list(service_description_SRV2 = "SRV2 description (new)"), serviceMetrics = list(SRV2 = list("201"))), auto_unbox = TRUE)
  save_services_draft_quiet_merged(connection, plan_id, payload_b)

  # The original tab's stale autosave fires, mentioning only SRV1.
  payload_a2 <- jsonlite::toJSON(list(savedAt = "t3", values = list(service_description_SRV1 = "SRV1 description edited"), serviceMetrics = list(SRV1 = list("101", "102"))), auto_unbox = TRUE)
  save_services_draft_quiet_merged(connection, plan_id, payload_a2)

  final_payload <- jsonlite::fromJSON(get_section_draft(connection, plan_id, "services")$payload[[1]])
  expect_equal(final_payload$values$service_description_SRV1, "SRV1 description edited")
  expect_equal(final_payload$values$service_description_SRV2, "SRV2 description (new)")
  expect_equal(unlist(final_payload$serviceMetrics$SRV1), c("101", "102"))
  expect_equal(unlist(final_payload$serviceMetrics$SRV2), "201")
})
