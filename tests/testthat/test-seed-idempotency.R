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

test_that("apply_user_entity_access_seed_once is a no-op on a second call once marked applied", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)

  with_rollback(connection, {
    seed_path <- repo_path("database", "seed", "user_entity_access_seed.csv")

    apply_user_entity_access_seed_once(connection, path = seed_path)
    expect_true(seed_already_applied(connection, "user_entity_access_seed"))

    # This is the exact regression: before the fix, this second call (which
    # is what happened on every app restart) would re-apply the seed and
    # silently re-insert/overwrite live access rows an admin had since
    # changed or deleted. After the fix it must return FALSE and touch
    # nothing.
    second_call_result <- apply_user_entity_access_seed_once(connection, path = seed_path)
    expect_false(second_call_result)
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
