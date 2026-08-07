# Regression guard for extending the refresh_app_data() capacity fix
# (2026-08-05/06, CLS was the first domain) to Measures -- the second,
# more cross-table-coupled domain the backlog specifically called out.
# Every measure save function (save_measure_record, delete_measure_record,
# review_measure_record, set_measure_active, revert_measure_to_draft,
# ensure_measure_current_entity_link) writes exclusively to
# performance.performance_measure/measure_actuals/pm_goal_link/
# pm_service_link/measure_entity_link and review.measure_review -- goal/
# service KPI links only ever change at plan publish time
# (apply_plan_drafts_to_records()), which stays on a full reload, so a
# measures-only refresh can't leave those pages stale. city_measures and
# strategic_plan are derived from performance_measure/measure_actuals, so
# they're recomputed here too, or the Action Plan page would show stale
# numbers after a measure save.
test_that("load_measures_domain_data matches the measures slice of a full load_app_data reload", {
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)

  full <- load_app_data(connection)
  domain <- load_measures_domain_data(connection)

  measures_keys <- c(
    "performance_pm_goal_link", "performance_pm_service_link", "performance_pm_service_link_all",
    "performance_measure_entity_link", "performance_performance_measure", "performance_measure_actuals",
    "review_measure_review", "city_measures", "strategic_plan"
  )
  expect_setequal(names(domain), measures_keys)
  for (key in measures_keys) {
    expect_identical(domain[[key]], full[[key]], info = key)
  }
})

test_that("load_measures_domain_data does not export reference.pillar/pillar_goal themselves", {
  # Those tables are queried internally to compute city_measures/
  # strategic_plan but deliberately not re-exported -- a measures-only
  # refresh shouldn't also overwrite app_data()'s reference_pillar/
  # reference_pillar_goal keys, since nothing about a measure save
  # changes them.
  skip_if_no_test_database()
  connection <- connect_app_database()
  on.exit(DBI::dbDisconnect(connection), add = TRUE)

  domain <- load_measures_domain_data(connection)
  expect_false("reference_pillar" %in% names(domain))
  expect_false("reference_pillar_goal" %in% names(domain))
})
