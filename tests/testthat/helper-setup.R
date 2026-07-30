# Beacon (app.R) isn't structured as an R package, so there's no NAMESPACE
# to load -- tests instead source app.R's top-level definitions directly,
# the same trick already used by the ad hoc scripts under outputs/: strip
# everything from the shinyApp(...) call onward (so we get every function
# definition without actually launching the app) and eval it into the global
# environment once per test run.
if (!exists("connect_app_database", mode = "function", envir = globalenv())) {
  # testthat runs with the working directory shifted to tests/testthat/, but
  # app.R's own source(file.path("R", "database.R")) call is repo-root-relative
  # -- so the working directory needs to actually be the repo root while
  # app.R's top-level code runs, not just when reading the file.
  repo_root <- file.path("..", "..")
  app_lines <- readLines(file.path(repo_root, "app.R"), warn = FALSE)
  shiny_app_call <- grep("^shinyApp\\(", app_lines)
  if (length(shiny_app_call)) app_lines <- app_lines[seq_len(shiny_app_call[[1]] - 1)]

  previous_wd <- setwd(repo_root)
  on.exit(setwd(previous_wd), add = TRUE)
  eval(parse(text = app_lines), envir = globalenv())
}

# DB-backed tests need a real Postgres reachable via DATABASE_URL (CI provides
# one as a service container with the same schema/seed as docker-compose;
# locally, run `docker compose up db` and export DATABASE_URL to match). Tests
# that don't touch the database at all (pure display-name/export-row logic
# against hand-built fixtures) run everywhere, with or without a database.
skip_if_no_test_database <- function() {
  testthat::skip_if_not(nzchar(Sys.getenv("DATABASE_URL")), "DATABASE_URL not set -- skipping database-backed test")
}

# Resolves a path (e.g. "database/seed/user_entity_access_seed.csv") from the
# repo root, regardless of testthat's working-directory shift to tests/testthat/.
repo_path <- function(...) file.path("..", "..", ...)

# Runs `code` inside a transaction that is always rolled back, so
# database-backed tests never leave residue in whatever Postgres they ran
# against (the CI database is ephemeral anyway, but this also makes it safe
# to point a developer's own persistent local dev database at these tests).
with_rollback <- function(connection, code) {
  DBI::dbBegin(connection)
  on.exit(DBI::dbRollback(connection), add = TRUE)
  force(code)
}
