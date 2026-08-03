# Reported 2026-08-03: the plan review/scoring page (history_plan_modal(),
# shared by both the review detail page and the full-page scoring
# workspace) rendered whatever rows happened to sit in
# performance.plan_service for a plan, with no check against which
# service(s) that plan's entity actually owns (reference.plan_entity_service)
# and no check for submitter_is_mayoral_service(). In production data this
# surfaced as quasi-agency plans showing services that belong to a
# different entity entirely, and every Mayoral Office plan showing a
# service despite Mayoral Offices being structurally exempt from Services.
# Fixed by scoping service_rows/services in history_plan_modal() through
# plan_review_allowed_service_ids().

test_that("plan_review_allowed_service_ids returns nothing for a Mayoral Office plan", {
  plan <- data.frame(entity_id = 5L, agency_id = NA_character_)
  db <- list(
    reference_plan_entity = data.frame(
      entity_id = 5L, entity_type = "MayoraltyOffice", parent_agency_id = "AGC1",
      public_name = "Mayor's Office of Example", active = TRUE, has_own_plan = TRUE,
      stringsAsFactors = FALSE
    ),
    reference_plan_entity_service = data.frame(entity_id = 5L, service_id = "SRV1", is_primary = TRUE, stringsAsFactors = FALSE)
  )
  expect_equal(plan_review_allowed_service_ids(db, plan, c("SRV1", "SRV2")), character(0))
})

test_that("plan_review_allowed_service_ids restricts a Quasi-Agency plan to its own linked service(s)", {
  plan <- data.frame(entity_id = 7L, agency_id = NA_character_)
  db <- list(
    reference_plan_entity = data.frame(
      entity_id = 7L, entity_type = "QuasiAgency", parent_agency_id = "AGC2",
      public_name = "Some Quasi-Agency", active = TRUE, has_own_plan = TRUE,
      stringsAsFactors = FALSE
    ),
    reference_plan_entity_service = data.frame(entity_id = 7L, service_id = "SRV1", is_primary = TRUE, stringsAsFactors = FALSE)
  )
  expect_equal(plan_review_allowed_service_ids(db, plan, c("SRV1", "SRV2")), "SRV1")
})

test_that("plan_review_allowed_service_ids leaves a bare-agency plan's services unrestricted", {
  plan <- data.frame(entity_id = NA_integer_, agency_id = "AGC3")
  db <- list(
    reference_plan_entity = data.frame(
      entity_id = integer(0), entity_type = character(0), parent_agency_id = character(0),
      public_name = character(0), active = logical(0), has_own_plan = logical(0),
      stringsAsFactors = FALSE
    )
  )
  expect_equal(plan_review_allowed_service_ids(db, plan, c("SRV1", "SRV2")), c("SRV1", "SRV2"))
})
