library(DBI)

source("R/database.R")

con <- connect_app_database()
on.exit(dbDisconnect(con), add = TRUE)

assignments <- dbGetQuery(
  con,
  paste(
    "SELECT public_name, submitter_name, submitter_user_id, reviewer_name, reviewer_user_id,",
    "deputy_mayor_name, deputy_mayor_user_id, ca_office_name, ca_office_user_id",
    "FROM workflow.entity_role_assignment",
    "WHERE (submitter_name IS NOT NULL AND submitter_user_id IS NULL)",
    "OR (reviewer_name IS NOT NULL AND reviewer_user_id IS NULL)",
    "OR (deputy_mayor_name IS NOT NULL AND deputy_mayor_user_id IS NULL)",
    "OR (ca_office_name IS NOT NULL AND ca_office_user_id IS NULL)",
    "ORDER BY public_name"
  )
)
cat("Unmatched assignment rows:", nrow(assignments), "\n")
print(assignments)

users <- dbGetQuery(con, "SELECT user_id, full_name, email, active FROM access.\"user\" ORDER BY full_name")
terms <- c(
  "Letitia", "Dzirasa", "John", "Merrill", "Faith", "Samuel", "Nelson",
  "Asma", "Hanson", "Jermaine", "Bundley", "Melanie Bryant", "Dartanion",
  "Reginald", "Veronica", "Vicki", "Kirby", "Jan Miles", "Robert Hair"
)
for (term in terms) {
  hit <- users[
    grepl(term, users$full_name, ignore.case = TRUE) |
      grepl(term, users$email, ignore.case = TRUE),
    ,
    drop = FALSE
  ]
  if (nrow(hit)) {
    cat("\n--", term, "--\n")
    print(hit, row.names = FALSE)
  }
}
