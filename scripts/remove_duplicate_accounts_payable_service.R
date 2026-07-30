# reference.service had two "accounts payable" rows: SRV0702 under Finance
# (AGC2300) and SRV0902 under Comptroller (AGC1200). SRV0902 is the real,
# fully-built service -- it has a description, three linked measures
# (586, 587, 597), and is correctly included in Comptroller's plan.
# SRV0702 had no description, no linked measures, and its only reference was
# a single plan_service row on Finance's own (Returned) plan -- an empty
# stray duplicate, likely a manual data-entry error, not the same record
# that just needed its agency_id corrected.
#
# Removes SRV0702 and its one plan_service reference. Comptroller's SRV0902
# is untouched.

source("R/database.R", local = TRUE)

connection <- connect_app_database()
on.exit(DBI::dbDisconnect(connection), add = TRUE)

DBI::dbWithTransaction(connection, {
  removed_plan_service <- DBI::dbExecute(
    connection,
    "DELETE FROM performance.plan_service WHERE service_id = 'SRV0702'"
  )
  removed_service <- DBI::dbExecute(
    connection,
    "DELETE FROM reference.service WHERE service_id = 'SRV0702'"
  )
  cat("removed_plan_service_rows=", removed_plan_service, "\n", sep = "")
  cat("removed_service_rows=", removed_service, "\n", sep = "")
})
