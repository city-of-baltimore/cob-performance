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
  sslmode_match <- regmatches(database_url, regexec("[?&]sslmode=([^&]+)", database_url))[[1]]
  sslmode <- if (length(sslmode_match) == 2) sslmode_match[[2]] else "prefer"
  DBI::dbConnect(
    RPostgres::Postgres(),
    user = utils::URLdecode(parts[[2]]),
    password = utils::URLdecode(parts[[3]]),
    host = parts[[4]],
    port = as.integer(if (nzchar(parts[[5]])) parts[[5]] else "5432"),
    dbname = utils::URLdecode(parts[[6]]),
    sslmode = sslmode
  )
}

ensure_review_schema <- function(connection) {
  DBI::dbExecute(connection, "ALTER TABLE access.user_agency_access ADD COLUMN IF NOT EXISTS agency_roles text")
  DBI::dbExecute(connection, "ALTER TABLE review.section_score ADD COLUMN IF NOT EXISTS target_type varchar(20) NOT NULL DEFAULT 'plan'")
  DBI::dbExecute(connection, "ALTER TABLE review.section_score ADD COLUMN IF NOT EXISTS target_id integer")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_section_score_target ON review.section_score(review_id, target_type, target_id)")
  DBI::dbExecute(connection, "CREATE SCHEMA IF NOT EXISTS workflow")
  DBI::dbExecute(
    connection,
    paste(
      "CREATE TABLE IF NOT EXISTS workflow.plan_approval_stamp (",
      "stamp_id serial PRIMARY KEY,",
      "plan_id integer NOT NULL REFERENCES planning.agency_plan(plan_id) ON DELETE CASCADE,",
      "approval_stage varchar(40) NOT NULL,",
      "approved_by integer REFERENCES access.\"user\"(user_id),",
      "added_by integer REFERENCES access.\"user\"(user_id),",
      "approved_at timestamptz NOT NULL DEFAULT now(),",
      "notes text,",
      "created_at timestamptz NOT NULL DEFAULT now()",
      ")"
    )
  )
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_plan_approval_stamp_plan_stage ON workflow.plan_approval_stamp(plan_id, approval_stage, approved_at DESC)")
  DBI::dbExecute(
    connection,
    paste(
      "CREATE TABLE IF NOT EXISTS workflow.entity_role_assignment (",
      "assignment_id serial PRIMARY KEY,",
      "entity_type varchar(80),",
      "agency_id varchar(20) REFERENCES reference.agency(agency_id),",
      "agency text,",
      "entity_id integer REFERENCES reference.plan_entity(entity_id),",
      "public_name text NOT NULL,",
      "submitter_user_id integer REFERENCES access.\"user\"(user_id),",
      "submitter_name text,",
      "reviewer_user_id integer REFERENCES access.\"user\"(user_id),",
      "reviewer_name text,",
      "deputy_mayor_user_id integer REFERENCES access.\"user\"(user_id),",
      "deputy_mayor_name text,",
      "ca_office_user_id integer REFERENCES access.\"user\"(user_id),",
      "ca_office_name text,",
      "created_at timestamptz NOT NULL DEFAULT now(),",
      "updated_at timestamptz NOT NULL DEFAULT now(),",
      "modified_by integer REFERENCES access.\"user\"(user_id),",
      "UNIQUE (public_name)",
      ")"
    )
  )
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_entity_role_assignment_agency ON workflow.entity_role_assignment(agency_id)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_entity_role_assignment_entity ON workflow.entity_role_assignment(entity_id)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_entity_role_assignment_users ON workflow.entity_role_assignment(submitter_user_id, reviewer_user_id, deputy_mayor_user_id, ca_office_user_id)")
  DBI::dbExecute(connection, "CREATE SCHEMA IF NOT EXISTS application")
  DBI::dbExecute(
    connection,
    paste(
      "CREATE TABLE IF NOT EXISTS application.feedback_request (",
      "feedback_id serial PRIMARY KEY,",
      "user_email text,",
      "comment text NOT NULL,",
      "screenshot_data text,",
      "page_key varchar(80),",
      "page_url text,",
      "category varchar(30) NOT NULL DEFAULT 'Uncategorized',",
      "priority varchar(30) NOT NULL DEFAULT 'Unassigned',",
      "status varchar(30) NOT NULL DEFAULT 'Open',",
      "assigned_admin_id integer REFERENCES access.\"user\"(user_id),",
      "created_at timestamptz NOT NULL DEFAULT now(),",
      "updated_at timestamptz NOT NULL DEFAULT now(),",
      "modified_by text",
      ")"
    )
  )
  DBI::dbExecute(connection, "ALTER TABLE application.feedback_request ADD COLUMN IF NOT EXISTS assigned_admin_id integer REFERENCES access.\"user\"(user_id)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_feedback_request_status ON application.feedback_request(status, priority, category)")
  invisible(TRUE)
}

load_app_data <- function(connection) {
  query <- function(sql) DBI::dbGetQuery(connection, sql)
  data <- list(
    reference_agency = query(
      "SELECT agency_id, agency_name, public_name, deputy_mayor_pillar, submit_plan FROM reference.agency WHERE active ORDER BY COALESCE(public_name, agency_name), agency_name"
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
        "SELECT ap.plan_id, ap.agency_id, ap.entity_id, ap.cycle_id, pc.fiscal_year, ap.plan_status, ap.budget_status, ap.version,",
        "ap.assigned_reviewer, reviewer.full_name AS assigned_reviewer_name, ap.submitted_at, ap.updated_at",
        "FROM planning.agency_plan ap JOIN planning.plan_cycle pc ON pc.cycle_id = ap.cycle_id",
        "LEFT JOIN access.\"user\" reviewer ON reviewer.user_id = ap.assigned_reviewer",
        "ORDER BY pc.fiscal_year DESC, ap.plan_id"
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
        "SELECT service_id, agency_id, pillar_id, service_name, service_type, service_description, active",
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
      paste(
        "SELECT l.agency_goal_id, l.measure_id",
        "FROM performance.pm_goal_link l",
        "JOIN performance.performance_measure m ON m.measure_id = l.measure_id",
        "JOIN planning.plan_cycle pc ON pc.cycle_id = m.initial_cycle",
        "WHERE pc.fiscal_year = 2027",
        "AND m.active",
        "AND COALESCE(m.approval_status, '') <> 'Deprecated'",
        "AND COALESCE(m.change_mapping, '') NOT IN ('Removed', 'Replaced')"
      )
    ),
    performance_pm_service_link = query(
      paste(
        "SELECT l.service_id, l.measure_id",
        "FROM performance.pm_service_link l",
        "JOIN performance.performance_measure m ON m.measure_id = l.measure_id",
        "JOIN planning.plan_cycle pc ON pc.cycle_id = m.initial_cycle",
        "WHERE pc.fiscal_year = 2027",
        "AND m.active",
        "AND COALESCE(m.approval_status, '') <> 'Deprecated'",
        "AND COALESCE(m.change_mapping, '') NOT IN ('Removed', 'Replaced')",
        "ORDER BY l.service_id, l.measure_id"
      )
    ),
    performance_pm_service_link_all = query(
      "SELECT service_id, measure_id FROM performance.pm_service_link ORDER BY service_id, measure_id"
    ),
    performance_measure_entity_link = query(
      paste(
        "SELECT link_id, measure_id, agency_id, service_id, entity_type, entity_id, public_name, source_old_measure_id",
        "FROM performance.measure_entity_link ORDER BY agency_id, service_id, entity_type, public_name, measure_id"
      )
    ),
    performance_performance_measure = query(
      paste(
        "SELECT measure_id, agency_id, initial_cycle, title, measure_type, description, data_source, data_owner, data_owner_role,",
        "update_frequency, formula, desired_direction, baseline_value, baseline_fy, format_type, display_unit, context_required,",
        "replicability, disaggregation, data_location, collection_method, how_data_used, why_meaningful, proxy_measure, improvement_notes,",
        "change_mapping, pillar_id, pillar_goal_id, is_city, is_agency, is_service, active, validated, approval_status, submitted_for_approval_at,",
        "created_date, last_updated, pc.fiscal_year",
        "FROM performance.performance_measure",
        "JOIN planning.plan_cycle pc ON pc.cycle_id = performance_measure.initial_cycle",
        "ORDER BY agency_id, title"
      )
    ),
    performance_measure_actuals = query(
      "SELECT measure_id, fiscal_year, annual_actual, annual_actual_notes, target_value, target_value_notes FROM performance.measure_actuals ORDER BY measure_id, fiscal_year"
    ),
    performance_service_risk = query(
      "SELECT risk_id, plan_id, risk_type, description FROM performance.service_risk ORDER BY plan_id, risk_id"
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
      "SELECT score_id, review_id, section_code, criterion_code, COALESCE(target_type, 'plan') AS target_type, target_id, score, weight, weighted_score, justification FROM review.section_score ORDER BY review_id, section_code, target_type, target_id, criterion_code"
    ),
    review_section_feedback = query(
      "SELECT feedback_id, review_id, section_code, feedback_text, return_required, resolved_at FROM review.section_feedback ORDER BY review_id, section_code, feedback_id"
    ),
    review_measure_review = query(
      paste(
        "SELECT mr.measure_review_id, mr.measure_id, mr.reviewer_id, u.full_name AS reviewer_name,",
        "mr.decision, mr.feedback, mr.reviewed_at, mr.created_at",
        "FROM review.measure_review mr",
        "LEFT JOIN access.\"user\" u ON u.user_id = mr.reviewer_id",
        "ORDER BY mr.reviewed_at DESC, mr.measure_review_id DESC"
      )
    ),
    workflow_plan_status_history = query(
      paste(
        "SELECT psh.history_id, psh.plan_id, psh.changed_by, u.full_name AS changed_by_name,",
        "psh.from_status, psh.to_status, psh.plan_phase, psh.changed_at, psh.notes",
        "FROM workflow.plan_status_history psh LEFT JOIN access.\"user\" u ON u.user_id = psh.changed_by",
        "ORDER BY psh.plan_id, psh.changed_at"
      )
    ),
    workflow_plan_approval_stamp = query(
      paste(
        "SELECT pas.stamp_id, pas.plan_id, pas.approval_stage, pas.approved_by, approver.full_name AS approved_by_name,",
        "pas.added_by, added.full_name AS added_by_name, pas.approved_at AT TIME ZONE 'America/New_York' AS approved_at,",
        "pas.notes, pas.created_at AT TIME ZONE 'America/New_York' AS created_at",
        "FROM workflow.plan_approval_stamp pas",
        "LEFT JOIN access.\"user\" approver ON approver.user_id = pas.approved_by",
        "LEFT JOIN access.\"user\" added ON added.user_id = pas.added_by",
        "ORDER BY pas.plan_id, pas.approved_at DESC, pas.stamp_id DESC"
      )
    ),
    workflow_entity_role_assignment = query(
      paste(
        "SELECT assignment_id, entity_type, agency_id, agency, entity_id, public_name,",
        "submitter_user_id, submitter_name, reviewer_user_id, reviewer_name,",
        "deputy_mayor_user_id, deputy_mayor_name, ca_office_user_id, ca_office_name,",
        "created_at AT TIME ZONE 'America/New_York' AS created_at,",
        "updated_at AT TIME ZONE 'America/New_York' AS updated_at, modified_by",
        "FROM workflow.entity_role_assignment",
        "ORDER BY public_name"
      )
    ),
    planning_plan_section_draft = query(
      "SELECT draft_id, plan_id, section_key, payload::text AS payload, revision, updated_by, updated_at AT TIME ZONE 'America/New_York' AS updated_at FROM planning.plan_section_draft ORDER BY plan_id, section_key"
    ),
    access_user_agency_access = query(
      paste(
        "SELECT uaa.access_id, u.user_id, uaa.agency_id, uaa.service_id, u.full_name, u.email,",
        "uaa.agency_role, COALESCE(NULLIF(uaa.agency_roles, ''), uaa.agency_role) AS agency_roles,",
        "uaa.access_level, uaa.budget_access, uaa.performance_plan_access",
        "FROM access.user_agency_access uaa JOIN access.\"user\" u ON u.user_id = uaa.user_id",
        "WHERE u.active ORDER BY uaa.agency_id, u.full_name"
      )
    ),
    access_user_role = query(
      paste(
        "SELECT ur.user_role_id, ur.user_id, ur.app_role, ur.agency_id, ur.pillar_id,",
        "ur.budget_access, ur.adaptive_planning, ur.performance_plan_access, u.full_name, u.email",
        "FROM access.user_role ur JOIN access.\"user\" u ON u.user_id = ur.user_id",
        "WHERE u.active ORDER BY ur.agency_id, ur.app_role, u.full_name"
      )
    ),
    access_user = query(
      "SELECT user_id, full_name, email FROM access.\"user\" WHERE active ORDER BY full_name, email"
    ),
    application_feedback_request = query(
      paste(
        "SELECT fr.feedback_id, fr.user_email, fr.comment, fr.screenshot_data, fr.page_key, fr.page_url, fr.category, fr.priority, fr.status,",
        "fr.assigned_admin_id, assigned_admin.full_name AS assigned_admin_name, assigned_admin.email AS assigned_admin_email,",
        "fr.created_at AT TIME ZONE 'America/New_York' AS created_at,",
        "fr.updated_at AT TIME ZONE 'America/New_York' AS updated_at, fr.modified_by",
        "FROM application.feedback_request fr",
        "LEFT JOIN access.\"user\" assigned_admin ON assigned_admin.user_id = fr.assigned_admin_id",
        "ORDER BY fr.created_at DESC, fr.feedback_id DESC"
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
  normalize_measure_name <- function(value) {
    trimws(tolower(gsub("[^a-z0-9]+", " ", as.character(value))))
  }
  match_action_plan_measure <- function(measure_name) {
    if (!nrow(data$performance_performance_measure)) return(list(measure_id = NA_integer_, match_type = NA_character_, match_distance = NA_real_))
    action_key <- normalize_measure_name(measure_name)
    measure_keys <- normalize_measure_name(data$performance_performance_measure$title)
    exact_matches <- which(measure_keys == action_key)
    if (length(exact_matches)) {
      row <- data$performance_performance_measure[exact_matches[[1]], , drop = FALSE]
      return(list(measure_id = row$measure_id[[1]], match_type = "Exact title match", match_distance = 0))
    }
    distances <- as.numeric(utils::adist(action_key, measure_keys, ignore.case = TRUE))
    normalized <- distances / pmax(nchar(action_key), nchar(measure_keys))
    best <- which.min(normalized)
    if (length(best) && !is.na(normalized[[best]]) && normalized[[best]] <= 0.25) {
      row <- data$performance_performance_measure[best, , drop = FALSE]
      return(list(measure_id = row$measure_id[[1]], match_type = "Close title match", match_distance = normalized[[best]]))
    }
    list(measure_id = NA_integer_, match_type = NA_character_, match_distance = NA_real_)
  }
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
      matched_measure <- match_action_plan_measure(measure$measure_name[[1]])
      list(
        name = measure$measure_name[[1]],
        baseline = as.numeric(measure$baseline_value[[1]]),
        current = as.numeric(measure$current_value[[1]]),
        target = as.numeric(measure$target_value[[1]]),
        direction = measure$desired_direction[[1]],
        unit = if (is.na(measure$display_unit[[1]])) NULL else measure$display_unit[[1]],
        matched_measure_id = matched_measure$measure_id,
        match_type = matched_measure$match_type,
        match_distance = matched_measure$match_distance
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

save_feedback_request <- function(connection, user_email, comment, screenshot_data = "", page_key = "", page_url = "") {
  user_email <- trimws(as.character(user_email %||% ""))
  comment <- trimws(as.character(comment %||% ""))
  screenshot_data <- as.character(screenshot_data %||% "")
  page_key <- as.character(page_key %||% "")
  page_url <- as.character(page_url %||% "")
  if (!nzchar(comment)) stop("Add a comment before submitting feedback.")
  DBI::dbGetQuery(
    connection,
    paste(
      "INSERT INTO application.feedback_request (user_email, comment, screenshot_data, page_key, page_url)",
      "VALUES ($1::text, $2::text, NULLIF($3::text, ''), NULLIF($4::text, ''), NULLIF($5::text, ''))",
      "RETURNING feedback_id"
    ),
    params = list(user_email, comment, screenshot_data, page_key, page_url)
  )$feedback_id[[1]]
}

update_feedback_request <- function(connection, feedback_id, category, priority, status, assigned_admin_id = NULL, modified_by = NULL) {
  feedback_id <- as.integer(feedback_id)
  if (is.na(feedback_id)) stop("Choose a valid feedback request.")
  valid_category <- c("Uncategorized", "Bug", "Feature")
  valid_priority <- c("Unassigned", "Low", "Medium", "High", "Urgent")
  valid_status <- c("Open", "In Review", "Complete", "Archived")
  category <- as.character(category %||% "Uncategorized")
  priority <- as.character(priority %||% "Unassigned")
  status <- as.character(status %||% "Open")
  assigned_admin_id <- suppressWarnings(as.integer(assigned_admin_id %||% NA_integer_))
  if (!category %in% valid_category) category <- "Uncategorized"
  if (!priority %in% valid_priority) priority <- "Unassigned"
  if (!status %in% valid_status) status <- "Open"
  if (!is.na(assigned_admin_id)) {
    admin_rows <- DBI::dbGetQuery(
      connection,
      paste(
        "SELECT ur.user_id",
        "FROM access.user_role ur JOIN access.\"user\" u ON u.user_id = ur.user_id",
        "WHERE ur.user_id = $1 AND ur.app_role = 'SystemAdmin' AND u.active",
        "LIMIT 1"
      ),
      params = list(assigned_admin_id)
    )
    if (!nrow(admin_rows)) stop("Choose an active System Admin assignee.")
  }
  DBI::dbExecute(
    connection,
    paste(
      "UPDATE application.feedback_request",
      "SET category = $2::varchar, priority = $3::varchar, status = $4::varchar,",
      "assigned_admin_id = $5::integer, updated_at = now(), modified_by = NULLIF($6::text, '')",
      "WHERE feedback_id = $1"
    ),
    params = list(feedback_id, category, priority, status, if (is.na(assigned_admin_id)) NA_integer_ else assigned_admin_id, as.character(modified_by %||% ""))
  )
  invisible(feedback_id)
}

delete_feedback_request <- function(connection, feedback_id) {
  feedback_id <- as.integer(feedback_id)
  if (is.na(feedback_id)) stop("Choose a valid feedback request.")
  DBI::dbExecute(connection, "DELETE FROM application.feedback_request WHERE feedback_id = $1", params = list(feedback_id))
  invisible(feedback_id)
}

save_measure_record <- function(connection, values, yearly_values, reported_by, submit = FALSE) {
  DBI::dbWithTransaction(connection, {
    status <- if (submit) {
      "PendingApproval"
    } else if (!is.null(values$measure_id) && values$approval_status %in% c("Validated", "PendingApproval", "Returned")) {
      "Draft"
    } else {
      values$approval_status
    }
    submitted_at <- if (submit) {
      Sys.time()
    } else if (!is.null(values$measure_id) && values$approval_status %in% c("Validated", "PendingApproval", "Returned")) {
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

review_measure_record <- function(connection, measure_id, decision, feedback = "", reviewer_id = NULL) {
  decision <- as.character(decision)
  if (!decision %in% c("approve", "return")) stop("Unknown measure review decision")
  measure_id <- as.integer(measure_id)
  if (is.null(feedback) || length(feedback) == 0 || is.na(feedback)) feedback <- ""
  feedback <- trimws(as.character(feedback))
  reviewer_id <- if (is.null(reviewer_id) || is.na(reviewer_id)) NA_integer_ else as.integer(reviewer_id)
  review_decision <- if (identical(decision, "approve")) "Approved" else "Returned"
  approval_status <- if (identical(decision, "approve")) "Validated" else "Returned"
  if (identical(decision, "return") && !nzchar(feedback)) {
    stop("Reviewer feedback is required when returning a measure.")
  }
  DBI::dbWithTransaction(connection, {
    changed <- DBI::dbExecute(
      connection,
      paste(
        "UPDATE performance.performance_measure",
        "SET approval_status=$2::varchar(30), validated=$3, submitted_for_approval_at=NULL, last_updated=now()",
        "WHERE measure_id=$1"
      ),
      params = list(measure_id, approval_status, identical(decision, "approve"))
    )
    if (changed != 1) stop("Measure not found")
    DBI::dbExecute(
      connection,
      paste(
        "INSERT INTO review.measure_review (measure_id, reviewer_id, decision, feedback, modified_by)",
        "VALUES ($1, $2, $3, $4, $2)"
      ),
      params = list(measure_id, reviewer_id, review_decision, feedback)
    )
  })
  invisible(TRUE)
}

save_plan_review_scores <- function(connection, plan_id, reviewer_id, scores, internal_notes = "") {
  plan_id <- as.integer(plan_id)
  reviewer_id <- if (is.null(reviewer_id) || is.na(reviewer_id)) NA_integer_ else as.integer(reviewer_id)
  if (is.null(scores) || !length(scores)) stop("No review scores were submitted.")
  if (is.null(internal_notes) || length(internal_notes) == 0 || is.na(internal_notes)) internal_notes <- ""

  fallback_value <- function(value, fallback) {
    if (is.null(value) || length(value) == 0 || is.na(value)) fallback else value
  }
  review_rows <- lapply(scores, function(row) {
    score <- suppressWarnings(as.integer(row$score))
    if (length(score) == 0) score <- NA_integer_
    if (!is.na(score) && (score < 1 || score > 4)) score <- NA_integer_
    weight <- suppressWarnings(as.numeric(row$weight))
    if (length(weight) == 0) weight <- 0
    if (is.na(weight)) weight <- 0
    list(
      section_code = as.character(row$section_code),
      criterion_code = as.character(row$criterion_code),
      target_type = as.character(fallback_value(row$target_type, "plan")),
      target_id = if (is.null(row$target_id) || is.na(row$target_id) || !nzchar(as.character(row$target_id))) NA_integer_ else as.integer(row$target_id),
      score = score,
      weight = weight,
      weighted_score = if (is.na(score)) 0 else weight * score / 4,
      justification = as.character(fallback_value(row$justification, ""))
    )
  })
  review_rows <- Filter(Negate(is.null), review_rows)
  score_rows <- Filter(function(row) !is.na(row$score), review_rows)
  score_rows <- Filter(Negate(is.null), score_rows)
  if (!length(score_rows)) stop("Enter at least one valid score before saving.")

  scale_score <- function(value, raw_max, target_max) {
    if (is.na(value) || is.na(raw_max) || raw_max <= 0) return(0)
    min(target_max, value / raw_max * target_max)
  }

  section_totals <- vapply(c("S1", "S2", "S3", "S5", "S6"), function(section_code) {
    rows <- Filter(function(row) identical(row$section_code, section_code), review_rows)
    if (!length(rows)) return(0)
    if (identical(section_code, "S2")) {
      target_keys <- unique(vapply(rows, function(row) paste(row$target_type, row$target_id, sep = ":"), character(1)))
      has_pillar_alignment <- any(vapply(rows, function(row) identical(row$criterion_code, "PILLAR") && !is.na(row$score), logical(1)))
      target_scores <- vapply(target_keys, function(key) {
        target_rows <- rows[vapply(rows, function(row) identical(paste(row$target_type, row$target_id, sep = ":"), key), logical(1))]
        if (!any(vapply(target_rows, function(row) identical(row$criterion_code, "PILLAR") && !is.na(row$score), logical(1)))) {
          target_rows <- Filter(function(row) !identical(row$criterion_code, "PILLAR"), target_rows)
        }
        raw_score <- sum(vapply(target_rows, function(row) row$weighted_score, numeric(1)), na.rm = TRUE)
        raw_max <- sum(vapply(target_rows, function(row) row$weight, numeric(1)), na.rm = TRUE)
        scale_score(raw_score, raw_max, 55)
      }, numeric(1))
      goal_score <- mean(target_scores, na.rm = TRUE)
      if (!has_pillar_alignment) goal_score <- max(0, goal_score - 7)
      return(goal_score)
    }
    if (identical(section_code, "S3")) {
      plan_rows <- Filter(function(row) identical(row$target_type, "plan"), rows)
      plan_score <- sum(vapply(plan_rows, function(row) row$weighted_score, numeric(1)), na.rm = TRUE)
      plan_max <- sum(vapply(plan_rows, function(row) row$weight, numeric(1)), na.rm = TRUE)
      plan_score <- scale_score(plan_score, plan_max, 5)
      service_rows <- Filter(function(row) identical(row$target_type, "service"), rows)
      if (!length(service_rows)) return(plan_score)
      target_keys <- unique(vapply(service_rows, function(row) paste(row$target_type, row$target_id, sep = ":"), character(1)))
      service_scores <- vapply(target_keys, function(key) {
        target_rows <- service_rows[vapply(service_rows, function(row) identical(paste(row$target_type, row$target_id, sep = ":"), key), logical(1))]
        raw_score <- sum(vapply(target_rows, function(row) row$weighted_score, numeric(1)), na.rm = TRUE)
        raw_max <- sum(vapply(target_rows, function(row) row$weight, numeric(1)), na.rm = TRUE)
        scale_score(raw_score, raw_max, 15)
      }, numeric(1))
      return(plan_score + mean(service_scores, na.rm = TRUE))
    }
    raw_score <- sum(vapply(rows, function(row) row$weighted_score, numeric(1)), na.rm = TRUE)
    raw_max <- sum(vapply(rows, function(row) row$weight, numeric(1)), na.rm = TRUE)
    target_max <- switch(section_code, S1 = 10, S5 = 5, S6 = 10, raw_max)
    scale_score(raw_score, raw_max, target_max)
  }, numeric(1))
  overall_score <- min(100, sum(section_totals, na.rm = TRUE))

  DBI::dbWithTransaction(connection, {
    existing <- DBI::dbGetQuery(
      connection,
      "SELECT review_id FROM review.plan_review WHERE plan_id=$1 ORDER BY review_started_at DESC NULLS LAST, review_id DESC LIMIT 1",
      params = list(plan_id)
    )
    if (nrow(existing)) {
      review_id <- existing$review_id[[1]]
      DBI::dbExecute(
        connection,
        "UPDATE review.plan_review SET reviewer_id=$2, review_started_at=COALESCE(review_started_at, now()), overall_score=$3, internal_notes=$4, review_complete=false WHERE review_id=$1",
        params = list(review_id, reviewer_id, overall_score, internal_notes)
      )
    } else {
      inserted <- DBI::dbGetQuery(
        connection,
        "INSERT INTO review.plan_review (plan_id, reviewer_id, review_started_at, overall_score, internal_notes, review_complete) VALUES ($1,$2,now(),$3,$4,false) RETURNING review_id",
        params = list(plan_id, reviewer_id, overall_score, internal_notes)
      )
      review_id <- inserted$review_id[[1]]
    }
    for (row in score_rows) {
      existing_score <- DBI::dbGetQuery(
        connection,
        paste(
          "SELECT score_id FROM review.section_score",
          "WHERE review_id=$1 AND section_code=$2 AND criterion_code=$3 AND target_type=$4",
          "AND ((target_id IS NULL AND $5::integer IS NULL) OR target_id=$5::integer)",
          "LIMIT 1"
        ),
        params = list(review_id, row$section_code, row$criterion_code, row$target_type, row$target_id)
      )
      if (nrow(existing_score)) {
        DBI::dbExecute(
          connection,
          paste(
            "UPDATE review.section_score",
            "SET score=$2, weight=$3, weighted_score=$4, justification=$5",
            "WHERE score_id=$1"
          ),
          params = list(existing_score$score_id[[1]], row$score, row$weight, row$weighted_score, row$justification)
        )
      } else {
        DBI::dbExecute(
          connection,
          paste(
            "INSERT INTO review.section_score",
            "(review_id, section_code, criterion_code, target_type, target_id, score, weight, weighted_score, justification)",
            "VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)"
          ),
          params = list(review_id, row$section_code, row$criterion_code, row$target_type, row$target_id, row$score, row$weight, row$weighted_score, row$justification)
        )
      }
    }
  })
  invisible(overall_score)
}

approve_plan_review <- function(connection, plan_id, reviewer_id = NULL, next_status = "DeputyMayorReview", routed_by = NULL) {
  plan_id <- as.integer(plan_id)
  reviewer_id <- if (is.null(reviewer_id) || is.na(reviewer_id)) NA_integer_ else as.integer(reviewer_id)
  routed_by <- if (is.null(routed_by) || is.na(routed_by)) NA_integer_ else as.integer(routed_by)
  next_status <- as.character(next_status %||% "DeputyMayorReview")
  if (is.na(plan_id)) stop("Plan is required.")
  valid_next_statuses <- c("Returned", "DeputyMayorReview", "CAReview", "Approved")
  if (!next_status %in% valid_next_statuses) {
    stop("Choose a valid routing destination.")
  }
  DBI::dbWithTransaction(connection, {
    plan <- DBI::dbGetQuery(
      connection,
      "SELECT plan_id, plan_status FROM planning.agency_plan WHERE plan_id = $1",
      params = list(plan_id)
    )
    if (!nrow(plan)) stop("Plan not found.")
    approvable_statuses <- c("Submitted", "UnderReview", "FeedbackReturned", "Returned", "AgencyRevised")
    if (!plan$plan_status[[1]] %in% approvable_statuses) {
      stop("Only submitted, returned, revised, or active reviewer-review plans can be approved by the reviewer.")
    }
    if (is.na(reviewer_id)) {
      assigned <- DBI::dbGetQuery(
        connection,
        "SELECT assigned_reviewer FROM planning.agency_plan WHERE plan_id = $1",
        params = list(plan_id)
      )
      reviewer_id <- assigned$assigned_reviewer[[1]]
    }
    if (is.na(routed_by)) {
      routed_by <- reviewer_id
    }
    if (is.na(reviewer_id)) {
      users <- DBI::dbGetQuery(
        connection,
        paste(
          "SELECT ur.user_id",
          "FROM access.user_role ur JOIN access.\"user\" u ON u.user_id = ur.user_id",
          "WHERE ur.app_role IN ('SystemAdmin', 'OPIReviewer') AND u.active",
          "ORDER BY ur.user_id LIMIT 1"
        )
      )
      if (!nrow(users)) stop("No active reviewer is available to approve this plan.")
      reviewer_id <- users$user_id[[1]]
    }
    if (is.na(routed_by)) {
      routed_by <- reviewer_id
    }
    existing_review <- DBI::dbGetQuery(
      connection,
      "SELECT review_id FROM review.plan_review WHERE plan_id = $1 ORDER BY review_started_at DESC NULLS LAST, review_id DESC LIMIT 1",
      params = list(plan_id)
    )
    if (nrow(existing_review)) {
      DBI::dbExecute(
        connection,
        "UPDATE review.plan_review SET reviewer_id = $2, review_complete = true, feedback_released_at = COALESCE(feedback_released_at, now()) WHERE review_id = $1",
        params = list(existing_review$review_id[[1]], reviewer_id)
      )
    } else {
      DBI::dbExecute(
        connection,
        "INSERT INTO review.plan_review (plan_id, reviewer_id, review_started_at, feedback_released_at, review_complete) VALUES ($1, $2, now(), now(), true)",
        params = list(plan_id, reviewer_id)
      )
    }
    DBI::dbExecute(
      connection,
      "UPDATE planning.agency_plan SET plan_status = $2, assigned_reviewer = COALESCE(assigned_reviewer, $3), updated_at = now() WHERE plan_id = $1",
      params = list(plan_id, next_status, reviewer_id)
    )
    DBI::dbExecute(
      connection,
      paste(
        "INSERT INTO workflow.plan_status_history (plan_id, changed_by, from_status, to_status, plan_phase, changed_at, notes)",
        "VALUES ($1, $2, $3, $4, 'PerformancePlan', now(), $5)"
      ),
      params = list(plan_id, routed_by, plan$plan_status[[1]], next_status, if (identical(next_status, "Returned")) "Reviewer returned plan to submitter." else paste("Reviewer approved plan and routed to", next_status))
    )
    DBI::dbExecute(
      connection,
      "DELETE FROM workflow.plan_approval_stamp WHERE plan_id = $1 AND approval_stage = 'Reviewer'",
      params = list(plan_id)
    )
    if (!identical(next_status, "Returned")) {
      DBI::dbExecute(
        connection,
        paste(
          "INSERT INTO workflow.plan_approval_stamp (plan_id, approval_stage, approved_by, added_by, approved_at, notes)",
          "VALUES ($1, 'Reviewer', $2, $3, now(), $4)"
        ),
        params = list(plan_id, routed_by, routed_by, paste("Reviewer approval routed to", next_status))
      )
    }
  })
  invisible(plan_id)
}

approve_plan_gate <- function(connection, plan_id, approved_by = NULL) {
  plan_id <- as.integer(plan_id)
  approved_by <- if (is.null(approved_by) || is.na(approved_by)) NA_integer_ else as.integer(approved_by)
  if (is.na(plan_id)) stop("Plan is required.")
  DBI::dbWithTransaction(connection, {
    plan <- DBI::dbGetQuery(
      connection,
      "SELECT plan_id, plan_status FROM planning.agency_plan WHERE plan_id = $1",
      params = list(plan_id)
    )
    if (!nrow(plan)) stop("Plan not found.")
    stage <- switch(
      as.character(plan$plan_status[[1]]),
      DeputyMayorReview = "DeputyMayor",
      CAReview = "CAOffice",
      NA_character_
    )
    next_status <- switch(
      as.character(plan$plan_status[[1]]),
      DeputyMayorReview = "CAReview",
      CAReview = "Approved",
      NA_character_
    )
    if (is.na(stage) || is.na(next_status)) {
      stop("This plan is not waiting for Deputy Mayor or CA Office approval.")
    }
    DBI::dbExecute(
      connection,
      "UPDATE planning.agency_plan SET plan_status = $2, updated_at = now() WHERE plan_id = $1",
      params = list(plan_id, next_status)
    )
    DBI::dbExecute(
      connection,
      "DELETE FROM workflow.plan_approval_stamp WHERE plan_id = $1 AND approval_stage = $2",
      params = list(plan_id, stage)
    )
    DBI::dbExecute(
      connection,
      paste(
        "INSERT INTO workflow.plan_approval_stamp (plan_id, approval_stage, approved_by, added_by, approved_at, notes)",
        "VALUES ($1, $2, $3, $3, now(), $4)"
      ),
      params = list(plan_id, stage, approved_by, paste(stage, "approved plan and routed to", next_status))
    )
    DBI::dbExecute(
      connection,
      paste(
        "INSERT INTO workflow.plan_status_history (plan_id, changed_by, from_status, to_status, plan_phase, changed_at, notes)",
        "VALUES ($1, $2, $3, $4, 'PerformancePlan', now(), $5)"
      ),
      params = list(plan_id, approved_by, plan$plan_status[[1]], next_status, paste(stage, "approval routed plan to", next_status))
    )
  })
  invisible(plan_id)
}

add_plan_approval_stamp <- function(connection, plan_id, approval_stage, added_by = NULL, approved_by = NULL, notes = NULL) {
  plan_id <- as.integer(plan_id)
  added_by <- if (is.null(added_by) || is.na(added_by)) NA_integer_ else as.integer(added_by)
  approved_by <- if (is.null(approved_by) || is.na(approved_by)) added_by else as.integer(approved_by)
  approval_stage <- as.character(approval_stage %||% "")
  valid_stages <- c("Reviewer", "DeputyMayor", "CAOffice")
  if (is.na(plan_id)) stop("Plan is required.")
  if (!approval_stage %in% valid_stages) stop("Choose a valid approval stage.")
  DBI::dbWithTransaction(connection, {
    plan <- DBI::dbGetQuery(connection, "SELECT plan_id FROM planning.agency_plan WHERE plan_id = $1", params = list(plan_id))
    if (!nrow(plan)) stop("Plan not found.")
    DBI::dbExecute(
      connection,
      "DELETE FROM workflow.plan_approval_stamp WHERE plan_id = $1 AND approval_stage = $2",
      params = list(plan_id, approval_stage)
    )
    DBI::dbExecute(
      connection,
      paste(
        "INSERT INTO workflow.plan_approval_stamp (plan_id, approval_stage, approved_by, added_by, approved_at, notes)",
        "VALUES ($1, $2, $3, $4, now(), $5)"
      ),
      params = list(plan_id, approval_stage, approved_by, added_by, as.character(notes %||% ""))
    )
    DBI::dbExecute(
      connection,
      paste(
        "INSERT INTO workflow.plan_status_history (plan_id, changed_by, from_status, to_status, plan_phase, changed_at, notes)",
        "SELECT plan_id, $2, plan_status, plan_status, 'PerformancePlan', now(), $3",
        "FROM planning.agency_plan WHERE plan_id = $1"
      ),
      params = list(plan_id, added_by, paste(approval_stage, "approval stamp added."))
    )
  })
  invisible(plan_id)
}

remove_plan_approval_stamp <- function(connection, plan_id, approval_stage, removed_by = NULL, notes = NULL) {
  plan_id <- as.integer(plan_id)
  removed_by <- if (is.null(removed_by) || is.na(removed_by)) NA_integer_ else as.integer(removed_by)
  approval_stage <- as.character(approval_stage %||% "")
  valid_stages <- c("Reviewer", "DeputyMayor", "CAOffice")
  if (is.na(plan_id)) stop("Plan is required.")
  if (!approval_stage %in% valid_stages) stop("Choose a valid approval stage.")
  DBI::dbWithTransaction(connection, {
    plan <- DBI::dbGetQuery(
      connection,
      "SELECT plan_id, plan_status FROM planning.agency_plan WHERE plan_id = $1",
      params = list(plan_id)
    )
    if (!nrow(plan)) stop("Plan not found.")
    stamp_count <- DBI::dbGetQuery(
      connection,
      paste(
        "SELECT COUNT(*) AS stamp_count FROM workflow.plan_approval_stamp",
        "WHERE plan_id = $1 AND approval_stage = $2"
      ),
      params = list(plan_id, approval_stage)
    )
    if (!nrow(stamp_count) || stamp_count$stamp_count[[1]] < 1) stop("No approval stamp exists for this stage.")
    stages_to_remove <- switch(
      approval_stage,
      Reviewer = c("Reviewer", "DeputyMayor", "CAOffice"),
      DeputyMayor = c("DeputyMayor", "CAOffice"),
      CAOffice = c("CAOffice")
    )
    stage_placeholders <- paste0("$", seq_along(stages_to_remove) + 1L, collapse = ", ")
    DBI::dbExecute(
      connection,
      paste0("DELETE FROM workflow.plan_approval_stamp WHERE plan_id = $1 AND approval_stage IN (", stage_placeholders, ")"),
      params = c(list(plan_id), as.list(stages_to_remove))
    )
    target_status <- switch(
      approval_stage,
      Reviewer = if (plan$plan_status[[1]] %in% c("DeputyMayorReview", "CAReview", "Approved")) "UnderReview" else plan$plan_status[[1]],
      DeputyMayor = if (plan$plan_status[[1]] %in% c("CAReview", "Approved")) "DeputyMayorReview" else plan$plan_status[[1]],
      CAOffice = if (identical(plan$plan_status[[1]], "Approved")) "CAReview" else plan$plan_status[[1]]
    )
    if (!identical(target_status, plan$plan_status[[1]])) {
      DBI::dbExecute(
        connection,
        "UPDATE planning.agency_plan SET plan_status = $2, updated_at = now() WHERE plan_id = $1",
        params = list(plan_id, target_status)
      )
    }
    history_note <- as.character(notes %||% paste(approval_stage, "approval stamp removed."))
    if (length(stages_to_remove) > 1) {
      history_note <- paste0(history_note, " Downstream approval stamps were also removed.")
    }
    if (!identical(target_status, plan$plan_status[[1]])) {
      history_note <- paste0(history_note, " Plan returned to ", target_status, ".")
    }
    DBI::dbExecute(
      connection,
      paste(
        "INSERT INTO workflow.plan_status_history (plan_id, changed_by, from_status, to_status, plan_phase, changed_at, notes)",
        "VALUES ($1, $2, $3, $4, 'PerformancePlan', now(), $5)"
      ),
      params = list(plan_id, removed_by, plan$plan_status[[1]], target_status, history_note)
    )
  })
  invisible(plan_id)
}

route_plan_from_publishing_queue <- function(connection, plan_id, routed_by = NULL, next_status = "UnderReview") {
  plan_id <- as.integer(plan_id)
  routed_by <- if (is.null(routed_by) || is.na(routed_by)) NA_integer_ else as.integer(routed_by)
  next_status <- as.character(next_status %||% "UnderReview")
  valid_next_statuses <- c("Returned", "UnderReview", "DeputyMayorReview", "CAReview")
  if (is.na(plan_id)) stop("Plan is required.")
  if (!next_status %in% valid_next_statuses) stop("Choose a valid route for this plan.")
  DBI::dbWithTransaction(connection, {
    plan <- DBI::dbGetQuery(
      connection,
      "SELECT plan_id, plan_status FROM planning.agency_plan WHERE plan_id = $1",
      params = list(plan_id)
    )
    if (!nrow(plan)) stop("Plan not found.")
    if (!identical(plan$plan_status[[1]], "Approved")) {
      stop("Only plans in the ready-to-publish queue can be routed back.")
    }
    DBI::dbExecute(
      connection,
      "UPDATE planning.agency_plan SET plan_status = $2, updated_at = now() WHERE plan_id = $1",
      params = list(plan_id, next_status)
    )
    stages_to_clear <- switch(
      next_status,
      Returned = c("Reviewer", "DeputyMayor", "CAOffice"),
      UnderReview = c("Reviewer", "DeputyMayor", "CAOffice"),
      DeputyMayorReview = c("DeputyMayor", "CAOffice"),
      CAReview = c("CAOffice"),
      character(0)
    )
    if (length(stages_to_clear)) {
      stage_placeholders <- paste0("$", seq_along(stages_to_clear) + 1L, collapse = ", ")
      DBI::dbExecute(
        connection,
        paste0("DELETE FROM workflow.plan_approval_stamp WHERE plan_id = $1 AND approval_stage IN (", stage_placeholders, ")"),
        params = c(list(plan_id), as.list(stages_to_clear))
      )
    }
    history_note <- paste("System Admin routed ready-to-publish plan back to", next_status)
    if (length(stages_to_clear)) {
      history_note <- paste0(history_note, ". Cleared approval stamps: ", paste(stages_to_clear, collapse = ", "), ".")
    }
    DBI::dbExecute(
      connection,
      paste(
        "INSERT INTO workflow.plan_status_history (plan_id, changed_by, from_status, to_status, plan_phase, changed_at, notes)",
        "VALUES ($1, $2, $3, $4, 'PerformancePlan', now(), $5)"
      ),
      params = list(plan_id, routed_by, plan$plan_status[[1]], next_status, history_note)
    )
  })
  invisible(plan_id)
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

save_team_role_assignment <- function(connection, access_id, agency_id, full_name, email, agency_role, performance_role, budget_access, adaptive_planning, performance_plan_access, service_id = NULL) {
  agency_role_values <- c("Agency Head", "Agency Director", "Chief of Staff", "Fiscal Officer", "Fiscal Staff", "Agency Staff", "Program Staff", "Performance Lead", "Admin")
  performance_role_values <- c("AgencySubmitter", "AgencyWriter", "AgencyApprover", "AgencyViewer", "OPIReviewer", "BBMRReviewer", "DeputyMayor", "CAOffice", "SystemAdmin")
  is_new <- identical(as.character(access_id), "new")
  access_id <- if (is_new) NA_integer_ else as.integer(access_id)
  agency_id <- trimws(as.character(agency_id %||% ""))
  service_id <- trimws(as.character(service_id %||% ""))
  if (!nzchar(service_id)) service_id <- NA_character_
  full_name <- trimws(as.character(full_name %||% ""))
  email <- tolower(trimws(as.character(email %||% "")))
  agency_roles <- if (is.null(agency_role) || length(agency_role) == 0) "" else agency_role
  agency_roles <- unique(trimws(as.character(agency_roles)))
  agency_roles <- agency_roles[nzchar(agency_roles)]
  agency_role <- if (length(agency_roles)) agency_roles[[1]] else ""
  agency_roles_value <- paste(agency_roles, collapse = "||")
  performance_role <- trimws(as.character(performance_role %||% ""))
  if (!nzchar(agency_id)) stop("Agency assignment is required.")
  if (!nzchar(full_name)) stop("Person name is required.")
  if (!nzchar(email) || !grepl("@", email, fixed = TRUE)) stop("A valid email is required.")
  if (!length(agency_roles) || any(!agency_roles %in% agency_role_values)) stop("Choose valid agency roles.")
  if (!performance_role %in% performance_role_values) stop("Choose a valid performance role.")

  DBI::dbWithTransaction(connection, {
    if (is_new) {
      DBI::dbExecute(connection, "SELECT setval(pg_get_serial_sequence('access.\"user\"', 'user_id'), COALESCE((SELECT MAX(user_id) FROM access.\"user\"), 1), (SELECT COUNT(*) > 0 FROM access.\"user\"))")
      DBI::dbExecute(connection, "SELECT setval(pg_get_serial_sequence('access.user_agency_access', 'access_id'), COALESCE((SELECT MAX(access_id) FROM access.user_agency_access), 1), (SELECT COUNT(*) > 0 FROM access.user_agency_access))")
      DBI::dbExecute(connection, "SELECT setval(pg_get_serial_sequence('access.user_role', 'user_role_id'), COALESCE((SELECT MAX(user_role_id) FROM access.user_role), 1), (SELECT COUNT(*) > 0 FROM access.user_role))")
      user <- DBI::dbGetQuery(
        connection,
        paste(
          'INSERT INTO access."user" (email, full_name, auth_type, active)',
          "VALUES ($1, $2, 'MicrosoftAD', true)",
          'ON CONFLICT (email) DO UPDATE SET full_name = EXCLUDED.full_name, active = true',
          "RETURNING user_id"
        ),
        params = list(email, full_name)
      )
      user_id <- user$user_id[[1]]
      access <- DBI::dbGetQuery(
        connection,
        "SELECT access_id, user_id, agency_id, service_id FROM access.user_agency_access WHERE user_id = $1 AND agency_id = $2 AND service_id IS NOT DISTINCT FROM $3::varchar(20) ORDER BY access_id LIMIT 1",
        params = list(user_id, agency_id, service_id)
      )
      if (nrow(access)) {
        access_id <- access$access_id[[1]]
      } else {
        access <- DBI::dbGetQuery(
          connection,
          "INSERT INTO access.user_agency_access (user_id, agency_id, service_id, agency_role, agency_roles, access_level, budget_access, performance_plan_access) VALUES ($1, $2, $4::varchar(20), $3::varchar(30), $5, CASE WHEN $3::text = 'Agency Staff' THEN 'ReadOnly' WHEN $3::text IN ('Agency Head', 'Agency Director') THEN 'Submit' ELSE 'Edit' END, false, true) RETURNING access_id, user_id, agency_id, service_id",
          params = list(user_id, agency_id, agency_role, service_id, agency_roles_value)
        )
        access_id <- access$access_id[[1]]
      }
    } else {
      access <- DBI::dbGetQuery(connection, "SELECT access_id, user_id, agency_id, service_id FROM access.user_agency_access WHERE access_id = $1", params = list(access_id))
      if (!nrow(access)) stop("Team access row not found.")
    }
    user_id <- access$user_id[[1]]
    agency_id <- access$agency_id[[1]]
    DBI::dbExecute(
      connection,
      'UPDATE access."user" SET full_name = $2, email = $3, updated_at = now() WHERE user_id = $1',
      params = list(user_id, full_name, email)
    )
    DBI::dbExecute(
      connection,
      "UPDATE access.user_agency_access SET agency_role = $2::varchar(30), agency_roles = $3, access_level = CASE WHEN $2::text = 'Agency Staff' THEN 'ReadOnly' WHEN $2::text IN ('Agency Head', 'Agency Director') THEN 'Submit' ELSE 'Edit' END WHERE access_id = $1",
      params = list(access_id, agency_role, agency_roles_value)
    )
    existing_role <- DBI::dbGetQuery(
      connection,
      "SELECT user_role_id FROM access.user_role WHERE user_id = $1 AND agency_id IS NOT DISTINCT FROM $2::varchar(20) ORDER BY user_role_id LIMIT 1",
      params = list(user_id, agency_id)
    )
    if (nrow(existing_role)) {
      DBI::dbExecute(
        connection,
        "UPDATE access.user_role SET app_role = $2::varchar(30), budget_access = $3, adaptive_planning = $4, performance_plan_access = $5 WHERE user_role_id = $1",
        params = list(existing_role$user_role_id[[1]], performance_role, isTRUE(budget_access), isTRUE(adaptive_planning), isTRUE(performance_plan_access))
      )
    } else {
      DBI::dbExecute(
        connection,
        "INSERT INTO access.user_role (user_id, app_role, agency_id, budget_access, adaptive_planning, performance_plan_access) VALUES ($1, $2::varchar(30), $3::varchar(20), $4, $5, $6)",
        params = list(user_id, performance_role, agency_id, isTRUE(budget_access), isTRUE(adaptive_planning), isTRUE(performance_plan_access))
      )
    }
  })
  invisible(TRUE)
}

delete_team_role_assignment <- function(connection, access_id, acting_user_id = NULL) {
  access_id <- as.integer(access_id)
  acting_user_id <- suppressWarnings(as.integer(acting_user_id %||% NA_integer_))
  access <- DBI::dbGetQuery(
    connection,
    "SELECT access_id, user_id, agency_id, service_id FROM access.user_agency_access WHERE access_id = $1",
    params = list(access_id)
  )
  if (!nrow(access)) stop("Team access row not found.")
  if (!is.na(acting_user_id) && access$user_id[[1]] == acting_user_id) {
    stop("You cannot delete your own team access row.")
  }
  DBI::dbWithTransaction(connection, {
    DBI::dbExecute(
      connection,
      "DELETE FROM access.user_agency_access WHERE access_id = $1",
      params = list(access_id)
    )
    remaining_access_for_agency <- DBI::dbGetQuery(
      connection,
      "SELECT COUNT(*)::integer AS n FROM access.user_agency_access WHERE user_id = $1 AND agency_id = $2",
      params = list(access$user_id[[1]], access$agency_id[[1]])
    )$n[[1]]
    if (remaining_access_for_agency == 0L) {
      DBI::dbExecute(
        connection,
        "DELETE FROM access.user_role WHERE user_id = $1 AND agency_id IS NOT DISTINCT FROM $2::varchar(20)",
        params = list(access$user_id[[1]], access$agency_id[[1]])
      )
    }
    remaining_access <- DBI::dbGetQuery(
      connection,
      "SELECT (SELECT COUNT(*) FROM access.user_agency_access WHERE user_id = $1) + (SELECT COUNT(*) FROM access.user_role WHERE user_id = $1) AS n",
      params = list(access$user_id[[1]])
    )$n[[1]]
    if (remaining_access == 0) {
      DBI::dbExecute(
        connection,
        'UPDATE access."user" SET active = false, updated_at = now() WHERE user_id = $1',
        params = list(access$user_id[[1]])
      )
    }
  })
  invisible(TRUE)
}

risk_type_values <- c(
  "procurement", "federal funding", "state funding", "city funding",
  "technology", "environmental", "staffing", "legislation", "cross-agency inputs", "other"
)

save_service_risk <- function(connection, risk_id, plan_id, risk_type, description) {
  if (is.null(risk_type) || length(risk_type) == 0 || is.na(risk_type)) risk_type <- ""
  risk_type <- trimws(tolower(as.character(risk_type)))
  if (!nzchar(risk_type) || !risk_type %in% risk_type_values) stop("Risk type is required")
  if (is.null(description) || length(description) == 0 || is.na(description)) description <- ""
  description <- trimws(as.character(description))
  if (!nzchar(description)) stop("Risk description is required")
  if (is.null(risk_id) || is.na(risk_id)) {
    row <- DBI::dbGetQuery(
      connection,
      "INSERT INTO performance.service_risk (plan_id, risk_type, description) VALUES ($1, $2, $3) RETURNING risk_id",
      params = list(as.integer(plan_id), risk_type, description)
    )
    return(row$risk_id[[1]])
  }
  changed <- DBI::dbExecute(
    connection,
    "UPDATE performance.service_risk SET risk_type=$3, description=$4, updated_at=now() WHERE risk_id=$1 AND plan_id=$2",
    params = list(as.integer(risk_id), as.integer(plan_id), risk_type, description)
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
      "VALUES ($1, $2, $3, 'Submitted', 'PerformancePlan', now(), 'Submitted from agency workspace.')"
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

assign_plan_reviewer <- function(connection, plan_id, reviewer_id, modified_by = NULL) {
  plan_id <- as.integer(plan_id)
  reviewer_id <- as.integer(reviewer_id)
  modified_by <- if (is.null(modified_by) || is.na(modified_by)) reviewer_id else as.integer(modified_by)
  if (is.na(plan_id) || is.na(reviewer_id)) stop("Choose a valid reviewer before saving.")

  DBI::dbWithTransaction(connection, {
    plan_rows <- DBI::dbGetQuery(connection, "SELECT plan_id FROM planning.agency_plan WHERE plan_id = $1", params = list(plan_id))
    if (!nrow(plan_rows)) stop("Plan not found.")
    user_rows <- DBI::dbGetQuery(connection, "SELECT user_id FROM access.\"user\" WHERE user_id = $1 AND active", params = list(reviewer_id))
    if (!nrow(user_rows)) stop("Reviewer is not an active user.")
    DBI::dbExecute(
      connection,
      "UPDATE planning.agency_plan SET assigned_reviewer = $2, updated_at = now(), modified_by = $3 WHERE plan_id = $1",
      params = list(plan_id, reviewer_id, modified_by)
    )
    existing_review <- DBI::dbGetQuery(
      connection,
      "SELECT review_id FROM review.plan_review WHERE plan_id = $1 ORDER BY review_started_at DESC NULLS LAST, review_id DESC LIMIT 1",
      params = list(plan_id)
    )
    if (nrow(existing_review)) {
      DBI::dbExecute(
        connection,
        "UPDATE review.plan_review SET reviewer_id = $2, updated_at = now(), modified_by = $3 WHERE review_id = $1",
        params = list(existing_review$review_id[[1]], reviewer_id, modified_by)
      )
    }
  })
  invisible(plan_id)
}

return_plan_from_approval_gate <- function(connection, plan_id, returned_by = NULL, next_status = "UnderReview", return_note = NULL) {
  plan_id <- as.integer(plan_id)
  returned_by <- if (is.null(returned_by) || is.na(returned_by)) NA_integer_ else as.integer(returned_by)
  next_status <- as.character(next_status %||% "UnderReview")
  return_note <- trimws(as.character(return_note %||% ""))
  valid_next_statuses <- c("Returned", "UnderReview", "DeputyMayorReview")
  if (is.na(plan_id)) stop("Plan is required.")
  if (!next_status %in% valid_next_statuses) stop("Choose a valid return destination.")
  if (!nzchar(return_note)) stop("Add a return reason before returning this plan.")
  DBI::dbWithTransaction(connection, {
    plan <- DBI::dbGetQuery(
      connection,
      "SELECT plan_id, plan_status FROM planning.agency_plan WHERE plan_id = $1",
      params = list(plan_id)
    )
    if (!nrow(plan)) stop("Plan not found.")
    if (!plan$plan_status[[1]] %in% c("DeputyMayorReview", "CAReview", "Approved")) {
      stop("Only plans in Deputy Mayor, CA Office, or ready-to-publish review can be returned from this workflow.")
    }
    if (identical(plan$plan_status[[1]], "DeputyMayorReview") && identical(next_status, "DeputyMayorReview")) {
      stop("Deputy Mayor review cannot return a plan to Deputy Mayor review.")
    }
    stages_to_remove <- switch(
      next_status,
      Returned = c("Reviewer", "DeputyMayor", "CAOffice"),
      UnderReview = c("Reviewer", "DeputyMayor", "CAOffice"),
      DeputyMayorReview = c("DeputyMayor", "CAOffice")
    )
    stage_placeholders <- paste0("$", seq_along(stages_to_remove) + 1L, collapse = ", ")
    DBI::dbExecute(
      connection,
      paste0("DELETE FROM workflow.plan_approval_stamp WHERE plan_id = $1 AND approval_stage IN (", stage_placeholders, ")"),
      params = c(list(plan_id), as.list(stages_to_remove))
    )
    DBI::dbExecute(
      connection,
      "UPDATE planning.agency_plan SET plan_status = $2, updated_at = now() WHERE plan_id = $1",
      params = list(plan_id, next_status)
    )
    DBI::dbExecute(
      connection,
      paste(
        "INSERT INTO workflow.plan_status_history (plan_id, changed_by, from_status, to_status, plan_phase, changed_at, notes)",
        "VALUES ($1, $2, $3, $4, 'PerformancePlan', now(), $5)"
      ),
      params = list(plan_id, returned_by, plan$plan_status[[1]], next_status, paste("Returned from approval workflow:", return_note))
    )
  })
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

publish_agency_plan <- function(connection, plan_id, published_by = NULL) {
  plan_id <- as.integer(plan_id)
  published_by <- if (is.null(published_by) || is.na(published_by)) NA_integer_ else as.integer(published_by)
  if (is.na(published_by)) {
    users <- DBI::dbGetQuery(connection, "SELECT user_id FROM access.\"user\" ORDER BY user_id LIMIT 1")
    if (!nrow(users)) stop("No user is available to publish this plan.")
    published_by <- users$user_id[[1]]
  }
  DBI::dbWithTransaction(connection, {
    plan <- DBI::dbGetQuery(
      connection,
      "SELECT plan_id, plan_status FROM planning.agency_plan WHERE plan_id = $1",
      params = list(plan_id)
    )
    if (!nrow(plan)) stop("Plan not found.")
    if (!identical(plan$plan_status[[1]], "Approved")) {
      stop("Only plans in the ready-to-publish queue can be published.")
    }
    apply_plan_drafts_to_records(connection, plan_id)
    DBI::dbExecute(
      connection,
      "UPDATE planning.agency_plan SET plan_status = 'Published', approved_at = COALESCE(approved_at, now()), updated_at = now() WHERE plan_id = $1",
      params = list(plan_id)
    )
    DBI::dbExecute(
      connection,
      paste(
        "INSERT INTO workflow.plan_status_history (plan_id, changed_by, from_status, to_status, plan_phase, changed_at, notes)",
        "VALUES ($1, $2, $3, 'Published', 'PerformancePlan', now(), 'Approved payload promoted to plan records and published.')"
      ),
      params = list(plan_id, published_by, plan$plan_status[[1]])
    )
    DBI::dbExecute(connection, "DELETE FROM planning.plan_section_draft WHERE plan_id = $1", params = list(plan_id))
  })
  invisible(plan_id)
}
