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
# entity_id = 4 (LGBTQ Affairs).
#
# Follow-up bug, same day: that first fix over-corrected -- leaving the
# picker at its default (Mayor's Office / OPI) is documented in the modal's
# own field help text as meaning "no single clear owner", not "OPI owns
# this". Linking the default selection to OPI anyway made every unassigned
# Citywide measure incorrectly show up on OPI's own Measures page. Confirmed
# in production: measure 784 ("test"), created with the picker left at its
# default, got a measure_entity_link row pointing at OPI's entity_id. See
# resolve_link_submitter_value() and its call in persist_measure() in app.R.

test_that("resolve_link_submitter_value uses the owning-entity picker for a brand-new measure", {
  expect_equal(
    resolve_link_submitter_value("new", "entity:4", "entity:2", default_picker_value = "entity:2"),
    "entity:4"
  )
  expect_equal(
    resolve_link_submitter_value(NULL, "agency:AGC4346", "entity:2", default_picker_value = "entity:2"),
    "agency:AGC4346"
  )
})

test_that("resolve_link_submitter_value skips linking when the picker is left at its default (no single clear owner)", {
  expect_true(is.na(
    resolve_link_submitter_value("new", "entity:2", "entity:2", default_picker_value = "entity:2")
  ))
  expect_true(is.na(
    resolve_link_submitter_value(NULL, "entity:2", "agency:AGC2600", default_picker_value = "entity:2")
  ))
  # No default_picker_value supplied -- can't tell "left at default" from
  # "explicitly chose this", so fall back to using the picker value as-is.
  expect_equal(
    resolve_link_submitter_value("new", "entity:2", "entity:2"),
    "entity:2"
  )
})

test_that("resolve_link_submitter_value falls back to the current submitter when editing an existing measure", {
  # Editing an existing measure never shows the owning-entity picker, so
  # input$measure_owning_entity is NULL/unset -- but even if some stale value
  # were present, an existing measure_id must not have its link reassigned.
  expect_equal(
    resolve_link_submitter_value("42", "entity:4", "entity:2", default_picker_value = "entity:2"),
    "entity:2"
  )
  expect_equal(
    resolve_link_submitter_value("42", NULL, "entity:2", default_picker_value = "entity:2"),
    "entity:2"
  )
})

test_that("resolve_link_submitter_value falls back to the current submitter when the picker value is missing or blank", {
  expect_equal(resolve_link_submitter_value("new", NULL, "entity:2", default_picker_value = "entity:2"), "entity:2")
  expect_equal(resolve_link_submitter_value("new", "", "entity:2", default_picker_value = "entity:2"), "entity:2")
  expect_equal(resolve_link_submitter_value(NULL, character(0), "entity:2", default_picker_value = "entity:2"), "entity:2")
})
