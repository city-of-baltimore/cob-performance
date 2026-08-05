# Reported 2026-08-06: saving a new measure for a Mayoral Office with zero
# services (Mayoral Offices are exempt from having any -- see
# submitter_is_mayoral_service()) appeared to do nothing -- the measure
# actually saved fine, but it never showed up in that entity's measure
# library. Two separate bugs combined to cause this:
#
# 1. ensure_measure_current_entity_link() required a service to anchor the
#    new performance.measure_entity_link row to (that table's service_id
#    was NOT NULL for every entity_type), so a zero-service entity's link
#    was silently never created (returned FALSE, no error).
# 2. plan_measure_rows() bailed out entirely whenever a plan had zero
#    services, before ever checking measure_entity_link's entity_id-based
#    match -- which doesn't depend on services at all for an entity
#    submitter -- so even a successfully-created link would still have
#    been invisible in the library.
#
# Fixed by making measure_entity_link.service_id nullable (a 'mayoral
# service'/'quasi agency' link is entity-scoped, not service-scoped, the
# same way a 'service' link's entity_id is already nullable) and updating
# both functions accordingly.

test_that("plan_measure_rows finds an entity-linked measure for a plan with zero services", {
  plan <- data.frame(plan_id = 144L, entity_id = 32L, agency_id = NA_character_, stringsAsFactors = FALSE)
  db <- list(
    performance_plan_service = data.frame(plan_service_id = integer(0), plan_id = integer(0), service_id = character(0)),
    reference_service = data.frame(service_id = character(0), active = logical(0), sort_order = integer(0), service_name = character(0), service_type = character(0), stringsAsFactors = FALSE),
    performance_measure_entity_link = data.frame(
      measure_id = 900L, agency_id = "TST9003", service_id = NA_character_,
      entity_type = "mayoral service", entity_id = 32L, public_name = "TEST Mayor's Office of Tiny Triumphs",
      stringsAsFactors = FALSE
    ),
    performance_pm_service_link = data.frame(measure_id = integer(0), service_id = character(0)),
    performance_performance_measure = data.frame(
      measure_id = 900L, agency_id = "TST9003", fiscal_year = 2027L, active = TRUE,
      approval_status = "Validated", change_mapping = "Unchanged", title = "A new Tiny Triumphs measure",
      stringsAsFactors = FALSE
    )
  )
  # Confirms the entity has genuinely zero services -- otherwise this test
  # would pass for the wrong reason.
  expect_equal(nrow(plan_service_rows(db, plan)), 0)

  result <- plan_measure_rows(db, plan)
  expect_equal(result$measure_id, 900L)
})

test_that("plan_measure_rows still returns nothing for a bare agency plan with zero services (unaffected)", {
  plan <- data.frame(plan_id = 10L, entity_id = NA_integer_, agency_id = "AGC1000", stringsAsFactors = FALSE)
  db <- list(
    performance_plan_service = data.frame(plan_service_id = integer(0), plan_id = integer(0), service_id = character(0)),
    reference_service = data.frame(service_id = character(0), active = logical(0), sort_order = integer(0), service_name = character(0), service_type = character(0), stringsAsFactors = FALSE),
    performance_measure_entity_link = data.frame(
      measure_id = 901L, agency_id = "AGC9999", service_id = "SRV1",
      entity_type = "service", entity_id = NA_integer_, public_name = "Someone else's service",
      stringsAsFactors = FALSE
    ),
    performance_pm_service_link = data.frame(measure_id = integer(0), service_id = character(0)),
    performance_performance_measure = data.frame(
      measure_id = 901L, agency_id = "AGC9999", fiscal_year = 2027L, active = TRUE,
      approval_status = "Validated", change_mapping = "Unchanged", title = "Not this agency's measure",
      stringsAsFactors = FALSE
    )
  )
  result <- plan_measure_rows(db, plan)
  expect_equal(nrow(result), 0)
})

test_that("ensure_measure_current_entity_link creates a NULL-service_id link for a zero-service entity, and re-saving updates it instead of duplicating", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  # Ensures the service_id-nullable migration has actually been applied to
  # this test database, regardless of test execution order.
  ensure_review_schema(connection)

  agency_id <- DBI::dbGetQuery(connection, "SELECT agency_id FROM reference.agency LIMIT 1")$agency_id[[1]]
  entity_id <- DBI::dbGetQuery(
    connection,
    "INSERT INTO reference.plan_entity (parent_agency_id, public_name, entity_type, has_own_plan, active) VALUES ($1, 'TEST zero-service mayoral entity', 'MayoraltyOffice', true, true) RETURNING entity_id",
    params = list(agency_id)
  )$entity_id[[1]]
  cycle_id <- DBI::dbGetQuery(connection, "SELECT cycle_id FROM planning.plan_cycle LIMIT 1")$cycle_id[[1]]
  measure_id <- DBI::dbGetQuery(
    connection,
    paste(
      "INSERT INTO performance.performance_measure",
      "(agency_id, initial_cycle, title, measure_type, description, data_source, data_owner, data_owner_role, update_frequency, formula, desired_direction, baseline_fy, format_type, replicability, change_mapping, is_agency, is_service, approval_status)",
      "VALUES ($1, $2, 'TEST zero-service entity-link measure', 'Output', 'd', 's', 'o', 'r', 'Monthly', 'f', 'Increase', 2023, 'Count', true, 'Unchanged', false, true, 'Validated')",
      "RETURNING measure_id"
    ),
    params = list(agency_id, cycle_id)
  )$measure_id[[1]]
  on.exit(
    {
      # Order matters: measure_entity_link must go before performance_measure
      # (FK), which must go before plan_entity (FK), before disconnecting.
      DBI::dbExecute(connection, "DELETE FROM performance.measure_entity_link WHERE entity_id = $1", params = list(entity_id))
      DBI::dbExecute(connection, "DELETE FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
      DBI::dbExecute(connection, "DELETE FROM reference.plan_entity WHERE entity_id = $1", params = list(entity_id))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )

  data <- list(
    reference_plan_entity = data.frame(entity_id = entity_id, public_name = "TEST zero-service mayoral entity", entity_type = "MayoraltyOffice", parent_agency_id = agency_id, stringsAsFactors = FALSE),
    performance_performance_measure = data.frame(measure_id = measure_id, agency_id = agency_id, stringsAsFactors = FALSE),
    performance_plan_service = data.frame(plan_service_id = integer(0), plan_id = integer(0), service_id = character(0)),
    reference_service = data.frame(service_id = character(0), active = logical(0), sort_order = integer(0), service_name = character(0), service_type = character(0), stringsAsFactors = FALSE)
  )
  plan <- data.frame(plan_id = 99999L, entity_id = entity_id, agency_id = NA_character_, stringsAsFactors = FALSE)

  result1 <- ensure_measure_current_entity_link(connection, measure_id, data, plan)
  expect_true(isTRUE(result1))
  links_after_first <- DBI::dbGetQuery(connection, "SELECT link_id, service_id FROM performance.measure_entity_link WHERE measure_id = $1", params = list(measure_id))
  expect_equal(nrow(links_after_first), 1)
  expect_true(is.na(links_after_first$service_id[[1]]))

  # Re-saving the same measure (e.g. editing it again later) must update
  # the existing link, not create a second one -- this is the exact
  # Postgres NULL-distinct-under-UNIQUE gap the fix has to work around.
  result2 <- ensure_measure_current_entity_link(connection, measure_id, data, plan)
  expect_true(isTRUE(result2))
  links_after_second <- DBI::dbGetQuery(connection, "SELECT link_id FROM performance.measure_entity_link WHERE measure_id = $1", params = list(measure_id))
  expect_equal(nrow(links_after_second), 1)
  expect_equal(links_after_second$link_id[[1]], links_after_first$link_id[[1]])
})
