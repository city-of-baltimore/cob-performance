source(file.path("R", "database.R"))

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

uploaded <- read.csv(file.path(csv_dir, "PLAN_ENTITY_SERVICE.csv"), check.names = FALSE, stringsAsFactors = FALSE)
uploaded$pes_id <- as.integer(uploaded$pes_id)
uploaded$entity_id <- as.integer(uploaded$entity_id)
uploaded$service_id <- clean_text(uploaded$service_id)
uploaded$is_primary <- clean_bool(uploaded$is_primary)
new_rows <- uploaded[uploaded$entity_id %in% 25:30 & !is.na(uploaded$service_id), , drop = FALSE]

con <- connect_app_database()
on.exit(DBI::dbDisconnect(con), add = TRUE)
DBI::dbBegin(con)
tryCatch({
  for (i in seq_len(nrow(new_rows))) {
    row <- new_rows[i, , drop = FALSE]
    DBI::dbExecute(
      con,
      "INSERT INTO reference.plan_entity_service (pes_id, entity_id, service_id, is_primary)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (entity_id, service_id) DO UPDATE SET is_primary = EXCLUDED.is_primary",
      params = list(row$pes_id, row$entity_id, row$service_id, row$is_primary)
    )
  }
  DBI::dbExecute(con, "SELECT setval(pg_get_serial_sequence('reference.plan_entity_service', 'pes_id'), COALESCE((SELECT MAX(pes_id) FROM reference.plan_entity_service), 1), (SELECT COUNT(*) > 0 FROM reference.plan_entity_service))")

  plan_rows <- DBI::dbGetQuery(
    con,
    "SELECT ap.plan_id, ap.entity_id
     FROM planning.agency_plan ap
     JOIN planning.plan_cycle pc ON pc.cycle_id = ap.cycle_id
     WHERE pc.fiscal_year = 2027
       AND ap.entity_id BETWEEN 25 AND 30"
  )
  for (i in seq_len(nrow(new_rows))) {
    row <- new_rows[i, , drop = FALSE]
    plan_id <- plan_rows$plan_id[match(row$entity_id, plan_rows$entity_id)]
    if (is.na(plan_id)) next
    DBI::dbExecute(
      con,
      "INSERT INTO performance.plan_service (plan_id, service_id, sort_order)
       SELECT $1, $2::varchar(20), 1
       WHERE NOT EXISTS (
         SELECT 1 FROM performance.plan_service
         WHERE plan_id = $1 AND service_id = $2::varchar(20)
       )",
      params = list(plan_id, row$service_id)
    )
  }
  DBI::dbExecute(con, "SELECT setval(pg_get_serial_sequence('performance.plan_service', 'plan_service_id'), COALESCE((SELECT MAX(plan_service_id) FROM performance.plan_service), 1), (SELECT COUNT(*) > 0 FROM performance.plan_service))")

  DBI::dbCommit(con)
  cat("Applied", nrow(new_rows), "entity service links and plan service rows.\n")
}, error = function(err) {
  DBI::dbRollback(con)
  stop(err)
})
