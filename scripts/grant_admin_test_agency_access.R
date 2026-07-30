# Grants all current SystemAdmin/OPIReviewer users user_agency_access to
# TST9001 (TEST Agency of Sparkly Sidewalks). This one is deliberately
# separate from the entity-access grants added via
# database/seed/user_entity_access_seed.csv: TST9001's plan is scoped by
# agency_id (planning.agency_plan.entity_id is NULL for it), unlike
# TST9002/TST9003 which are entity-scoped, so user_submitter_choices() only
# resolves it via user_agency_access/user_role.agency_id, not
# user_entity_access.
#
# Idempotent via WHERE NOT EXISTS, not ON CONFLICT: the existing
# (user_id, agency_id, service_id) unique constraint would never actually
# fire here since service_id is NULL on these rows and Postgres treats NULLs
# as distinct for uniqueness purposes, so ON CONFLICT would silently insert
# a duplicate row on a second run.

source("R/database.R", local = TRUE)

connection <- connect_app_database()
on.exit(DBI::dbDisconnect(connection), add = TRUE)

admin_emails <- c(
  "audrey.randazzo@baltimorecity.gov", "darren.lu@baltimorecity.gov", "derek.thomas@baltimorecity.gov",
  "nelson.gomesboronat@baltimorecity.gov", "ross.hackett@baltimorecity.gov",
  "danny.heller@baltimorecity.gov", "ethan.buckborough@baltimorecity.gov", "griffin.riddler@baltimorecity.gov",
  "melanie.lada@baltimorecity.gov", "sarah.schulte@baltimorecity.gov"
)

DBI::dbWithTransaction(connection, {
  inserted <- 0L
  for (email in admin_emails) {
    result <- DBI::dbExecute(
      connection,
      paste(
        "INSERT INTO access.user_agency_access",
        "(user_id, agency_id, agency_role, agency_roles, access_level, budget_access, performance_plan_access)",
        "SELECT u.user_id, 'TST9001', 'Agency Head', 'Agency Head', 'Submit', false, true",
        "FROM access.\"user\" u",
        "WHERE lower(u.email) = lower($1)",
        "AND NOT EXISTS (",
        "  SELECT 1 FROM access.user_agency_access uaa",
        "  WHERE uaa.user_id = u.user_id AND uaa.agency_id = 'TST9001' AND uaa.service_id IS NULL",
        ")"
      ),
      params = list(email)
    )
    inserted <- inserted + result
  }
  cat("inserted_agency_access_rows=", inserted, "\n", sep = "")
})
