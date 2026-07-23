# Regression guard for the AGC4317 display bug fixed this session: a regular
# single agency (public_name = NULL) must display under its own agency_name,
# not fall back to some other label -- only true quasi-agency umbrellas (a
# distinct, non-empty public_name) should override it.

fake_db_with_agencies <- function() {
  list(
    reference_agency = data.frame(
      agency_id = c("AGC0001", "AGC0002", "AGC0003"),
      agency_name = c("Department of Regular Business", "Quasi Umbrella Agency", "Blank String Agency"),
      public_name = c(NA_character_, "Public-Facing Umbrella Name", ""),
      stringsAsFactors = FALSE
    ),
    reference_plan_entity = data.frame(
      entity_id = integer(0),
      public_name = character(0),
      stringsAsFactors = FALSE
    )
  )
}

test_that("a regular agency with no public_name displays under its own agency_name", {
  db <- fake_db_with_agencies()
  expect_equal(agency_name(db, "AGC0001"), "Department of Regular Business")
})

test_that("a quasi-agency with a distinct public_name displays under that public_name", {
  db <- fake_db_with_agencies()
  expect_equal(agency_name(db, "AGC0002"), "Public-Facing Umbrella Name")
})

test_that("a blank (empty string) public_name is treated the same as NULL", {
  db <- fake_db_with_agencies()
  expect_equal(agency_name(db, "AGC0003"), "Blank String Agency")
})

test_that("an unknown agency_id falls back to a generic label instead of erroring", {
  db <- fake_db_with_agencies()
  expect_equal(agency_name(db, "AGC9999"), "Agency")
})

test_that("plan_display_name resolves an entity-scoped plan via reference_plan_entity", {
  db <- fake_db_with_agencies()
  db$reference_plan_entity <- data.frame(
    entity_id = 42L,
    public_name = "Baltimore Development Corporation",
    stringsAsFactors = FALSE
  )
  plan <- data.frame(entity_id = 42L, agency_id = NA_character_, stringsAsFactors = FALSE)
  expect_equal(plan_display_name(db, plan), "Baltimore Development Corporation")
})

test_that("plan_display_name falls back to agency_name for an agency-scoped plan (entity_id is NA)", {
  db <- fake_db_with_agencies()
  plan <- data.frame(entity_id = NA_integer_, agency_id = "AGC0001", stringsAsFactors = FALSE)
  expect_equal(plan_display_name(db, plan), "Department of Regular Business")
})

test_that("plan_display_name handles a NULL/empty plan without erroring", {
  db <- fake_db_with_agencies()
  expect_equal(plan_display_name(db, NULL), "Plan submitter")
  expect_equal(plan_display_name(db, db$reference_agency[0, ]), "Plan submitter")
})
