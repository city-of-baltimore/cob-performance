source(file.path("R", "database.R"))

con <- connect_app_database()
on.exit(DBI::dbDisconnect(con), add = TRUE)

DBI::dbExecute(
  con,
  "SELECT setval(
    pg_get_serial_sequence('performance.performance_measure', 'measure_id'),
    COALESCE((SELECT MAX(measure_id) FROM performance.performance_measure), 1),
    true
  )"
)

print(DBI::dbGetQuery(con, "SELECT MAX(measure_id) AS max_measure_id FROM performance.performance_measure"))
print(DBI::dbGetQuery(con, "SELECT last_value, is_called FROM performance.performance_measure_measure_id_seq"))
