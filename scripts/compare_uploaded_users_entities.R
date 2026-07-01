source(file.path("R", "database.R"))

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x
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

read_uploaded <- function(name) {
  read.csv(file.path(csv_dir, paste0(name, ".csv")), check.names = FALSE, stringsAsFactors = FALSE)
}

plan_entity <- read_uploaded("PLAN_ENTITY")
plan_entity_service <- read_uploaded("PLAN_ENTITY_SERVICE")
users <- read_uploaded("USER")
user_role <- read_uploaded("USER_ROLE")
user_functions <- read_uploaded("USER_FUNCTIONS")

names(users) <- sub(" PK$", "", names(users))
names(users) <- sub(" FK2$", "", names(users))
names(users) <- sub(" FK$", "", names(users))
names(user_role) <- sub(" PK$", "", names(user_role))
names(user_role) <- sub(" FK2$", "", names(user_role))
names(user_role) <- sub(" FK$", "", names(user_role))
names(user_functions) <- sub(" PK$", "", names(user_functions))
names(user_functions) <- sub(" FK2$", "", names(user_functions))
names(user_functions) <- sub(" FK$", "", names(user_functions))

con <- connect_app_database()
on.exit(DBI::dbDisconnect(con), add = TRUE)

db_entities <- DBI::dbGetQuery(con, "SELECT entity_id, parent_agency_id, public_name, entity_type, has_own_plan, active FROM reference.plan_entity ORDER BY entity_id")
db_entity_services <- DBI::dbGetQuery(con, "SELECT pes_id, entity_id, service_id, is_primary FROM reference.plan_entity_service ORDER BY pes_id")
db_users <- DBI::dbGetQuery(con, 'SELECT user_id, email, full_name, auth_type, active FROM access."user" ORDER BY user_id')
db_roles <- DBI::dbGetQuery(con, "SELECT user_role_id, user_id, app_role, agency_id, budget_access, adaptive_planning, performance_plan_access FROM access.user_role ORDER BY user_role_id")
db_functions <- DBI::dbGetQuery(con, "SELECT access_id, user_id, agency_id, service_id, agency_role FROM access.user_agency_access ORDER BY access_id")

plan_entity$entity_id <- as.integer(plan_entity$entity_id)
plan_entity$parent_agency_id <- clean_text(plan_entity$parent_agency_id)
plan_entity$public_name <- clean_text(plan_entity$public_name)
plan_entity$entity_type <- clean_text(plan_entity$entity_type)
plan_entity$has_own_plan <- clean_bool(plan_entity$has_own_plan)
plan_entity$active <- clean_bool(plan_entity$active)

plan_entity_service$pes_id <- as.integer(plan_entity_service$pes_id)
plan_entity_service$entity_id <- as.integer(plan_entity_service$entity_id)
plan_entity_service$service_id <- clean_text(plan_entity_service$service_id)
plan_entity_service$is_primary <- clean_bool(plan_entity_service$is_primary)

users$user_id <- as.integer(users$user_id)
users$email <- clean_text(users$email)
users$full_name <- clean_text(users$full_name)
users$auth_type <- clean_text(users$auth_type)
users$active <- clean_bool(users$active, TRUE)

user_role$user_role_id <- as.integer(user_role$user_role_id)
user_role$user_id <- clean_text(user_role$user_id)
user_role$app_role <- clean_text(user_role$app_role)
user_role$agency_id <- clean_text(user_role$agency_id)
user_role$budget_access <- clean_bool(user_role$budget_access)
user_role$adaptive_planning <- clean_bool(user_role$adaptive_planning)
user_role$performance_plan_access <- clean_bool(user_role$performance_plan_access, TRUE)

user_functions$user_id <- clean_text(user_functions$user_id)
user_functions$agency_id <- clean_text(user_functions$agency_id)
user_functions$service_id <- clean_text(user_functions$service_id)
user_functions$agency_role <- clean_text(user_functions$agency_role)

new_entities <- plan_entity[!plan_entity$entity_id %in% db_entities$entity_id, , drop = FALSE]
changed_entities <- merge(plan_entity, db_entities, by = "entity_id", suffixes = c("_upload", "_db"))
changed_entities <- changed_entities[
  changed_entities$parent_agency_id_upload != changed_entities$parent_agency_id_db |
    changed_entities$public_name_upload != changed_entities$public_name_db |
    changed_entities$entity_type_upload != changed_entities$entity_type_db |
    changed_entities$has_own_plan_upload != changed_entities$has_own_plan_db |
    changed_entities$active_upload != changed_entities$active_db,
  ,
  drop = FALSE
]

new_entity_services <- plan_entity_service[!plan_entity_service$pes_id %in% db_entity_services$pes_id, , drop = FALSE]
changed_entity_services <- merge(plan_entity_service[, c("pes_id", "entity_id", "service_id", "is_primary")], db_entity_services, by = "pes_id", suffixes = c("_upload", "_db"))
changed_entity_services <- changed_entity_services[
  changed_entity_services$entity_id_upload != changed_entity_services$entity_id_db |
    changed_entity_services$service_id_upload != changed_entity_services$service_id_db |
    changed_entity_services$is_primary_upload != changed_entity_services$is_primary_db,
  ,
  drop = FALSE
]

valid_users <- users[!is.na(users$email), , drop = FALSE]
new_users <- valid_users[!tolower(valid_users$email) %in% tolower(db_users$email), , drop = FALSE]
existing_user_compare <- merge(valid_users, db_users, by = "email", suffixes = c("_upload", "_db"))
changed_users <- existing_user_compare[
  existing_user_compare$full_name_upload != existing_user_compare$full_name_db |
    existing_user_compare$auth_type_upload != existing_user_compare$auth_type_db |
    existing_user_compare$active_upload != existing_user_compare$active_db,
  ,
  drop = FALSE
]

db_user_email <- setNames(tolower(db_users$email), db_users$user_id)
upload_user_email <- setNames(tolower(valid_users$email), valid_users$user_id)

uploaded_roles_for_compare <- user_role[!is.na(user_role$user_id) & !is.na(user_role$app_role), , drop = FALSE]
uploaded_roles_for_compare$email <- tolower(ifelse(grepl("@", uploaded_roles_for_compare$user_id), uploaded_roles_for_compare$user_id, upload_user_email[uploaded_roles_for_compare$user_id]))
uploaded_roles_for_compare$key <- paste(uploaded_roles_for_compare$email, uploaded_roles_for_compare$app_role, uploaded_roles_for_compare$agency_id %||% "", sep = "|")
db_roles_for_compare <- db_roles
db_roles_for_compare$email <- db_user_email[as.character(db_roles_for_compare$user_id)]
db_roles_for_compare$key <- paste(db_roles_for_compare$email, db_roles_for_compare$app_role, db_roles_for_compare$agency_id %||% "", sep = "|")
new_roles <- uploaded_roles_for_compare[!uploaded_roles_for_compare$key %in% db_roles_for_compare$key, , drop = FALSE]

uploaded_functions_for_compare <- user_functions[!is.na(user_functions$user_id) & !is.na(user_functions$agency_id), , drop = FALSE]
uploaded_functions_for_compare$email <- tolower(ifelse(grepl("@", uploaded_functions_for_compare$user_id), uploaded_functions_for_compare$user_id, upload_user_email[uploaded_functions_for_compare$user_id]))
uploaded_functions_for_compare$key <- paste(uploaded_functions_for_compare$email, uploaded_functions_for_compare$agency_id, uploaded_functions_for_compare$service_id %||% "", uploaded_functions_for_compare$agency_role %||% "", sep = "|")
db_functions_for_compare <- db_functions
db_functions_for_compare$email <- db_user_email[as.character(db_functions_for_compare$user_id)]
db_functions_for_compare$key <- paste(db_functions_for_compare$email, db_functions_for_compare$agency_id, db_functions_for_compare$service_id %||% "", db_functions_for_compare$agency_role %||% "", sep = "|")
new_functions <- uploaded_functions_for_compare[!uploaded_functions_for_compare$key %in% db_functions_for_compare$key, , drop = FALSE]

cat("\nNew plan entities:\n")
print(new_entities, row.names = FALSE)
cat("\nChanged plan entities:\n")
print(changed_entities, row.names = FALSE)
cat("\nNew plan entity service rows:\n")
print(new_entity_services, row.names = FALSE)
cat("\nChanged plan entity service rows:\n")
print(changed_entity_services, row.names = FALSE)
cat("\nNew users:\n")
print(new_users[, c("user_id", "email", "full_name", "auth_type", "active"), drop = FALSE], row.names = FALSE)
cat("\nChanged users:\n")
print(changed_users[, c("email", "full_name_upload", "full_name_db", "auth_type_upload", "auth_type_db", "active_upload", "active_db"), drop = FALSE], row.names = FALSE)
cat("\nNew user roles:\n")
print(new_roles[, c("user_role_id", "email", "app_role", "agency_id", "budget_access", "adaptive_planning", "performance_plan_access"), drop = FALSE], row.names = FALSE)
cat("\nNew user function rows:\n")
print(new_functions[, c("email", "agency_id", "service_id", "agency_role"), drop = FALSE], row.names = FALSE)
