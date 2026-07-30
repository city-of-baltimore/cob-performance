# Regression guard for the production incident (Darren Lu / Nadine Olaniran,
# "duplicate key value violates unique constraint user_role_user_id_key")
# fixed by switching save_team_role_assignment()'s access.user_role write from
# a check-then-branch UPDATE/INSERT to an atomic
# INSERT ... ON CONFLICT (user_id) DO UPDATE. The bug was a race between two
# overlapping saves for the same user both seeing "no existing row" and
# racing to INSERT; a single test process can't reproduce the race itself,
# but it can pin the behavior the fix depends on: saving the same person
# twice must never throw, and must never leave two access.user_role rows for
# one user_id.
#
# AGC3100 (Housing and Community Development) is a real seeded agency used
# elsewhere in this repo's own ad hoc test scripts (outputs/test_entity_team_rows.R).
#
# save_team_role_assignment() manages its own DBI::dbWithTransaction()
# internally (that's the fix being tested), so these tests can't wrap it in
# another transaction (nested transactions aren't supported) -- instead they
# clean up the rows they create by a distinctive email, in on.exit, so a run
# against a real local dev database never leaves residue behind.

test_that("saving the same person twice does not violate user_role_user_id_key", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  email <- "ci.regression.test.user@example.com"
  on.exit(
    {
      user_row <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" WHERE email = $1', params = list(email))
      if (nrow(user_row)) {
        uid <- user_row$user_id[[1]]
        DBI::dbExecute(connection, "DELETE FROM access.user_role WHERE user_id = $1", params = list(uid))
        DBI::dbExecute(connection, "DELETE FROM access.user_agency_access WHERE user_id = $1", params = list(uid))
        DBI::dbExecute(connection, 'DELETE FROM access."user" WHERE user_id = $1', params = list(uid))
      }
      DBI::dbDisconnect(connection)
    },
    add = TRUE
  )

  expect_no_error(
    save_team_role_assignment(
      connection, access_id = "new", agency_id = "AGC3100",
      full_name = "CI Regression Test User", email = email,
      agency_role = "Agency Staff", performance_role = "AgencySubmitter",
      budget_access = FALSE, adaptive_planning = FALSE, performance_plan_access = TRUE
    )
  )

  user_id <- DBI::dbGetQuery(connection, 'SELECT user_id FROM access."user" WHERE email = $1', params = list(email))$user_id[[1]]
  first_pass_roles <- DBI::dbGetQuery(connection, "SELECT app_role FROM access.user_role WHERE user_id = $1", params = list(user_id))
  expect_equal(nrow(first_pass_roles), 1)
  expect_equal(first_pass_roles$app_role[[1]], "AgencySubmitter")

  # Second save for the same person/agency -- this is the exact shape of the
  # failing case: same user_id, another INSERT attempt into
  # access.user_role. Also changes the role, to confirm the upsert actually
  # updates rather than silently no-op'ing.
  expect_no_error(
    save_team_role_assignment(
      connection, access_id = "new", agency_id = "AGC3100",
      full_name = "CI Regression Test User", email = email,
      agency_role = "Agency Staff", performance_role = "AgencyApprover",
      budget_access = FALSE, adaptive_planning = FALSE, performance_plan_access = TRUE
    )
  )

  second_pass_roles <- DBI::dbGetQuery(connection, "SELECT app_role FROM access.user_role WHERE user_id = $1", params = list(user_id))
  expect_equal(nrow(second_pass_roles), 1)
  expect_equal(second_pass_roles$app_role[[1]], "AgencyApprover")
})

test_that("save_team_role_assignment rejects an invalid performance role rather than writing bad data", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)

  # No transaction is opened on this path -- validation fails before
  # save_team_role_assignment() ever calls DBI::dbWithTransaction() -- so
  # nothing is written and there's nothing to clean up.
  expect_error(
    save_team_role_assignment(
      connection, access_id = "new", agency_id = "AGC3100",
      full_name = "CI Bad Role Test User", email = "ci.bad.role.test@example.com",
      agency_role = "Agency Staff", performance_role = "NotARealRole",
      budget_access = FALSE, adaptive_planning = FALSE, performance_plan_access = TRUE
    ),
    "valid performance role"
  )
})
