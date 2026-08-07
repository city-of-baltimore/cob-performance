# Regression guard for agency-scoped measures loading (2026-08-07) --
# Services/Measures page navigation was scanning the full citywide
# performance_measure_actuals table inside a per-service/per-measure
# loop, which is what made large agencies (many services) feel slow to
# navigate. The real fix is loading less in the first place: an ordinary
# single-agency session's INITIAL load is scoped to just the agencies its
# own access actually touches, resolved by resolve_measures_scope_agency_ids().
#
# The resolved set is deliberately a SUPERSET at the agency level (see
# the function's own comment in R/database.R) -- a shared-grant entity
# (e.g. Family League) can have a service/measure filed under a
# different agency_id than its own parent agency, so every source of
# agency linkage is unioned in rather than picking just one. Citywide
# roles (SystemAdmin/OPIReviewer/BBMRReviewer/DeputyMayor/CAOffice)
# always get NULL (unscoped) since they review across agencies.

make_test_user <- function(connection, email) {
  DBI::dbGetQuery(
    connection,
    paste(
      'INSERT INTO access."user" (email, full_name, auth_type, active)',
      "VALUES ($1, 'Measures Scope Test User', 'MicrosoftAD', true)",
      "RETURNING user_id"
    ),
    params = list(email)
  )$user_id[[1]]
}

test_that("resolve_measures_scope_agency_ids returns NULL for citywide roles", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)

  with_rollback(connection, {
    for (role in c("SystemAdmin", "OPIReviewer", "BBMRReviewer", "DeputyMayor", "CAOffice")) {
      user_id <- make_test_user(connection, paste0("measures-scope-", tolower(role), "@example.com"))
      DBI::dbExecute(
        connection,
        "INSERT INTO access.user_role (user_id, app_role, agency_id, budget_access, adaptive_planning, performance_plan_access) VALUES ($1, $2::varchar(30), NULL, false, false, true)",
        params = list(user_id, role)
      )
      expect_null(resolve_measures_scope_agency_ids(connection, user_id), info = role)
    }
  })
})

test_that("resolve_measures_scope_agency_ids returns NULL when the user has no role row at all", {
  # Fail open to the existing (citywide) behavior rather than silently
  # showing an ordinary user nothing, in case some account genuinely has
  # no access.user_role row yet.
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)

  with_rollback(connection, {
    user_id <- make_test_user(connection, "measures-scope-norole@example.com")
    expect_null(resolve_measures_scope_agency_ids(connection, user_id))
  })
})

test_that("resolve_measures_scope_agency_ids returns the directly-granted agency for an ordinary agency role", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)

  with_rollback(connection, {
    agency_id <- DBI::dbGetQuery(connection, "SELECT agency_id FROM reference.agency WHERE active ORDER BY agency_id LIMIT 1")$agency_id[[1]]
    user_id <- make_test_user(connection, "measures-scope-direct@example.com")
    DBI::dbExecute(
      connection,
      "INSERT INTO access.user_role (user_id, app_role, agency_id, budget_access, adaptive_planning, performance_plan_access) VALUES ($1, 'AgencySubmitter', NULL, false, false, true)",
      params = list(user_id)
    )
    DBI::dbExecute(
      connection,
      "INSERT INTO access.user_agency_access (user_id, agency_id, service_id, agency_role, agency_roles, access_level, budget_access, performance_plan_access) VALUES ($1, $2, NULL, 'Agency Staff', 'Agency Staff', 'Edit', false, true)",
      params = list(user_id, agency_id)
    )
    expect_identical(resolve_measures_scope_agency_ids(connection, user_id), agency_id)
  })
})

test_that("resolve_measures_scope_agency_ids resolves an entity grant to its parent agency", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)

  with_rollback(connection, {
    entity <- DBI::dbGetQuery(connection, "SELECT entity_id, parent_agency_id FROM reference.plan_entity WHERE active AND has_own_plan ORDER BY entity_id LIMIT 1")
    user_id <- make_test_user(connection, "measures-scope-entity@example.com")
    DBI::dbExecute(
      connection,
      "INSERT INTO access.user_role (user_id, app_role, agency_id, budget_access, adaptive_planning, performance_plan_access) VALUES ($1, 'AgencySubmitter', NULL, false, false, true)",
      params = list(user_id)
    )
    DBI::dbExecute(
      connection,
      "INSERT INTO access.user_entity_access (user_id, entity_id, agency_id, service_id, agency_role, agency_roles, access_level, budget_access, adaptive_planning, performance_plan_access) VALUES ($1, $2, NULL, NULL, 'Agency Staff', 'Agency Staff', 'Edit', false, false, true)",
      params = list(user_id, entity$entity_id[[1]])
    )
    resolved <- resolve_measures_scope_agency_ids(connection, user_id)
    expect_true(entity$parent_agency_id[[1]] %in% resolved)
  })
})

test_that("resolve_measures_scope_agency_ids includes an agency named only via measure_entity_link, not the entity's own parent agency", {
  # The shared-grant-program case (Family League ↔ AGC4321/AGC4316-style):
  # an entity can be entity-linked to a measure filed under a DIFFERENT
  # agency than its own parent_agency_id. A naive filter on just the
  # entity's parent agency would silently drop that measure from the
  # entity's own Services/Measures pages -- this is exactly the failure
  # mode the resolution is designed to avoid.
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)

  with_rollback(connection, {
    entity <- DBI::dbGetQuery(connection, "SELECT entity_id, parent_agency_id FROM reference.plan_entity WHERE active AND has_own_plan ORDER BY entity_id LIMIT 1")
    other_agency_id <- DBI::dbGetQuery(
      connection, "SELECT agency_id FROM reference.agency WHERE active AND agency_id <> $1 ORDER BY agency_id LIMIT 1", params = list(entity$parent_agency_id[[1]])
    )$agency_id[[1]]
    user_id <- make_test_user(connection, "measures-scope-crossprogram@example.com")
    DBI::dbExecute(
      connection,
      "INSERT INTO access.user_role (user_id, app_role, agency_id, budget_access, adaptive_planning, performance_plan_access) VALUES ($1, 'AgencySubmitter', NULL, false, false, true)",
      params = list(user_id)
    )
    DBI::dbExecute(
      connection,
      "INSERT INTO access.user_entity_access (user_id, entity_id, agency_id, service_id, agency_role, agency_roles, access_level, budget_access, adaptive_planning, performance_plan_access) VALUES ($1, $2, NULL, NULL, 'Agency Staff', 'Agency Staff', 'Edit', false, false, true)",
      params = list(user_id, entity$entity_id[[1]])
    )
    # A measure_entity_link row naming a DIFFERENT agency_id for this same entity.
    DBI::dbExecute(
      connection,
      "INSERT INTO performance.measure_entity_link (measure_id, agency_id, service_id, entity_type, entity_id, public_name) SELECT measure_id, $1, NULL, 'quasi agency', $2, 'Cross-program test link' FROM performance.performance_measure LIMIT 1",
      params = list(other_agency_id, entity$entity_id[[1]])
    )
    resolved <- resolve_measures_scope_agency_ids(connection, user_id)
    expect_true(entity$parent_agency_id[[1]] %in% resolved, info = "must still include the entity's own parent agency")
    expect_true(other_agency_id %in% resolved, info = "must ALSO include the agency named only via measure_entity_link")
  })
})

test_that("load_measures_domain_data with agency_ids filters the scopable tables but never city_measures/strategic_plan", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)

  agencies <- DBI::dbGetQuery(connection, "SELECT agency_id FROM reference.agency WHERE active ORDER BY agency_id LIMIT 2")$agency_id
  full <- load_measures_domain_data(connection)
  scoped <- load_measures_domain_data(connection, agency_ids = agencies[1])

  expect_true(all(scoped$performance_performance_measure$agency_id %in% agencies[1]))
  expect_true(nrow(scoped$performance_performance_measure) <= nrow(full$performance_performance_measure))
  if (nrow(full$performance_performance_measure) > nrow(full$performance_performance_measure[full$performance_performance_measure$agency_id %in% agencies[1], ])) {
    expect_true(nrow(scoped$performance_performance_measure) < nrow(full$performance_performance_measure), info = "scoping to one agency out of several must actually narrow the result")
  }
  expect_true(all(scoped$performance_measure_entity_link$agency_id %in% agencies[1]))

  # Timeline/Action Plan pages show the same citywide dashboard to every
  # signed-in user regardless of role -- these must be byte-identical
  # whether or not agency_ids is passed.
  expect_identical(scoped$city_measures, full$city_measures)
  expect_identical(scoped$strategic_plan, full$strategic_plan)
})
