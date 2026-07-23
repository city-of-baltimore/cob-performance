# reviewer_assignments.csv keys reviewer assignments by a free-text
# agency_name, matched at runtime (apply_reviewer_assignments() in app.R)
# by normalizing both sides to a bare alphanumeric string and doing an exact
# match against each plan's display name -- the same "fragile non-ID
# matching silently fails" pattern behind the two reseeding bugs fixed
# earlier this session. A plan whose agency was renamed, reworded, or given
# a prefix (e.g. "M-R ") after the CSV was written just silently gets no
# assigned reviewer, with no error and no way to notice short of checking
# every row by hand.
#
# planning.agency_plan.assigned_reviewer already exists as a proper FK to
# access.user.user_id, and is already the source of truth whenever it's set
# (R/database.R:694-696, load_app_data()'s join) -- the CSV is only ever
# consulted as a fallback for plans where this column is still NULL. This
# script does that resolution ONCE:
#   1. Exact match (CSV agency_name, normalized) against either
#      reference.agency.agency_name or reference.plan_entity.public_name
#      (a plan is scoped by exactly one of the two) -> backfilled
#      automatically, since there's no ambiguity.
#   2. A same-except-for-a-known-prefix match (dropping/adding "M-R ",
#      "Board of ", trailing "'s Office"/" Office") -> reported as a
#      suggested mapping, NOT applied automatically, since it's a guess
#      about a rename rather than a confirmed identity.
#   3. Anything left over -> reported as fully unmatched, needs a human.
# It never overwrites an existing assigned_reviewer.
#
# Local dev data and production data have diverged (confirmed 2026-07-23),
# so run this against each database separately and treat the printed report
# as authoritative for whichever one you just ran against -- don't reuse
# numbers from one run to reason about the other.
#
# Three of the plans this surfaced as fully unmatched were resolved directly
# by Melanie (2026-07-23):
#   - Mayor's Office of Infrastructure Development: an abolished office --
#     handled separately, see scripts/deactivate_abolished_plan_entities.R,
#     not a reviewer-assignment question at all.
#   - M-R Office of Immigrant Affairs (AGC4393) confirmed to be the same
#     office as the CSV's "Office of Immigrant and Multicultural Affairs".
#   - M-R Office of Information and Technology (AGC4303) confirmed to be the
#     same office as the CSV's "Baltimore City Information Technology (BCIT)".
# These two are keyed by agency_id (a stable reference code, unlike the
# autoincrement plan_id/entity_id, which can differ across environments) so
# this stays correct whichever database it runs against.

source("R/database.R", local = TRUE)

connection <- connect_app_database()
on.exit(DBI::dbDisconnect(connection), add = TRUE)

normalize_key <- function(value) {
  value <- tolower(trimws(as.character(value %||% "")))
  gsub("[^a-z0-9]+", "", value)
}

# Strips patterns that show up as wording drift between the CSV and
# reference.agency/reference.plan_entity (a dropped "M-R " prefix, a
# "Board of " prefix, or a trailing "'s Office"/" Office" suffix) so a
# same-underlying-agency pair can be surfaced as a suggested match instead
# of silently falling into "no match at all".
loosen_key <- function(value) {
  value <- tolower(trimws(as.character(value %||% "")))
  value <- sub("^m[- ]?r\\s+", "", value)
  value <- sub("^board of\\s+", "", value)
  value <- sub("'s office$", "", value)
  value <- sub("\\s+office$", "", value)
  gsub("[^a-z0-9]+", "", value)
}

csv <- read.csv("database/seed/reviewer_assignments.csv", stringsAsFactors = FALSE, check.names = FALSE)
csv$key <- normalize_key(csv$agency_name)
csv$loose_key <- loosen_key(csv$agency_name)

users <- DBI::dbGetQuery(connection, 'SELECT user_id, email FROM access."user"')
csv$user_id <- users$user_id[match(tolower(trimws(csv$email)), tolower(users$email))]

plans <- DBI::dbGetQuery(
  connection,
  paste(
    "SELECT ap.plan_id, ap.agency_id, ap.entity_id,",
    "COALESCE(pe.public_name, ra.agency_name) AS display_name",
    "FROM planning.agency_plan ap",
    "LEFT JOIN reference.agency ra ON ra.agency_id = ap.agency_id",
    "LEFT JOIN reference.plan_entity pe ON pe.entity_id = ap.entity_id",
    "WHERE ap.assigned_reviewer IS NULL"
  )
)
plans$key <- normalize_key(plans$display_name)
plans$loose_key <- loosen_key(plans$display_name)

cat("Plans missing an ID-keyed reviewer:", nrow(plans), "\n\n")

unmatched_email <- csv[is.na(csv$user_id), c("agency_name", "analyst", "email")]
if (nrow(unmatched_email)) {
  cat("CSV rows whose email doesn't resolve to any access.user (excluded entirely):\n")
  print(unmatched_email, row.names = FALSE)
  cat("\n")
}
csv <- csv[!is.na(csv$user_id), ]

common_cols <- c("plan_id", "display_name", "user_id", "agency_name")

exact <- merge(plans, csv[, c("key", "user_id", "agency_name")], by = "key")[, common_cols]

confirmed_manual <- data.frame(
  agency_id = c("AGC4393", "AGC4303"),
  csv_agency_name = c("Office of Immigrant and Multicultural Affairs", "Baltimore City Information Technology (BCIT)"),
  stringsAsFactors = FALSE
)
manual_matches <- merge(
  plans[plans$agency_id %in% confirmed_manual$agency_id, c("plan_id", "agency_id", "display_name")],
  confirmed_manual,
  by = "agency_id"
)
manual_matches <- merge(manual_matches, csv[, c("agency_name", "user_id")], by.x = "csv_agency_name", by.y = "agency_name")
manual_matches$agency_name <- manual_matches$csv_agency_name
if (nrow(manual_matches)) {
  exact <- rbind(exact, manual_matches[, common_cols])
}

cat("Exact + confirmed manual matches (auto-applied):", nrow(exact), "\n")
if (nrow(exact)) print(exact[, c("plan_id", "display_name", "agency_name")], row.names = FALSE)
cat("\n")

remaining_plans <- plans[!plans$plan_id %in% exact$plan_id, ]
loose <- merge(remaining_plans, csv[, c("loose_key", "user_id", "agency_name")], by = "loose_key")
cat("Suggested matches after stripping a prefix/suffix (NOT applied -- review and confirm):", nrow(loose), "\n")
if (nrow(loose)) print(loose[, c("plan_id", "display_name", "agency_name")], row.names = FALSE)
cat("\n")

fully_unmatched <- remaining_plans[!remaining_plans$plan_id %in% loose$plan_id, ]
cat("Fully unmatched plans (no CSV row found at all -- needs a human):", nrow(fully_unmatched), "\n")
if (nrow(fully_unmatched)) print(fully_unmatched[, c("plan_id", "agency_id", "entity_id", "display_name")], row.names = FALSE)
cat("\n")

if (nrow(exact)) {
  DBI::dbWithTransaction(connection, {
    updated <- 0L
    for (i in seq_len(nrow(exact))) {
      updated <- updated + DBI::dbExecute(
        connection,
        "UPDATE planning.agency_plan SET assigned_reviewer = $2, updated_at = now() WHERE plan_id = $1 AND assigned_reviewer IS NULL",
        params = list(exact$plan_id[i], exact$user_id[i])
      )
    }
    cat("plan rows backfilled:", updated, "\n")
  })
} else {
  cat("plan rows backfilled: 0 (no exact matches)\n")
}
