# Regression guard for the refresh_app_data() capacity fix (2026-08-06):
# every save anywhere in the app used to reload the entire ~31-query
# load_app_data(), even for a single CLS request edit. CLS was the first
# domain migrated to a targeted refresh (domains = "cls") since every CLS
# mutation function writes exclusively to budget.cls_request/
# cls_request_line/cls_request_position/cls_review -- confirmed by
# reading every one of them, see the comment on load_cls_domain_data() in
# R/database.R. This test guards the one thing that could quietly break
# that guarantee: load_cls_domain_data() (the targeted-refresh path) must
# always return exactly the same 4 tables, with the same content, as the
# equivalent slice of a full load_app_data() reload.

test_that("load_cls_domain_data matches the CLS slice of a full load_app_data reload", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)

  full <- load_app_data(connection)
  domain <- load_cls_domain_data(connection)

  cls_keys <- c("budget_cls_request", "budget_cls_request_line", "budget_cls_request_position", "budget_cls_review")
  expect_setequal(names(domain), cls_keys)
  for (key in cls_keys) {
    expect_identical(domain[[key]], full[[key]], info = key)
  }
})

test_that("refresh_domain_loaders in app.R only references known R/database.R loaders", {
  # A lightweight sanity check that doesn't require sourcing the whole
  # Shiny app: every loader named in app.R's refresh_domain_loaders list
  # must exist as a real function, so a typo'd domain name fails loudly
  # in CI rather than silently no-op-ing in production.
  app_lines <- readLines(repo_path("app.R"), warn = FALSE)
  # Trailing comma is optional -- every entry but the last in
  # refresh_domain_loaders has one, and this must keep matching all of
  # them as more domains are added, not just whichever is listed last.
  loader_lines <- grep("^\\s*[a-z_]+ = load_[a-z_]+_domain_data,?\\s*$", app_lines, value = TRUE)
  expect_true(length(loader_lines) >= 2)
  loader_names <- trimws(sub("^\\s*[a-z_]+ = (load_[a-z_]+_domain_data),?\\s*$", "\\1", loader_lines))
  for (loader_name in loader_names) {
    expect_true(exists(loader_name, mode = "function"), info = loader_name)
  }
})
