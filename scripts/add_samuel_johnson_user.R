library(DBI)

source("R/database.R")

next_id <- function(con, table, column) {
  as.integer(dbGetQuery(con, sprintf("SELECT COALESCE(MAX(%s), 0) + 1 AS next_id FROM %s", column, table))$next_id[[1]])
}

interpolate_dollar_params <- function(con, sql, params = list()) {
  if (!length(params)) return(sql)
  for (i in rev(seq_along(params))) {
    value <- params[[i]]
    quoted <- if (length(value) == 0 || is.null(value) || (length(value) == 1 && is.na(value))) {
      "NULL"
    } else {
      as.character(DBI::dbQuoteLiteral(con, value))
    }
    sql <- gsub(paste0("\\$", i, "(?![0-9])"), quoted, sql, perl = TRUE)
  }
  sql
}

exec <- function(con, sql, params = list()) {
  dbExecute(con, interpolate_dollar_params(con, sql, params))
}

query_params <- function(con, sql, params = list()) {
  dbGetQuery(con, interpolate_dollar_params(con, sql, params))
}

con <- connect_app_database()
on.exit(dbDisconnect(con), add = TRUE)

email <- "samuel.johnson@baltimorecity.gov"
full_name <- "Samuel Johnson"
phone <- "410-396-4903"

DBI::dbWithTransaction(con, {
  user <- query_params(con, "SELECT user_id FROM access.\"user\" WHERE lower(email) = lower($1)", list(email))
  if (nrow(user)) {
    user_id <- user$user_id[[1]]
    exec(
      con,
      "UPDATE access.\"user\"
       SET full_name = $2,
           phone = COALESCE(NULLIF(phone, ''), $3),
           active = true
       WHERE user_id = $1",
      list(user_id, full_name, phone)
    )
  } else {
    user_id <- next_id(con, "access.\"user\"", "user_id")
    exec(
      con,
      "INSERT INTO access.\"user\"
       (user_id, email, full_name, phone, auth_type, password_hash, active, modified_by)
       VALUES ($1, $2, $3, $4, 'MicrosoftAD', NULL, true, NULL)",
      list(user_id, email, full_name, phone)
    )
  }

  existing_role <- query_params(
    con,
    "SELECT user_role_id FROM access.user_role WHERE user_id = $1 AND app_role = 'DeputyMayor' LIMIT 1",
    list(user_id)
  )
  if (!nrow(existing_role)) {
    exec(
      con,
      "INSERT INTO access.user_role
       (user_role_id, user_id, app_role, agency_id, budget_access, adaptive_planning, performance_plan_access)
       VALUES ($1, $2, 'DeputyMayor', NULL, false, false, true)",
      list(next_id(con, "access.user_role", "user_role_id"), user_id)
    )
  }

  cat("Samuel Johnson user_id:", user_id, "\n")
})
