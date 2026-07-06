source(file.path("R", "database.R"))

con <- connect_app_database()
on.exit(DBI::dbDisconnect(con), add = TRUE)

cat("Entity service links for entities 25-30:\n")
print(DBI::dbGetQuery(
  con,
  "SELECT pe.entity_id, pe.public_name, pes.service_id, s.service_name, pes.is_primary
   FROM reference.plan_entity pe
   JOIN reference.plan_entity_service pes ON pes.entity_id = pe.entity_id
   JOIN reference.service s ON s.service_id = pes.service_id
   WHERE pe.entity_id BETWEEN 25 AND 30
   ORDER BY pe.entity_id, pes.service_id"
), row.names = FALSE)

cat("\nFY27 plan service rows for entities 25-30:\n")
print(DBI::dbGetQuery(
  con,
  "SELECT ap.plan_id, pe.entity_id, pe.public_name, ps.plan_service_id, ps.service_id, s.service_name
   FROM planning.agency_plan ap
   JOIN planning.plan_cycle pc ON pc.cycle_id = ap.cycle_id AND pc.fiscal_year = 2027
   JOIN reference.plan_entity pe ON pe.entity_id = ap.entity_id
   LEFT JOIN performance.plan_service ps ON ps.plan_id = ap.plan_id
   LEFT JOIN reference.service s ON s.service_id = ps.service_id
   WHERE pe.entity_id BETWEEN 25 AND 30
   ORDER BY pe.entity_id, ps.plan_service_id"
), row.names = FALSE)
