source("R/database.R")

output_dir <- "outputs/performance_entity_table"
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

con <- connect_app_database()
on.exit(DBI::dbDisconnect(con), add = TRUE)

query <- function(sql) DBI::dbGetQuery(con, sql)

db_rows <- query(
  paste(
    "WITH entity_service AS (",
    "  SELECT pes.service_id,",
    "    COUNT(DISTINCT pe.entity_id) FILTER (WHERE pe.active) AS active_entity_count,",
    "    MIN(pe.entity_id) FILTER (WHERE pe.active) AS entity_id,",
    "    MIN(pe.public_name) FILTER (WHERE pe.active) AS entity_public_name,",
    "    MIN(pe.entity_type) FILTER (WHERE pe.active) AS source_entity_type,",
    "    string_agg(DISTINCT pe.public_name, '; ' ORDER BY pe.public_name) FILTER (WHERE pe.active) AS candidate_entity_names,",
    "    string_agg(DISTINCT pe.entity_id::text || '|' || pe.public_name || '|' || pe.entity_type, ';;' ORDER BY pe.entity_id::text || '|' || pe.public_name || '|' || pe.entity_type) FILTER (WHERE pe.active) AS candidate_entity_records",
    "  FROM reference.plan_entity_service pes",
    "  JOIN reference.plan_entity pe ON pe.entity_id = pes.entity_id",
    "  GROUP BY pes.service_id",
    ")",
    "SELECT",
    "  pm.measure_id AS new_measure_id,",
    "  pm.agency_id,",
    "  COALESCE(a.public_name, a.agency_name) AS agency_public_name,",
    "  pm.title AS measure_name,",
    "  pc.fiscal_year,",
    "  pm.active AS measure_active,",
    "  pm.approval_status,",
    "  pm.change_mapping,",
    "  s.service_id,",
    "  s.service_name,",
    "  s.service_type,",
    "  s.active AS service_active,",
    "  COALESCE(es.active_entity_count, 0) AS active_entity_count,",
    "  es.entity_id,",
    "  es.entity_public_name,",
    "  es.source_entity_type,",
    "  COALESCE(es.candidate_entity_names, '') AS candidate_entity_names,",
    "  COALESCE(es.candidate_entity_records, '') AS candidate_entity_records",
    "FROM performance.performance_measure pm",
    "JOIN planning.plan_cycle pc ON pc.cycle_id = pm.initial_cycle",
    "JOIN reference.agency a ON a.agency_id = pm.agency_id",
    "LEFT JOIN performance.pm_service_link psl ON psl.measure_id = pm.measure_id",
    "LEFT JOIN reference.service s ON s.service_id = psl.service_id",
    "LEFT JOIN entity_service es ON es.service_id = s.service_id",
    "WHERE pc.fiscal_year = 2027",
    "ORDER BY agency_public_name, pm.title, s.service_name"
  )
)

service_rows <- query(
  paste(
    "WITH entity_service AS (",
    "  SELECT pes.service_id,",
    "    COUNT(DISTINCT pe.entity_id) FILTER (WHERE pe.active) AS active_entity_count,",
    "    MIN(pe.entity_id) FILTER (WHERE pe.active) AS entity_id,",
    "    MIN(pe.public_name) FILTER (WHERE pe.active) AS entity_public_name,",
    "    MIN(pe.entity_type) FILTER (WHERE pe.active) AS source_entity_type,",
    "    string_agg(DISTINCT pe.public_name, '; ' ORDER BY pe.public_name) FILTER (WHERE pe.active) AS candidate_entity_names,",
    "    string_agg(DISTINCT pe.entity_id::text || '|' || pe.public_name || '|' || pe.entity_type, ';;' ORDER BY pe.entity_id::text || '|' || pe.public_name || '|' || pe.entity_type) FILTER (WHERE pe.active) AS candidate_entity_records",
    "  FROM reference.plan_entity_service pes",
    "  JOIN reference.plan_entity pe ON pe.entity_id = pes.entity_id",
    "  GROUP BY pes.service_id",
    ")",
    "SELECT",
    "  s.service_id,",
    "  s.agency_id,",
    "  COALESCE(a.public_name, a.agency_name) AS agency_public_name,",
    "  s.service_name,",
    "  s.service_type,",
    "  s.active AS service_active,",
    "  COALESCE(es.active_entity_count, 0) AS active_entity_count,",
    "  es.entity_id,",
    "  es.entity_public_name,",
    "  es.source_entity_type,",
    "  COALESCE(es.candidate_entity_names, '') AS candidate_entity_names,",
    "  COALESCE(es.candidate_entity_records, '') AS candidate_entity_records",
    "FROM reference.service s",
    "JOIN reference.agency a ON a.agency_id = s.agency_id",
    "LEFT JOIN entity_service es ON es.service_id = s.service_id",
    "ORDER BY agency_public_name, s.service_name"
  )
)

write.csv(db_rows, file.path(output_dir, "db_measure_entity_source.csv"), row.names = FALSE, na = "")
write.csv(service_rows, file.path(output_dir, "db_service_entity_source.csv"), row.names = FALSE, na = "")

cat("db_measure_entity_source_rows=", nrow(db_rows), "\n", sep = "")
cat("db_service_entity_source_rows=", nrow(service_rows), "\n", sep = "")
