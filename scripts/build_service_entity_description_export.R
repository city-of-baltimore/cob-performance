source("R/database.R")

output_dir <- "outputs/service_entity_description_export"
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

con <- connect_app_database()
on.exit(DBI::dbDisconnect(con), add = TRUE)

rows <- DBI::dbGetQuery(con, paste(
  "SELECT",
  "  s.agency_id AS \"Agency ID\",",
  "  COALESCE(NULLIF(a.public_name, ''), a.agency_name) AS \"Agency\",",
  "  s.service_id AS \"Service ID\",",
  "  s.service_name AS \"Service\",",
  "  pe.entity_id AS \"Entity ID\",",
  "  pe.public_name AS \"Public_Name\",",
  "  s.service_description AS \"Service Description\"",
  "FROM reference.service s",
  "JOIN reference.agency a ON a.agency_id = s.agency_id",
  "LEFT JOIN reference.plan_entity_service pes ON pes.service_id = s.service_id",
  "LEFT JOIN reference.plan_entity pe ON pe.entity_id = pes.entity_id AND pe.active",
  "WHERE s.active",
  "ORDER BY COALESCE(NULLIF(a.public_name, ''), a.agency_name), s.service_name, pe.public_name"
))

write.csv(file = file.path(output_dir, "service_entity_description_export.csv"), rows, row.names = FALSE, na = "")
cat("rows=", nrow(rows), "\n", sep = "")
cat("blank_entities=", sum(is.na(rows[["Entity ID"]]) | rows[["Entity ID"]] == ""), "\n", sep = "")
