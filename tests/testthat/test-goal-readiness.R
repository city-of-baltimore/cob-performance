# Regression guard for a bug reported 2026-07-23 (MOHS and BCIT): agencies
# had written complete, substantive goals -- statement, initiative, KPI,
# alignment -- but the "Goals drafted" counter on the Goals page and the
# "Plan readiness" checklist on View Plan both showed 0 complete goals no
# matter what they entered.
#
# Root cause: performance.agency_goal rows only get created when a plan is
# Approved (apply_plan_drafts_to_records() promotes the draft payload at
# that point, in R/database.R) -- every plan before that (Draft, Submitted,
# UnderReview, Returned) has its goals living only in the
# planning.plan_section_draft "goals" payload. goal_draft_readiness() used
# to early-return 0/0 whenever there were no published rows to iterate,
# so this was broken for every single agency still drafting -- confirmed
# against production: all 67 non-Approved FY2027 plans had zero published
# goal rows. Not specific to MOHS/BCIT; they're just who reported it.

fake_db_no_links <- function(draft_payload_json) {
  list(
    planning_plan_section_draft = data.frame(
      plan_id = 1L, section_key = "goals", payload = draft_payload_json, updated_at = as.POSIXct("2026-07-23 12:00:00", tz = "UTC"),
      stringsAsFactors = FALSE
    ),
    performance_agency_goal_initiative_link = data.frame(agency_goal_id = integer(0), initiative_id = integer(0)),
    performance_initiative = data.frame(initiative_id = integer(0), title = character(0)),
    performance_pm_goal_link = data.frame(agency_goal_id = integer(0), measure_id = integer(0))
  )
}

draft_plan <- data.frame(plan_id = 1L, plan_status = "Draft", stringsAsFactors = FALSE)
no_published_goals <- data.frame(agency_goal_id = integer(0), title = character(0), alignment_code = character(0), stringsAsFactors = FALSE)

test_that("a plan with real goals only in the draft (no published rows yet) is counted complete", {
  # Shape matches the actual MOHS production draft payload that triggered this bug.
  draft_json <- '{
    "goalIds": ["draft-1", "draft-2"],
    "values": {
      "goal_statement_draft-1": "By the end of FY2027, increase the exit rate to 30%.",
      "goal_alignment_draft-1": "3.2",
      "goal_statement_draft-2": "By the end of FY2027, maintain the count at 188 or fewer.",
      "goal_alignment_draft-2": "3.2"
    },
    "initiatives": {"draft-1": ["Establish a referral process."], "draft-2": ["Maintain an encampment list."]},
    "kpis": {"draft-1": ["351"], "draft-2": ["360"]}
  }'
  db <- fake_db_no_links(draft_json)
  result <- goal_draft_readiness(db, draft_plan, no_published_goals)
  expect_equal(result$complete_count, 2)
  expect_equal(result$aligned_count, 2)
})

test_that("a draft goal missing an initiative or KPI is not counted complete", {
  draft_json <- '{
    "goalIds": ["draft-1"],
    "values": {"goal_statement_draft-1": "A goal with no initiative or KPI yet.", "goal_alignment_draft-1": "3.2"},
    "initiatives": {},
    "kpis": {}
  }'
  db <- fake_db_no_links(draft_json)
  result <- goal_draft_readiness(db, draft_plan, no_published_goals)
  expect_equal(result$complete_count, 0)
  expect_equal(result$aligned_count, 1)
})

test_that("no draft and no published rows returns 0/0 without erroring", {
  db <- fake_db_no_links("{}")
  db$planning_plan_section_draft <- db$planning_plan_section_draft[0, ]
  result <- goal_draft_readiness(db, draft_plan, no_published_goals)
  expect_equal(result$complete_count, 0)
  expect_equal(result$aligned_count, 0)
})

test_that("an already-published goal (post-approval) is still counted from the real row when there's no draft", {
  db <- fake_db_no_links("{}")
  db$planning_plan_section_draft <- db$planning_plan_section_draft[0, ]
  db$performance_agency_goal_initiative_link <- data.frame(agency_goal_id = 501L, initiative_id = 1L)
  db$performance_initiative <- data.frame(initiative_id = 1L, title = "Published initiative")
  db$performance_pm_goal_link <- data.frame(agency_goal_id = 501L, measure_id = 900L)
  published_plan <- data.frame(plan_id = 1L, plan_status = "Published", stringsAsFactors = FALSE)
  published_goals <- data.frame(agency_goal_id = 501L, title = "Published goal", alignment_code = "3.2", stringsAsFactors = FALSE)
  result <- goal_draft_readiness(db, published_plan, published_goals)
  expect_equal(result$complete_count, 1)
  expect_equal(result$aligned_count, 1)
})
