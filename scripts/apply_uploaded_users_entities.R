source(file.path("R", "database.R"))

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0 || is.na(x)) y else x
csv_dir <- file.path("tmp", "upload_compare")
clean_text <- function(x) {
  x <- as.character(x)
  x[is.na(x) | trimws(x) %in% c("", "NA", "\u00a0")] <- NA_character_
  trimws(x)
}
clean_bool <- function(x, default = FALSE) {
  if (is.logical(x)) return(ifelse(is.na(x), default, x))
  text <- tolower(clean_text(x))
  ifelse(is.na(text), default, text %in% c("1", "true", "yes", "y"))
}
normalize_agency_role <- function(x) {
  x <- clean_text(x)
  ifelse(x == "Performance Metric Updates", "Performance Lead", x)
}
read_uploaded <- function(name) {
  read.csv(file.path(csv_dir, paste0(name, ".csv")), check.names = FALSE, stringsAsFactors = FALSE)
}
normalize_names <- function(data) {
  names(data) <- sub(" PK$", "", names(data))
  names(data) <- sub(" FK2$", "", names(data))
  names(data) <- sub(" FK$", "", names(data))
  data
}

plan_entity <- read_uploaded("PLAN_ENTITY")
users <- normalize_names(read_uploaded("USER"))
user_role <- normalize_names(read_uploaded("USER_ROLE"))
user_functions <- normalize_names(read_uploaded("USER_FUNCTIONS"))

plan_entity$entity_id <- as.integer(plan_entity$entity_id)
plan_entity$parent_agency_id <- clean_text(plan_entity$parent_agency_id)
plan_entity$parent_agency_id[plan_entity$parent_agency_id == "AGC4300"] <- "AGC4301"
plan_entity$public_name <- clean_text(plan_entity$public_name)
plan_entity$entity_type <- clean_text(plan_entity$entity_type)
plan_entity$has_own_plan <- clean_bool(plan_entity$has_own_plan)
plan_entity$active <- clean_bool(plan_entity$active)

users$user_id <- as.integer(users$user_id)
users$email <- clean_text(users$email)
users$full_name <- clean_text(users$full_name)
users$auth_type <- clean_text(users$auth_type)
users$active <- clean_bool(users$active, TRUE)

user_role$user_role_id <- as.integer(user_role$user_role_id)
user_role$user_id <- clean_text(user_role$user_id)
user_role$app_role <- clean_text(user_role$app_role)
user_role$agency_id <- clean_text(user_role$agency_id)
user_role$agency_id[user_role$agency_id %in% c("AGC3101", "AGC3102", "AGC3103")] <- "AGC3100"
user_role$budget_access <- clean_bool(user_role$budget_access)
user_role$adaptive_planning <- clean_bool(user_role$adaptive_planning)
user_role$performance_plan_access <- clean_bool(user_role$performance_plan_access, TRUE)

user_functions$user_id <- clean_text(user_functions$user_id)
user_functions$agency_id <- clean_text(user_functions$agency_id)
user_functions$agency_id[user_functions$agency_id %in% c("AGC3101", "AGC3102", "AGC3103")] <- "AGC3100"
user_functions$service_id <- clean_text(user_functions$service_id)
user_functions$agency_role <- normalize_agency_role(user_functions$agency_role)

con <- connect_app_database()
on.exit(DBI::dbDisconnect(con), add = TRUE)
DBI::dbBegin(con)
tryCatch({
  db_entities <- DBI::dbGetQuery(con, "SELECT entity_id FROM reference.plan_entity")
  new_entities <- plan_entity[!plan_entity$entity_id %in% db_entities$entity_id, , drop = FALSE]
  for (i in seq_len(nrow(new_entities))) {
    row <- new_entities[i, , drop = FALSE]
    DBI::dbExecute(
      con,
      "INSERT INTO reference.plan_entity (entity_id, parent_agency_id, public_name, entity_type, has_own_plan, active)
       VALUES ($1, $2, $3, $4, $5, $6)
       ON CONFLICT (entity_id) DO UPDATE SET
         parent_agency_id = EXCLUDED.parent_agency_id,
         public_name = EXCLUDED.public_name,
         entity_type = EXCLUDED.entity_type,
         has_own_plan = EXCLUDED.has_own_plan,
         active = EXCLUDED.active",
      params = list(row$entity_id, row$parent_agency_id, row$public_name, row$entity_type, row$has_own_plan, row$active)
    )
  }
  DBI::dbExecute(con, "SELECT setval(pg_get_serial_sequence('reference.plan_entity', 'entity_id'), COALESCE((SELECT MAX(entity_id) FROM reference.plan_entity), 1), (SELECT COUNT(*) > 0 FROM reference.plan_entity))")

  fy2027_cycle <- DBI::dbGetQuery(con, "SELECT cycle_id FROM planning.plan_cycle WHERE fiscal_year = 2027 LIMIT 1")$cycle_id[[1]]
  next_plan_id <- DBI::dbGetQuery(con, "SELECT COALESCE(MAX(plan_id), 0) + 1 AS next_plan_id FROM planning.agency_plan")$next_plan_id[[1]]
  for (entity_id in new_entities$entity_id[new_entities$has_own_plan & new_entities$active]) {
    existing_plan <- DBI::dbGetQuery(
      con,
      "SELECT plan_id FROM planning.agency_plan WHERE entity_id = $1 AND cycle_id = $2",
      params = list(entity_id, fy2027_cycle)
    )
    if (!nrow(existing_plan)) {
      DBI::dbExecute(
        con,
        "INSERT INTO planning.agency_plan (plan_id, agency_id, entity_id, cycle_id, plan_status, budget_status, version, created_at, updated_at)
         VALUES ($1, NULL, $2, $3, 'Draft', 'Draft', 1, now(), now())",
        params = list(next_plan_id, entity_id, fy2027_cycle)
      )
      next_plan_id <- next_plan_id + 1L
    }
  }
  DBI::dbExecute(con, "SELECT setval(pg_get_serial_sequence('planning.agency_plan', 'plan_id'), COALESCE((SELECT MAX(plan_id) FROM planning.agency_plan), 1), (SELECT COUNT(*) > 0 FROM planning.agency_plan))")

  valid_users <- users[!is.na(users$email), , drop = FALSE]
  for (i in seq_len(nrow(valid_users))) {
    row <- valid_users[i, , drop = FALSE]
    DBI::dbExecute(
      con,
      'INSERT INTO access."user" (email, full_name, phone, auth_type, password_hash, active, created_at)
       VALUES ($1, $2, NULL, $3, NULL, $4, now())
       ON CONFLICT (email) DO UPDATE SET
         full_name = EXCLUDED.full_name,
         auth_type = EXCLUDED.auth_type,
         active = EXCLUDED.active',
      params = list(row$email, row$full_name, row$auth_type %||% "MicrosoftAD", row$active)
    )
  }

  db_users <- DBI::dbGetQuery(con, 'SELECT user_id, lower(email) AS email FROM access."user"')
  user_id_by_email <- setNames(db_users$user_id, db_users$email)
  upload_email_by_id <- setNames(tolower(valid_users$email), valid_users$user_id)

  valid_roles <- user_role[!is.na(user_role$user_id) & !is.na(user_role$app_role), , drop = FALSE]
  for (i in seq_len(nrow(valid_roles))) {
    row <- valid_roles[i, , drop = FALSE]
    email <- tolower(if (grepl("@", row$user_id)) row$user_id else upload_email_by_id[[as.character(row$user_id)]])
    user_id <- user_id_by_email[[email]]
    if (is.null(user_id) || is.na(user_id)) next
    DBI::dbExecute(
      con,
      "INSERT INTO access.user_role (user_id, app_role, agency_id, granted_at, budget_access, adaptive_planning, performance_plan_access)
       SELECT $1, $2::varchar(30), $3::varchar(20), now(), $4, $5, $6
       WHERE NOT EXISTS (
         SELECT 1 FROM access.user_role
         WHERE user_id = $1
           AND app_role = $2::varchar(30)
           AND agency_id IS NOT DISTINCT FROM $3::varchar(20)
       )",
      params = list(user_id, row$app_role, row$agency_id, row$budget_access, row$adaptive_planning, row$performance_plan_access)
    )
  }
  DBI::dbExecute(con, "SELECT setval(pg_get_serial_sequence('access.user_role', 'user_role_id'), COALESCE((SELECT MAX(user_role_id) FROM access.user_role), 1), (SELECT COUNT(*) > 0 FROM access.user_role))")

  valid_functions <- user_functions[!is.na(user_functions$user_id) & !is.na(user_functions$agency_id) & !is.na(user_functions$agency_role), , drop = FALSE]
  for (i in seq_len(nrow(valid_functions))) {
    row <- valid_functions[i, , drop = FALSE]
    email <- tolower(if (grepl("@", row$user_id)) row$user_id else upload_email_by_id[[as.character(row$user_id)]])
    user_id <- user_id_by_email[[email]]
    if (is.null(user_id) || is.na(user_id)) next
    DBI::dbExecute(
      con,
      "UPDATE access.user_agency_access
       SET agency_role = $4::varchar(30)
       WHERE user_id = $1
         AND agency_id = $2::varchar(20)
         AND service_id IS NOT DISTINCT FROM $3::varchar(20)",
      params = list(user_id, row$agency_id, row$service_id, row$agency_role)
    )
    DBI::dbExecute(
      con,
      "INSERT INTO access.user_agency_access (user_id, agency_id, service_id, agency_role)
       SELECT $1, $2::varchar(20), $3::varchar(20), $4::varchar(30)
       WHERE NOT EXISTS (
         SELECT 1 FROM access.user_agency_access
         WHERE user_id = $1
           AND agency_id = $2::varchar(20)
           AND service_id IS NOT DISTINCT FROM $3::varchar(20)
       )",
      params = list(user_id, row$agency_id, row$service_id, row$agency_role)
    )
  }
  DBI::dbExecute(con, "SELECT setval(pg_get_serial_sequence('access.user_agency_access', 'access_id'), COALESCE((SELECT MAX(access_id) FROM access.user_agency_access), 1), (SELECT COUNT(*) > 0 FROM access.user_agency_access))")

  DBI::dbCommit(con)
  cat("Applied", nrow(new_entities), "new entities, refreshed users/roles/functions from upload.\n")
}, error = function(err) {
  DBI::dbRollback(con)
  stop(err)
})
