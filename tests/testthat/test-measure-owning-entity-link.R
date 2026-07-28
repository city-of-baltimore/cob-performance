# Reported 2026-07-28: a brand-new Citywide measure created via the
# owning-entity picker (measure_modal_ui's show_owning_entity_picker, added
# alongside the Action Plan Measures admin page) got its measure_entity_link
# row based on whatever plan the CURRENT user happened to be viewing, not the
# entity actually selected in the picker -- e.g. a SystemAdmin viewing
# Mayoralty's own plan who picked "OPI" as the new measure's owner would
# silently link the measure to Mayoralty's context instead of OPI. Confirmed
# by direct browser testing against local dev: before this fix, saving with
# "Mayor's Office of LGBTQ Affairs" picked wrote a link row for whatever
# entity/agency the current session was scoped to; after, it correctly wrote
# entity_id = 4 (LGBTQ Affairs). See resolve_link_submitter_value() and its
# call in persist_measure() in app.R.

test_that("resolve_link_submitter_value uses the owning-entity picker for a brand-new measure", {
  expect_equal(
    resolve_link_submitter_value("new", "entity:4", "entity:2"),
    "entity:4"
  )
  expect_equal(
    resolve_link_submitter_value(NULL, "agency:AGC4346", "entity:2"),
    "agency:AGC4346"
  )
})

test_that("resolve_link_submitter_value falls back to the current submitter when editing an existing measure", {
  # Editing an existing measure never shows the owning-entity picker, so
  # input$measure_owning_entity is NULL/unset -- but even if some stale value
  # were present, an existing measure_id must not have its link reassigned.
  expect_equal(
    resolve_link_submitter_value("42", "entity:4", "entity:2"),
    "entity:2"
  )
  expect_equal(
    resolve_link_submitter_value("42", NULL, "entity:2"),
    "entity:2"
  )
})

test_that("resolve_link_submitter_value falls back to the current submitter when the picker value is missing or blank", {
  expect_equal(resolve_link_submitter_value("new", NULL, "entity:2"), "entity:2")
  expect_equal(resolve_link_submitter_value("new", "", "entity:2"), "entity:2")
  expect_equal(resolve_link_submitter_value(NULL, character(0), "entity:2"), "entity:2")
})
