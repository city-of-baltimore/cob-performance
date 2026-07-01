source(file.path("R", "database.R"))

args <- commandArgs(trailingOnly = TRUE)
agency_filter <- if (length(args) >= 1 && nzchar(args[[1]])) args[[1]] else "AGC2600"

con <- connect_app_database()
on.exit(DBI::dbDisconnect(con), add = TRUE)

if (!grepl("^AGC", agency_filter, ignore.case = TRUE)) {
  agency_matches <- DBI::dbGetQuery(
    con,
    "SELECT agency_id, agency_name, public_name
     FROM reference.agency
     WHERE agency_name ILIKE $1 OR public_name ILIKE $1
     ORDER BY agency_id",
    params = list(paste0("%", agency_filter, "%"))
  )
  if (nrow(agency_matches) != 1) {
    print(agency_matches, row.names = FALSE)
    stop("Pass one agency_id, or use a search term with exactly one match.")
  }
  agency_filter <- agency_matches$agency_id[[1]]
}

agency_row <- DBI::dbGetQuery(
  con,
  "SELECT agency_id, agency_name, public_name FROM reference.agency WHERE agency_id = $1",
  params = list(agency_filter)
)
print(agency_row, row.names = FALSE)

sql <- "
SELECT
  m.measure_id,
  m.title,
  pc.fiscal_year,
  m.active,
  COALESCE(m.approval_status, '') AS approval_status,
  COALESCE(m.change_mapping, '') AS change_mapping,
  m.is_city,
  m.is_agency,
  m.is_service,
  STRING_AGG(DISTINCT mel.service_id, ', ' ORDER BY mel.service_id) AS entity_link_service_ids,
  STRING_AGG(DISTINCT els.service_name, '; ' ORDER BY els.service_name) AS entity_link_services,
  STRING_AGG(DISTINCT psl.service_id, ', ' ORDER BY psl.service_id) AS service_link_ids,
  STRING_AGG(DISTINCT sls.service_name, '; ' ORDER BY sls.service_name) AS service_link_services
FROM performance.performance_measure m
JOIN planning.plan_cycle pc ON pc.cycle_id = m.initial_cycle
LEFT JOIN performance.measure_entity_link mel ON mel.measure_id = m.measure_id
LEFT JOIN reference.service els ON els.service_id = mel.service_id
LEFT JOIN performance.pm_service_link psl ON psl.measure_id = m.measure_id
LEFT JOIN reference.service sls ON sls.service_id = psl.service_id
WHERE m.agency_id = $1
  AND pc.fiscal_year = 2027
GROUP BY
  m.measure_id,
  m.title,
  pc.fiscal_year,
  m.active,
  m.approval_status,
  m.change_mapping,
  m.is_city,
  m.is_agency,
  m.is_service
ORDER BY m.title
"

rows <- DBI::dbGetQuery(con, sql, params = list(agency_filter))
print(rows, row.names = FALSE)

cat("\nScope summary:\n")
print(
  aggregate(
    measure_id ~ is_agency + is_service,
    data = rows,
    FUN = length
  ),
  row.names = FALSE
)
