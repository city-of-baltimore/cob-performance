# Regression guard for moving the failed-login throttle from an in-process
# R environment to Postgres (2026-08-07, ahead of running Beacon as
# multiple app processes) -- an in-memory version only holds the
# 5-failure/15-minute lockout within whichever single process happens to
# see all of one email's attempts; across multiple processes, a reconnect
# landing on a still-empty process would silently reset the count.

test_that("auth_attempt_blocked only blocks after AUTH_MAX_FAILURES failures within the lockout window", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)
  ensure_review_schema(connection)

  with_rollback(connection, {
    email <- "throttle-test@example.com"
    expect_false(auth_attempt_blocked(connection, email))

    for (i in seq_len(AUTH_MAX_FAILURES - 1)) {
      auth_note_failure(connection, email)
      expect_false(auth_attempt_blocked(connection, email), info = paste("failure", i))
    }
    auth_note_failure(connection, email)
    expect_true(auth_attempt_blocked(connection, email))
  })
})

test_that("auth_clear_failures resets the count so a subsequent login isn't blocked", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)
  ensure_review_schema(connection)

  with_rollback(connection, {
    email <- "throttle-clear-test@example.com"
    for (i in seq_len(AUTH_MAX_FAILURES)) auth_note_failure(connection, email)
    expect_true(auth_attempt_blocked(connection, email))

    auth_clear_failures(connection, email)
    expect_false(auth_attempt_blocked(connection, email))
  })
})

test_that("a lockout that has already expired does not block, and the next failure resets the count to 1", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)
  ensure_review_schema(connection)

  with_rollback(connection, {
    email <- "throttle-expired-test@example.com"
    for (i in seq_len(AUTH_MAX_FAILURES)) auth_note_failure(connection, email)
    expect_true(auth_attempt_blocked(connection, email))

    # Simulate the lockout window having already passed.
    DBI::dbExecute(connection, "UPDATE access.login_throttle SET locked_until = now() - interval '1 minute' WHERE email = $1", params = list(email))
    expect_false(auth_attempt_blocked(connection, email))

    auth_note_failure(connection, email)
    row <- DBI::dbGetQuery(connection, "SELECT failure_count FROM access.login_throttle WHERE email = $1", params = list(email))
    expect_identical(row$failure_count[[1]], 1L)
    expect_false(auth_attempt_blocked(connection, email))
  })
})

test_that("case and whitespace in the email don't create separate throttle entries", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)
  ensure_review_schema(connection)

  with_rollback(connection, {
    for (i in seq_len(AUTH_MAX_FAILURES)) auth_note_failure(connection, "  Throttle-Case-Test@Example.com ")
    expect_true(auth_attempt_blocked(connection, "throttle-case-test@example.com"))
  })
})
