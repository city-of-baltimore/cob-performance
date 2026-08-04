# Three purpose-built agencies exist in production for rehearsing the CLS
# workflow without touching real data (TST9001-3, all named "TEST ..."). BBMR
# reviewers were given edit access to those, and only those, on 2026-08-03.
#
# There is no is_test column on reference.agency, so membership is derived from
# the naming convention. These tests pin that derivation down, because the whole
# permission carve-out hangs off it: if cls_test_agency_ids() ever started
# returning a real agency, reviewers would silently gain edit rights over a real
# agency's submissions.
#
# Pure functions over a db list, so no database is needed.

agency_table <- function(agency_id, agency_name, public_name = NULL, submit_plan = TRUE) {
  n <- length(agency_id)
  data.frame(
    agency_id = as.character(agency_id),
    agency_name = as.character(agency_name),
    public_name = if (is.null(public_name)) rep(NA_character_, n) else as.character(public_name),
    submit_plan = rep(submit_plan, length.out = n),
    stringsAsFactors = FALSE
  )
}

fake_db <- function(...) list(reference_agency = agency_table(...))

# A db complete enough for agency_selector_choices() and resolve_owning_agency_id():
# two agencies (one test, one real), and one entity rolling up to the test agency.
selector_db <- function() {
  list(
    reference_agency = agency_table(
      c("TST9001", "AGC1200"),
      c("TEST Agency of Sparkly Sidewalks", "Comptroller")
    ),
    planning_agency_plan = data.frame(
      plan_id = c(1L, 2L, 3L),
      agency_id = c("TST9001", "AGC1200", NA_character_),
      entity_id = c(NA_integer_, NA_integer_, 31L),
      fiscal_year = c(2027L, 2027L, 2027L),
      stringsAsFactors = FALSE
    ),
    reference_plan_entity = data.frame(
      entity_id = 31L,
      public_name = "TEST Quasi Bureau of Waffle Forecasting",
      parent_agency_id = "TST9001",
      stringsAsFactors = FALSE
    )
  )
}

test_that("cls_test_agency_ids finds the TST-prefixed agencies", {
  db <- fake_db(
    c("TST9001", "TST9002", "TST9003", "AGC1200", "AGC2500"),
    c("TEST Agency of Sparkly Sidewalks", "TEST Quasi Bureau of Waffle Forecasting",
      "TEST Mayor's Office of Tiny Triumphs", "Comptroller", "Fire")
  )
  expect_equal(cls_test_agency_ids(db), c("TST9001", "TST9002", "TST9003"))
})

test_that("either the id prefix or the name prefix is enough", {
  expect_equal(cls_test_agency_ids(fake_db("TST9004", "Sandbox Agency")), "TST9004")
  expect_equal(cls_test_agency_ids(fake_db("AGC9999", "TEST Something Else")), "AGC9999")
  expect_equal(cls_test_agency_ids(fake_db("AGC9998", "Internal", "TEST Public Facing")), "AGC9998")
})

test_that("real agencies are never treated as test agencies", {
  # The important negatives: "test" appearing mid-name must not match, or a real
  # agency would inherit the carve-out.
  db <- fake_db(
    c("AGC1200", "AGC2500", "AGC3000", "AGC4000", "AGC5000"),
    c("Comptroller",
      "Office of Protest and Testimony",
      "Contested Elections Board",
      "Latest Initiatives Office",
      "Attestation Services")
  )
  expect_equal(cls_test_agency_ids(db), character(0))
  expect_false(cls_is_test_agency(db, "AGC2500"))
  expect_false(cls_is_test_agency(db, "AGC3000"))
})

test_that("cls_is_test_agency handles missing and empty input", {
  db <- fake_db(c("TST9001", "AGC1200"), c("TEST Sparkly", "Comptroller"))
  expect_true(cls_is_test_agency(db, "TST9001"))
  expect_false(cls_is_test_agency(db, "AGC1200"))
  expect_false(cls_is_test_agency(db, ""))
  expect_false(cls_is_test_agency(db, NA))
  expect_false(cls_is_test_agency(db, NULL))
  expect_false(cls_is_test_agency(db, "AGC-DOES-NOT-EXIST"))
})

test_that("an empty or absent agency table yields no test agencies", {
  expect_equal(cls_test_agency_ids(list()), character(0))
  expect_equal(cls_test_agency_ids(list(reference_agency = NULL)), character(0))
  expect_equal(cls_test_agency_ids(fake_db(character(0), character(0))), character(0))
})

test_that("cls_test_selector_choices returns the test agency and its entities only", {
  choices <- cls_test_selector_choices(selector_db())
  expect_setequal(unname(choices), c("agency:TST9001", "entity:31"))
  expect_false("agency:AGC1200" %in% unname(choices))
})

test_that("cls_add_test_choices_for_reviewers only affects BBMR reviewers", {
  db <- selector_db()
  existing <- c("Comptroller" = "agency:AGC1200")

  reviewer <- cls_add_test_choices_for_reviewers(db, existing, "BBMRReviewer")
  expect_setequal(unname(reviewer), c("agency:AGC1200", "agency:TST9001", "entity:31"))

  for (role in c("AgencyWriter", "AgencySubmitter", "AgencyViewer", "OPIReviewer", "DeputyMayor")) {
    expect_equal(cls_add_test_choices_for_reviewers(db, existing, role), existing,
                 info = paste("role:", role))
  }
})

test_that("adding test choices does not duplicate what is already there", {
  db <- selector_db()
  already <- c("TEST Agency of Sparkly Sidewalks" = "agency:TST9001",
               "Comptroller" = "agency:AGC1200")
  merged <- cls_add_test_choices_for_reviewers(db, already, "BBMRReviewer")
  expect_equal(sum(unname(merged) == "agency:TST9001"), 1L)
  expect_setequal(unname(merged), c("agency:TST9001", "agency:AGC1200", "entity:31"))
})

test_that("a reviewer with no grants at all still gets the test agencies", {
  # The real starting state: BBMRReviewer rows carry no agency_id, so
  # user_submitter_choices() returns nothing and the switcher came up empty.
  merged <- cls_add_test_choices_for_reviewers(selector_db(), character(0), "BBMRReviewer")
  expect_setequal(unname(merged), c("agency:TST9001", "entity:31"))
})

test_that("a database with no test agencies adds nothing", {
  db <- selector_db()
  db$reference_agency <- agency_table(c("AGC1200", "AGC2500"), c("Comptroller", "Fire"))
  expect_equal(cls_test_selector_choices(db), character(0))
  existing <- c("Comptroller" = "agency:AGC1200")
  expect_equal(cls_add_test_choices_for_reviewers(db, existing, "BBMRReviewer"), existing)
})

test_that("BBMR reviewers can now reach both Budget Planning pages", {
  expect_true(can_access_budget_planning("BBMRReviewer"))
  expect_true(can_view_cls_requests("BBMRReviewer"))
  expect_true(can_review_cls("BBMRReviewer"))
  expect_true(can_edit_cls_requests("BBMRReviewer"))
})

test_that("agencies are still shut out of Budget Planning entirely", {
  # The placeholder spend-category list is why. If this ever flips it should be a
  # deliberate change, with this test updated alongside it.
  for (role in c("AgencyViewer", "AgencyWriter", "AgencySubmitter", "OPIReviewer",
                 "DeputyMayor", "CAOffice")) {
    expect_false(can_access_budget_planning(role), info = paste("role:", role))
  }
})
