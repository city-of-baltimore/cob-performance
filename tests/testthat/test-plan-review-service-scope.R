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

# Reported 2026-08-05: a Mayoral Office scored 4/4 on every single criterion
# still came out capped at 85/100. plan_service_rows() (app.R) synthesizes
# "extra" service rows from performance_measure_entity_link/
# reference_plan_entity_service with no submitter_is_mayoral_service()
# check -- so collect_plan_review_scores() (server(), builds the scores
# list submitted on save) was still appending a phantom, unscored "service"
# criterion for a plan that should have none at all. That's what made the
# S3 scoring formula take the 5+15 split path instead of folding the full
# 20 points into Family of Measures. This is the same 15-point gap as PR
# #94's Tiny Triumphs data fix, but that was a stray *real*
# performance.plan_service row; this is the code path that still leaks
# even with zero such rows (performance_measure_entity_link is the
# backfill source that's actually reachable with zero plan_service rows --
# plan_service_rows() early-returns before ever consulting
# reference_plan_entity_service if the row set is still empty at that
# point).
test_that("plan_review_scorable_services excludes a phantom service synthesized for a Mayoral Office", {
  plan <- data.frame(plan_id = 144L, entity_id = 32L, agency_id = NA_character_, stringsAsFactors = FALSE)
  db <- list(
    performance_plan_service = data.frame(plan_service_id = integer(0), plan_id = integer(0), service_id = character(0)),
    reference_service = data.frame(
      service_id = "SRV1", active = TRUE, sort_order = 1L, service_name = "Phantom Service",
      service_type = "Performance", stringsAsFactors = FALSE
    ),
    performance_measure_entity_link = data.frame(entity_id = 32L, agency_id = NA_character_, entity_type = "service", service_id = "SRV1", stringsAsFactors = FALSE),
    reference_plan_entity_service = data.frame(entity_id = integer(0), service_id = character(0), is_primary = logical(0)),
    reference_plan_entity = data.frame(
      entity_id = 32L, entity_type = "MayoraltyOffice", parent_agency_id = "AGC1",
      public_name = "TEST Mayor's Office of Tiny Triumphs", active = TRUE, has_own_plan = TRUE,
      stringsAsFactors = FALSE
    )
  )
  # Confirms the phantom row really does get synthesized -- otherwise this
  # test would pass for the wrong reason (nothing to filter out).
  expect_equal(nrow(plan_service_rows(db, plan)), 1)

  result <- plan_review_scorable_services(db, plan)
  expect_equal(nrow(result), 0)
})

test_that("plan_review_scorable_services still returns a Quasi-Agency's genuinely linked service", {
  plan <- data.frame(plan_id = 143L, entity_id = 31L, agency_id = NA_character_, stringsAsFactors = FALSE)
  db <- list(
    performance_plan_service = data.frame(plan_service_id =293L, plan_id = 143L, service_id = "TST002", stringsAsFactors = FALSE),
    reference_service = data.frame(
      service_id = "TST002", active = TRUE, sort_order = 1L, service_name = "Waffle Forecasting Service",
      service_type = "Performance", stringsAsFactors = FALSE
    ),
    performance_measure_entity_link = data.frame(entity_id = integer(0), agency_id = character(0), entity_type = character(0), service_id = character(0)),
    reference_plan_entity_service = data.frame(entity_id = 31L, service_id = "TST002", is_primary = TRUE, stringsAsFactors = FALSE),
    reference_plan_entity = data.frame(
      entity_id = 31L, entity_type = "QuasiAgency", parent_agency_id = "AGC1",
      public_name = "TEST Quasi Bureau of Waffle Forecasting", active = TRUE, has_own_plan = TRUE,
      stringsAsFactors = FALSE
    )
  )
  result <- plan_review_scorable_services(db, plan)
  expect_equal(result$service_id, "TST002")
})
