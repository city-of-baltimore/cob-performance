# Some reference.plan_entity rows represent offices that have since been
# abolished. They stay in the table for historical plan data, but should no
# longer appear as a selectable/active submitter -- reference.plan_entity.active
# already gates that everywhere entities are listed (app.R:596, 620, 2751,
# 2806, 3374, 3396), so setting it to false is enough; no data is deleted.
#
# Confirmed by Melanie (2026-07-23): Mayor's Office of Infrastructure
# Development is abolished.

source("R/database.R", local = TRUE)

connection <- connect_app_database()
on.exit(DBI::dbDisconnect(connection), add = TRUE)

abolished_public_names <- c("Mayor's Office of Infrastructure Development")

# RPostgres binds each params[[i]] to exactly one $i placeholder rather than
# serializing an R vector into a Postgres array literal, so an IN clause
# with one placeholder per name (built here) is used instead of = ANY($1).
placeholders <- paste0("$", seq_along(abolished_public_names), collapse = ", ")

DBI::dbWithTransaction(connection, {
  before <- DBI::dbGetQuery(
    connection,
    sprintf("SELECT entity_id, public_name, active FROM reference.plan_entity WHERE public_name IN (%s)", placeholders),
    params = as.list(abolished_public_names)
  )
  print(before)
  if (!nrow(before)) stop("No matching reference.plan_entity rows found -- check the name(s) above.")

  updated <- DBI::dbExecute(
    connection,
    sprintf("UPDATE reference.plan_entity SET active = false WHERE public_name IN (%s)", placeholders),
    params = as.list(abolished_public_names)
  )
  cat("rows deactivated:", updated, "\n")
})
