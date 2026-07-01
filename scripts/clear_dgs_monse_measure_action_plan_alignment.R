source(file.path("R", "database.R"))

con <- connect_app_database()
on.exit(DBI::dbDisconnect(con), add = TRUE)

changed <- DBI::dbExecute(
  con,
  "UPDATE performance.performance_measure
   SET pillar_id = NULL,
       pillar_goal_id = NULL,
       last_updated = CURRENT_TIMESTAMP
   WHERE agency_id IN ('AGC2600', 'AGC4346')
     AND (pillar_id IS NOT NULL OR pillar_goal_id IS NOT NULL)"
)

message("Cleared Action Plan measure alignment rows: ", changed)

print(DBI::dbGetQuery(
  con,
  "SELECT agency_id, COUNT(*) AS aligned_measures
   FROM performance.performance_measure
   WHERE agency_id IN ('AGC2600', 'AGC4346')
     AND (pillar_id IS NOT NULL OR pillar_goal_id IS NOT NULL)
   GROUP BY agency_id
   ORDER BY agency_id"
))
