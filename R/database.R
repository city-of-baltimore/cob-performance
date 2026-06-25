load_env_file <- function(path = ".env") {
  if (!file.exists(path)) return(invisible(FALSE))
  lines <- readLines(path, warn = FALSE)
  for (line in lines) {
    line <- trimws(line)
    if (!nzchar(line) || startsWith(line, "#") || !grepl("=", line, fixed = TRUE)) next
    parts <- strsplit(line, "=", fixed = TRUE)[[1]]
    key <- trimws(parts[[1]])
    value <- trimws(paste(parts[-1], collapse = "="))
    value <- sub("^['\"]", "", sub("['\"]$", "", value))
    if (!nzchar(Sys.getenv(key))) do.call(Sys.setenv, stats::setNames(list(value), key))
  }
  invisible(TRUE)
}

connect_app_database <- function() {
  load_env_file()
  database_url <- Sys.getenv("DATABASE_URL")
  if (!nzchar(database_url)) stop("DATABASE_URL is not configured")
  match <- regexec(
    "^postgres(?:ql)?://([^:]+):([^@]+)@([^:/]+)(?::([0-9]+))?/([^?]+)",
    database_url,
    perl = TRUE
  )
  parts <- regmatches(database_url, match)[[1]]
  if (length(parts) != 6) stop("DATABASE_URL has an unsupported format")
  DBI::dbConnect(
    RPostgres::Postgres(),
    user = utils::URLdecode(parts[[2]]),
    password = utils::URLdecode(parts[[3]]),
    host = parts[[4]],
    port = as.integer(if (nzchar(parts[[5]])) parts[[5]] else "5432"),
    dbname = utils::URLdecode(parts[[6]])
  )
}

load_app_data <- function(connection) {
  query <- function(sql) DBI::dbGetQuery(connection, sql)
  data <- list(
    reference_agency = query(
      "SELECT agency_id, agency_name, deputy_mayor_pillar FROM reference.agency WHERE active ORDER BY agency_name"
    ),
    reference_pillar = query(
      "SELECT pillar_id, pillar_name, pillar_lead, pillar_lead_name, summary, overview, sort_order FROM reference.pillar ORDER BY sort_order"
    ),
    reference_pillar_goal = query(
      paste(
        "SELECT pg.pillar_goal_id, pg.pillar_id, pg.goal_code, pg.goal_title, pg.goal_lead, pg.sort_order",
        "FROM reference.pillar_goal pg JOIN reference.pillar p ON p.pillar_id = pg.pillar_id",
        "ORDER BY p.sort_order, pg.sort_order"
      )
    ),
    planning_agency_plan = query(
      paste(
        "SELECT ap.plan_id, ap.agency_id, ap.cycle_id, pc.fiscal_year, ap.plan_status, ap.budget_status, ap.version,",
        "ap.submitted_at, ap.updated_at",
        "FROM planning.agency_plan ap JOIN planning.plan_cycle pc ON pc.cycle_id = ap.cycle_id",
        "WHERE ap.agency_id IS NOT NULL ORDER BY pc.fiscal_year DESC"
      )
    ),
    performance_plan_header = query(
      "SELECT plan_id, primary_contact_name, primary_contact_email, version_label FROM performance.plan_header"
    ),
    performance_overview_vision = query(
      "SELECT plan_id, overview, vision, web_address FROM performance.overview_vision"
    ),
    reference_service = query(
      paste(
        "SELECT service_id, agency_id, pillar_id, service_name, service_type, service_description",
        "FROM reference.service WHERE active ORDER BY agency_id, service_name"
      )
    ),
    performance_plan_service = query(
      "SELECT plan_service_id, plan_id, service_id, sort_order FROM performance.plan_service"
    ),
    reference_plan_entity = query(
      "SELECT entity_id, parent_agency_id, public_name, entity_type, has_own_plan, active FROM reference.plan_entity WHERE active ORDER BY public_name"
    ),
    reference_plan_entity_service = query(
      "SELECT pes_id, entity_id, service_id, is_primary FROM reference.plan_entity_service ORDER BY pes_id"
    ),
    performance_agency_goal = query(
      paste(
        "SELECT ag.agency_goal_id, ag.plan_id, ag.title, ag.description, ag.sort_order,",
        "COALESCE(alignment.goal_code, '') AS alignment_code,",
        "COALESCE(alignment.goal_label, '') AS alignment",
        "FROM performance.agency_goal ag",
        "LEFT JOIN LATERAL (",
        "SELECT pg.goal_code, pg.goal_code || ' ' || pg.goal_title AS goal_label",
        "FROM performance.agency_goal_pillar_link link",
        "JOIN reference.pillar_goal pg ON pg.pillar_goal_id = link.pillar_goal_id",
        "WHERE link.agency_goal_id = ag.agency_goal_id",
        "ORDER BY CASE WHEN link.link_type = 'Primary' THEN 0 ELSE 1 END, link.link_id LIMIT 1",
        ") alignment ON TRUE",
        "ORDER BY ag.plan_id, ag.sort_order"
      )
    ),
    performance_initiative = query(
      "SELECT initiative_id, title FROM performance.initiative ORDER BY initiative_id"
    ),
    performance_agency_goal_initiative_link = query(
      "SELECT agency_goal_id, initiative_id FROM performance.agency_goal_initiative_link"
    ),
    performance_pm_goal_link = query(
      "SELECT agency_goal_id, measure_id FROM performance.pm_goal_link"
    ),
    performance_pm_service_link = query(
      "SELECT service_id, measure_id FROM performance.pm_service_link ORDER BY service_id, measure_id"
    ),
    performance_performance_measure = query(
      paste(
        "SELECT measure_id, agency_id, initial_cycle, title, measure_type, description, data_source, data_owner, data_owner_role,",
        "update_frequency, formula, desired_direction, baseline_value, baseline_fy, format_type, display_unit, context_required,",
        "replicability, disaggregation, data_location, collection_method, how_data_used, why_meaningful, proxy_measure, improvement_notes,",
        "change_mapping, pillar_id, pillar_goal_id, is_city, is_agency, is_service, active, validated, approval_status, submitted_for_approval_at,",
        "created_date, last_updated",
        "FROM performance.performance_measure ORDER BY agency_id, title"
      )
    ),
    performance_measure_actuals = query(
      "SELECT measure_id, fiscal_year, annual_actual, annual_actual_notes, target_value, target_value_notes FROM performance.measure_actuals ORDER BY measure_id, fiscal_year"
    ),
    performance_service_risk = query(
      "SELECT risk_id, plan_id, description FROM performance.service_risk ORDER BY plan_id, risk_id"
    ),
    review_plan_review = query(
      paste(
        "SELECT pr.review_id, pr.plan_id, pr.reviewer_id, u.full_name AS reviewer_name,",
        "pr.review_started_at, pr.feedback_released_at, pr.overall_score, pr.internal_notes, pr.review_complete",
        "FROM review.plan_review pr JOIN access.\"user\" u ON u.user_id = pr.reviewer_id",
        "ORDER BY pr.review_started_at DESC NULLS LAST, pr.review_id DESC"
      )
    ),
    review_section_score = query(
      "SELECT score_id, review_id, section_code, criterion_code, score, weight, weighted_score, justification FROM review.section_score ORDER BY review_id, section_code, criterion_code"
    ),
    review_section_feedback = query(
      "SELECT feedback_id, review_id, section_code, feedback_text, return_required, resolved_at FROM review.section_feedback ORDER BY review_id, section_code, feedback_id"
    ),
    workflow_plan_status_history = query(
      paste(
        "SELECT psh.history_id, psh.plan_id, psh.changed_by, u.full_name AS changed_by_name,",
        "psh.from_status, psh.to_status, psh.plan_phase, psh.changed_at, psh.notes",
        "FROM workflow.plan_status_history psh JOIN access.\"user\" u ON u.user_id = psh.changed_by",
        "ORDER BY psh.plan_id, psh.changed_at"
      )
    ),
    planning_plan_section_draft = query(
      "SELECT draft_id, plan_id, section_key, payload::text AS payload, revision, updated_by, updated_at AT TIME ZONE 'America/New_York' AS updated_at FROM planning.plan_section_draft ORDER BY plan_id, section_key"
    ),
    access_user_agency_access = query(
      paste(
        "SELECT u.user_id, uaa.agency_id, u.full_name, u.email, uaa.agency_role",
        "FROM access.user_agency_access uaa JOIN access.\"user\" u ON u.user_id = uaa.user_id",
        "WHERE u.active ORDER BY uaa.agency_id, u.full_name"
      )
    ),
    access_user_role = query(
      paste(
        "SELECT ur.user_role_id, ur.user_id, ur.app_role, ur.agency_id, ur.pillar_id, u.full_name, u.email",
        "FROM access.user_role ur JOIN access.\"user\" u ON u.user_id = ur.user_id",
        "WHERE u.active ORDER BY ur.agency_id, ur.app_role, u.full_name"
      )
    )
  )

  action_plan_initiatives <- query(
    "SELECT pillar_goal_id, initiative_title, sort_order FROM reference.action_plan_initiative ORDER BY pillar_goal_id, sort_order"
  )
  action_plan_measures <- query(
    paste(
      "SELECT pillar_id, measure_name, desired_direction, display_unit, baseline_value, current_value, target_value, sort_order",
      "FROM reference.action_plan_measure ORDER BY pillar_id, sort_order"
    )
  )
  data$strategic_plan <- lapply(seq_len(nrow(data$reference_pillar)), function(index) {
    pillar <- data$reference_pillar[index, , drop = FALSE]
    pillar_goals <- data$reference_pillar_goal[data$reference_pillar_goal$pillar_id == pillar$pillar_id, , drop = FALSE]
    goals <- lapply(seq_len(nrow(pillar_goals)), function(goal_index) {
      goal <- pillar_goals[goal_index, , drop = FALSE]
      initiatives <- action_plan_initiatives$initiative_title[action_plan_initiatives$pillar_goal_id == goal$pillar_goal_id]
      list(code = goal$goal_code[[1]], title = goal$goal_title[[1]], lead = goal$goal_lead[[1]], initiatives = initiatives)
    })
    pillar_measures <- action_plan_measures[action_plan_measures$pillar_id == pillar$pillar_id, , drop = FALSE]
    metrics <- lapply(seq_len(nrow(pillar_measures)), function(measure_index) {
      measure <- pillar_measures[measure_index, , drop = FALSE]
      list(
        name = measure$measure_name[[1]],
        baseline = as.numeric(measure$baseline_value[[1]]),
        current = as.numeric(measure$current_value[[1]]),
        target = as.numeric(measure$target_value[[1]]),
        direction = measure$desired_direction[[1]],
        unit = if (is.na(measure$display_unit[[1]])) NULL else measure$display_unit[[1]]
      )
    })
    list(
      id = pillar$pillar_id[[1]],
      title = pillar$pillar_name[[1]],
      lead = pillar$pillar_lead[[1]],
      lead_name = pillar$pillar_lead_name[[1]],
      summary = pillar$summary[[1]],
      overview = pillar$overview[[1]],
      goals = goals,
      metrics = metrics
    )
  })
  data
}

save_measure_record <- function(connection, values, yearly_values, reported_by, submit = FALSE) {
  DBI::dbWithTransaction(connection, {
    status <- if (submit) {
      "PendingApproval"
    } else if (!is.null(values$measure_id) && values$approval_status %in% c("Validated", "PendingApproval")) {
      "Draft"
    } else {
      values$approval_status
    }
    submitted_at <- if (submit) {
      Sys.time()
    } else if (!is.null(values$measure_id) && values$approval_status %in% c("Validated", "PendingApproval")) {
      as.POSIXct(NA)
    } else {
      values$submitted_for_approval_at
    }
    params <- list(
      values$agency_id, values$initial_cycle, values$title, values$measure_type, values$description,
      values$data_source, values$data_owner, values$data_owner_role, values$update_frequency, values$formula,
      values$desired_direction, values$baseline_value, values$baseline_fy, values$format_type, values$display_unit,
      values$context_required, values$replicability, values$disaggregation, values$data_location, values$collection_method,
      values$how_data_used, values$why_meaningful, values$proxy_measure, values$improvement_notes, values$change_mapping,
      values$pillar_id, values$pillar_goal_id, values$is_city, values$is_agency, values$is_service, status, submitted_at
    )
    if (is.null(values$measure_id)) {
      row <- DBI::dbGetQuery(
        connection,
        paste(
          "INSERT INTO performance.performance_measure (agency_id, initial_cycle, title, measure_type, description, data_source, data_owner,",
          "data_owner_role, update_frequency, formula, desired_direction, baseline_value, baseline_fy, format_type, display_unit, context_required,",
          "replicability, disaggregation, data_location, collection_method, how_data_used, why_meaningful, proxy_measure, improvement_notes,",
          "change_mapping, pillar_id, pillar_goal_id, is_city, is_agency, is_service, approval_status, submitted_for_approval_at)",
          "VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25,$26,$27,$28,$29,$30,$31::varchar(30),$32::timestamptz)",
          "RETURNING measure_id"
        ),
        params = params
      )
      measure_id <- row$measure_id[[1]]
    } else {
      measure_id <- as.integer(values$measure_id)
      DBI::dbExecute(
        connection,
        paste(
          "UPDATE performance.performance_measure SET initial_cycle=$2, title=$3, measure_type=$4, description=$5, data_source=$6, data_owner=$7,",
          "data_owner_role=$8, update_frequency=$9, formula=$10, desired_direction=$11, baseline_value=$12, baseline_fy=$13,",
          "format_type=$14, display_unit=$15, context_required=$16, replicability=$17, disaggregation=$18, data_location=$19,",
          "collection_method=$20, how_data_used=$21, why_meaningful=$22, proxy_measure=$23, improvement_notes=$24, change_mapping=$25,",
          "pillar_id=$26, pillar_goal_id=$27, is_city=$28, is_agency=$29, is_service=$30, approval_status=$31::varchar(30),",
          "submitted_for_approval_at=$32::timestamptz, validated=CASE WHEN $31::text='Validated' THEN true ELSE false END, last_updated=now()",
          "WHERE measure_id=$33 AND agency_id=$1"
        ),
        params = c(params, list(measure_id))
      )
    }
    for (year_value in yearly_values) {
      DBI::dbExecute(
        connection,
        paste(
          "INSERT INTO performance.measure_actuals (measure_id, fiscal_year, annual_actual, annual_actual_notes, target_value, target_value_notes, reported_by)",
          "VALUES ($1,$2,$3,$4,$5,$6,$7)",
          "ON CONFLICT (measure_id, fiscal_year) DO UPDATE SET annual_actual=EXCLUDED.annual_actual,",
          "annual_actual_notes=EXCLUDED.annual_actual_notes, target_value=EXCLUDED.target_value,",
          "target_value_notes=EXCLUDED.target_value_notes, reported_by=EXCLUDED.reported_by, updated_at=now()"
        ),
        params = list(measure_id, year_value$fiscal_year, year_value$annual_actual, year_value$annual_actual_notes, year_value$target_value, year_value$target_value_notes, reported_by)
      )
    }
    measure_id
  })
}

set_measure_active <- function(connection, measure_id, agency_id, active) {
  status_sql <- if (isTRUE(active)) {
    ", approval_status = CASE WHEN approval_status = 'Validated' THEN 'PendingApproval' ELSE approval_status END, validated = false, submitted_for_approval_at = CASE WHEN approval_status = 'Validated' THEN now() ELSE submitted_for_approval_at END"
  } else {
    ""
  }
  changed <- DBI::dbExecute(
    connection,
    paste0("UPDATE performance.performance_measure SET active=$3", status_sql, ", last_updated=now() WHERE measure_id=$1 AND agency_id=$2"),
    params = list(as.integer(measure_id), agency_id, isTRUE(active))
  )
  if (changed != 1) stop("Measure not found for this agency")
}

save_service_risk <- function(connection, risk_id, plan_id, description) {
  if (is.null(description) || length(description) == 0 || is.na(description)) description <- ""
  description <- trimws(as.character(description))
  if (!nzchar(description)) stop("Risk description is required")
  if (is.null(risk_id) || is.na(risk_id)) {
    row <- DBI::dbGetQuery(
      connection,
      "INSERT INTO performance.service_risk (plan_id, description) VALUES ($1, $2) RETURNING risk_id",
      params = list(as.integer(plan_id), description)
    )
    return(row$risk_id[[1]])
  }
  changed <- DBI::dbExecute(
    connection,
    "UPDATE performance.service_risk SET description=$3 WHERE risk_id=$1 AND plan_id=$2",
    params = list(as.integer(risk_id), as.integer(plan_id), description)
  )
  if (changed != 1) stop("Risk not found for this plan")
  as.integer(risk_id)
}

get_section_draft <- function(connection, plan_id, section_key) {
  rows <- DBI::dbGetQuery(
    connection,
    paste(
      "SELECT draft_id, payload::text AS payload, revision, updated_by,",
      "updated_at AT TIME ZONE 'America/New_York' AS updated_at",
      "FROM planning.plan_section_draft",
      "WHERE plan_id = $1 AND section_key = $2"
    ),
    params = list(as.integer(plan_id), as.character(section_key))
  )
  if (!nrow(rows)) return(NULL)
  rows[1, , drop = FALSE]
}

save_section_draft <- function(connection, plan_id, section_key, payload, expected_revision = 0L, updated_by = NULL) {
  plan_id <- as.integer(plan_id)
  section_key <- as.character(section_key)
  if (is.null(expected_revision) || is.na(expected_revision)) expected_revision <- 0L
  expected_revision <- as.integer(expected_revision)
  updated_by <- if (is.null(updated_by) || is.na(updated_by)) NA_integer_ else as.integer(updated_by)

  if (expected_revision == 0L) {
    saved <- DBI::dbGetQuery(
      connection,
      paste(
        "INSERT INTO planning.plan_section_draft (plan_id, section_key, payload, revision, updated_by)",
        "VALUES ($1, $2, $3::jsonb, 1, $4)",
        "ON CONFLICT (plan_id, section_key) DO NOTHING",
        "RETURNING draft_id, revision, updated_at AT TIME ZONE 'America/New_York' AS updated_at"
      ),
      params = list(plan_id, section_key, payload, updated_by)
    )
  } else {
    saved <- DBI::dbGetQuery(
      connection,
      paste(
        "UPDATE planning.plan_section_draft",
        "SET payload = $3::jsonb, revision = revision + 1, updated_by = $4, updated_at = now()",
        "WHERE plan_id = $1 AND section_key = $2 AND revision = $5",
        "RETURNING draft_id, revision, updated_at AT TIME ZONE 'America/New_York' AS updated_at"
      ),
      params = list(plan_id, section_key, payload, updated_by, expected_revision)
    )
  }

  if (nrow(saved)) return(list(ok = TRUE, row = saved[1, , drop = FALSE]))
  list(ok = FALSE, conflict = get_section_draft(connection, plan_id, section_key))
}

overwrite_section_draft <- function(connection, plan_id, section_key, payload, updated_by = NULL) {
  updated_by <- if (is.null(updated_by) || is.na(updated_by)) NA_integer_ else as.integer(updated_by)
  DBI::dbGetQuery(
    connection,
    paste(
      "INSERT INTO planning.plan_section_draft (plan_id, section_key, payload, revision, updated_by)",
      "VALUES ($1, $2, $3::jsonb, 1, $4)",
      "ON CONFLICT (plan_id, section_key) DO UPDATE SET",
      "payload = EXCLUDED.payload, revision = planning.plan_section_draft.revision + 1,",
      "updated_by = EXCLUDED.updated_by, updated_at = now()",
      "RETURNING draft_id, revision, updated_at AT TIME ZONE 'America/New_York' AS updated_at"
    ),
    params = list(as.integer(plan_id), as.character(section_key), as.character(payload), updated_by)
  )
}

submit_agency_plan <- function(connection, plan_id, submitted_by = NULL) {
  plan_id <- as.integer(plan_id)
  submitted_by <- if (is.null(submitted_by) || is.na(submitted_by)) NA_integer_ else as.integer(submitted_by)
  if (is.na(submitted_by)) {
    users <- DBI::dbGetQuery(connection, "SELECT user_id FROM access.\"user\" ORDER BY user_id LIMIT 1")
    if (!nrow(users)) stop("No user is available to submit this plan.")
    submitted_by <- users$user_id[[1]]
  }
  changed <- DBI::dbGetQuery(
    connection,
    paste(
      "WITH current_plan AS (",
      "SELECT plan_id, plan_status FROM planning.agency_plan",
      "WHERE plan_id = $1 AND plan_status IN ('Draft', 'FeedbackReturned', 'Returned', 'AgencyRevised')",
      "), updated_plan AS (",
      "UPDATE planning.agency_plan ap",
      "SET plan_status = 'Submitted', submitted_at = now(), updated_at = now()",
      "FROM current_plan cp WHERE ap.plan_id = cp.plan_id",
      "RETURNING ap.plan_id, cp.plan_status AS from_status",
      ") SELECT plan_id, from_status FROM updated_plan"
    ),
    params = list(plan_id)
  )
  if (!nrow(changed)) stop("Only editable draft or returned plans can be submitted.")
  DBI::dbExecute(
    connection,
    paste(
      "INSERT INTO workflow.plan_status_history (plan_id, changed_by, from_status, to_status, plan_phase, changed_at, notes)",
      "VALUES ($1, $2, $3, 'Submitted', 'PerformancePlan', now(), 'Submitted from agency workspace prototype.')"
    ),
    params = list(plan_id, submitted_by, changed$from_status[[1]])
  )
  invisible(plan_id)
}

plan_draft_payloads <- function(connection, plan_id) {
  rows <- DBI::dbGetQuery(
    connection,
    "SELECT section_key, payload::text AS payload FROM planning.plan_section_draft WHERE plan_id = $1",
    params = list(as.integer(plan_id))
  )
  payloads <- list()
  for (i in seq_len(nrow(rows))) {
    payloads[[rows$section_key[[i]]]] <- jsonlite::fromJSON(rows$payload[[i]], simplifyVector = FALSE)
  }
  payloads
}

draft_field <- function(payload, field_id, fallback = "") {
  if (is.null(payload) || is.null(payload$values) || is.null(payload$values[[field_id]])) return(fallback)
  value <- payload$values[[field_id]]
  if (is.null(value) || length(value) == 0 || is.na(value)) return(fallback)
  as.character(value)
}

apply_plan_drafts_to_records <- function(connection, plan_id) {
  plan_id <- as.integer(plan_id)
  payloads <- plan_draft_payloads(connection, plan_id)

  overview <- payloads$overview
  if (!is.null(overview)) {
    DBI::dbExecute(
      connection,
      paste(
        "INSERT INTO performance.overview_vision (plan_id, overview, vision, web_address)",
        "VALUES ($1, $2, $3, $4)",
        "ON CONFLICT (plan_id) DO UPDATE SET overview = EXCLUDED.overview, vision = EXCLUDED.vision, web_address = EXCLUDED.web_address"
      ),
      params = list(
        plan_id,
        draft_field(overview, "agency_summary", "Overview pending."),
        draft_field(overview, "agency_vision", "Vision pending."),
        draft_field(overview, "agency_website", NA_character_)
      )
    )
  }

  goals <- payloads$goals
  if (!is.null(goals) && !is.null(goals$goalIds)) {
    goal_ids <- as.character(unlist(goals$goalIds))
    kept_goal_ids <- integer(0)
    DBI::dbExecute(
      connection,
      "UPDATE performance.agency_goal SET sort_order = sort_order + 1000 WHERE plan_id = $1",
      params = list(plan_id)
    )
    for (index in seq_along(goal_ids)) {
      draft_goal_id <- goal_ids[[index]]
      title <- draft_field(goals, paste0("goal_statement_", draft_goal_id), "Untitled goal")
      if (grepl("^[0-9]+$", draft_goal_id)) {
        saved_goal <- DBI::dbGetQuery(
          connection,
          paste(
            "UPDATE performance.agency_goal",
            "SET title = $3, sort_order = $4",
            "WHERE agency_goal_id = $1 AND plan_id = $2",
            "RETURNING agency_goal_id"
          ),
          params = list(as.integer(draft_goal_id), plan_id, title, as.integer(index))
        )
      } else {
        saved_goal <- data.frame()
      }
      if (!nrow(saved_goal)) {
        saved_goal <- DBI::dbGetQuery(
          connection,
          "INSERT INTO performance.agency_goal (plan_id, title, sort_order) VALUES ($1, $2, $3) RETURNING agency_goal_id",
          params = list(plan_id, title, as.integer(index))
        )
      }
      goal_id <- saved_goal$agency_goal_id[[1]]
      kept_goal_ids <- c(kept_goal_ids, goal_id)

      DBI::dbExecute(connection, "DELETE FROM performance.agency_goal_pillar_link WHERE agency_goal_id = $1", params = list(goal_id))
      alignment_code <- draft_field(goals, paste0("goal_alignment_", draft_goal_id), "")
      if (nzchar(alignment_code)) {
        pillar_goal <- DBI::dbGetQuery(connection, "SELECT pillar_goal_id FROM reference.pillar_goal WHERE goal_code = $1 LIMIT 1", params = list(alignment_code))
        if (nrow(pillar_goal)) {
          DBI::dbExecute(
            connection,
            "INSERT INTO performance.agency_goal_pillar_link (agency_goal_id, pillar_goal_id, link_type) VALUES ($1, $2, 'Primary') ON CONFLICT DO NOTHING",
            params = list(goal_id, pillar_goal$pillar_goal_id[[1]])
          )
        }
      }

      DBI::dbExecute(connection, "DELETE FROM performance.agency_goal_initiative_link WHERE agency_goal_id = $1", params = list(goal_id))
      initiative_titles <- if (!is.null(goals$initiatives[[draft_goal_id]])) as.character(unlist(goals$initiatives[[draft_goal_id]])) else character(0)
      initiative_titles <- initiative_titles[nzchar(trimws(initiative_titles))]
      for (initiative_title in initiative_titles) {
        initiative <- DBI::dbGetQuery(
          connection,
          "INSERT INTO performance.initiative (title, status) VALUES ($1, 'Planned') RETURNING initiative_id",
          params = list(initiative_title)
        )
        DBI::dbExecute(
          connection,
          "INSERT INTO performance.agency_goal_initiative_link (agency_goal_id, initiative_id, link_type) VALUES ($1, $2, 'Primary') ON CONFLICT DO NOTHING",
          params = list(goal_id, initiative$initiative_id[[1]])
        )
      }

      DBI::dbExecute(connection, "DELETE FROM performance.pm_goal_link WHERE agency_goal_id = $1", params = list(goal_id))
      kpi_ids <- if (!is.null(goals$kpis[[draft_goal_id]])) suppressWarnings(as.integer(unlist(goals$kpis[[draft_goal_id]]))) else integer(0)
      kpi_ids <- kpi_ids[!is.na(kpi_ids)]
      for (measure_id in kpi_ids) {
        DBI::dbExecute(
          connection,
          "INSERT INTO performance.pm_goal_link (measure_id, agency_goal_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
          params = list(measure_id, goal_id)
        )
      }
    }

    existing_goals <- DBI::dbGetQuery(connection, "SELECT agency_goal_id FROM performance.agency_goal WHERE plan_id = $1", params = list(plan_id))
    removed_goal_ids <- setdiff(existing_goals$agency_goal_id, kept_goal_ids)
    for (removed_goal_id in removed_goal_ids) {
      DBI::dbExecute(connection, "DELETE FROM performance.pm_goal_link WHERE agency_goal_id = $1", params = list(removed_goal_id))
      DBI::dbExecute(connection, "DELETE FROM performance.agency_goal_pillar_link WHERE agency_goal_id = $1", params = list(removed_goal_id))
      DBI::dbExecute(connection, "DELETE FROM performance.agency_goal_initiative_link WHERE agency_goal_id = $1", params = list(removed_goal_id))
      DBI::dbExecute(connection, "DELETE FROM performance.service_goal_link WHERE agency_goal_id = $1", params = list(removed_goal_id))
      DBI::dbExecute(connection, "DELETE FROM performance.agency_goal WHERE agency_goal_id = $1", params = list(removed_goal_id))
    }
  }

  services <- payloads$services
  if (!is.null(services)) {
    plan_services <- DBI::dbGetQuery(connection, "SELECT service_id FROM performance.plan_service WHERE plan_id = $1", params = list(plan_id))
    for (service_id in plan_services$service_id) {
      service_key <- as.character(service_id)
      description <- draft_field(services, paste0("service_description_", service_key), NA_character_)
      if (!is.na(description)) {
        DBI::dbExecute(connection, "UPDATE reference.service SET service_description = $2 WHERE service_id = $1", params = list(service_key, description))
      }
      if (!is.null(services$serviceMetrics[[service_key]])) {
        DBI::dbExecute(connection, "DELETE FROM performance.pm_service_link WHERE service_id = $1", params = list(service_key))
        metric_ids <- suppressWarnings(as.integer(unlist(services$serviceMetrics[[service_key]])))
        metric_ids <- metric_ids[!is.na(metric_ids)]
        for (measure_id in metric_ids) {
          DBI::dbExecute(
            connection,
            "INSERT INTO performance.pm_service_link (measure_id, service_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
            params = list(measure_id, service_key)
          )
        }
      }
    }
  }

  invisible(plan_id)
}

approve_agency_plan <- function(connection, plan_id, approved_by = NULL) {
  plan_id <- as.integer(plan_id)
  approved_by <- if (is.null(approved_by) || is.na(approved_by)) NA_integer_ else as.integer(approved_by)
  if (is.na(approved_by)) {
    users <- DBI::dbGetQuery(connection, "SELECT user_id FROM access.\"user\" ORDER BY user_id LIMIT 1")
    if (!nrow(users)) stop("No user is available to approve this plan.")
    approved_by <- users$user_id[[1]]
  }
  DBI::dbWithTransaction(connection, {
    apply_plan_drafts_to_records(connection, plan_id)
    changed <- DBI::dbGetQuery(
      connection,
      paste(
        "WITH current_plan AS (SELECT plan_id, plan_status FROM planning.agency_plan WHERE plan_id = $1),",
        "updated_plan AS (",
        "UPDATE planning.agency_plan ap SET plan_status = 'Approved', approved_at = now(), updated_at = now()",
        "FROM current_plan cp WHERE ap.plan_id = cp.plan_id",
        "RETURNING ap.plan_id, cp.plan_status AS from_status",
        ") SELECT plan_id, from_status FROM updated_plan"
      ),
      params = list(plan_id)
    )
    if (!nrow(changed)) stop("Plan not found.")
    DBI::dbExecute(
      connection,
      paste(
        "INSERT INTO workflow.plan_status_history (plan_id, changed_by, from_status, to_status, plan_phase, changed_at, notes)",
        "VALUES ($1, $2, $3, 'Approved', 'PerformancePlan', now(), 'Draft payload promoted to plan records and cleared.')"
      ),
      params = list(plan_id, approved_by, changed$from_status[[1]])
    )
    DBI::dbExecute(connection, "DELETE FROM planning.plan_section_draft WHERE plan_id = $1", params = list(plan_id))
  })
  invisible(plan_id)
}
