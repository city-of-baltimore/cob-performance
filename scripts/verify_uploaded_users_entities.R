source(file.path("R", "database.R"))

con <- connect_app_database()
on.exit(DBI::dbDisconnect(con), add = TRUE)

cat("New entities and plan shells:\n")
print(DBI::dbGetQuery(
  con,
  "SELECT pe.entity_id, pe.parent_agency_id, pe.public_name, pe.entity_type, ap.plan_id, ap.plan_status
   FROM reference.plan_entity pe
   LEFT JOIN planning.agency_plan ap ON ap.entity_id = pe.entity_id
   LEFT JOIN planning.plan_cycle pc ON pc.cycle_id = ap.cycle_id AND pc.fiscal_year = 2027
   WHERE pe.entity_id BETWEEN 25 AND 30
   ORDER BY pe.entity_id"
), row.names = FALSE)

cat("\nUploaded/new users and app roles:\n")
print(DBI::dbGetQuery(
  con,
  "SELECT u.user_id, u.email, u.full_name, ur.app_role, ur.agency_id
   FROM access.\"user\" u
   LEFT JOIN access.user_role ur ON ur.user_id = u.user_id
   WHERE lower(u.email) IN (
     'otis@baltimoredevelopment.com',
     'tom.whelley@baltimoredevelopment.com',
     'jwatson@baltimoredevelopment.com',
     'rbroderickjr@baltimoredevelopment.com',
     'ehinderberger@baltimoredevelopment.com',
     'sunny.boyce@baltimorecity.gov'
   )
   ORDER BY u.email, ur.app_role"
), row.names = FALSE)

cat("\nUploaded/new users and team/function rows:\n")
print(DBI::dbGetQuery(
  con,
  "SELECT u.email, uaa.agency_id, uaa.service_id, uaa.agency_role
   FROM access.user_agency_access uaa
   JOIN access.\"user\" u ON u.user_id = uaa.user_id
   WHERE lower(u.email) IN (
     'otis@baltimoredevelopment.com',
     'tom.whelley@baltimoredevelopment.com',
     'jwatson@baltimoredevelopment.com',
     'rbroderickjr@baltimoredevelopment.com',
     'ehinderberger@baltimoredevelopment.com',
     'sunny.boyce@baltimorecity.gov'
   )
   ORDER BY u.email, uaa.agency_id"
), row.names = FALSE)
