# Follow-up to scripts/add_agc4317_agency_plan.R. Two things were still
# off for AGC4317 (M-R Consumer Protection and Business Licensing):
#
# 1. reference.agency.public_name was set to "Department of Consumer
#    Protection and Business Licensing", which made it display under that
#    name instead of the agency name -- every other regular (non-quasi)
#    single agency (Police, Fire, City Council, ...) has public_name = NULL
#    and displays under agency_name. Only true quasi-agency umbrellas (e.g.
#    AGC4326) have a distinct public_name. Nulling it here matches the
#    regular-agency convention.
#
# 2. The new plan (plan_id from add_agc4317_agency_plan.R) had no
#    performance.plan_service row linking it to SRV0921, so the service
#    never showed up on the plan's Services page even though the service
#    itself already existed in reference.service.

source("R/database.R", local = TRUE)

connection <- connect_app_database()
on.exit(DBI::dbDisconnect(connection), add = TRUE)

DBI::dbWithTransaction(connection, {
  updated <- DBI::dbExecute(connection, "UPDATE reference.agency SET public_name = NULL WHERE agency_id = 'AGC4317'")
  cat("reference.agency rows updated:", updated, "\n")

  plan <- DBI::dbGetQuery(connection, "SELECT plan_id FROM planning.agency_plan WHERE agency_id = 'AGC4317'")
  if (!nrow(plan)) stop("No plan found for AGC4317 -- run add_agc4317_agency_plan.R first.")
  plan_id <- plan$plan_id[[1]]

  existing_link <- DBI::dbGetQuery(connection, "SELECT plan_service_id FROM performance.plan_service WHERE plan_id = $1 AND service_id = 'SRV0921'", params = list(plan_id))
  if (nrow(existing_link)) {
    cat("plan_service link already exists for plan_id", plan_id, "\n")
  } else {
    DBI::dbExecute(
      connection,
      "INSERT INTO performance.plan_service (plan_id, service_id, sort_order) VALUES ($1, 'SRV0921', 1)",
      params = list(plan_id)
    )
    cat("Linked SRV0921 to plan_id", plan_id, "\n")
  }
})
