library(DBI)

source("R/database.R")

con <- connect_app_database()
on.exit(dbDisconnect(con), add = TRUE)

next_id <- function(table, column) {
  as.integer(dbGetQuery(con, sprintf("SELECT COALESCE(MAX(%s), 0) + 1 AS next_id FROM %s", column, table))$next_id[[1]])
}

insert_returning_id <- function(sql, params, id_column) {
  dbGetQuery(con, interpolate_dollar_params(sql, params))[[id_column]][[1]]
}

exec <- function(sql, params = list()) {
  dbExecute(con, interpolate_dollar_params(sql, params))
}

interpolate_dollar_params <- function(sql, params = list()) {
  if (!length(params)) return(sql)
  for (i in rev(seq_along(params))) {
    value <- params[[i]]
    quoted <- if (length(value) == 0 || is.null(value) || (length(value) == 1 && is.na(value))) {
      "NULL"
    } else {
      as.character(DBI::dbQuoteLiteral(con, value))
    }
    sql <- gsub(paste0("\\$", i, "(?![0-9])"), quoted, sql, perl = TRUE)
  }
  sql
}

measure_status <- function(validated) {
  if (isTRUE(validated)) "Validated" else "Draft"
}

insert_measure <- function(plan_def, measure_def, index, cycle_id, reporter_id) {
  measure_id <- next_id("performance.performance_measure", "measure_id")
  exec(
    paste(
      "INSERT INTO performance.performance_measure",
      "(measure_id, agency_id, initial_cycle, title, measure_type, description, data_source, data_owner, data_owner_role,",
      "update_frequency, formula, desired_direction, baseline_value, baseline_fy, format_type, display_unit, context_required,",
      "replicability, disaggregation, data_location, collection_method, how_data_used, why_meaningful, proxy_measure, improvement_notes,",
      "change_mapping, pillar_id, pillar_goal_id, is_city, is_agency, is_service, active, validated, approval_status, submitted_for_approval_at,",
      "created_date, last_updated, created_at, updated_at, modified_by, cycle_id, target_value)",
      "VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25,",
      "$26,$27,$28,$29,$30,$31,$32,$33,$34,$35,CURRENT_DATE,now(),now(),now(),$36,$37,$38)"
    ),
    list(
      measure_id,
      plan_def$agency_id,
      cycle_id,
      measure_def$title,
      measure_def$type,
      measure_def$description,
      "TEST spreadsheet of delight and mild chaos",
      "Pat Placeholder",
      "Performance Lead",
      "Quarterly",
      measure_def$formula,
      measure_def$direction,
      measure_def$baseline,
      2022L,
      measure_def$format,
      measure_def$unit,
      "This TEST measure exists to make review/export hierarchy visible.",
      TRUE,
      "Not yet disaggregated; the tiny parade committee is thinking about it.",
      "Shared drive / TEST dashboard",
      "Collected by a pretend clipboard, then reconciled by vibes and a pivot table.",
      "Used to decide whether the TEST plan is delightful enough for reviewers.",
      "It demonstrates whether the plan is making a resident-facing difference.",
      NA_character_,
      "Reviewer should verify source ownership before production use.",
      NA_character_,
      NA_integer_,
      NA_integer_,
      FALSE,
      index == 1L,
      TRUE,
      TRUE,
      isTRUE(measure_def$validated),
      measure_status(measure_def$validated),
      if (isTRUE(measure_def$validated)) NA else Sys.time(),
      reporter_id,
      cycle_id,
      measure_def$target_2027
    )
  )

  for (fy in 2022:2028) {
    actual <- if (fy <= 2026) measure_def$actuals[[as.character(fy)]] else NA_real_
    target <- measure_def$targets[[as.character(fy)]]
    exec(
      paste(
        "INSERT INTO performance.measure_actuals",
        "(actual_id, measure_id, fiscal_year, annual_actual, annual_actual_notes, target_value, target_value_notes, reported_by, notes, modified_by)",
        "VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$8)"
      ),
      list(
        next_id("performance.measure_actuals", "actual_id"),
        measure_id,
        fy,
        actual,
        if (is.na(actual)) NA_character_ else "TEST actual for export review.",
        target,
        if (is.na(target)) NA_character_ else "TEST target for export review.",
        reporter_id,
        "TEST data row."
      )
    )
  }

  exec(
    paste(
      "INSERT INTO performance.pm_service_link",
      "(link_id, measure_id, service_id, is_primary, modified_by)",
      "VALUES ($1,$2,$3,true,$4)"
    ),
    list(next_id("performance.pm_service_link", "link_id"), measure_id, plan_def$service_id, reporter_id)
  )
  exec(
    paste(
      "INSERT INTO performance.measure_entity_link",
      "(link_id, measure_id, agency_id, service_id, entity_type, entity_id, public_name, source_old_measure_id, modified_by)",
      "VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)"
    ),
    list(
      next_id("performance.measure_entity_link", "link_id"),
      measure_id,
      plan_def$agency_id,
      plan_def$service_id,
      plan_def$entity_type,
      if (is.na(plan_def$entity_id)) NA_integer_ else plan_def$entity_id,
      plan_def$name,
      paste0("TEST-OLD-", plan_def$plan_id, "-", index),
      reporter_id
    )
  )
  measure_id
}

score_rows <- function(review_id, target_type, target_id, section_code, criteria, scores, note_prefix, modified_by) {
  for (i in seq_along(criteria)) {
    criterion_code <- names(criteria)[[i]]
    weight <- unname(criteria[[i]])
    score <- scores[[i]]
    exec(
      paste(
        "INSERT INTO review.section_score",
        "(score_id, review_id, section_code, criterion_code, target_type, target_id, score, weight, weighted_score, justification, modified_by)",
        "VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)"
      ),
      list(
        next_id("review.section_score", "score_id"),
        review_id,
        section_code,
        criterion_code,
        target_type,
        if (is.na(target_id)) NA_integer_ else as.integer(target_id),
        as.integer(score),
        weight,
        weight * score / 4,
        paste(note_prefix, "-", criterion_code, "score", score, "with reviewer notes for TEST export hierarchy."),
        modified_by
      )
    )
  }
}

test_plans <- list(
  list(
    plan_id = 142L,
    agency_id = "TST9001",
    entity_id = NA_integer_,
    entity_type = "service",
    name = "TEST Agency of Sparkly Sidewalks",
    service_id = "TST001",
    service_description = "This TEST service buffs civic sidewalks until they gleam with cheerful accountability. Staff coordinate sparkle checks, resident delight dispatches, and very serious glitter containment procedures.",
    overview = "The TEST Agency of Sparkly Sidewalks exists to prove that resident-facing outcomes can be both measurable and mildly ridiculous. It serves pedestrians, reviewers, and anyone who has ever wanted a crosswalk to wink back.",
    vision = "Baltimore has sidewalks so clear, safe, and dazzling that residents can see both their destination and the performance logic that got them there.",
    web = "https://example.baltimorecity.gov/test-sparkly-sidewalks"
  ),
  list(
    plan_id = 143L,
    agency_id = "TST9002",
    entity_id = 31L,
    entity_type = "quasi agency",
    name = "TEST Quasi Bureau of Waffle Forecasting",
    service_id = "TST002",
    service_description = "This TEST service predicts breakfast-adjacent demand signals and translates syrup volatility into practical management actions. The team maintains griddle readiness, flavor equity, and crispy-edge reporting.",
    overview = "The TEST Quasi Bureau of Waffle Forecasting exists to help residents experience a future with fewer surprise breakfast shortages. It turns community appetite signals into decisions that are warm, square, and accountable.",
    vision = "Baltimore residents can count on timely, equitable waffle intelligence that makes every planning cycle feel slightly more golden brown.",
    web = "https://example.baltimorecity.gov/test-waffle-forecasting"
  ),
  list(
    plan_id = 144L,
    agency_id = "TST9003",
    entity_id = 32L,
    entity_type = "mayoral service",
    name = "TEST Mayor's Office of Tiny Triumphs",
    service_id = "TST003",
    service_description = "This TEST service catalogs small wins, celebrates implementation progress, and makes sure tiny triumphs do not get lost behind larger dashboards. Activities include confetti calibration and practical follow-through.",
    overview = "The TEST Mayor's Office of Tiny Triumphs exists to make incremental public-sector wins visible, durable, and useful. It serves teams doing hard work by turning small improvements into repeatable operating habits.",
    vision = "Baltimore city government recognizes, scales, and learns from tiny triumphs until they become ordinary excellence.",
    web = "https://example.baltimorecity.gov/test-tiny-triumphs"
  )
)

goals <- list(
  "Increase resident delight by 12 percent by June 2027 through one very specific and measurable burst of operational joy.",
  "Reduce preventable spreadsheet sighs by 15 percent by June 2027 while keeping every required field politely accounted for.",
  "Improve cross-team handoff confidence by 20 percent by June 2027 so no good idea has to wander the halls alone."
)

initiatives <- list(
  "Launch a tiny but disciplined pilot with named owners, monthly check-ins, and a celebratory checklist.",
  "Publish a field guide that explains the workflow in plain language and includes exactly one tasteful sparkle.",
  "Run quarterly problem-solving huddles where blockers are named, assigned, and gently escorted out."
)

measure_templates <- list(
  list(
    suffix = "Resident Delight Index",
    type = "Outcome",
    direction = "Increase",
    format = "Percent",
    unit = "%",
    validated = TRUE,
    baseline = 61,
    target_2027 = 78,
    formula = "Residents reporting delight divided by residents surveyed, multiplied by 100.",
    actuals = c("2022" = 55, "2023" = 58, "2024" = 61, "2025" = 66, "2026" = 70),
    targets = c("2022" = 56, "2023" = 60, "2024" = 64, "2025" = 68, "2026" = 72, "2027" = 78, "2028" = 82)
  ),
  list(
    suffix = "Clipboard-to-Confetti Cycle Time",
    type = "Efficiency",
    direction = "Decrease",
    format = "Count",
    unit = "days",
    validated = FALSE,
    baseline = 18,
    target_2027 = 10,
    formula = "Average calendar days from intake to celebratory closeout.",
    actuals = c("2022" = 22, "2023" = 20, "2024" = 18, "2025" = 17, "2026" = 14),
    targets = c("2022" = 21, "2023" = 19, "2024" = 17, "2025" = 15, "2026" = 12, "2027" = 10, "2028" = 9)
  ),
  list(
    suffix = "Tiny Win Follow-Through Rate",
    type = "Effectiveness",
    direction = "Increase",
    format = "Percent",
    unit = "%",
    validated = TRUE,
    baseline = 48,
    target_2027 = 74,
    formula = "Tiny wins completed divided by tiny wins committed, multiplied by 100.",
    actuals = c("2022" = 42, "2023" = 46, "2024" = 48, "2025" = 57, "2026" = 64),
    targets = c("2022" = 45, "2023" = 48, "2024" = 52, "2025" = 60, "2026" = 68, "2027" = 74, "2028" = 80)
  )
)

overview_criteria <- c(OVERVIEW = 5, VISION = 5)
goal_criteria <- c(GOALQUAL = 10, PILLAR = 7, INITCOH = 8, INITCON = 7, KPIQUAL = 10, KPIDFN = 10, KPITGT = 10)
service_criteria <- c(METQUAL = 5, METDFN = 5, METTGT = 5)
family_criteria <- c(FAMMEAS = 5)
risk_criteria <- c(RISK = 5)
data_criteria <- c(DATAREADY = 10)

cycle_id <- dbGetQuery(con, "SELECT cycle_id FROM planning.plan_cycle WHERE fiscal_year = 2027 ORDER BY cycle_id LIMIT 1")$cycle_id[[1]]
reviewer_id <- 293L

dbWithTransaction(con, {
  cat("Cleaning existing TEST rows...\n")
  test_plan_ids <- vapply(test_plans, `[[`, integer(1), "plan_id")
  test_agencies <- vapply(test_plans, `[[`, character(1), "agency_id")
  test_service_ids <- vapply(test_plans, `[[`, character(1), "service_id")

  goal_ids <- dbGetQuery(con, paste0("SELECT agency_goal_id FROM performance.agency_goal WHERE plan_id IN (", paste(test_plan_ids, collapse = ","), ")"))$agency_goal_id
  initiative_ids <- if (length(goal_ids)) {
    dbGetQuery(con, paste0("SELECT initiative_id FROM performance.agency_goal_initiative_link WHERE agency_goal_id IN (", paste(goal_ids, collapse = ","), ")"))$initiative_id
  } else integer(0)
  review_ids <- dbGetQuery(con, paste0("SELECT review_id FROM review.plan_review WHERE plan_id IN (", paste(test_plan_ids, collapse = ","), ")"))$review_id
  measure_ids <- dbGetQuery(
    con,
    paste0(
      "SELECT measure_id FROM performance.performance_measure WHERE agency_id IN ('",
      paste(test_agencies, collapse = "','"),
      "') OR title LIKE 'TEST - %'"
    )
  )$measure_id

  if (length(review_ids)) {
    dbExecute(con, paste0("DELETE FROM review.section_score WHERE review_id IN (", paste(review_ids, collapse = ","), ")"))
    dbExecute(con, paste0("DELETE FROM review.section_feedback WHERE review_id IN (", paste(review_ids, collapse = ","), ")"))
    dbExecute(con, paste0("DELETE FROM review.plan_review WHERE review_id IN (", paste(review_ids, collapse = ","), ")"))
  }
  if (length(measure_ids)) {
    dbExecute(con, paste0("DELETE FROM performance.measure_entity_link WHERE measure_id IN (", paste(measure_ids, collapse = ","), ")"))
    dbExecute(con, paste0("DELETE FROM performance.pm_goal_link WHERE measure_id IN (", paste(measure_ids, collapse = ","), ")"))
    dbExecute(con, paste0("DELETE FROM performance.pm_service_link WHERE measure_id IN (", paste(measure_ids, collapse = ","), ")"))
    dbExecute(con, paste0("DELETE FROM performance.measure_actuals WHERE measure_id IN (", paste(measure_ids, collapse = ","), ")"))
    dbExecute(con, paste0("DELETE FROM performance.performance_measure WHERE measure_id IN (", paste(measure_ids, collapse = ","), ")"))
  }
  if (length(goal_ids)) {
    dbExecute(con, paste0("DELETE FROM performance.agency_goal_pillar_link WHERE agency_goal_id IN (", paste(goal_ids, collapse = ","), ")"))
    dbExecute(con, paste0("DELETE FROM performance.agency_goal_initiative_link WHERE agency_goal_id IN (", paste(goal_ids, collapse = ","), ")"))
    dbExecute(con, paste0("DELETE FROM performance.agency_goal WHERE agency_goal_id IN (", paste(goal_ids, collapse = ","), ")"))
  }
  if (length(initiative_ids)) {
    dbExecute(con, paste0("DELETE FROM performance.initiative WHERE initiative_id IN (", paste(unique(initiative_ids), collapse = ","), ")"))
  }
  dbExecute(con, paste0("DELETE FROM performance.service_risk WHERE plan_id IN (", paste(test_plan_ids, collapse = ","), ")"))
  dbExecute(con, paste0("DELETE FROM performance.overview_vision WHERE plan_id IN (", paste(test_plan_ids, collapse = ","), ")"))

  for (plan_def in test_plans) {
    cat("Seeding", plan_def$name, "\n")
    exec(
      "UPDATE reference.service SET service_description=$2, active=true, updated_at=now(), modified_by=$3 WHERE service_id=$1",
      list(plan_def$service_id, plan_def$service_description, reviewer_id)
    )
    exec(
      "UPDATE planning.agency_plan SET plan_status='UnderReview', assigned_reviewer=$2, updated_at=now(), modified_by=$2 WHERE plan_id=$1",
      list(plan_def$plan_id, reviewer_id)
    )
    exec(
      paste(
        "INSERT INTO performance.overview_vision",
        "(mv_id, plan_id, overview, vision, web_address, modified_by)",
        "VALUES ($1,$2,$3,$4,$5,$6)"
      ),
      list(next_id("performance.overview_vision", "mv_id"), plan_def$plan_id, plan_def$overview, plan_def$vision, plan_def$web, reviewer_id)
    )

    measure_ids_for_plan <- integer(0)
    for (j in seq_along(measure_templates)) {
      cat("  measure", j, "\n")
      measure_def <- measure_templates[[j]]
      measure_def$title <- paste("TEST -", plan_def$name, measure_def$suffix)
      measure_def$description <- paste("TEST measure for", plan_def$name, "tracking", tolower(measure_def$suffix), "with enough detail for reviewer scoring.")
      measure_ids_for_plan[[j]] <- insert_measure(plan_def, measure_def, j, cycle_id, reviewer_id)
    }

    goal_ids_for_plan <- integer(0)
    for (j in seq_along(goals)) {
      cat("  goal", j, "\n")
      goal_id <- insert_returning_id(
        paste(
          "INSERT INTO performance.agency_goal",
          "(agency_goal_id, plan_id, title, description, sort_order, modified_by)",
          "VALUES ($1,$2,$3,$4,$5,$6) RETURNING agency_goal_id"
        ),
        list(next_id("performance.agency_goal", "agency_goal_id"), plan_def$plan_id, goals[[j]], "TEST goal description for review export.", j, reviewer_id),
        "agency_goal_id"
      )
      goal_ids_for_plan[[j]] <- goal_id
      initiative_id <- insert_returning_id(
        paste(
          "INSERT INTO performance.initiative",
          "(initiative_id, title, description, start_date, end_date, status, modified_by)",
          "VALUES ($1,$2,$3,'2026-07-01','2027-06-30','Planned',$4) RETURNING initiative_id"
        ),
        list(next_id("performance.initiative", "initiative_id"), initiatives[[j]], "TEST initiative description with ownership, timeline, and a tiny drumroll.", reviewer_id),
        "initiative_id"
      )
      exec(
        paste(
          "INSERT INTO performance.agency_goal_initiative_link",
          "(link_id, agency_goal_id, initiative_id, link_type, modified_by)",
          "VALUES ($1,$2,$3,'Primary',$4)"
        ),
        list(next_id("performance.agency_goal_initiative_link", "link_id"), goal_id, initiative_id, reviewer_id)
      )
      exec(
        paste(
          "INSERT INTO performance.pm_goal_link",
          "(link_id, measure_id, agency_goal_id, is_agency_level, modified_by)",
          "VALUES ($1,$2,$3,true,$4)"
        ),
        list(next_id("performance.pm_goal_link", "link_id"), measure_ids_for_plan[[j]], goal_id, reviewer_id)
      )
      if (j == 1L) {
        exec(
          paste(
            "INSERT INTO performance.agency_goal_pillar_link",
            "(link_id, agency_goal_id, pillar_goal_id, link_type, alignment_narrative, modified_by)",
            "VALUES ($1,$2,$3,'Primary',$4,$5)"
          ),
          list(
            next_id("performance.agency_goal_pillar_link", "link_id"),
            goal_id,
            13L,
            "TEST alignment narrative: this goal connects operational follow-through to responsible stewardship of City resources.",
            reviewer_id
          )
        )
      }
    }

    exec(
      paste(
        "INSERT INTO performance.service_risk",
        "(risk_id, plan_id, plan_service_id, risk_type, description, cross_agency_inputs, it_dependencies, external_concerns, legislation_effects, modified_by)",
        "VALUES ($1,$2,(SELECT plan_service_id FROM performance.plan_service WHERE plan_id=$2 AND service_id=$3 LIMIT 1),$4,$5,$6,$7,$8,$9,$10)"
      ),
      list(
        next_id("performance.service_risk", "risk_id"),
        plan_def$plan_id,
        plan_def$service_id,
        "technology",
        "TEST risk: the dashboard confetti cannon may fire during a serious budget meeting unless change controls are followed.",
        "Requires coordination with imaginary sparkle stewards.",
        "Depends on the pretend metrics dashboard staying awake.",
        "External snack shortages could reduce meeting morale.",
        "No legislation expected, but the tiny parade permit remains spiritually important.",
        reviewer_id
      )
    )

    review_id <- insert_returning_id(
      paste(
        "INSERT INTO review.plan_review",
        "(review_id, plan_id, reviewer_id, review_started_at, feedback_released_at, overall_score, internal_notes, review_complete, modified_by)",
        "VALUES ($1,$2,$3,now(),now(),$4,$5,false,$3) RETURNING review_id"
      ),
      list(
        next_id("review.plan_review", "review_id"),
        plan_def$plan_id,
        reviewer_id,
        84,
        "TEST review notes: strong structure, delightful placeholder voice, and one not-validated measure intentionally left for visual warning."
      ),
      "review_id"
    )

    score_rows(review_id, "plan", NA_integer_, "S1", overview_criteria, c(3, 4), "Overview and vision", reviewer_id)
    for (j in seq_along(goal_ids_for_plan)) {
      score_rows(review_id, "goal", goal_ids_for_plan[[j]], "S2", goal_criteria, c(4, if (j == 1L) 4 else 2, 3, 4, 3, 3, 3), paste("Goal", j), reviewer_id)
    }
    plan_service_id <- dbGetQuery(
      con,
      interpolate_dollar_params(
        "SELECT plan_service_id FROM performance.plan_service WHERE plan_id=$1 AND service_id=$2 LIMIT 1",
        list(plan_def$plan_id, plan_def$service_id)
      )
    )$plan_service_id[[1]]
    score_rows(review_id, "service", plan_service_id, "S3", service_criteria, c(3, 3, 4), "Service metrics", reviewer_id)
    score_rows(review_id, "plan", NA_integer_, "S3", family_criteria, c(3), "Family of measures", reviewer_id)
    score_rows(review_id, "plan", NA_integer_, "S5", risk_criteria, c(4), "Risks", reviewer_id)
    score_rows(review_id, "plan", NA_integer_, "S6", data_criteria, c(3), "Data readiness", reviewer_id)

    for (feedback in c(
      "Top improvement: replace the intentionally not-validated TEST metric before final approval.",
      "Add a clearer owner for the quarterly data quality check.",
      "The placeholder tone is charming, but production language should be less sparkly."
    )) {
      exec(
        paste(
          "INSERT INTO review.section_feedback",
          "(feedback_id, review_id, section_code, feedback_text, return_required, modified_by)",
          "VALUES ($1,$2,'Goals',$3,true,$4)"
        ),
        list(next_id("review.section_feedback", "feedback_id"), review_id, feedback, reviewer_id)
      )
    }
  }
})

cat("Seeded enriched TEST plans with goals, services, measures, risks, and review scores.\n")
