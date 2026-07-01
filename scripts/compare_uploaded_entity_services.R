source(file.path("R", "database.R"))

csv_dir <- file.path("tmp", "upload_compare")
service_csv <- file.path(csv_dir, "PLAN_ENTITY_SERVICE.csv")
if (!file.exists(service_csv)) {
  stop("Missing tmp/upload_compare/PLAN_ENTITY_SERVICE.csv. Export the workbook sheet first.")
}

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

uploaded <- read.csv(service_csv, check.names = FALSE, stringsAsFactors = FALSE)
uploaded$pes_id <- as.integer(uploaded$pes_id)
uploaded$entity_id <- as.integer(uploaded$entity_id)
uploaded$service_id <- clean_text(uploaded$service_id)
uploaded$service_name <- clean_text(uploaded$service_name)
uploaded$is_primary <- clean_bool(uploaded$is_primary)

con <- connect_app_database()
on.exit(DBI::dbDisconnect(con), add = TRUE)

db_rows <- DBI::dbGetQuery(
  con,
  "SELECT pes.pes_id, pes.entity_id, pe.public_name, pes.service_id, s.service_name, pes.is_primary
   FROM reference.plan_entity_service pes
   JOIN reference.plan_entity pe ON pe.entity_id = pes.entity_id
   JOIN reference.service s ON s.service_id = pes.service_id
   ORDER BY pes.pes_id"
)

service_ids <- unique(uploaded$service_id[!is.na(uploaded$service_id)])
service_id_sql <- paste(DBI::dbQuoteString(con, service_ids), collapse = ", ")
service_rows <- DBI::dbGetQuery(
  con,
  paste0(
    "SELECT service_id, service_name, agency_id, active
     FROM reference.service
     WHERE service_id IN (", service_id_sql, ")
     ORDER BY service_id"
  )
)

entity_ids <- unique(uploaded$entity_id[!is.na(uploaded$entity_id)])
entity_id_sql <- paste(entity_ids, collapse = ", ")
entity_rows <- DBI::dbGetQuery(
  con,
  paste0(
    "SELECT entity_id, parent_agency_id, public_name, entity_type, active
     FROM reference.plan_entity
     WHERE entity_id IN (", entity_id_sql, ")
     ORDER BY entity_id"
  )
)

new_uploaded <- uploaded[uploaded$entity_id %in% 25:30, , drop = FALSE]
new_uploaded <- merge(new_uploaded, entity_rows, by = "entity_id", all.x = TRUE)
new_uploaded <- merge(new_uploaded, service_rows, by = "service_id", all.x = TRUE, suffixes = c("_uploaded", "_db"))
new_uploaded <- new_uploaded[order(new_uploaded$pes_id), , drop = FALSE]

cat("Uploaded rows for entities 25-30:\n")
print(new_uploaded[, c("pes_id", "entity_id", "public_name", "service_id", "service_name_uploaded", "service_name_db", "agency_id", "active_db", "is_primary")], row.names = FALSE)

cat("\nExisting DB links for entities 25-30:\n")
print(db_rows[db_rows$entity_id %in% 25:30, , drop = FALSE], row.names = FALSE)
