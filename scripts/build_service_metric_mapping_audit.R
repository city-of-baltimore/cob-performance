source("R/database.R")

con <- connect_app_database()
on.exit(DBI::dbDisconnect(con), add = TRUE)

output_dir <- "outputs/service_metric_mapping_audit"
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

query <- function(sql) DBI::dbGetQuery(con, sql)

summary_rows <- query(
  paste(
    "WITH agency_measure_counts AS (",
    "  SELECT agency_id, COUNT(*) AS active_measure_count",
    "  FROM performance.performance_measure",
    "  WHERE active AND COALESCE(approval_status, '') <> 'Deprecated'",
    "    AND COALESCE(change_mapping, '') NOT IN ('Removed', 'Replaced')",
    "  GROUP BY agency_id",
    "), service_counts AS (",
    "  SELECT s.agency_id, COUNT(*) AS active_performance_services,",
    "    COUNT(*) FILTER (WHERE linked.linked_metric_count > 0) AS services_with_metrics,",
    "    COUNT(*) FILTER (WHERE COALESCE(linked.linked_metric_count, 0) = 0) AS services_without_metrics",
    "  FROM reference.service s",
    "  LEFT JOIN LATERAL (",
    "    SELECT COUNT(DISTINCT psl.measure_id) AS linked_metric_count",
    "    FROM performance.pm_service_link psl",
    "    JOIN performance.performance_measure pm ON pm.measure_id = psl.measure_id",
    "    WHERE psl.service_id = s.service_id",
    "      AND pm.active",
    "      AND COALESCE(pm.approval_status, '') <> 'Deprecated'",
    "      AND COALESCE(pm.change_mapping, '') NOT IN ('Removed', 'Replaced')",
    "  ) linked ON TRUE",
    "  WHERE s.active AND s.service_type = 'Performance'",
    "  GROUP BY s.agency_id",
    ")",
    "SELECT a.agency_id, COALESCE(a.public_name, a.agency_name) AS agency_name,",
    "  COALESCE(amc.active_measure_count, 0) AS active_measure_count,",
    "  COALESCE(sc.active_performance_services, 0) AS active_performance_services,",
    "  COALESCE(sc.services_with_metrics, 0) AS services_with_metrics,",
    "  COALESCE(sc.services_without_metrics, 0) AS services_without_metrics",
    "FROM reference.agency a",
    "LEFT JOIN agency_measure_counts amc ON amc.agency_id = a.agency_id",
    "LEFT JOIN service_counts sc ON sc.agency_id = a.agency_id",
    "WHERE a.active AND (a.submit_plan OR COALESCE(amc.active_measure_count, 0) > 0 OR COALESCE(sc.active_performance_services, 0) > 0)",
    "ORDER BY services_without_metrics DESC, active_measure_count DESC, agency_name"
  )
)

services_without_metrics <- query(
  paste(
    "SELECT a.agency_id, COALESCE(a.public_name, a.agency_name) AS agency_name,",
    "  NULL::integer AS entity_id, NULL::text AS entity_name,",
    "  s.service_id, s.service_name, s.service_type,",
    "  COUNT(DISTINCT pm.measure_id) AS agency_active_measure_count,",
    "  'Service has no active linked performance measures' AS issue",
    "FROM reference.service s",
    "JOIN reference.agency a ON a.agency_id = s.agency_id",
    "LEFT JOIN performance.performance_measure pm ON pm.agency_id = s.agency_id",
    "  AND pm.active",
    "  AND COALESCE(pm.approval_status, '') <> 'Deprecated'",
    "  AND COALESCE(pm.change_mapping, '') NOT IN ('Removed', 'Replaced')",
    "WHERE s.active AND s.service_type = 'Performance'",
    "AND NOT EXISTS (",
    "  SELECT 1",
    "  FROM performance.pm_service_link psl",
    "  JOIN performance.performance_measure linked_pm ON linked_pm.measure_id = psl.measure_id",
    "  WHERE psl.service_id = s.service_id",
    "    AND linked_pm.active",
    "    AND COALESCE(linked_pm.approval_status, '') <> 'Deprecated'",
    "    AND COALESCE(linked_pm.change_mapping, '') NOT IN ('Removed', 'Replaced')",
    ")",
    "GROUP BY a.agency_id, agency_name, s.service_id, s.service_name, s.service_type",
    "ORDER BY agency_name, s.service_name"
  )
)

unassigned_measures <- query(
  paste(
    "SELECT pm.agency_id, COALESCE(a.public_name, a.agency_name) AS agency_name,",
    "  pm.measure_id, pm.title AS measure_title, pm.measure_type, pm.desired_direction,",
    "  pm.data_owner, pm.data_owner_role, pm.approval_status, pm.change_mapping,",
    "  'Measure is active but not linked to an active performance service' AS issue",
    "FROM performance.performance_measure pm",
    "JOIN reference.agency a ON a.agency_id = pm.agency_id",
    "WHERE pm.active",
    "  AND COALESCE(pm.approval_status, '') <> 'Deprecated'",
    "  AND COALESCE(pm.change_mapping, '') NOT IN ('Removed', 'Replaced')",
    "  AND NOT EXISTS (",
    "    SELECT 1",
    "    FROM performance.pm_service_link psl",
    "    JOIN reference.service s ON s.service_id = psl.service_id",
    "    WHERE psl.measure_id = pm.measure_id",
    "      AND s.active",
    "      AND s.service_type = 'Performance'",
    "  )",
    "ORDER BY agency_name, pm.title"
  )
)

shared_entity_services <- query(
  paste(
    "WITH shared_services AS (",
    "  SELECT service_id, COUNT(DISTINCT entity_id) AS entity_count",
    "  FROM reference.plan_entity_service",
    "  GROUP BY service_id",
    "  HAVING COUNT(DISTINCT entity_id) > 1",
    ")",
    "SELECT pe.parent_agency_id AS agency_id, COALESCE(a.public_name, a.agency_name) AS agency_name,",
    "  pe.entity_id, pe.public_name AS entity_name, pes.service_id, s.service_name,",
    "  shared.entity_count AS entities_sharing_service,",
    "  pm.measure_id, pm.title AS measure_title,",
    "  CASE WHEN pm.measure_id IS NULL THEN 'Shared entity service has no linked measures'",
    "       ELSE 'Shared service link cannot identify which entity owns this measure' END AS issue",
    "FROM shared_services shared",
    "JOIN reference.plan_entity_service pes ON pes.service_id = shared.service_id",
    "JOIN reference.plan_entity pe ON pe.entity_id = pes.entity_id",
    "JOIN reference.agency a ON a.agency_id = pe.parent_agency_id",
    "JOIN reference.service s ON s.service_id = pes.service_id",
    "LEFT JOIN performance.pm_service_link psl ON psl.service_id = s.service_id",
    "LEFT JOIN performance.performance_measure pm ON pm.measure_id = psl.measure_id",
    "  AND pm.active",
    "  AND COALESCE(pm.approval_status, '') <> 'Deprecated'",
    "  AND COALESCE(pm.change_mapping, '') NOT IN ('Removed', 'Replaced')",
    "WHERE pe.active AND pe.has_own_plan AND s.active",
    "ORDER BY agency_name, s.service_name, entity_name, measure_title"
  )
)

entity_services_without_metrics <- query(
  paste(
    "SELECT pe.parent_agency_id AS agency_id, COALESCE(a.public_name, a.agency_name) AS agency_name,",
    "  pe.entity_id, pe.public_name AS entity_name, pes.service_id, s.service_name,",
    "  'Plan entity service has no active linked performance measures' AS issue",
    "FROM reference.plan_entity pe",
    "JOIN reference.agency a ON a.agency_id = pe.parent_agency_id",
    "JOIN reference.plan_entity_service pes ON pes.entity_id = pe.entity_id",
    "JOIN reference.service s ON s.service_id = pes.service_id",
    "WHERE pe.active AND pe.has_own_plan AND s.active",
    "AND NOT EXISTS (",
    "  SELECT 1",
    "  FROM performance.pm_service_link psl",
    "  JOIN performance.performance_measure pm ON pm.measure_id = psl.measure_id",
    "  WHERE psl.service_id = s.service_id",
    "    AND pm.active",
    "    AND COALESCE(pm.approval_status, '') <> 'Deprecated'",
    "    AND COALESCE(pm.change_mapping, '') NOT IN ('Removed', 'Replaced')",
    ")",
    "ORDER BY agency_name, entity_name, s.service_name"
  )
)

entity_measure_review <- query(
  paste(
    "WITH parent_entity_agencies AS (",
    "  SELECT DISTINCT parent_agency_id AS agency_id",
    "  FROM reference.plan_entity",
    "  WHERE active AND has_own_plan",
    "), active_measures AS (",
    "  SELECT pm.*",
    "  FROM performance.performance_measure pm",
    "  JOIN parent_entity_agencies pea ON pea.agency_id = pm.agency_id",
    "  WHERE pm.active",
    "    AND COALESCE(pm.approval_status, '') <> 'Deprecated'",
    "    AND COALESCE(pm.change_mapping, '') NOT IN ('Removed', 'Replaced')",
    "), measure_services AS (",
    "  SELECT pm.measure_id,",
    "    string_agg(DISTINCT s.service_id, '; ' ORDER BY s.service_id) AS current_service_ids,",
    "    string_agg(DISTINCT s.service_name, '; ' ORDER BY s.service_name) AS current_service_names,",
    "    COUNT(DISTINCT s.service_id) AS linked_service_count",
    "  FROM active_measures pm",
    "  LEFT JOIN performance.pm_service_link psl ON psl.measure_id = pm.measure_id",
    "  LEFT JOIN reference.service s ON s.service_id = psl.service_id AND s.active",
    "  GROUP BY pm.measure_id",
    "), linked_entity_candidates AS (",
    "  SELECT pm.measure_id,",
    "    string_agg(DISTINCT pe.entity_id::text || ': ' || pe.public_name || ' [' || pes.service_id || ']', '; ' ORDER BY pe.entity_id::text || ': ' || pe.public_name || ' [' || pes.service_id || ']') AS candidate_entities_from_linked_services,",
    "    COUNT(DISTINCT pe.entity_id) AS linked_entity_count",
    "  FROM active_measures pm",
    "  JOIN performance.pm_service_link psl ON psl.measure_id = pm.measure_id",
    "  JOIN reference.plan_entity_service pes ON pes.service_id = psl.service_id",
    "  JOIN reference.plan_entity pe ON pe.entity_id = pes.entity_id AND pe.active AND pe.has_own_plan",
    "  GROUP BY pm.measure_id",
    "), all_parent_entities AS (",
    "  SELECT pe.parent_agency_id AS agency_id,",
    "    string_agg(DISTINCT pe.entity_id::text || ': ' || pe.public_name, '; ' ORDER BY pe.entity_id::text || ': ' || pe.public_name) AS all_candidate_entities",
    "  FROM reference.plan_entity pe",
    "  WHERE pe.active AND pe.has_own_plan",
    "  GROUP BY pe.parent_agency_id",
    ")",
    "SELECT",
    "  CASE",
    "    WHEN COALESCE(ms.linked_service_count, 0) = 0 THEN 'No service link'",
    "    WHEN COALESCE(lec.linked_entity_count, 0) = 0 THEN 'Linked service not mapped to plan entity'",
    "    WHEN COALESCE(lec.linked_entity_count, 0) > 1 THEN 'Linked service maps to multiple entities'",
    "    ELSE 'Review entity assignment'",
    "  END AS issue_type,",
    "  pm.agency_id, COALESCE(a.public_name, a.agency_name) AS agency_name,",
    "  pm.measure_id, pm.title AS measure_title, pm.measure_type, pm.desired_direction,",
    "  pm.data_owner, pm.data_owner_role,",
    "  COALESCE(ms.current_service_ids, '') AS current_service_ids,",
    "  COALESCE(ms.current_service_names, '') AS current_service_names,",
    "  COALESCE(lec.candidate_entities_from_linked_services, '') AS candidate_entities_from_linked_services,",
    "  COALESCE(ape.all_candidate_entities, '') AS all_candidate_entities_for_parent_agency,",
    "  '' AS analyst_recommended_entity_id,",
    "  '' AS analyst_recommended_entity_name,",
    "  '' AS analyst_recommended_service_id,",
    "  '' AS analyst_action,",
    "  '' AS analyst_notes",
    "FROM active_measures pm",
    "JOIN reference.agency a ON a.agency_id = pm.agency_id",
    "LEFT JOIN measure_services ms ON ms.measure_id = pm.measure_id",
    "LEFT JOIN linked_entity_candidates lec ON lec.measure_id = pm.measure_id",
    "LEFT JOIN all_parent_entities ape ON ape.agency_id = pm.agency_id",
    "WHERE COALESCE(ms.linked_service_count, 0) = 0",
    "   OR COALESCE(lec.linked_entity_count, 0) <> 1",
    "ORDER BY agency_name, issue_type, pm.title"
  )
)

entity_reference <- query(
  paste(
    "SELECT pe.parent_agency_id AS agency_id, COALESCE(a.public_name, a.agency_name) AS agency_name,",
    "  pe.entity_id, pe.public_name AS entity_name, pe.entity_type,",
    "  pes.service_id, s.service_name, pes.is_primary",
    "FROM reference.plan_entity pe",
    "JOIN reference.agency a ON a.agency_id = pe.parent_agency_id",
    "JOIN reference.plan_entity_service pes ON pes.entity_id = pe.entity_id",
    "JOIN reference.service s ON s.service_id = pes.service_id",
    "WHERE pe.active AND pe.has_own_plan",
    "ORDER BY agency_name, entity_name, pes.is_primary DESC, s.service_name"
  )
)

write.csv(summary_rows, file.path(output_dir, "summary.csv"), row.names = FALSE, na = "")
write.csv(services_without_metrics, file.path(output_dir, "services_without_metrics.csv"), row.names = FALSE, na = "")
write.csv(unassigned_measures, file.path(output_dir, "unassigned_measures.csv"), row.names = FALSE, na = "")
write.csv(shared_entity_services, file.path(output_dir, "shared_entity_services.csv"), row.names = FALSE, na = "")
write.csv(entity_services_without_metrics, file.path(output_dir, "entity_services_without_metrics.csv"), row.names = FALSE, na = "")
write.csv(entity_measure_review, file.path(output_dir, "entity_measure_review.csv"), row.names = FALSE, na = "")
write.csv(entity_reference, file.path(output_dir, "entity_reference.csv"), row.names = FALSE, na = "")

cat("summary_rows=", nrow(summary_rows), "\n", sep = "")
cat("services_without_metrics=", nrow(services_without_metrics), "\n", sep = "")
cat("unassigned_measures=", nrow(unassigned_measures), "\n", sep = "")
cat("shared_entity_services=", nrow(shared_entity_services), "\n", sep = "")
cat("entity_services_without_metrics=", nrow(entity_services_without_metrics), "\n", sep = "")
cat("entity_measure_review=", nrow(entity_measure_review), "\n", sep = "")
cat("entity_reference=", nrow(entity_reference), "\n", sep = "")
