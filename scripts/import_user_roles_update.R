library(DBI)

source("R/database.R")

csv_dir <- "tmp_user_roles_update"

clean <- function(value) {
  if (is.null(value)) return("")
  value <- trimws(as.character(value))
  value[is.na(value)] <- ""
  value[value %in% c("NA", "NaN", "\u00a0")] <- ""
  value
}

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0 || is.na(x)) y else x

bool_from_sheet <- function(value, default = FALSE) {
  value <- tolower(clean(value))
  if (!nzchar(value)) return(default)
  value %in% c("yes", "true", "1", "y")
}

name_key <- function(value) {
  value <- clean(value)
  value <- sub("\\s+-\\s+.*$", "", value)
  value <- sub("^Independent\\s+-\\s+", "", value, ignore.case = TRUE)
  value <- tolower(value)
  gsub("[^a-z0-9]+", "", value)
}

public_name_key <- function(value) {
  value <- clean(value)
  value <- gsub("&", " and ", value, fixed = TRUE)
  value <- sub("^M-R\\s+Office\\s+of\\s+", "Mayor's Office of ", value, ignore.case = TRUE)
  value <- sub("^M-R\\s+", "Mayor's Office of ", value, ignore.case = TRUE)
  value <- sub("^Mayors\\s+Office\\s+of\\s+", "Mayor's Office of ", value, ignore.case = TRUE)
  value <- tolower(value)
  value <- gsub("\\band\\b", "", value)
  gsub("[^a-z0-9]+", "", value)
}

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

read_clean_csv <- function(filename) {
  path <- file.path(csv_dir, filename)
  if (!file.exists(path)) stop("Missing prepared CSV: ", path)
  rows <- read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
  for (column in names(rows)) rows[[column]] <- clean(rows[[column]])
  rows
}

user_rows <- read_clean_csv("user.csv")
role_rows <- read_clean_csv("user_role.csv")
function_rows <- read_clean_csv("user_functions.csv")
entity_scope_rows <- read_clean_csv("dh_userlist_with_entities.csv")

user_rows <- user_rows[nzchar(user_rows$email) & grepl("@", user_rows$email, fixed = TRUE), , drop = FALSE]
user_rows$email_key <- tolower(user_rows$email)
user_rows <- user_rows[!duplicated(user_rows$email_key), , drop = FALSE]

con <- connect_app_database()
on.exit(dbDisconnect(con), add = TRUE)
ensure_review_schema(con)

existing_users <- dbGetQuery(con, "SELECT user_id, email, full_name FROM access.\"user\"")
existing_users$email_key <- tolower(existing_users$email)
new_users <- user_rows[!user_rows$email_key %in% existing_users$email_key, , drop = FALSE]

cat("Workbook users:", nrow(user_rows), "\n")
cat("New users to insert:", nrow(new_users), "\n")
if (nrow(new_users)) {
  print(new_users[, c("email", "full_name", "auth_type"), drop = FALSE])
}

inserted <- data.frame(user_id = integer(), email = character(), full_name = character())

DBI::dbWithTransaction(con, {
  for (i in seq_len(nrow(new_users))) {
    row <- new_users[i, , drop = FALSE]
    user_id <- next_id(con, "access.\"user\"", "user_id")
    auth_type <- clean(row$auth_type[[1]])
    if (!nzchar(auth_type)) auth_type <- if (grepl("@baltimorecity.gov$", tolower(row$email[[1]]))) "MicrosoftAD" else "Email"
    exec(
      con,
      paste(
        "INSERT INTO access.\"user\"",
        "(user_id, email, full_name, phone, auth_type, password_hash, active, modified_by)",
        "VALUES ($1, $2, $3, NULLIF($4, ''), $5, NULL, true, NULL)"
      ),
      list(user_id, tolower(row$email[[1]]), row$full_name[[1]], clean(row$phone[[1]]), auth_type)
    )
    inserted <<- rbind(inserted, data.frame(user_id = user_id, email = tolower(row$email[[1]]), full_name = row$full_name[[1]]))

    role <- role_rows[tolower(role_rows[["user_id FK2"]]) == tolower(row$email[[1]]), , drop = FALSE]
    if (nrow(role)) {
      role <- role[1, , drop = FALSE]
      app_role <- clean(role$app_role[[1]])
      agency_id <- clean(role[["agency_id FK"]][[1]])
      if (nzchar(app_role)) {
        existing_role <- query_params(
          con,
          paste(
            "SELECT user_role_id FROM access.user_role",
            "WHERE user_id=$1 AND app_role=$2 AND COALESCE(agency_id, '')=COALESCE(NULLIF($3, ''), '')",
            "LIMIT 1"
          ),
          list(user_id, app_role, agency_id)
        )
        if (!nrow(existing_role)) {
          exec(
            con,
            paste(
              "INSERT INTO access.user_role",
              "(user_role_id, user_id, app_role, agency_id, budget_access, adaptive_planning, performance_plan_access)",
              "VALUES ($1,$2,$3,NULLIF($4, ''),$5,$6,$7)"
            ),
            list(
              next_id(con, "access.user_role", "user_role_id"),
              user_id,
              app_role,
              agency_id,
              bool_from_sheet(role$budget_access[[1]], FALSE),
              bool_from_sheet(role$adaptive_planning[[1]], FALSE),
              bool_from_sheet(role$performance_plan_access[[1]], TRUE)
            )
          )
        }
      }
    }

    workbook_id <- clean(row[["user_id PK"]][[1]])
    function_match <- function_rows[clean(function_rows[["user_id FK"]]) == workbook_id, , drop = FALSE]
    if (nrow(function_match)) {
      function_match <- function_match[1, , drop = FALSE]
      agency_id <- clean(function_match[["agency_id FK"]][[1]])
      agency_role <- clean(function_match$agency_role[[1]])
      if (nzchar(agency_id) && nzchar(agency_role)) {
        existing_access <- query_params(
          con,
          paste(
            "SELECT access_id FROM access.user_agency_access",
            "WHERE user_id=$1 AND agency_id=$2 AND COALESCE(service_id, '')=COALESCE(NULLIF($3, ''), '')",
            "LIMIT 1"
          ),
          list(user_id, agency_id, clean(function_match[["service_id FK"]][[1]]))
        )
        if (!nrow(existing_access)) {
          exec(
            con,
            paste(
              "INSERT INTO access.user_agency_access",
              "(access_id, user_id, agency_id, service_id, agency_role, access_level, budget_access, performance_plan_access)",
              "VALUES ($1,$2,$3,NULLIF($4, ''),$5,'Edit',false,true)"
            ),
            list(
              next_id(con, "access.user_agency_access", "access_id"),
              user_id,
              agency_id,
              clean(function_match[["service_id FK"]][[1]]),
              agency_role
            )
          )
        }
      }
    }
  }

  db_users_for_scope <- dbGetQuery(con, "SELECT user_id, lower(email) AS email_key FROM access.\"user\" WHERE active")
  user_id_by_email <- stats::setNames(db_users_for_scope$user_id, db_users_for_scope$email_key)
  db_entities <- dbGetQuery(
    con,
    paste(
      "SELECT pe.entity_id, pe.parent_agency_id, pe.public_name, pes.service_id, pes.is_primary",
      "FROM reference.plan_entity pe",
      "LEFT JOIN reference.plan_entity_service pes ON pes.entity_id = pe.entity_id",
      "WHERE pe.active AND pe.has_own_plan",
      "ORDER BY pe.entity_id, pes.is_primary DESC NULLS LAST, pes.pes_id"
    )
  )
  entity_ids <- unique(db_entities$entity_id)
  primary_entity_rows <- do.call(rbind, lapply(entity_ids, function(entity_id) {
    rows <- db_entities[db_entities$entity_id == entity_id, , drop = FALSE]
    rows[1, , drop = FALSE]
  }))
  entity_by_id <- stats::setNames(seq_len(nrow(primary_entity_rows)), as.character(primary_entity_rows$entity_id))
  entity_by_public_name <- stats::setNames(seq_len(nrow(primary_entity_rows)), public_name_key(primary_entity_rows$public_name))
  db_agencies <- dbGetQuery(con, "SELECT agency_id, public_name, agency_name FROM reference.agency WHERE active")
  agency_by_public_name <- stats::setNames(db_agencies$agency_id, public_name_key(ifelse(nzchar(clean(db_agencies$public_name)), db_agencies$public_name, db_agencies$agency_name)))

  resolve_scope <- function(row) {
    entity_id <- suppressWarnings(as.integer(clean(row[["Entity ID"]][[1]])))
    if (!is.na(entity_id) && as.character(entity_id) %in% names(entity_by_id)) {
      entity <- primary_entity_rows[entity_by_id[[as.character(entity_id)]], , drop = FALSE]
      return(list(agency_id = entity$parent_agency_id[[1]], service_id = clean(entity$service_id[[1]]), matched_public_name = entity$public_name[[1]]))
    }
    candidates <- unique(c(clean(row[["Final Tracking Name"]][[1]]), clean(row[["Entity Name"]][[1]]), clean(row[["Agency Name"]][[1]])))
    candidates <- candidates[nzchar(candidates)]
    for (candidate in candidates) {
      key <- public_name_key(candidate)
      if (nzchar(key) && key %in% names(entity_by_public_name)) {
        entity <- primary_entity_rows[entity_by_public_name[[key]], , drop = FALSE]
        return(list(agency_id = entity$parent_agency_id[[1]], service_id = clean(entity$service_id[[1]]), matched_public_name = entity$public_name[[1]]))
      }
    }
    for (candidate in candidates) {
      key <- public_name_key(candidate)
      if (nzchar(key) && key %in% names(agency_by_public_name)) {
        return(list(agency_id = agency_by_public_name[[key]], service_id = "", matched_public_name = candidate))
      }
    }
    agency_id <- clean(row[["agency_id FK"]][[1]])
    if (nzchar(agency_id)) return(list(agency_id = agency_id, service_id = "", matched_public_name = clean(row[["Final Tracking Name"]][[1]])))
    NULL
  }

  scoped_rows_added <- 0L
  scoped_roles_added <- 0L
  unmatched_scope_rows <- data.frame(email = character(), final_tracking_name = character(), stringsAsFactors = FALSE)
  valid_entity_scope_rows <- entity_scope_rows[
    nzchar(entity_scope_rows[["user_id FK2"]]) &
      grepl("@", entity_scope_rows[["user_id FK2"]], fixed = TRUE),
    ,
    drop = FALSE
  ]
  for (i in seq_len(nrow(valid_entity_scope_rows))) {
    row <- valid_entity_scope_rows[i, , drop = FALSE]
    email <- tolower(clean(row[["user_id FK2"]][[1]]))
    user_id <- user_id_by_email[[email]]
    if (is.null(user_id) || is.na(user_id)) next
    scope <- resolve_scope(row)
    if (is.null(scope) || !nzchar(clean(scope$agency_id))) {
      unmatched_scope_rows <- rbind(unmatched_scope_rows, data.frame(email = email, final_tracking_name = clean(row[["Final Tracking Name"]][[1]])))
      next
    }
    app_role <- clean(row$app_role[[1]])
    if (nzchar(app_role)) {
      existing_role <- query_params(
        con,
        paste(
          "SELECT user_role_id FROM access.user_role",
          "WHERE user_id=$1 AND app_role=$2 AND agency_id IS NOT DISTINCT FROM $3::varchar(20)",
          "LIMIT 1"
        ),
        list(user_id, app_role, scope$agency_id)
      )
      if (!nrow(existing_role)) {
        exec(
          con,
          paste(
            "INSERT INTO access.user_role",
            "(user_role_id, user_id, app_role, agency_id, budget_access, adaptive_planning, performance_plan_access)",
            "VALUES ($1,$2,$3,$4,$5,$6,$7)"
          ),
          list(
            next_id(con, "access.user_role", "user_role_id"),
            user_id,
            app_role,
            scope$agency_id,
            bool_from_sheet(row$budget_access[[1]], FALSE),
            bool_from_sheet(row$adaptive_planning[[1]], FALSE),
            bool_from_sheet(row$performance_plan_access[[1]], TRUE)
          )
        )
        scoped_roles_added <- scoped_roles_added + 1L
      }
    }
    existing_access <- query_params(
      con,
      paste(
        "SELECT access_id FROM access.user_agency_access",
        "WHERE user_id=$1 AND agency_id=$2 AND service_id IS NOT DISTINCT FROM NULLIF($3, '')::varchar(20)",
        "LIMIT 1"
      ),
      list(user_id, scope$agency_id, scope$service_id)
    )
    if (!nrow(existing_access)) {
      exec(
        con,
        paste(
          "INSERT INTO access.user_agency_access",
          "(access_id, user_id, agency_id, service_id, agency_role, access_level, budget_access, performance_plan_access)",
          "VALUES ($1,$2,$3,NULLIF($4, ''),$5,'Edit',false,true)"
        ),
        list(
          next_id(con, "access.user_agency_access", "access_id"),
          user_id,
          scope$agency_id,
          scope$service_id,
          "Agency Staff"
        )
      )
      scoped_rows_added <- scoped_rows_added + 1L
    }
  }

  current_users <- dbGetQuery(con, "SELECT user_id, full_name, email FROM access.\"user\" WHERE active")
  user_lookup <- stats::setNames(current_users$user_id, name_key(current_users$full_name))

  resolve_user_id <- function(name) {
    key <- name_key(name)
    if (!nzchar(key) || !key %in% names(user_lookup)) return(NA_integer_)
    as.integer(user_lookup[[key]])
  }

  assignment_rows <- dbGetQuery(con, "SELECT assignment_id, submitter_name, submitter_user_id, reviewer_name, reviewer_user_id, deputy_mayor_name, deputy_mayor_user_id, ca_office_name, ca_office_user_id FROM workflow.entity_role_assignment")
  for (i in seq_len(nrow(assignment_rows))) {
    row <- assignment_rows[i, , drop = FALSE]
    submitter_user_id <- if (is.na(row$submitter_user_id[[1]])) resolve_user_id(row$submitter_name[[1]]) else row$submitter_user_id[[1]]
    reviewer_user_id <- if (is.na(row$reviewer_user_id[[1]])) resolve_user_id(row$reviewer_name[[1]]) else row$reviewer_user_id[[1]]
    deputy_mayor_user_id <- if (is.na(row$deputy_mayor_user_id[[1]])) resolve_user_id(row$deputy_mayor_name[[1]]) else row$deputy_mayor_user_id[[1]]
    ca_office_user_id <- if (is.na(row$ca_office_user_id[[1]])) resolve_user_id(row$ca_office_name[[1]]) else row$ca_office_user_id[[1]]
    exec(
      con,
      paste(
        "UPDATE workflow.entity_role_assignment",
        "SET submitter_user_id=$2, reviewer_user_id=$3, deputy_mayor_user_id=$4, ca_office_user_id=$5, updated_at=now()",
        "WHERE assignment_id=$1"
      ),
      list(row$assignment_id[[1]], submitter_user_id, reviewer_user_id, deputy_mayor_user_id, ca_office_user_id)
    )
  }
})

unmatched_assignments <- dbGetQuery(
  con,
  paste(
    "SELECT public_name, submitter_name, reviewer_name, deputy_mayor_name, ca_office_name",
    "FROM workflow.entity_role_assignment",
    "WHERE (submitter_name IS NOT NULL AND submitter_user_id IS NULL)",
    "OR (reviewer_name IS NOT NULL AND reviewer_user_id IS NULL)",
    "OR (deputy_mayor_name IS NOT NULL AND deputy_mayor_user_id IS NULL)",
    "OR (ca_office_name IS NOT NULL AND ca_office_user_id IS NULL)",
    "ORDER BY public_name"
  )
)

cat("Inserted users:", nrow(inserted), "\n")
if (nrow(inserted)) print(inserted)
cat("Assignment rows still missing at least one user id:", nrow(unmatched_assignments), "\n")
if (nrow(unmatched_assignments)) print(utils::head(unmatched_assignments, 12))
if (exists("scoped_rows_added")) cat("Entity/public-name scoped access rows added:", scoped_rows_added, "\n")
if (exists("scoped_roles_added")) cat("Entity/public-name scoped roles added:", scoped_roles_added, "\n")
if (exists("unmatched_scope_rows") && nrow(unmatched_scope_rows)) {
  cat("DH_USERLIST rows still unmatched by public name:", nrow(unmatched_scope_rows), "\n")
  print(utils::head(unmatched_scope_rows, 12))
}
