# Reported 2026-07-31: Art and Culture Grants (and 5 other grant-funded
# services) is used by several peer grantee entities -- e.g. the Baltimore
# Museum of Art and the Walters Art Gallery -- that all share their parent
# agency's agency_id. legacy_service_measure_ids() used to fall back to a
# bare agency_id match whenever a measure's own agency_id equalled the
# current plan's accounting agency_id, which let every grantee see (and,
# via service_editor_body_ui()'s description field, edit) every OTHER
# grantee's shared-service measures and description. Fixed by excluding
# measures on a shared service (per service_is_shared()/
# service_is_shared_db()) from that fallback -- a shared service's measures
# are only visible as CURRENTLY SELECTED to an entity via its own
# performance.measure_entity_link row, and apply_plan_drafts_to_records()
# now writes those per-entity links instead of blanket-overwriting
# reference.service/pm_service_link.
#
# legacy_service_measure_ids() takes an entity_scoped_only parameter for
# this. service_metric_ids() (what's currently selected) always needed
# entity_scoped_only = TRUE. plan_measure_rows()/measure_library_rows()
# (backing the Measures page/library) originally left it FALSE, on the
# theory that every grantee legitimately shares the same program catalog
# as CANDIDATES to pick from, and a brand-new grantee with zero measures
# yet would otherwise have nothing to pick. Reported 2026-08-05: this
# meant a QuasiAgency's own Measures page showed every sibling grantee's
# measures, not just its own -- real leakage, not a useful safety net,
# since any entity can always create a brand-new measure of its own
# (ensure_measure_current_entity_link() attaches it correctly regardless
# of services). Fixed by passing entity_scoped_only = TRUE here too, so
# plan_measure_rows()/measure_library_rows() now match
# service_metric_ids()'s exclusivity. Also fixed a related, previously
# masked bug in measure_library_rows(): its top-level guard required
# performance.measure_entity_link to have rows SOMEWHERE (a global check,
# not scoped to this plan/service), so on a fresh install with zero entity
# links anywhere it skipped entity-awareness entirely and fell through to
# an unscoped blanket agency-wide dump.

test_that("service_is_shared is TRUE for a service used by 2+ active has_own_plan entities", {
  db <- list(
    reference_plan_entity_service = data.frame(entity_id = c(1L, 2L), service_id = c("SVC1", "SVC1"), stringsAsFactors = FALSE),
    reference_plan_entity = data.frame(entity_id = c(1L, 2L, 3L), active = c(TRUE, TRUE, FALSE), has_own_plan = c(TRUE, TRUE, TRUE))
  )
  expect_true(service_is_shared(db, "SVC1"))
})

test_that("service_is_shared is FALSE for a service used by only one entity", {
  db <- list(
    reference_plan_entity_service = data.frame(entity_id = 1L, service_id = "SVC2", stringsAsFactors = FALSE),
    reference_plan_entity = data.frame(entity_id = 1L, active = TRUE, has_own_plan = TRUE)
  )
  expect_false(service_is_shared(db, "SVC2"))
})

test_that("service_is_shared ignores an inactive or no-own-plan duplicate entity link", {
  db <- list(
    reference_plan_entity_service = data.frame(entity_id = c(1L, 2L), service_id = c("SVC3", "SVC3"), stringsAsFactors = FALSE),
    reference_plan_entity = data.frame(entity_id = c(1L, 2L), active = c(TRUE, FALSE), has_own_plan = c(TRUE, TRUE))
  )
  expect_false(service_is_shared(db, "SVC3"))
})

test_that("service_is_shared_db (raw-connection equivalent) matches service_is_shared for a genuinely shared service", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)

  with_rollback(connection, {
    agency_id <- DBI::dbGetQuery(connection, "SELECT agency_id FROM reference.agency LIMIT 1")$agency_id[[1]]
    service_id <- "TSTSHR01"
    DBI::dbExecute(
      connection,
      "INSERT INTO reference.service (service_id, service_name, agency_id, service_type, active) VALUES ($1, 'Test shared service', $2, 'Performance', true)",
      params = list(service_id, agency_id)
    )
    entity1 <- DBI::dbGetQuery(
      connection,
      "INSERT INTO reference.plan_entity (parent_agency_id, public_name, entity_type, has_own_plan, active) VALUES ($1, 'Test Grantee One', 'QuasiAgency', true, true) RETURNING entity_id",
      params = list(agency_id)
    )$entity_id[[1]]
    entity2 <- DBI::dbGetQuery(
      connection,
      "INSERT INTO reference.plan_entity (parent_agency_id, public_name, entity_type, has_own_plan, active) VALUES ($1, 'Test Grantee Two', 'QuasiAgency', true, true) RETURNING entity_id",
      params = list(agency_id)
    )$entity_id[[1]]
    DBI::dbExecute(connection, "INSERT INTO reference.plan_entity_service (entity_id, service_id, is_primary) VALUES ($1, $2, true)", params = list(entity1, service_id))
    DBI::dbExecute(connection, "INSERT INTO reference.plan_entity_service (entity_id, service_id, is_primary) VALUES ($1, $2, true)", params = list(entity2, service_id))

    expect_true(service_is_shared_db(connection, service_id))

    # A second, non-shared service linked to only entity1 stays FALSE.
    solo_service_id <- "TSTSOL01"
    DBI::dbExecute(
      connection,
      "INSERT INTO reference.service (service_id, service_name, agency_id, service_type, active) VALUES ($1, 'Test solo service', $2, 'Performance', true)",
      params = list(solo_service_id, agency_id)
    )
    DBI::dbExecute(connection, "INSERT INTO reference.plan_entity_service (entity_id, service_id, is_primary) VALUES ($1, $2, false)", params = list(entity1, solo_service_id))
    expect_false(service_is_shared_db(connection, solo_service_id))
  })
})

test_that("legacy_service_measure_ids excludes a shared-service measure from the bare agency fallback, keeping only the entity-scoped link", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  # save_measure_record() manages its own transaction (dbWithTransaction),
  # so this can't be wrapped in with_rollback() -- clean up manually
  # instead, same pattern as test-services-draft-field.R.
  service_id <- "TSTSHR02"
  entity1 <- NULL
  entity2 <- NULL
  measure_id <- NULL
  on.exit(
    {
      DBI::dbExecute(connection, "DELETE FROM performance.plan_service WHERE plan_id IN (SELECT plan_id FROM planning.agency_plan WHERE entity_id IN (SELECT entity_id FROM reference.plan_entity WHERE public_name IN ('Test Grantee Alpha', 'Test Grantee Beta')))")
      DBI::dbExecute(connection, "DELETE FROM planning.agency_plan WHERE entity_id IN (SELECT entity_id FROM reference.plan_entity WHERE public_name IN ('Test Grantee Alpha', 'Test Grantee Beta'))")
      if (!is.null(measure_id)) {
        DBI::dbExecute(connection, "DELETE FROM performance.measure_entity_link WHERE measure_id = $1", params = list(measure_id))
        DBI::dbExecute(connection, "DELETE FROM performance.pm_service_link WHERE measure_id = $1", params = list(measure_id))
        DBI::dbExecute(connection, "DELETE FROM performance.measure_actuals WHERE measure_id = $1", params = list(measure_id))
        DBI::dbExecute(connection, "DELETE FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
      }
      DBI::dbExecute(connection, "DELETE FROM reference.plan_entity_service WHERE service_id = $1", params = list(service_id))
      DBI::dbExecute(connection, "DELETE FROM reference.plan_entity WHERE public_name IN ('Test Grantee Alpha', 'Test Grantee Beta')")
      DBI::dbExecute(connection, "DELETE FROM reference.service WHERE service_id = $1", params = list(service_id))
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )

  agency_id <- DBI::dbGetQuery(connection, "SELECT agency_id FROM reference.agency LIMIT 1")$agency_id[[1]]
  cycle_id <- DBI::dbGetQuery(connection, "SELECT cycle_id FROM planning.plan_cycle LIMIT 1")$cycle_id[[1]]
  user_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" LIMIT 1')$user_id[[1]]
  fy <- current_fiscal_year()

  DBI::dbExecute(
    connection,
    "INSERT INTO reference.service (service_id, service_name, agency_id, service_type, active) VALUES ($1, 'Test shared grant service', $2, 'Performance', true)",
    params = list(service_id, agency_id)
  )
  entity1 <- DBI::dbGetQuery(
    connection,
    "INSERT INTO reference.plan_entity (parent_agency_id, public_name, entity_type, has_own_plan, active) VALUES ($1, 'Test Grantee Alpha', 'QuasiAgency', true, true) RETURNING entity_id",
    params = list(agency_id)
  )$entity_id[[1]]
  entity2 <- DBI::dbGetQuery(
    connection,
    "INSERT INTO reference.plan_entity (parent_agency_id, public_name, entity_type, has_own_plan, active) VALUES ($1, 'Test Grantee Beta', 'QuasiAgency', true, true) RETURNING entity_id",
    params = list(agency_id)
  )$entity_id[[1]]
  DBI::dbExecute(connection, "INSERT INTO reference.plan_entity_service (entity_id, service_id, is_primary) VALUES ($1, $2, true)", params = list(entity1, service_id))
  DBI::dbExecute(connection, "INSERT INTO reference.plan_entity_service (entity_id, service_id, is_primary) VALUES ($1, $2, true)", params = list(entity2, service_id))

  base_values <- list(
    measure_id = NULL, agency_id = agency_id, initial_cycle = cycle_id,
    title = "Shared-service scoping test measure", measure_type = "Output", description = "d",
    data_source = "s", data_owner = "o", data_owner_role = "r", update_frequency = "Monthly",
    formula = "f", desired_direction = "Increase", baseline_value = 10, baseline_fy = fy - 4L,
    format_type = "Count", display_unit = NA_character_, context_required = "", replicability = TRUE,
    disaggregation = "", data_location = "", collection_method = "", how_data_used = "",
    why_meaningful = "", proxy_measure = "", improvement_notes = "", change_mapping = "New",
    pillar_id = NA_integer_, pillar_goal_id = NA_integer_, is_city = FALSE, is_agency = FALSE, is_service = TRUE,
    approval_status = "Draft", submitted_for_approval_at = as.POSIXct(NA)
  )
  measure_id <- save_measure_record(connection, base_values, list(), user_id, submit = FALSE, is_admin = TRUE)
  DBI::dbExecute(connection, "INSERT INTO performance.pm_service_link (measure_id, service_id) VALUES ($1, $2)", params = list(measure_id, service_id))
  DBI::dbExecute(
    connection,
    paste(
      "INSERT INTO performance.measure_entity_link",
      "(measure_id, agency_id, service_id, entity_type, entity_id, public_name)",
      "VALUES ($1, $2, $3, 'quasi agency', $4, 'Test Grantee Alpha')"
    ),
    params = list(measure_id, agency_id, service_id, entity1)
  )

  entity1_plan <- DBI::dbGetQuery(
    connection,
    "INSERT INTO planning.agency_plan (entity_id, cycle_id, plan_status, budget_status) VALUES ($1, $2, 'Draft', 'Draft') RETURNING plan_id",
    params = list(entity1, cycle_id)
  )
  entity2_plan <- DBI::dbGetQuery(
    connection,
    "INSERT INTO planning.agency_plan (entity_id, cycle_id, plan_status, budget_status) VALUES ($1, $2, 'Draft', 'Draft') RETURNING plan_id",
    params = list(entity2, cycle_id)
  )
  DBI::dbExecute(connection, "INSERT INTO performance.plan_service (plan_id, service_id, sort_order) VALUES ($1, $2, 1)", params = list(entity1_plan$plan_id[[1]], service_id))
  DBI::dbExecute(connection, "INSERT INTO performance.plan_service (plan_id, service_id, sort_order) VALUES ($1, $2, 1)", params = list(entity2_plan$plan_id[[1]], service_id))

  db <- load_app_data(connection)
  plan1 <- db$planning_agency_plan[db$planning_agency_plan$plan_id == entity1_plan$plan_id[[1]], , drop = FALSE]
  plan2 <- db$planning_agency_plan[db$planning_agency_plan$plan_id == entity2_plan$plan_id[[1]], , drop = FALSE]

  # service_metric_ids() is the real "what's currently selected" API
  # (entity_scoped_only = TRUE internally) -- entity1 has an explicit
  # measure_entity_link and sees the measure; entity2 shares the same
  # accounting agency_id but has NO link and must NOT see it via the old
  # bare agency_id fallback.
  expect_true(measure_id %in% service_metric_ids(db, plan1, service_id))
  expect_false(measure_id %in% service_metric_ids(db, plan2, service_id))

  # measure_library_rows()/plan_measure_rows() now match
  # service_metric_ids()'s exclusivity -- entity2 must NOT see entity1's
  # shared-service measure in its own Measures page/library, entity link
  # or not.
  expect_true(measure_id %in% measure_library_rows(db, plan1, include_ineligible = TRUE)$measure_id)
  expect_false(measure_id %in% measure_library_rows(db, plan2, include_ineligible = TRUE)$measure_id)
})
