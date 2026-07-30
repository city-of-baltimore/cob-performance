source("R/database.R", local = TRUE)

connection <- connect_app_database()
on.exit(DBI::dbDisconnect(connection), add = TRUE)

DBI::dbWithTransaction(connection, {
  removed_entity_access <- DBI::dbExecute(
    connection,
    paste(
      "DELETE FROM access.user_entity_access",
      "WHERE user_id = 91 AND entity_id = 55"
    )
  )
  removed_agency_access <- DBI::dbExecute(
    connection,
    paste(
      "DELETE FROM access.user_agency_access",
      "WHERE user_id = 91 AND agency_id = 'AGC3100'"
    )
  )
  cat("removed_wrong_entity_access_rows=", removed_entity_access, "\n", sep = "")
  cat("removed_wrong_agency_access_rows=", removed_agency_access, "\n", sep = "")
})
