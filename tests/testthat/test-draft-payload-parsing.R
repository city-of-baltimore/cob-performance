# Backlog item: "silent JSON-parse error swallowing." Scoped 2026-07-24.
#
# Surveyed every jsonlite::fromJSON call site in app.R/R/database.R.
# Two genuinely risky ones (reading a *stored* draft payload back out --
# in with_section_draft_lock() and section_draft_payload()) silently
# treated a parse failure identically to "no draft exists yet," with no
# trace that anything was wrong. Both now go through
# parse_stored_draft_payload(), which warns instead. Note: Postgres's
# jsonb column type already rejects syntactically invalid JSON at INSERT
# time, so this is defensive against something other than a jsonlite
# quirk -- it doesn't change behavior in the "valid JSON but not a list"
# case (a JSON string/array/number instead of an object), which the merge
# functions already handle safely via their own is.list() guard. A
# warning at least makes a genuine parse failure discoverable in logs
# rather than silently indistinguishable from a normal first-ever save.
#
# The other fromJSON call sites were checked and are fine as-is:
# - goals_draft_quiet_save/services_draft_quiet_save parse the *incoming*
#   client payload and already surface a visible error to the user on
#   failure ("The goals/services draft could not be read"), rather than
#   silently proceeding.
# - plan_draft_payloads() (used at plan approval/publish) has no tryCatch
#   at all -- a corrupted payload throws and aborts the transaction, which
#   is loud, not silent.
# - validate_measure_selection_limit() parses but is a deliberate no-op
#   regardless of parse outcome (see its own comment) -- not a swallowing
#   bug, just an intentionally permissive validator.

test_that("parse_stored_draft_payload warns and returns NULL on invalid JSON", {
  expect_warning(
    result <- parse_stored_draft_payload("{not valid json", context = "test context"),
    "test context"
  )
  expect_null(result)
})

test_that("parse_stored_draft_payload returns the parsed payload silently when JSON is valid", {
  expect_no_warning(
    result <- parse_stored_draft_payload('{"values":{"a":"b"}}')
  )
  expect_equal(result$values$a, "b")
})
