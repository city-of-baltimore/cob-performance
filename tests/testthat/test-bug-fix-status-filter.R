# Reported 2026-08-03: the Bug/Fix page reloaded in a loop when clearing
# the status filter to empty. Root cause #1: page_bug_fix() silently
# rewrote an empty status_filter to default_feedback_status_filter for
# DISPLAY purposes only, without ever writing that substitution back into
# feedback_status_filter_value() -- so the rendered selectInput's
# `selected =` didn't match what the reactive value actually held. Fixed by
# treating an empty status_filter as "no filter" (show everything), exactly
# like category_filter/priority_filter already do, and only applying
# default_feedback_status_filter where the reactive value is actually
# initialized (its reactiveVal declaration, and complete_sign_in()).
#
# Reported again 2026-08-04, still looping after the above fix: removing a
# single status (not clearing to empty) could also loop. Root cause #2:
# page_bug_fix()'s filter selectInputs were recreated from scratch every
# time output$page re-rendered, and output$page depended on the very
# reactiveVals those selectInputs fed back into. A freshly-initialized
# selectize widget echoes its current selection back to the server as an
# input event; when that echo raced the render that had just removed a
# status, it could report the *old* (pre-removal) selection, flipping the
# reactiveVal back, re-rendering again, and so on -- confirmed via
# server-side logging showing the selection oscillate between the pre- and
# post-removal values. Fixed by splitting the feedback list out into its
# own uiOutput("feedback_admin_list") (see feedback_list_ui() below and its
# registration in server()), and isolate()-ing the reads that feed
# page_bug_fix()'s filter controls inside output$page -- so changing a
# filter only re-renders the list, never the controls themselves.

feedback_rows_fixture <- function() {
  data.frame(
    feedback_id = 1:5,
    user_email = "user@example.com",
    comment = "test",
    screenshot_data = NA_character_,
    page_key = "metrics",
    page_url = NA_character_,
    category = "Bug",
    priority = "Medium",
    status = c("New", "Open", "In Review", "Complete", "Archived"),
    assigned_admin_id = NA_integer_,
    assigned_admin_name = NA_character_,
    created_at = Sys.time(),
    updated_at = Sys.time(),
    modified_by = NA_integer_,
    stringsAsFactors = FALSE
  )
}

feedback_db_fixture <- function(feedback) {
  list(application_feedback_request = feedback, access_user_role = data.frame(user_id = integer(0), app_role = character(0), email = character(0), full_name = character(0)))
}

test_that("feedback_list_ui shows every status when status_filter is empty, not just the default subset", {
  db <- feedback_db_fixture(feedback_rows_fixture())
  html <- as.character(feedback_list_ui(db, status_filter = character(0)))
  for (status in c("New", "Open", "In Review", "Complete", "Archived")) {
    expect_true(grepl(paste0("data-feedback-status=\"", status, "\""), html, fixed = TRUE))
  }
})

test_that("feedback_list_ui still filters when a status is explicitly selected", {
  feedback <- feedback_rows_fixture()
  feedback <- feedback[feedback$status %in% c("New", "Archived"), , drop = FALSE]
  db <- feedback_db_fixture(feedback)
  html <- as.character(feedback_list_ui(db, status_filter = "New"))
  expect_true(grepl("data-feedback-status=\"New\"", html, fixed = TRUE))
  expect_false(grepl("data-feedback-status=\"Archived\"", html, fixed = TRUE))
})

test_that("feedback_list_ui removing one status from a multi-selection only drops that status's rows", {
  db <- feedback_db_fixture(feedback_rows_fixture())
  # Simulates the exact repro: default New/Open/In Review, then "In Review"
  # gets removed, leaving New/Open -- rows for the other three statuses
  # (In Review/Complete/Archived) must all disappear, not just the removed one.
  html <- as.character(feedback_list_ui(db, status_filter = c("New", "Open")))
  expect_true(grepl("data-feedback-status=\"New\"", html, fixed = TRUE))
  expect_true(grepl("data-feedback-status=\"Open\"", html, fixed = TRUE))
  expect_false(grepl("data-feedback-status=\"In Review\"", html, fixed = TRUE))
  expect_false(grepl("data-feedback-status=\"Complete\"", html, fixed = TRUE))
  expect_false(grepl("data-feedback-status=\"Archived\"", html, fixed = TRUE))
})

test_that("feedback_list_ui shows the empty state when a filter combination matches nothing", {
  feedback <- feedback_rows_fixture()
  feedback <- feedback[feedback$status == "In Review", , drop = FALSE]
  db <- feedback_db_fixture(feedback)
  html <- as.character(feedback_list_ui(db, status_filter = c("New", "Open")))
  expect_true(grepl("No matching feedback", html, fixed = TRUE))
  expect_false(grepl("data-feedback-status", html, fixed = TRUE))
})

test_that("page_bug_fix no longer inlines the feedback list -- it renders a uiOutput instead", {
  db <- feedback_db_fixture(feedback_rows_fixture())
  html <- as.character(page_bug_fix(db, status_filter = character(0)))
  expect_false(grepl("data-feedback-status", html, fixed = TRUE))
  expect_true(grepl("feedback_admin_list", html, fixed = TRUE))
})

test_that("page_bug_fix renders the status selectInput with the given selection, not the hardcoded default", {
  db <- feedback_db_fixture(feedback_rows_fixture())
  html <- as.character(page_bug_fix(db, status_filter = c("New", "Open")))
  select_html <- sub(".*(<select[^>]*id=\"feedback_status_filter\".*?</select>).*", "\\1", html)
  expect_true(grepl("value=\"New\" selected", select_html, fixed = TRUE))
  expect_true(grepl("value=\"Open\" selected", select_html, fixed = TRUE))
  expect_false(grepl("value=\"In Review\" selected", select_html, fixed = TRUE))
})

test_that("feedback_filtered_rows combines search, category, priority, and status filters", {
  feedback <- feedback_rows_fixture()
  feedback$comment <- c("alpha issue", "beta issue", "gamma issue", "delta issue", "epsilon issue")
  feedback$category <- c("Bug", "Feature", "Bug", "Feature", "Bug")
  result <- feedback_filtered_rows(feedback, search = "beta", category_filter = character(0), priority_filter = character(0), status_filter = character(0))
  expect_equal(nrow(result), 1)
  expect_equal(result$comment, "beta issue")

  result2 <- feedback_filtered_rows(feedback, category_filter = "Bug", status_filter = c("New", "Archived"))
  expect_setequal(result2$status, c("New", "Archived"))
})
