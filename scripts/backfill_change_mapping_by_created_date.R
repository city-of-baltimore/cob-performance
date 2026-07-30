# Manual, immediate trigger for apply_change_mapping_by_created_date_once()
# in R/database.R -- that function also runs automatically (gated by
# application.seed_applied, so it's a no-op after the first run) the next
# time ensure_review_schema() executes, i.e. the next time this app boots
# in any environment, including production once deployed. This script
# just lets you apply it to a database right now instead of waiting for
# the next restart.
source("R/database.R", local = TRUE)

connection <- connect_app_database()
on.exit(DBI::dbDisconnect(connection), add = TRUE)

before <- DBI::dbGetQuery(
  connection,
  "SELECT change_mapping, COUNT(*) AS n FROM performance.performance_measure GROUP BY change_mapping ORDER BY change_mapping"
)
cat("Before:\n")
print(before)

applied <- apply_change_mapping_by_created_date_once(connection)
cat(if (applied) "Applied.\n" else "Already applied on this database -- no-op.\n")

after <- DBI::dbGetQuery(
  connection,
  "SELECT change_mapping, COUNT(*) AS n FROM performance.performance_measure GROUP BY change_mapping ORDER BY change_mapping"
)
cat("After:\n")
print(after)
