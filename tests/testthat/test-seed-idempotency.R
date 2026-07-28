# Regression guard for the two production incidents this session where a
# seed/reconciliation routine re-ran on every app restart and silently
# resurrected deleted team members / reverted role changes. Both were fixed
# with the same pattern: an `application.seed_applied` marker table gating a
# seed function to run at most once. These tests pin that gating behavior
# directly, independent of any particular seed's contents.

test_that("seed_already_applied / mark_seed_applied round-trip and re-marking is a no-op, not an error", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)

  with_rollback(connection, {
    marker <- paste0("ci_test_marker_", format(Sys.time(), "%Y%m%d%H%M%OS6"))

    expect_false(seed_already_applied(connection, marker))
    mark_seed_applied(connection, marker)
    expect_true(seed_already_applied(connection, marker))

    # ON CONFLICT (seed_name) DO NOTHING -- re-marking an already-applied
    # seed must not error (this is what makes the gate idempotent).
    expect_no_error(mark_seed_applied(connection, marker))
    expect_true(seed_already_applied(connection, marker))
  })
})

test_that("apply_user_entity_access_seed_once is a no-op once the seed is already marked applied", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)

  with_rollback(connection, {
    # This is the exact regression: before the fix, apply_user_entity_access_seed_once()
    # re-ran its seeding logic on every app restart, silently re-inserting
    # deleted access rows / overwriting role changes an admin had since made.
    # Marking "already applied" directly (rather than running the real seed
    # first) keeps this deterministic and, critically, never lets
    # apply_user_entity_access_seed()'s own internal DBI::dbWithTransaction()
    # run inside this test's transaction -- Postgres/DBI doesn't support
    # nesting those, which is what happened when this test ran for real
    # against CI's empty database (locally it passed by accident, since a
    # dev database usually already has this marker set).
    mark_seed_applied(connection, "user_entity_access_seed")
    result <- apply_user_entity_access_seed_once(
      connection,
      path = repo_path("database", "seed", "user_entity_access_seed.csv")
    )
    expect_false(result)
  })
})

test_that("apply_user_entity_access_seed_once with a missing seed file is a harmless no-op", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)

  with_rollback(connection, {
    marker_before <- seed_already_applied(connection, "user_entity_access_seed")
    result <- apply_user_entity_access_seed(connection, path = repo_path("database", "seed", "does_not_exist.csv"))
    expect_false(result)
  })
})

test_that("apply_change_mapping_by_created_date_once is a no-op once already marked applied", {
  # This is exactly how the backfill reaches production: it runs
  # automatically the next time ensure_review_schema() executes (any app
  # restart), gated so a second restart doesn't re-run it. Marking
  # "already applied" directly, rather than running it for real first,
  # matches the established pattern in this file for the same reason --
  # keeps this deterministic and avoids nesting a second transaction.
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)

  with_rollback(connection, {
    mark_seed_applied(connection, "change_mapping_by_created_date_backfill")
    result <- apply_change_mapping_by_created_date_once(connection)
    expect_false(result)
  })
})

test_that("apply_percent_value_scale_backfill_once is a no-op once already marked applied", {
  # Same reasoning as the change_mapping backfill above: this reaches
  # production automatically on next restart, gated so it never re-runs
  # (re-running would incorrectly re-scale values a human has since
  # legitimately entered as whole numbers).
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)

  with_rollback(connection, {
    mark_seed_applied(connection, "percent_value_scale_backfill")
    result <- apply_percent_value_scale_backfill_once(connection)
    expect_false(result)
  })
})
