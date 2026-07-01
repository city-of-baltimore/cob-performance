source(file.path("R", "database.R"))

con <- connect_app_database()
on.exit(DBI::dbDisconnect(con), add = TRUE)

print(DBI::dbGetQuery(
  con,
  "SELECT ap.plan_id, ag.agency_goal_id, ag.sort_order, ag.title,
          COALESCE(pg.goal_code, '') AS alignment_code,
          COUNT(pgl.measure_id) AS kpi_count,
          STRING_AGG(pgl.measure_id::text, ', ' ORDER BY pgl.measure_id) AS measure_ids
   FROM planning.agency_plan ap
   JOIN planning.plan_cycle pc ON pc.cycle_id = ap.cycle_id
   JOIN performance.agency_goal ag ON ag.plan_id = ap.plan_id
   LEFT JOIN performance.agency_goal_pillar_link agpl ON agpl.agency_goal_id = ag.agency_goal_id
   LEFT JOIN reference.pillar_goal pg ON pg.pillar_goal_id = agpl.pillar_goal_id
   LEFT JOIN performance.pm_goal_link pgl ON pgl.agency_goal_id = ag.agency_goal_id
   WHERE ap.agency_id = 'AGC2600'
     AND pc.fiscal_year = 2027
   GROUP BY ap.plan_id, ag.agency_goal_id, ag.sort_order, ag.title, pg.goal_code
   ORDER BY ag.sort_order"
))

print(DBI::dbGetQuery(
  con,
  "SELECT section_key, payload::text AS payload, revision, updated_at
   FROM planning.plan_section_draft
   WHERE plan_id IN (
     SELECT ap.plan_id
     FROM planning.agency_plan ap
     JOIN planning.plan_cycle pc ON pc.cycle_id = ap.cycle_id
     WHERE ap.agency_id = 'AGC2600' AND pc.fiscal_year = 2027
   )
   AND section_key = 'goals'"
))

print(DBI::dbGetQuery(
  con,
  "SELECT m.measure_id, m.title, pc.fiscal_year, m.active, m.approval_status, m.change_mapping
   FROM performance.performance_measure m
   JOIN planning.plan_cycle pc ON pc.cycle_id = m.initial_cycle
   WHERE m.measure_id IN (97, 663, 664, 665, 666, 667, 668, 85)
   ORDER BY m.measure_id"
))

data <- load_app_data(con)
print(data$performance_pm_goal_link[data$performance_pm_goal_link$agency_goal_id %in% c(1, 2, 3), , drop = FALSE])

source("app.R")
data <- load_app_data(con)
plan <- current_plan(data, "agency:AGC2600")
goals <- data$performance_agency_goal[data$performance_agency_goal$plan_id == plan$plan_id, , drop = FALSE]
goal_links <- data$performance_pm_goal_link[data$performance_pm_goal_link$agency_goal_id %in% goals$agency_goal_id, , drop = FALSE]
library_rows <- eligible_plan_measures(measure_library_rows(data, plan, include_ineligible = FALSE))
choice_rows <- goal_kpi_choice_rows(data, plan, goals)
linked_ids <- unique(goal_links$measure_id)
cat("Goal-linked measure IDs:", paste(linked_ids, collapse = ", "), "\n")
cat("Library measure IDs:", paste(library_rows$measure_id, collapse = ", "), "\n")
cat("Missing linked IDs from library:", paste(setdiff(linked_ids, library_rows$measure_id), collapse = ", "), "\n")
cat("Dropdown choice measure IDs:", paste(choice_rows$measure_id, collapse = ", "), "\n")
cat("Missing linked IDs from dropdown choices:", paste(setdiff(linked_ids, choice_rows$measure_id), collapse = ", "), "\n")
