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

# Reported 2026-08-05: a Returned plan's "Plan readiness" checklist flagged
# a goal as over the 5-KPI limit that the agency had already trimmed to 5
# or fewer in their current draft -- plan_goal_measure_counts() only ever
# counted the live performance_pm_goal_link rows (last written whenever
# that goal was previously Approved/Published), with no awareness of the
# in-progress draft the person is actually looking at.
test_that("plan_goal_measure_counts reads the current draft's KPI list, not the stale published one, for a Returned plan", {
  returned_plan <- data.frame(plan_id = 1L, plan_status = "Returned", stringsAsFactors = FALSE)
  goals <- data.frame(agency_goal_id = 501L, stringsAsFactors = FALSE)
  db <- list(
    planning_plan_section_draft = data.frame(
      plan_id = 1L, section_key = "goals",
      payload = '{"kpis": {"501": ["1", "2", "3"]}}',
      stringsAsFactors = FALSE
    ),
    # The live table still has the old, over-the-limit set from before this
    # goal was last published/returned.
    performance_pm_goal_link = data.frame(agency_goal_id = rep(501L, 7), measure_id = 1:7)
  )
  counts <- plan_goal_measure_counts(db, returned_plan, goals)
  expect_equal(counts$measure_count[[1]], 3)
})

test_that("plan_goal_measure_counts falls back to the live table for a goal the draft doesn't mention", {
  returned_plan <- data.frame(plan_id = 1L, plan_status = "Returned", stringsAsFactors = FALSE)
  goals <- data.frame(agency_goal_id = 501L, stringsAsFactors = FALSE)
  db <- list(
    planning_plan_section_draft = data.frame(plan_id = 1L, section_key = "goals", payload = '{"kpis": {}}', stringsAsFactors = FALSE),
    performance_pm_goal_link = data.frame(agency_goal_id = 501L, measure_id = 900L)
  )
  counts <- plan_goal_measure_counts(db, returned_plan, goals)
  expect_equal(counts$measure_count[[1]], 1)
})

test_that("plan_goal_measure_counts uses the live table for an Approved/Published plan, ignoring any leftover draft", {
  published_plan <- data.frame(plan_id = 1L, plan_status = "Published", stringsAsFactors = FALSE)
  goals <- data.frame(agency_goal_id = 501L, stringsAsFactors = FALSE)
  db <- list(
    planning_plan_section_draft = data.frame(plan_id = 1L, section_key = "goals", payload = '{"kpis": {"501": ["1"]}}', stringsAsFactors = FALSE),
    performance_pm_goal_link = data.frame(agency_goal_id = 501L, measure_id = c(1L, 2L))
  )
  counts <- plan_goal_measure_counts(db, published_plan, goals)
  expect_equal(counts$measure_count[[1]], 2)
})

# Reported 2026-08-05 (Overdose Response): the "Plan readiness" checklist
# said "missing at least one plan measure" despite 4 KPIs genuinely picked
# across two draft-only goals. plan_selected_measure_ids() only ever read
# the live performance_agency_goal/pm_goal_link tables for its goal-linked
# half -- same root cause as plan_goal_measure_counts() above (goals only
# become published rows on Approval), but that function's draft-awareness
# fix was never applied here. The service-linked half already had its own
# services-draft handling; only goals were missing it.
test_that("plan_selected_measure_ids counts draft-only goals' KPI picks for a still-Drafting plan", {
  draft_plan <- data.frame(plan_id = 1L, plan_status = "Draft", stringsAsFactors = FALSE)
  no_published_goals <- data.frame(agency_goal_id = integer(0), title = character(0), stringsAsFactors = FALSE)
  no_services <- data.frame(plan_service_id = integer(0), plan_id = integer(0), service_id = character(0))
  db <- list(
    planning_plan_section_draft = data.frame(
      plan_id = 1L, section_key = "goals",
      payload = '{"goalIds": ["draft-1", "draft-2"], "kpis": {"draft-1": ["884", "883"], "draft-2": ["882", "894"]}}',
      stringsAsFactors = FALSE
    ),
    performance_pm_goal_link = data.frame(agency_goal_id = integer(0), measure_id = integer(0))
  )
  result <- plan_selected_measure_ids(db, draft_plan, no_published_goals, no_services)
  expect_setequal(result, c(884L, 883L, 882L, 894L))
})

test_that("plan_selected_measure_ids falls back to the live table for a published goal with no draft KPI entry", {
  returned_plan <- data.frame(plan_id = 1L, plan_status = "Returned", stringsAsFactors = FALSE)
  published_goals <- data.frame(agency_goal_id = 501L, stringsAsFactors = FALSE)
  no_services <- data.frame(plan_service_id = integer(0), plan_id = integer(0), service_id = character(0))
  db <- list(
    planning_plan_section_draft = data.frame(plan_id = 1L, section_key = "goals", payload = '{"kpis": {}}', stringsAsFactors = FALSE),
    performance_pm_goal_link = data.frame(agency_goal_id = 501L, measure_id = 900L)
  )
  result <- plan_selected_measure_ids(db, returned_plan, published_goals, no_services)
  expect_setequal(result, 900L)
})

test_that("plan_selected_measure_ids uses the live table for an Approved/Published plan, ignoring any leftover draft", {
  published_plan <- data.frame(plan_id = 1L, plan_status = "Published", stringsAsFactors = FALSE)
  published_goals <- data.frame(agency_goal_id = 501L, stringsAsFactors = FALSE)
  no_services <- data.frame(plan_service_id = integer(0), plan_id = integer(0), service_id = character(0))
  db <- list(
    planning_plan_section_draft = data.frame(plan_id = 1L, section_key = "goals", payload = '{"kpis": {"501": ["1"]}}', stringsAsFactors = FALSE),
    performance_pm_goal_link = data.frame(agency_goal_id = 501L, measure_id = 900L)
  )
  result <- plan_selected_measure_ids(db, published_plan, published_goals, no_services)
  expect_setequal(result, 900L)
})

# Reported 2026-08-05: a reviewer's score/notes entered under a goal
# silently never saved, even though the autosave indicator said it had --
# reproduced on a real plan (agency AGC4310, UnderReview) whose 5 goals,
# including one about growing Minority/Women Business Enterprise
# participation, all still live only in the goals draft payload (zero rows
# in performance.agency_goal, since goals aren't promoted until Approval).
# collect_plan_review_scores() only ever iterated the live table, so it
# never attempted to save ANY goal-level score for such a plan. Separately,
# the previous synthetic-id fallback (`suppressWarnings(as.integer(goal_id))
# %||% -i`) never actually triggered: base R's %||% (R 4.4+) only
# substitutes on NULL, not NA, so every draft-only goal's target_id stayed
# NA -- collapsing every draft goal's review controls onto the same widget
# IDs. plan_review_goal_target_ids() is the shared fix used by both the
# render side (history_plan_modal()/plan_export_payload()) and the save
# side (collect_plan_review_scores()).
test_that("plan_review_goal_target_ids assigns distinct, non-NA synthetic ids to every draft-only goal", {
  plan <- data.frame(plan_id = 107L, plan_status = "UnderReview", stringsAsFactors = FALSE)
  no_goals <- data.frame(agency_goal_id = integer(0), sort_order = integer(0), stringsAsFactors = FALSE)
  db <- list(
    planning_plan_section_draft = data.frame(
      plan_id = 107L, section_key = "goals",
      payload = '{"goalIds": ["draft-1", "draft-1784904475724", "draft-1785177674731", "draft-1785177811325", "draft-1785331311771"]}',
      stringsAsFactors = FALSE
    )
  )
  result <- plan_review_goal_target_ids(db, plan, no_goals)
  expect_equal(nrow(result), 5)
  expect_equal(result$target_id, -(1:5))
  expect_false(any(is.na(result$target_id)))
})

test_that("plan_review_goal_target_ids keeps an already-promoted goal's real id and only synthesizes one for a genuinely draft-only goal", {
  plan <- data.frame(plan_id = 999L, plan_status = "Returned", stringsAsFactors = FALSE)
  no_goals <- data.frame(agency_goal_id = integer(0), sort_order = integer(0), stringsAsFactors = FALSE)
  db <- list(
    planning_plan_section_draft = data.frame(
      plan_id = 999L, section_key = "goals",
      payload = '{"goalIds": ["501", "draft-abc"]}',
      stringsAsFactors = FALSE
    )
  )
  result <- plan_review_goal_target_ids(db, plan, no_goals)
  expect_equal(result$target_id, c(501L, -2L))
})

test_that("plan_review_goal_target_ids falls back to the live table when there is no goals draft at all", {
  plan <- data.frame(plan_id = 501L, plan_status = "Published", stringsAsFactors = FALSE)
  goals <- data.frame(agency_goal_id = c(10L, 11L), sort_order = c(1L, 2L), stringsAsFactors = FALSE)
  db <- list(planning_plan_section_draft = data.frame(plan_id = integer(0), section_key = character(0), payload = character(0), stringsAsFactors = FALSE))
  result <- plan_review_goal_target_ids(db, plan, goals)
  expect_equal(result$target_id, c(10L, 11L))
})
