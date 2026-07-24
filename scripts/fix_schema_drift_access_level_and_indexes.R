# One-off fix for two of the schema-drift items found in the 2026-07-24
# audit against database/schema/target_schema.sql (see project backlog item
# #1, "Schema drift beyond target_schema.sql"):
#
#   - access.user_agency_access.access_level predates the NOT NULL DEFAULT
#     'Edit' constraint added to target_schema.sql; since ADD COLUMN IF NOT
#     EXISTS is a no-op against a column that already exists, the constraint
#     was never actually enforced on this database. 7 of 469 rows had a NULL
#     access_level as of this audit. Backfills those 7 to 'Edit' (the same
#     default every other row already effectively uses) and then applies the
#     constraint for real.
#   - Six modified_by indexes that target_schema.sql's generic backfill loop
#     should have created were missing, because each of these tables/columns
#     reached its current state only after that loop's one-time run against
#     this database (target_schema.sql only auto-applies on a fresh database
#     -- see its own header comment). All CREATE INDEX IF NOT EXISTS, so
#     re-running this script is always safe.
#
# Not covered here (confirmed via the same audit, no live change needed):
#   - performance.service_risk and review.section_score already have the
#     columns/constraints target_schema.sql was missing -- only the file
#     itself needed updating to match reality.
#   - workflow.plan_approval_stamp's missing updated_at/modified_by columns
#     are fixed in R/database.R directly (self-healing on next app
#     deploy/restart), not here.

source("R/database.R", local = TRUE)

connection <- connect_app_database()
on.exit(DBI::dbDisconnect(connection), add = TRUE)

DBI::dbWithTransaction(connection, {
  null_before <- DBI::dbGetQuery(
    connection,
    "SELECT count(*) AS n FROM access.user_agency_access WHERE access_level IS NULL"
  )$n[[1]]
  cat("access_level NULL rows before backfill:", null_before, "\n")

  backfilled <- DBI::dbExecute(
    connection,
    "UPDATE access.user_agency_access SET access_level = 'Edit' WHERE access_level IS NULL"
  )
  cat("rows backfilled to 'Edit':", backfilled, "\n")

  DBI::dbExecute(connection, "ALTER TABLE access.user_agency_access ALTER COLUMN access_level SET DEFAULT 'Edit'")
  DBI::dbExecute(connection, "ALTER TABLE access.user_agency_access ALTER COLUMN access_level SET NOT NULL")
  cat("access_level constraint applied (NOT NULL DEFAULT 'Edit')\n")

  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_access_password_reset_token_modified_by ON access.password_reset_token(modified_by)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_access_user_entity_access_modified_by ON access.user_entity_access(modified_by)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_access_user_login_session_modified_by ON access.user_login_session(modified_by)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_review_measure_review_modified_by ON review.measure_review(modified_by)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_workflow_entity_role_assignment_modified_by ON workflow.entity_role_assignment(modified_by)")
  cat("indexes created (or already present)\n")

  null_after <- DBI::dbGetQuery(
    connection,
    "SELECT count(*) AS n FROM access.user_agency_access WHERE access_level IS NULL"
  )$n[[1]]
  if (null_after != 0) stop("expected 0 NULL access_level rows after backfill, found ", null_after)
  cat("access_level NULL rows after backfill:", null_after, "\n")
})
