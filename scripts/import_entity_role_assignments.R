library(DBI)

source("R/database.R")

assignment_path <- file.path("database", "seed", "entity_role_assignments.csv")
if (!file.exists(assignment_path)) {
  stop("Missing assignment CSV: ", assignment_path)
}

name_key <- function(value) {
  value <- as.character(value)
  value[is.na(value)] <- ""
  value <- trimws(value)
  value <- gsub("\\([^)]*\\)", "", value)
  value <- sub("^(Dr\\.?|Captain)\\s+", "", value, ignore.case = TRUE)
  title_named <- grepl("^(Chief of Staff|City Administrator)\\s+-\\s+", value, ignore.case = TRUE)
  value[title_named] <- sub("^[^-]+-\\s*", "", value[title_named])
  value <- sub("\\s+-\\s+.*$", "", value)
  value <- sub("^Independent\\s+-\\s+", "", value, ignore.case = TRUE)
  value <- tolower(value)
  gsub("[^a-z0-9]+", "", value)
}

clean_text <- function(value) {
  value <- trimws(as.character(value %||% ""))
  if (!nzchar(value)) NA_character_ else value
}

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0 || is.na(x)) y else x

con <- connect_app_database()
on.exit(dbDisconnect(con), add = TRUE)
ensure_review_schema(con)

assignments <- read.csv(assignment_path, stringsAsFactors = FALSE, check.names = FALSE)
users <- dbGetQuery(con, "SELECT user_id, full_name, email FROM access.\"user\" WHERE active")
user_keys <- stats::setNames(users$user_id, name_key(users$full_name))
user_aliases <- c(
  "johnmerrill" = "johndavidmerrill",
  "nelsongomesboronat" = "nelsongomes",
  "markhanson" = "markchanson",
  "veronicapmcbeth" = "veronicamcbeth",
  "dartanionswiftwilliams" = "dartanionsmithwilliams",
  "samueljohnson" = "samueljohnsonasstdeputymayorpublicsafety"
)
for (canonical_key in names(user_aliases)) {
  alias_key <- user_aliases[[canonical_key]]
  if (canonical_key %in% names(user_keys) && !alias_key %in% names(user_keys)) {
    user_keys[[alias_key]] <- user_keys[[canonical_key]]
  }
}

resolve_user_id <- function(name) {
  key <- name_key(name)
  if (!nzchar(key) || !key %in% names(user_keys)) return(NA_integer_)
  as.integer(user_keys[[key]])
}

rows <- lapply(seq_len(nrow(assignments)), function(i) {
  row <- assignments[i, , drop = FALSE]
  entity_id <- suppressWarnings(as.integer(row$entity_id[[1]]))
  if (is.na(entity_id)) entity_id <- NA_integer_
  deputy_mayor_name <- clean_text(row$deputy_mayor[[1]])
  ca_office_name <- clean_text(row$ca_office[[1]])
  if (!is.na(deputy_mayor_name) && deputy_mayor_name %in% c(
    "Independent - Legislative Branch",
    "Independent - Elected Comptroller (Bill Henry)"
  )) {
    deputy_mayor_name <- "Shamiah Kerney"
    ca_office_name <- "Faith Leach"
  } else if (!is.na(deputy_mayor_name) && identical(deputy_mayor_name, "Mayor's Office - Multiple portfolios")) {
    deputy_mayor_name <- "John Merrill"
    ca_office_name <- "Shamiah Kerney"
  }
  list(
    entity_type = clean_text(row$entity_type[[1]]),
    agency_id = clean_text(row$agency_id[[1]]),
    agency = clean_text(row$agency[[1]]),
    entity_id = entity_id,
    public_name = clean_text(row$public_name[[1]]),
    submitter_name = clean_text(row$submitter[[1]]),
    reviewer_name = clean_text(row$reviewer[[1]]),
    deputy_mayor_name = deputy_mayor_name,
    ca_office_name = ca_office_name
  )
})

rows <- Filter(function(row) !is.na(row$public_name) && nzchar(row$public_name), rows)

DBI::dbWithTransaction(con, {
  for (row in rows) {
    submitter_user_id <- resolve_user_id(row$submitter_name)
    reviewer_user_id <- resolve_user_id(row$reviewer_name)
    deputy_mayor_user_id <- resolve_user_id(row$deputy_mayor_name)
    ca_office_user_id <- resolve_user_id(row$ca_office_name)
    dbExecute(
      con,
      paste(
        "INSERT INTO workflow.entity_role_assignment",
        "(entity_type, agency_id, agency, entity_id, public_name,",
        "submitter_user_id, submitter_name, reviewer_user_id, reviewer_name,",
        "deputy_mayor_user_id, deputy_mayor_name, ca_office_user_id, ca_office_name, updated_at)",
        "VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,now())",
        "ON CONFLICT (public_name) DO UPDATE SET",
        "entity_type=EXCLUDED.entity_type, agency_id=EXCLUDED.agency_id, agency=EXCLUDED.agency,",
        "entity_id=EXCLUDED.entity_id, submitter_user_id=EXCLUDED.submitter_user_id, submitter_name=EXCLUDED.submitter_name,",
        "reviewer_user_id=EXCLUDED.reviewer_user_id, reviewer_name=EXCLUDED.reviewer_name,",
        "deputy_mayor_user_id=EXCLUDED.deputy_mayor_user_id, deputy_mayor_name=EXCLUDED.deputy_mayor_name,",
        "ca_office_user_id=EXCLUDED.ca_office_user_id, ca_office_name=EXCLUDED.ca_office_name, updated_at=now()"
      ),
      params = list(
        row$entity_type,
        row$agency_id,
        row$agency,
        row$entity_id,
        row$public_name,
        submitter_user_id,
        row$submitter_name,
        reviewer_user_id,
        row$reviewer_name,
        deputy_mayor_user_id,
        row$deputy_mayor_name,
        ca_office_user_id,
        row$ca_office_name
      )
    )
  }
})

loaded <- dbGetQuery(con, "SELECT COUNT(*)::integer AS rows FROM workflow.entity_role_assignment")$rows[[1]]
unmatched <- dbGetQuery(
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

cat("Loaded", loaded, "entity role assignment rows into workflow.entity_role_assignment.\n")
cat("Rows with at least one unmatched user name:", nrow(unmatched), "\n")
if (nrow(unmatched)) {
  print(utils::head(unmatched, 12))
}
