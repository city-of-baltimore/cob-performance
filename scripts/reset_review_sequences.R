source(file.path("R", "database.R"), local = TRUE)

connection <- connect_app_database()
on.exit(DBI::dbDisconnect(connection), add = TRUE)

reset_sequence <- function(table_name, column_name) {
  sql <- sprintf(
    "SELECT setval(pg_get_serial_sequence('%s', '%s'), COALESCE((SELECT MAX(%s) FROM %s), 1), (SELECT COUNT(*) > 0 FROM %s))",
    table_name,
    column_name,
    column_name,
    table_name,
    table_name
  )
  DBI::dbExecute(connection, sql)
}

reset_sequence("review.plan_review", "review_id")
reset_sequence("review.section_score", "score_id")

print(DBI::dbGetQuery(connection, "SELECT last_value, is_called FROM review.plan_review_review_id_seq"))
print(DBI::dbGetQuery(connection, "SELECT last_value, is_called FROM review.section_score_score_id_seq"))
