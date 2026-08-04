# Reported 2026-08-03: the Bug/Fix page reloaded in a loop when toggling
# the status filter. Root cause: page_bug_fix() silently rewrote an empty
# status_filter to default_feedback_status_filter for DISPLAY purposes
# only, without ever writing that substitution back into
# feedback_status_filter_value() -- so the rendered selectInput's
# `selected =` didn't match what the reactive value actually held. Shiny
# re-syncing that mismatch (the freshly-rendered widget reporting its
# `selected` values back to the server as a fresh input) could re-trigger
# a full page re-render, reproducing the same mismatch again. Fixed by
# treating an empty status_filter as "no filter" (show everything),
# exactly like category_filter/priority_filter already do, and only
# applying default_feedback_status_filter where the reactive value is
# actually initialized (its reactiveVal declaration, and
# complete_sign_in()) -- never inside the render function itself.

test_that("page_bug_fix shows every status when status_filter is empty, not just the default subset", {
  feedback <- data.frame(
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
  db <- list(application_feedback_request = feedback, access_user_role = data.frame(user_id = integer(0), app_role = character(0), email = character(0), full_name = character(0)))

  html <- as.character(page_bug_fix(db, status_filter = character(0)))
  for (status in c("New", "Open", "In Review", "Complete", "Archived")) {
    expect_true(grepl(paste0("data-feedback-status=\"", status, "\""), html, fixed = TRUE))
  }
})

test_that("page_bug_fix still filters when a status is explicitly selected", {
  feedback <- data.frame(
    feedback_id = 1:2,
    user_email = "user@example.com",
    comment = "test",
    screenshot_data = NA_character_,
    page_key = "metrics",
    page_url = NA_character_,
    category = "Bug",
    priority = "Medium",
    status = c("New", "Archived"),
    assigned_admin_id = NA_integer_,
    assigned_admin_name = NA_character_,
    created_at = Sys.time(),
    updated_at = Sys.time(),
    modified_by = NA_integer_,
    stringsAsFactors = FALSE
  )
  db <- list(application_feedback_request = feedback, access_user_role = data.frame(user_id = integer(0), app_role = character(0), email = character(0), full_name = character(0)))

  html <- as.character(page_bug_fix(db, status_filter = "New"))
  expect_true(grepl("data-feedback-status=\"New\"", html, fixed = TRUE))
  expect_false(grepl("data-feedback-status=\"Archived\"", html, fixed = TRUE))
})
