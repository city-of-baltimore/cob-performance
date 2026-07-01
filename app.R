library(shiny)
library(DBI)
library(RPostgres)

source(file.path("R", "database.R"), local = TRUE)

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0 || is.na(x)) y else x


pages <- list(
  login = "Login",
  landing = "Cycle home",
  reviewer_dashboard = "Plan review",
  measure_review = "Measure review",
  strategic_plan = "City action plan",
  team = "Performance team",
  plan_history = "Plan history & status",
  metrics = "Measures review",
  overview = "Agency overview",
  goals = "Agency goals",
  services = "Agency services",
  risks = "Plan risks"
)

risk_type_choices <- c(
  "Procurement" = "procurement",
  "Federal funding" = "federal funding",
  "State funding" = "state funding",
  "City funding" = "city funding",
  "Technology" = "technology",
  "Environmental" = "environmental",
  "Staffing" = "staffing",
  "Legislation" = "legislation",
  "Cross-agency inputs" = "cross-agency inputs",
  "Other" = "other"
)

agency_role_choices <- c(
  "Agency Head",
  "Agency Director",
  "Chief of Staff",
  "Fiscal Officer",
  "Fiscal Staff",
  "Agency Staff",
  "Program Staff",
  "Performance Lead",
  "Admin"
)

performance_role_choices <- c(
  "AgencySubmitter",
  "AgencyWriter",
  "AgencyApprover",
  "AgencyViewer",
  "OPIReviewer",
  "BBMRReviewer",
  "DeputyMayor",
  "CAOffice",
  "SystemAdmin"
)

risk_type_label <- function(value) {
  labels <- names(risk_type_choices)
  match_index <- match(value, unname(risk_type_choices))
  ifelse(is.na(match_index), "Uncategorized", labels[match_index])
}

status_tone <- function(status) {
  switch(
    as.character(status),
    Approved = "success",
    Published = "success",
    Submitted = "primary",
    UnderReview = "primary",
    DeputyMayorReview = "primary",
    CAReview = "primary",
    FeedbackReturned = "warning",
    Returned = "warning",
    DirectorSignOff = "warning",
    Draft = "warning",
    Drafting = "warning",
    Amended = "warning",
    "primary"
  )
}

format_status <- function(status) {
  gsub("([a-z])([A-Z])", "\\1 \\2", status)
}

agency_plan_status <- function(status) {
  switch(
    as.character(status),
    Draft = "Drafting",
    AgencyRevised = "Drafting",
    FeedbackReturned = "Returned",
    Returned = "Returned",
    UnderReview = "Under review",
    DirectorSignOff = "Under review",
    DeputyMayorReview = "Under review",
    CAReview = "Under review",
    Approved = "Approved",
    Published = "Published",
    Submitted = "Submitted",
    Amended = "Published",
    format_status(status)
  )
}

format_measure_value <- function(value, format_type, display_unit = NA, missing_label = "Not reported") {
  if (is.na(value)) {
    return(missing_label)
  }
  formatted <- switch(
    format_type,
    Percent = paste0(value, "%"),
    Currency = paste0("$", format(value, big.mark = ",", trim = TRUE)),
    Count = format(value, big.mark = ",", trim = TRUE),
    Days = paste(value, "days"),
    Decimal = as.character(value),
    Rate = as.character(value),
    Score = as.character(value),
    as.character(value)
  )
  if (!is.na(display_unit) && !format_type %in% c("Percent", "Days")) {
    formatted <- paste(formatted, display_unit)
  }
  formatted
}

fiscal_measure_snapshot_years <- function(today = Sys.Date()) {
  calendar_year <- as.integer(format(today, "%Y"))
  fiscal_year_start <- as.Date(sprintf("%s-07-01", calendar_year))
  last_completed_fy <- if (today >= fiscal_year_start) calendar_year else calendar_year - 1L
  list(actual_fy = last_completed_fy, target_fy = last_completed_fy + 1L)
}

measure_entry_years <- function() {
  2022:2028
}

parse_submitter_value <- function(value) {
  value <- as.character(value %||% "agency:AGC2600")
  if (grepl("^entity:", value)) {
    return(list(type = "entity", id = suppressWarnings(as.integer(sub("^entity:", "", value)))))
  }
  list(type = "agency", id = sub("^agency:", "", value))
}

submitter_value_for_plan <- function(plan) {
  if (is.null(plan) || !nrow(plan)) {
    return(NA_character_)
  }
  if (!is.null(plan) && nrow(plan) && !is.na(plan$entity_id[[1]])) {
    return(paste0("entity:", plan$entity_id[[1]]))
  }
  paste0("agency:", plan$agency_id[[1]])
}

current_plan <- function(db, submitter_value) {
  submitter <- parse_submitter_value(submitter_value)
  if (identical(submitter$type, "entity")) {
    plan <- db$planning_agency_plan[!is.na(db$planning_agency_plan$entity_id) & db$planning_agency_plan$entity_id == submitter$id & db$planning_agency_plan$fiscal_year == 2027, , drop = FALSE]
  } else {
    plan <- db$planning_agency_plan[!is.na(db$planning_agency_plan$agency_id) & db$planning_agency_plan$agency_id == submitter$id & db$planning_agency_plan$fiscal_year == 2027, , drop = FALSE]
  }
  if (nrow(plan) == 0) {
    return(NULL)
  }
  plan[1, , drop = FALSE]
}

submitter_is_mayoral_service <- function(db, submitter_value) {
  submitter <- parse_submitter_value(submitter_value)
  if (!identical(submitter$type, "entity")) return(FALSE)
  entity <- db$reference_plan_entity[db$reference_plan_entity$entity_id == submitter$id, , drop = FALSE]
  nrow(entity) > 0 && identical(entity$entity_type[[1]], "MayoraltyOffice")
}

plan_is_entity_submitter <- function(plan) {
  !is.null(plan) && nrow(plan) && !is.na(plan$entity_id[[1]])
}

goal_minimum_count <- function(plan) {
  if (plan_is_entity_submitter(plan)) 2L else 3L
}

goal_maximum_count <- function(plan) {
  if (plan_is_entity_submitter(plan)) 4L else 5L
}

goal_count_word <- function(value) {
  words <- c("zero", "one", "two", "three", "four", "five")
  if (!is.na(value) && value >= 0 && value <= 5) words[[value + 1L]] else as.character(value)
}

agency_name <- function(db, agency_id) {
  agency <- db$reference_agency[db$reference_agency$agency_id == agency_id, , drop = FALSE]
  if (!nrow(agency)) return("Agency")
  if (!is.na(agency$public_name[1]) && nzchar(trimws(agency$public_name[1]))) agency$public_name[1] else agency$agency_name[1]
}

plan_display_name <- function(db, plan) {
  if (is.null(plan) || !nrow(plan)) return("Plan submitter")
  if (!is.na(plan$entity_id[[1]])) {
    entity <- db$reference_plan_entity[db$reference_plan_entity$entity_id == plan$entity_id[[1]], , drop = FALSE]
    if (nrow(entity)) return(entity$public_name[[1]])
    return("Plan entity")
  }
  agency_name(db, plan$agency_id[[1]])
}

plan_accounting_agency_id <- function(db, plan) {
  if (is.null(plan) || !nrow(plan)) return(NA_character_)
  if (!is.na(plan$agency_id[[1]])) return(plan$agency_id[[1]])
  entity <- db$reference_plan_entity[db$reference_plan_entity$entity_id == plan$entity_id[[1]], , drop = FALSE]
  if (nrow(entity)) entity$parent_agency_id[[1]] else NA_character_
}

plan_service_rows <- function(db, plan) {
  if (is.null(plan) || !nrow(plan)) return(db$reference_service[0, , drop = FALSE])
  if (is.na(plan$plan_id[[1]])) return(db$reference_service[0, , drop = FALSE])
  plan_services <- db$performance_plan_service[db$performance_plan_service$plan_id == plan$plan_id[[1]], , drop = FALSE]
  service_rows <- merge(plan_services, db$reference_service, by = "service_id", all.x = TRUE)
  if ("performance_measure_entity_link" %in% names(db) && nrow(db$performance_measure_entity_link)) {
    assigned_service_ids <- character(0)
    if (!is.na(plan$entity_id[[1]])) {
      assigned_service_ids <- unique(db$performance_measure_entity_link$service_id[
        !is.na(db$performance_measure_entity_link$entity_id) &
          db$performance_measure_entity_link$entity_id == plan$entity_id[[1]]
      ])
    } else {
      assigned_service_ids <- unique(db$performance_measure_entity_link$service_id[
        db$performance_measure_entity_link$agency_id == plan$agency_id[[1]] &
          db$performance_measure_entity_link$entity_type == "service"
      ])
    }
    assigned_service_ids <- assigned_service_ids[!is.na(assigned_service_ids)]
    missing_service_ids <- setdiff(assigned_service_ids, service_rows$service_id)
    if (length(missing_service_ids)) {
      extra_services <- db$reference_service[db$reference_service$service_id %in% missing_service_ids, , drop = FALSE]
      if (nrow(extra_services)) {
        extra_services$plan_service_id <- NA_integer_
        extra_services$plan_id <- plan$plan_id[[1]]
        extra_services$sort_order <- seq_len(nrow(extra_services)) + ifelse(nrow(service_rows), max(service_rows$sort_order, na.rm = TRUE), 0)
        service_rows <- rbind(service_rows[, names(extra_services), drop = FALSE], extra_services)
      }
    }
  }
  if (!nrow(service_rows)) return(service_rows)
  if (!is.na(plan$entity_id[[1]])) {
    pes <- db$reference_plan_entity_service[db$reference_plan_entity_service$entity_id == plan$entity_id[[1]], , drop = FALSE]
    service_rows <- merge(service_rows, pes[, c("service_id", "is_primary"), drop = FALSE], by = "service_id", all.x = TRUE)
    service_rows$is_primary[is.na(service_rows$is_primary)] <- FALSE
    service_rows <- service_rows[service_rows$active, , drop = FALSE]
    service_rows <- service_rows[order(-as.integer(service_rows$is_primary), service_rows$sort_order, service_rows$service_name), , drop = FALSE]
  } else {
    entity_service_ids <- character(0)
    if ("reference_plan_entity_service" %in% names(db) && "reference_plan_entity" %in% names(db)) {
      child_entities <- db$reference_plan_entity[
        db$reference_plan_entity$parent_agency_id == plan$agency_id[[1]] &
          db$reference_plan_entity$has_own_plan &
          db$reference_plan_entity$active,
        ,
        drop = FALSE
      ]
      if (nrow(child_entities)) {
        entity_service_ids <- unique(db$reference_plan_entity_service$service_id[
          db$reference_plan_entity_service$entity_id %in% child_entities$entity_id
        ])
      }
    }
    service_rows <- service_rows[service_rows$active & service_rows$service_type == "Performance", , drop = FALSE]
    service_rows <- service_rows[!service_rows$service_id %in% entity_service_ids, , drop = FALSE]
    service_rows <- service_rows[order(service_rows$service_name), , drop = FALSE]
  }
  service_rows
}

plan_measure_rows <- function(db, plan, include_ineligible = FALSE) {
  if (is.null(plan) || !nrow(plan)) return(db$performance_performance_measure[0, , drop = FALSE])
  if (is.na(plan$plan_id[[1]])) return(db$performance_performance_measure[0, , drop = FALSE])
  services <- plan_service_rows(db, plan)
  if (!nrow(services)) return(db$performance_performance_measure[0, , drop = FALSE])
  if ("performance_measure_entity_link" %in% names(db) && nrow(db$performance_measure_entity_link)) {
    entity_links <- db$performance_measure_entity_link
    if (!is.na(plan$entity_id[[1]])) {
      entity_links <- entity_links[!is.na(entity_links$entity_id) & entity_links$entity_id == plan$entity_id[[1]], , drop = FALSE]
    } else {
      entity_links <- entity_links[
        entity_links$agency_id == plan$agency_id[[1]] &
          entity_links$entity_type == "service" &
          entity_links$service_id %in% services$service_id,
        ,
        drop = FALSE
      ]
    }
    measure_ids <- unique(entity_links$measure_id)
  } else {
    link_table <- if (include_ineligible && "performance_pm_service_link_all" %in% names(db)) db$performance_pm_service_link_all else db$performance_pm_service_link
    measure_ids <- unique(link_table$measure_id[link_table$service_id %in% services$service_id])
  }
  rows <- db$performance_performance_measure[db$performance_performance_measure$measure_id %in% measure_ids, , drop = FALSE]
  if (!include_ineligible && nrow(rows)) {
    approval_status <- ifelse(is.na(rows$approval_status), "", rows$approval_status)
    change_mapping <- ifelse(is.na(rows$change_mapping), "", rows$change_mapping)
    rows <- rows[
      rows$fiscal_year == 2027 &
        rows$active &
        approval_status != "Deprecated" &
        !(change_mapping %in% c("Removed", "Replaced")),
      ,
      drop = FALSE
    ]
  }
  rows[order(rows$title), , drop = FALSE]
}

measure_library_rows <- function(db, plan, include_ineligible = FALSE) {
  if (is.null(plan) || !nrow(plan)) return(db$performance_performance_measure[0, , drop = FALSE])
  if ("performance_measure_entity_link" %in% names(db) && nrow(db$performance_measure_entity_link)) {
    if (include_ineligible && is.na(plan$entity_id[[1]])) {
      library_links <- db$performance_measure_entity_link[
        db$performance_measure_entity_link$agency_id == plan$agency_id[[1]] &
          db$performance_measure_entity_link$entity_type == "service",
        ,
        drop = FALSE
      ]
      if (nrow(library_links)) {
        rows <- db$performance_performance_measure[
          db$performance_performance_measure$measure_id %in% unique(library_links$measure_id),
          ,
          drop = FALSE
        ]
        return(rows[order(rows$title), , drop = FALSE])
      }
    }
    linked_rows <- plan_measure_rows(db, plan, include_ineligible = include_ineligible)
    if (nrow(linked_rows) || !include_ineligible || !is.na(plan$entity_id[[1]])) {
      return(linked_rows[order(linked_rows$title), , drop = FALSE])
    }
  }
  agency_id <- plan_accounting_agency_id(db, plan)
  rows <- db$performance_performance_measure[db$performance_performance_measure$agency_id == agency_id, , drop = FALSE]
  if (!include_ineligible && nrow(rows)) {
    approval_status <- ifelse(is.na(rows$approval_status), "", rows$approval_status)
    change_mapping <- ifelse(is.na(rows$change_mapping), "", rows$change_mapping)
    rows <- rows[
      rows$fiscal_year == 2027 &
        rows$active &
        approval_status != "Deprecated" &
        !(change_mapping %in% c("Removed", "Replaced")),
      ,
      drop = FALSE
    ]
  }
  rows[order(rows$title), , drop = FALSE]
}

service_metric_ids <- function(db, plan, service_id, measures = NULL, include_ineligible = FALSE) {
  if ("performance_measure_entity_link" %in% names(db) && nrow(db$performance_measure_entity_link)) {
    entity_links <- db$performance_measure_entity_link[db$performance_measure_entity_link$service_id == service_id, , drop = FALSE]
    if (!is.null(plan) && nrow(plan)) {
      if (!is.na(plan$entity_id[[1]])) {
        entity_links <- entity_links[!is.na(entity_links$entity_id) & entity_links$entity_id == plan$entity_id[[1]], , drop = FALSE]
      } else {
        entity_links <- entity_links[
          entity_links$agency_id == plan$agency_id[[1]] & entity_links$entity_type == "service",
          ,
          drop = FALSE
        ]
      }
    }
    linked_ids <- unique(entity_links$measure_id)
  } else {
    link_table <- if (include_ineligible && "performance_pm_service_link_all" %in% names(db)) db$performance_pm_service_link_all else db$performance_pm_service_link
    linked_ids <- unique(link_table$measure_id[link_table$service_id == service_id])
  }
  linked_ids <- linked_ids[!is.na(linked_ids)]
  if (!include_ineligible && length(linked_ids)) {
    eligible_ids <- plan_measure_rows(db, plan, include_ineligible = FALSE)$measure_id
    linked_ids <- linked_ids[linked_ids %in% eligible_ids]
  }
  linked_ids
}

performance_planning_timeline <- function() {
  data.frame(
    start_date = as.Date(c("2026-06-30", "2026-07-01", "2026-07-06", "2026-08-05", "2026-08-05", "2026-08-26")),
    end_date = as.Date(c("2026-06-30", "2026-08-05", "2026-07-17", "2026-08-12", "2026-09-04", "2026-09-30")),
    date_label = c(
      "June 30",
      "July 1 - August 5",
      "July 6 - July 17",
      "Upon submission - August 12",
      "August 5 - September 4",
      "August 26 - September 30"
    ),
    milestone = c(
      "Agency Performance Plan Guidance is Released and Application Open",
      "Agencies submit first draft and set up individual meetings with their assigned analyst for in-depth support.",
      "Training",
      "First drafts scored by analyst using in-application rubric.",
      "Identified agencies present their Performance Plan. Presentations are due three business days prior.",
      "Mayoralty Agency Performance Plans approved by approval chain, including OPI, BBMR, Deputy Mayor, and City Administrator's Office."
    ),
    stringsAsFactors = FALSE
  )
}

timeline_home_items <- function(today = Sys.Date()) {
  timeline <- performance_planning_timeline()
  current_rows <- timeline[timeline$start_date <= today & timeline$end_date >= today, , drop = FALSE]
  if (nrow(current_rows)) {
    current <- current_rows[order(current_rows$end_date, current_rows$start_date), , drop = FALSE][1, , drop = FALSE]
  } else {
    current <- timeline[timeline$start_date == min(timeline$start_date[timeline$start_date > today]), , drop = FALSE][1, , drop = FALSE]
  }
  completed <- timeline[timeline$end_date < today, , drop = FALSE]
  last <- if (nrow(completed)) completed[order(completed$end_date, decreasing = TRUE), , drop = FALSE][1, , drop = FALSE] else timeline[0, , drop = FALSE]
  upcoming <- timeline[timeline$start_date > today, , drop = FALSE]
  upcoming <- upcoming[order(upcoming$start_date, upcoming$end_date), , drop = FALSE]
  upcoming <- upcoming[seq_len(min(2, nrow(upcoming))), , drop = FALSE]
  rbind(
    cbind(status = "Last step", last),
    cbind(status = "Current step", current),
    cbind(status = c("Next step", "Following step")[seq_len(nrow(upcoming))], upcoming)
  )
}

timeline_step_card <- function(row) {
  div(
    class = paste("timeline-step-card", tolower(gsub(" ", "-", row$status[[1]]))),
    div(class = "eyebrow", row$status[[1]]),
    h3(row$milestone[[1]]),
    div(class = "timeline-date", row$date_label[[1]])
  )
}

snapshot_check_row <- function(label, detail, complete = FALSE) {
  div(
    class = "snapshot-check-row",
    span(class = paste("snapshot-check-icon", if (complete) "complete" else "missing"), `aria-hidden` = "true"),
    div(strong(label), span(detail))
  )
}

nonblank_text <- function(value) {
  !is.null(value) && length(value) > 0 && !is.na(value) && nzchar(trimws(as.character(value)))
}

goal_draft_readiness <- function(db, plan, goals) {
  if (is.null(plan) || !nrow(plan) || !nrow(goals)) {
    return(list(complete_count = 0L, aligned_count = 0L))
  }
  goals_draft <- if (plan_uses_draft_payload(plan)) section_draft_payload(db, plan$plan_id[[1]], "goals") else NULL
  complete <- 0L
  aligned <- 0L
  for (i in seq_len(nrow(goals))) {
    goal_id <- as.character(goals$agency_goal_id[[i]])
    statement <- draft_value(goals_draft, paste0("goal_statement_", goal_id), goals$title[[i]])
    initiative_values <- if (!is.null(goals_draft) && !is.null(goals_draft$initiatives[[goal_id]])) {
      as.character(unlist(goals_draft$initiatives[[goal_id]]))
    } else {
      initiative_links <- db$performance_agency_goal_initiative_link[db$performance_agency_goal_initiative_link$agency_goal_id == goals$agency_goal_id[[i]], , drop = FALSE]
      db$performance_initiative$title[match(initiative_links$initiative_id, db$performance_initiative$initiative_id)]
    }
    kpi_values <- if (!is.null(goals_draft) && !is.null(goals_draft$kpis[[goal_id]])) {
      as.character(unlist(goals_draft$kpis[[goal_id]]))
    } else {
      measure_links <- db$performance_pm_goal_link[db$performance_pm_goal_link$agency_goal_id == goals$agency_goal_id[[i]], , drop = FALSE]
      as.character(measure_links$measure_id)
    }
    fallback_alignment <- if ("alignment_code" %in% names(goals) && !is.na(goals$alignment_code[[i]])) goals$alignment_code[[i]] else ""
    alignment <- draft_value(goals_draft, paste0("goal_alignment_", goal_id), fallback_alignment)
    has_initiative <- any(nzchar(trimws(initiative_values[!is.na(initiative_values)])))
    has_kpi <- any(nzchar(trimws(kpi_values[!is.na(kpi_values)])))
    if (nonblank_text(statement) && has_initiative && has_kpi) complete <- complete + 1L
    if (nonblank_text(alignment)) aligned <- aligned + 1L
  }
  list(complete_count = complete, aligned_count = aligned)
}

selected_context <- function(db, submitter_value) {
  plan <- current_plan(db, submitter_value)
  agency_id <- plan_accounting_agency_id(db, plan)
  agency <- db$reference_agency[db$reference_agency$agency_id == agency_id, , drop = FALSE]
  header <- if (is.null(plan) || !nrow(plan)) data.frame() else db$performance_plan_header[db$performance_plan_header$plan_id == plan$plan_id, , drop = FALSE]
  list(agency = agency, plan = plan, header = header, display_name = plan_display_name(db, plan), accounting_agency_id = agency_id)
}


nav_item <- function(id, label, icon_tag, section = NULL, item_class = NULL) {
  tags$button(
    type = "button",
    class = paste("nav-item", if (!is.null(section)) "nav-subitem" else "", item_class %||% ""),
    `data-page` = id,
    `aria-label` = label,
    span(class = "nav-icon", `aria-hidden` = "true", icon_tag),
    span(class = "nav-label", label)
  )
}

status_chip <- function(label, tone = "primary") {
  span(class = paste("status-chip", paste0("tone-", tone)), label)
}

metric_tile <- function(label, value, detail = NULL, tone = NULL) {
  div(
    class = paste("metric-tile", if (!is.null(tone)) paste0("tone-", tone) else ""),
    div(class = "metric-label", label),
    div(class = "metric-value", value),
    if (!is.null(detail)) div(class = "metric-detail", detail)
  )
}

action_plan_stat <- function(value, label) {
  div(
    class = "metric-tile action-plan-stat",
    div(class = "metric-value", value),
    div(class = "metric-label", label)
  )
}

deadline_item <- function(date, title, detail, tone = "primary") {
  div(
    class = "deadline-item",
    div(class = paste("deadline-date", paste0("tone-", tone)), date),
    div(
      class = "deadline-copy",
      tags$strong(title),
      span(detail)
    )
  )
}

surface <- function(title, description = NULL, ..., actions = NULL) {
  tags$section(
    class = "section-surface",
    div(
      class = "surface-header",
      div(
        h2(title),
        if (!is.null(description)) p(description)
      ),
      if (!is.null(actions)) div(class = "surface-actions", actions)
    ),
    ...
  )
}

pillar_by_id <- function(strategic_plan, pillar_id) {
  for (pillar in strategic_plan) {
    if (pillar$id == pillar_id) {
      return(pillar)
    }
  }
  NULL
}

metric_number <- function(value, unit = NULL) {
  if (is.null(unit)) {
    return(format(value, big.mark = ",", trim = TRUE))
  }
  if (unit == "$") {
    return(paste0("$", format(value, big.mark = ",", trim = TRUE)))
  }
  if (unit == "%") {
    return(paste0(value, "%"))
  }
  paste(format(value, big.mark = ",", trim = TRUE), unit)
}

metric_visual <- function(metric) {
  unit <- metric$unit
  max_value <- max(metric$current, metric$target, na.rm = TRUE)
  current_width <- max(3, round(metric$current / max_value * 100))
  target_position <- min(100, max(3, round(metric$target / max_value * 100)))
  current_label_position <- min(96, max(4, current_width))
  target_label_position <- min(96, max(4, target_position))

  div(
    class = "metric-viz",
    div(
      class = "metric-viz-header",
      tags$strong(metric$name),
      status_chip(metric$direction, "success")
    ),
    div(
      class = "metric-single-bar",
      div(
        class = "metric-bar-track",
        role = "img",
        `aria-label` = paste("Current", metric_number(metric$current, unit), "target", metric_number(metric$target, unit)),
        div(class = "metric-bar current", style = paste0("width: ", current_width, "%;")),
        div(class = "target-marker", style = paste0("left: ", target_position, "%;"))
      ),
      span(class = "metric-bar-value current-value", style = paste0("left: ", current_label_position, "%;"), metric_number(metric$current, unit)),
      span(class = "metric-bar-value target-value", style = paste0("left: ", target_label_position, "%;"), metric_number(metric$target, unit))
    )
  )
}

goal_panel <- function(goal) {
  div(
    class = "goal-detail",
    div(
      class = "goal-detail-header",
      status_chip(paste("Goal", goal$code), "primary"),
      h3(goal$title)
    ),
    p(paste("Goal Lead:", goal$lead)),
    tags$ul(
      class = "initiative-list",
      lapply(seq_along(goal$initiatives), function(index) {
        tags$li(tags$strong(paste0(goal$code, ".", index, " ")), goal$initiatives[[index]])
      })
    )
  )
}

pillar_services <- function(db, pillar_id) {
  services <- db$reference_service
  agencies <- db$reference_agency
  if (nrow(services) == 0 || nrow(agencies) == 0) {
    return(data.frame())
  }
  services <- services[!is.na(services$pillar_id) & services$pillar_id == pillar_id, , drop = FALSE]
  merge(services, agencies, by = "agency_id", all.x = TRUE)
}

pillar_entities <- function(db, service_ids) {
  links <- db$reference_plan_entity_service
  entities <- db$reference_plan_entity
  if (nrow(links) == 0 || nrow(entities) == 0 || length(service_ids) == 0) {
    return(data.frame())
  }
  links <- links[links$service_id %in% service_ids, , drop = FALSE]
  merge(links, entities, by = "entity_id", all.x = TRUE)
}

service_hierarchy <- function(service_rows) {
  if (nrow(service_rows) == 0) {
    return(div(class = "service-hierarchy-empty", "No services are aligned to this pillar."))
  }

  service_rows$deputy_mayor_pillar[is.na(service_rows$deputy_mayor_pillar) | service_rows$deputy_mayor_pillar == ""] <- "Unassigned portfolio"
  service_rows$agency_name[is.na(service_rows$agency_name) | service_rows$agency_name == ""] <- "Unassigned agency"
  service_rows <- unique(service_rows[, c("deputy_mayor_pillar", "agency_name", "service_name"), drop = FALSE])
  service_rows <- service_rows[order(service_rows$deputy_mayor_pillar, service_rows$agency_name, service_rows$service_name), , drop = FALSE]

  portfolios <- unique(service_rows$deputy_mayor_pillar)
  div(
    class = "service-hierarchy",
    `aria-label` = "Services grouped by deputy mayor portfolio and agency",
    lapply(portfolios, function(portfolio) {
      portfolio_rows <- service_rows[service_rows$deputy_mayor_pillar == portfolio, , drop = FALSE]
      agencies <- unique(portfolio_rows$agency_name)
      tags$details(
        class = "deputy-service-group",
        open = "open",
        tags$summary(
          span(class = "hierarchy-title", portfolio),
          span(class = "hierarchy-count", paste(length(agencies), if (length(agencies) == 1) "agency" else "agencies", "|", nrow(portfolio_rows), "services"))
        ),
        div(
          class = "agency-service-list",
          lapply(agencies, function(agency) {
            agency_rows <- portfolio_rows[portfolio_rows$agency_name == agency, , drop = FALSE]
            tags$details(
              class = "agency-service-group",
              open = "open",
              tags$summary(
                span(class = "hierarchy-title", agency),
                span(class = "hierarchy-count", paste(nrow(agency_rows), if (nrow(agency_rows) == 1) "service" else "services"))
              ),
              tags$ul(
                class = "hierarchy-service-list",
                lapply(agency_rows$service_name, tags$li)
              )
            )
          })
        )
      )
    })
  )
}

pillar_modal <- function(pillar_id, db) {
  pillar <- pillar_by_id(db$strategic_plan, pillar_id)
  service_rows <- pillar_services(db, pillar_id)
  service_rows <- service_rows[order(service_rows$agency_name, service_rows$service_name), , drop = FALSE]
  entity_rows <- pillar_entities(db, unique(service_rows$service_id))

  div(
    class = "custom-modal-backdrop",
    `data-close-input` = "close_pillar_modal",
    div(
      class = "custom-modal",
      div(
        class = "custom-modal-header",
        h2(paste0("Pillar ", pillar$id, ": ", pillar$title)),
        actionButton("close_pillar_modal", "Close", class = "civic-button secondary small")
      ),
      div(
        class = "modal-section-stack",
        tags$section(
          class = "modal-section-block",
          h3("Overview"),
          p(class = "pillar-overview-copy", pillar$overview),
          div(class = "modal-fact-grid",
              metric_tile("Pillar lead", pillar$lead, pillar$lead_name),
              metric_tile("Goals", length(pillar$goals)),
              metric_tile("Strategies", sum(vapply(pillar$goals, function(goal) length(goal$initiatives), integer(1)))),
              metric_tile("Services", nrow(service_rows)))
        ),
        tags$section(
          class = "modal-section-block",
          h3("Goals & Strategies"),
          div(class = "goal-list", lapply(pillar$goals, goal_panel))
        ),
        tags$section(
          class = "modal-section-block",
          h3("Performance Measures"),
          p("These are Action Plan performance measures with seeded baseline, current, and target values."),
          div(class = "metric-viz-list", lapply(pillar$metrics, metric_visual))
        ),
        tags$section(
          class = "modal-section-block",
          h3("Agencies & Services"),
          service_hierarchy(service_rows),
          if (nrow(entity_rows) > 0) {
            div(
              class = "entity-list",
              h3("Plan entities"),
              div(
                class = "chip-row",
                lapply(seq_len(nrow(entity_rows)), function(i) status_chip(entity_rows$public_name[i], "primary"))
              )
            )
          }
        )
      )
    )
  )
}

page_login <- function() {
  div(
    class = "login-page",
    div(
      class = "login-panel",
      div(
        class = "brand-lockup brand-large",
        tags$img(class = "brand-mark", src = "baltimore-city-logo.png", alt = "City of Baltimore logo"),
        div(
          div(class = "brand-product", "B.O.B."),
          div(class = "brand-subtitle", "Baltimore Outcome Budgeting")
        )
      ),
      h1("Sign in to continue"),
      p("Choose the workspace that matches your role. Authentication and role assignment will connect to Microsoft Entra in the next workflow pass."),
      div(
        class = "login-workspace-grid",
        div(
          class = "login-workspace-card",
          actionButton("login_agency", "Agency", class = "civic-button primary")
        ),
        div(
          class = "login-workspace-card",
          actionButton("login_agency_director", "Agency Director", class = "civic-button primary")
        ),
        div(
          class = "login-workspace-card",
          actionButton("login_reviewer", "Admin", class = "civic-button secondary")
        )
      ),
      div(class = "support-note", "Need access? Contact performance@baltimorecity.gov.")
    )
  )
}

page_reviewer_dashboard <- function(db) {
  plans <- db$planning_agency_plan
  plans <- plans[order(plans$fiscal_year, plans$updated_at, decreasing = TRUE), , drop = FALSE]
  agency_lookup <- db$reference_agency[, c("agency_id", "agency_name", "deputy_mayor_pillar"), drop = FALSE]
  reviewer_lookup <- unique(db$review_plan_review[, c("plan_id", "reviewer_name", "overall_score", "review_complete"), drop = FALSE])
  joined <- merge(plans, agency_lookup, by = "agency_id", all.x = TRUE)
  joined <- merge(joined, reviewer_lookup, by = "plan_id", all.x = TRUE)
  measure_queue <- if ("performance_performance_measure" %in% names(db)) {
    db$performance_performance_measure[db$performance_performance_measure$approval_status == "PendingApproval", , drop = FALSE]
  } else {
    data.frame()
  }
  tagList(
    div(
      class = "briefing-header compact",
      div(
        div(class = "eyebrow", "Reviewer front end"),
        h1("Reviewer Workspace"),
        p("Review plan submissions across agencies, monitor returned plans, and prepare rubric-based feedback.")
      ),
      status_chip("Reviewer workspace", "primary")
    ),
    div(
      class = "dashboard-grid reviewer-dashboard-grid",
      metric_tile("Plans in queue", sum(joined$plan_status %in% c("Submitted", "UnderReview", "DirectorSignOff", "DeputyMayorReview", "CAReview"), na.rm = TRUE), "Submitted or under review"),
      metric_tile("Measures in queue", nrow(measure_queue), "Pending OPI or system admin review", if (nrow(measure_queue) > 0) "warning" else NULL),
      metric_tile("Returned", sum(joined$plan_status %in% c("FeedbackReturned", "Returned"), na.rm = TRUE), "Needs agency action", "warning"),
      metric_tile("Approved or published", sum(joined$plan_status %in% c("Approved", "Published", "Amended"), na.rm = TRUE), "Completed review")
    ),
    surface(
      "Review Workspaces",
      "Open the queue for the review type you need to work.",
      div(
        class = "reviewer-workspace-actions",
        tags$button(type = "button", class = "civic-button primary", `data-page` = "measure_review", icon("chart-line"), "Measure review"),
        tags$button(type = "button", class = "civic-button secondary", `data-page` = "reviewer_dashboard", icon("clipboard-check"), "Plan review")
      )
    ),
    surface(
      "Review Queue",
      "This is the reviewer-facing starting point. The next pass can filter this by assigned role, pillar, agency, and review stage.",
      div(
        class = "reviewer-plan-list",
        lapply(seq_len(nrow(joined)), function(i) {
          div(
            class = "reviewer-plan-row",
            div(
              div(class = "eyebrow", paste0("FY", joined$fiscal_year[i])),
              h3(if (!is.na(joined$agency_name[i])) joined$agency_name[i] else paste("Plan", joined$plan_id[i])),
              p(if (!is.na(joined$deputy_mayor_pillar[i])) joined$deputy_mayor_pillar[i] else "No pillar scope assigned")
            ),
            div(class = "chip-row", status_chip(agency_plan_status(joined$plan_status[i]), status_tone(joined$plan_status[i])), status_chip(paste("Version", joined$version[i]), "primary")),
            div(
              class = "reviewer-plan-meta",
              span("Reviewer"),
              strong(if (!is.na(joined$reviewer_name[i])) joined$reviewer_name[i] else "Unassigned")
            ),
            div(
              class = "reviewer-plan-meta",
              span("Score"),
              strong(if (!is.na(joined$overall_score[i])) score_out_of_100(joined$overall_score[i]) else "Not scored")
            ),
            tags$button(type = "button", class = "civic-button secondary small", `data-review-plan` = joined$plan_id[i], icon("clipboard-check"), "Open review")
          )
        })
      )
    )
  )
}

latest_measure_review <- function(db, measure_id) {
  if (!"review_measure_review" %in% names(db) || !nrow(db$review_measure_review)) return(data.frame())
  rows <- db$review_measure_review[db$review_measure_review$measure_id == measure_id, , drop = FALSE]
  if (!nrow(rows)) return(rows)
  rows[order(rows$reviewed_at, rows$measure_review_id, decreasing = TRUE), , drop = FALSE][1, , drop = FALSE]
}

measure_review_card <- function(db, measure) {
  agency <- db$reference_agency[db$reference_agency$agency_id == measure$agency_id[[1]], , drop = FALSE]
  entity_links <- if ("performance_measure_entity_link" %in% names(db)) {
    db$performance_measure_entity_link[db$performance_measure_entity_link$measure_id == measure$measure_id[[1]], , drop = FALSE]
  } else {
    data.frame()
  }
  entity_label <- if (nrow(entity_links)) {
    paste(unique(entity_links$public_name), collapse = ", ")
  } else if (nrow(agency)) {
    agency$public_name[[1]] %||% agency$agency_name[[1]]
  } else {
    measure$agency_id[[1]]
  }
  history <- db$performance_measure_actuals[db$performance_measure_actuals$measure_id == measure$measure_id[[1]], , drop = FALSE]
  latest_year <- if (nrow(history)) max(history$fiscal_year, na.rm = TRUE) else NA_integer_
  latest_actual <- if (!is.na(latest_year)) {
    latest_row <- history[history$fiscal_year == latest_year, , drop = FALSE][1, , drop = FALSE]
    format_measure_value(latest_row$annual_actual[[1]], measure$format_type[[1]], measure$display_unit[[1]])
  } else {
    "Not reported"
  }
  feedback_id <- paste0("measure_review_feedback_", measure$measure_id[[1]])
  latest_review <- latest_measure_review(db, measure$measure_id[[1]])
  status_meta <- measure_library_status(measure)
  is_pending <- identical(measure$approval_status[[1]], "PendingApproval")
  div(
    class = "measure-review-card",
    div(
      class = "measure-review-card-header",
      div(
        div(class = "eyebrow", entity_label),
        h3(measure$title[[1]]),
        div(
          class = "chip-row",
          status_chip(status_meta$label, status_meta$tone),
          status_chip(measure$measure_type[[1]], "primary"),
          status_chip(measure$desired_direction[[1]], "success")
        )
      ),
      div(
        class = "measure-review-meta",
        span("Submitted"),
        strong(if (is.na(measure$submitted_for_approval_at[[1]])) "Date unavailable" else as.character(measure$submitted_for_approval_at[[1]]))
      )
    ),
    div(
      class = "measure-review-detail-grid",
      div(tags$span("Definition"), p(measure$description[[1]])),
      div(tags$span("Data source"), p(measure$data_source[[1]])),
      div(tags$span("Formula"), p(measure$formula[[1]])),
      div(tags$span("Owner"), p(paste(measure$data_owner[[1]], measure$data_owner_role[[1]], sep = " - "))),
      div(tags$span("Most recent actual"), p(latest_actual))
    ),
    if (nrow(latest_review) && nzchar(trimws(latest_review$feedback[[1]] %||% ""))) {
      div(
        class = "measure-review-note",
        div(class = "eyebrow", paste(latest_review$decision[[1]], "feedback")),
        p(latest_review$feedback[[1]])
      )
    },
    if (is_pending) {
      tagList(
        textAreaInput(feedback_id, "Reviewer feedback", rows = 3, placeholder = "Add feedback before returning this measure to the agency."),
        div(
          class = "measure-review-actions",
          tags$button(type = "button", class = "civic-button secondary", `data-measure-review-action` = "return", `data-measure-id` = measure$measure_id[[1]], icon("rotate-left"), "Return with feedback"),
          tags$button(type = "button", class = "civic-button primary", `data-measure-review-action` = "approve", `data-measure-id` = measure$measure_id[[1]], icon("check"), "Approve")
        )
      )
    }
  )
}

page_measure_review <- function(db) {
  measures <- db$performance_performance_measure[db$performance_performance_measure$approval_status == "PendingApproval", , drop = FALSE]
  measures <- measures[order(measures$submitted_for_approval_at, measures$last_updated, decreasing = TRUE), , drop = FALSE]
  returned_count <- sum(db$performance_performance_measure$approval_status == "Returned", na.rm = TRUE)
  validated_count <- sum(db$performance_performance_measure$approval_status == "Validated", na.rm = TRUE)
  tagList(
    div(
      class = "briefing-header compact",
      div(
        div(class = "eyebrow", "Reviewer workspace"),
        h1("Measure Review"),
        p("Review submitted measures for definition quality, data ownership, validation rigor, and readiness for use in performance planning. Approve measures that are ready, or return them to the agency with feedback.")
      ),
      status_chip("OPI / System Admin", "primary")
    ),
    div(
      class = "dashboard-grid reviewer-dashboard-grid",
      metric_tile("Pending review", nrow(measures), "Submitted measures"),
      metric_tile("Returned", returned_count, "Needs agency revision", "warning"),
      metric_tile("Validated", validated_count, "Approved measure library")
    ),
    surface(
      "Measure Review Queue",
      "PendingApproval measures appear here after an agency submits them from the Measures page.",
      if (!nrow(measures)) {
        div(class = "empty-state", h3("No measures are waiting for review"), p("Submitted measures will appear here for OPI Reviewer or System Admin action."))
      } else {
        div(class = "measure-review-list", lapply(seq_len(nrow(measures)), function(i) measure_review_card(db, measures[i, , drop = FALSE])))
      }
    )
  )
}

page_landing <- function(db, agency_id) {
  ctx <- selected_context(db, agency_id)
  plan <- ctx$plan
  agency <- ctx$agency
  header <- ctx$header
  services <- plan_service_rows(db, plan)
  measures <- measure_library_rows(db, plan, include_ineligible = TRUE)
  goals <- db$performance_agency_goal[db$performance_agency_goal$plan_id == plan$plan_id, , drop = FALSE]
  risks <- db$performance_service_risk[db$performance_service_risk$plan_id == plan$plan_id, , drop = FALSE]
  validated_count <- sum(measures$validated)
  overview <- db$performance_overview_vision[db$performance_overview_vision$plan_id == plan$plan_id, , drop = FALSE]
  overview_draft <- if (plan_uses_draft_payload(plan)) section_draft_payload(db, plan$plan_id[[1]], "overview") else NULL
  overview_text <- if (nrow(overview)) overview$overview[[1]] else ""
  vision_text <- if (nrow(overview)) overview$vision[[1]] else ""
  web_address <- if (nrow(overview)) overview$web_address[[1]] else ""
  overview_text <- draft_value(overview_draft, "agency_summary", overview_text)
  vision_text <- draft_value(overview_draft, "agency_vision", vision_text)
  web_address <- draft_value(overview_draft, "agency_website", web_address)
  primary_contact <- if (nrow(header) && !is.na(header$primary_contact_name[[1]])) header$primary_contact_name[[1]] else "Unassigned"
  contact_email <- if (nrow(header) && !is.na(header$primary_contact_email[[1]])) header$primary_contact_email[[1]] else "Not provided"
  timeline_items <- timeline_home_items(Sys.Date())
  goal_readiness <- goal_draft_readiness(db, plan, goals)
  complete_goal_count <- goal_readiness$complete_count
  aligned_goal_count <- goal_readiness$aligned_count
  minimum_goals <- goal_minimum_count(plan)
  service_metric_service_ids <- unique(db$performance_pm_service_link$service_id[db$performance_pm_service_link$service_id %in% services$service_id])
  services_with_metrics <- sum(services$service_id %in% service_metric_service_ids)
  overview_complete <- nonblank_text(overview_text) &&
    nonblank_text(vision_text) &&
    nonblank_text(web_address)
  overview_missing <- c(
    if (!nonblank_text(overview_text)) "overview",
    if (!nonblank_text(vision_text)) "vision",
    if (!nonblank_text(web_address)) "website"
  )
  goals_missing <- c(
    if (complete_goal_count < minimum_goals) paste(minimum_goals - complete_goal_count, "more complete goals"),
    if (aligned_goal_count < 1) "one Action Plan alignment"
  )
  maximum_goals <- goal_maximum_count(plan)
  goals_complete <- complete_goal_count >= minimum_goals && complete_goal_count <= maximum_goals && aligned_goal_count >= 1
  missing_service_names <- if (nrow(services)) services$service_name[!services$service_id %in% service_metric_service_ids] else character(0)
  services_complete <- submitter_is_mayoral_service(db, agency_id) || (nrow(services) > 0 && services_with_metrics == nrow(services))
  measures_complete <- nrow(measures) > 0 && validated_count == nrow(measures)
  risks_complete <- nrow(risks) > 0
  service_detail <- if (submitter_is_mayoral_service(db, agency_id)) {
    "Not required for mayoral service plans"
  } else if (!nrow(services)) {
    "Missing: services"
  } else if (services_complete) {
    paste("All", nrow(services), "services have metrics")
  } else {
    listed_services <- paste(head(missing_service_names, 3), collapse = ", ")
    more_services <- if (length(missing_service_names) > 3) paste("and", length(missing_service_names) - 3, "more") else ""
    paste("Missing metrics:", listed_services, more_services)
  }

  tagList(
    div(
      class = "briefing-header",
      div(
        div(class = "eyebrow", "Performance cycle"),
        h1("Agency Performance Planning"),
        p(paste("Track", ctx$display_name, "plan status, assigned contacts, services, measures, and risks before moving into the builder.")),
        div(
          class = "chip-row",
          status_chip(format_status(plan$plan_status), status_tone(plan$plan_status)),
          status_chip(paste("Version", plan$version), "primary")
        )
      ),
      div(class = "briefing-meta", paste("Updated", plan$updated_at))
    ),
    surface(
      "Performance Planning Timeline",
      "Major milestones from the Agency Performance Planning Guidance.",
      tagList(
        div(class = "timeline-step-grid", lapply(seq_len(nrow(timeline_items)), function(i) timeline_step_card(timeline_items[i, , drop = FALSE]))),
        tags$a(
          class = "civic-button secondary small timeline-guidance-link",
          href = "agency-performance-planning-guidance.docx",
          target = "_blank",
          rel = "noopener",
          download = "Agency Performance Planning Guidance.docx",
          `data-guidance-download` = "true",
          icon("file-word"),
          "View Performance Planning Guidance"
        )
      )
    ),
    surface(
      "Plan Status",
      "Current plan details and a quick read on sections that are loaded or still need work.",
      tagList(
        tags$button(type = "button", class = "civic-button secondary small plan-status-history-link", `data-page` = "plan_history", icon("clock-rotate-left"), "Plan History & Status"),
        div(
          class = "plan-status-grid",
          div(
            class = "app-table plan-record-table",
            div(class = "table-row table-head", span("Field"), span("Value")),
            div(class = "table-row", span("Plan status"), status_chip(format_status(plan$plan_status), status_tone(plan$plan_status))),
            div(class = "table-row", span("Primary contact"), span(primary_contact)),
            div(class = "table-row", span("Contact email"), span(contact_email))
          ),
          div(
            class = "snapshot-check-list",
            snapshot_check_row("Agency overview and vision", if (overview_complete) "Overview, vision, and website are complete" else paste("Missing:", paste(overview_missing, collapse = ", ")), overview_complete),
            snapshot_check_row("Goals and KPIs", if (goals_complete) paste(complete_goal_count, "complete goals with Action Plan alignment") else paste("Missing:", paste(goals_missing, collapse = ", ")), goals_complete),
            snapshot_check_row("Services", service_detail, services_complete),
            snapshot_check_row("Measures", if (measures_complete) paste("All", nrow(measures), "measures validated") else paste("Missing:", nrow(measures) - validated_count, "validated measures"), measures_complete),
            snapshot_check_row("Risks", if (risks_complete) paste(nrow(risks), "risks registered") else "Missing: at least one risk", risks_complete)
          )
        ),
      )
    )
  )
}

page_strategic_plan <- function(db, agency_id) {
  strategic_plan <- db$strategic_plan
  div(
    class = "action-plan-page",
    div(
      class = "briefing-header compact",
      div(
        div(class = "eyebrow", "2026 Mayor's Action Plan"),
        h1("Mayor Scott's Second Term Action Plan"),
        p("Mayor Scott's Second Term Action Plan aligns the work of City government with the needs and priorities of Baltimore residents. Building on the progress of the Mayor's first term, the plan establishes clear goals, coordinated strategies, and measurable outcomes that guide how the city delivers essential services and invests resources. Alongside the City's 10 Year Financial Plan, it provides a decision-making framework for more efficient and effective government operations."),
        p("Data and accountability ground the plan's development, drawing on agency performance data, service delivery trends, and community needs analysis. From this process, the City identified six core priority areas: enhancing public safety; prioritizing youth, older adults, and vulnerable communities; clean, healthy, and sustainable communities; equitable economic development; responsible stewardship of City resources; and modernizing public infrastructure."),
      p("Each priority is supported by specific, measurable goals and targeted strategies that City agencies incorporate into their work. A performance framework tracks progress on key metrics through regular public reporting, promoting transparency and holding the City accountable to residents as it works toward a stronger, more resilient, and equitable Baltimore. Click through the pillars below to explore each priority area's goals, strategies, metrics, and services.")
      ),
      tags$a(
        class = "civic-button secondary action-plan-report-link",
        href = "https://s3.amazonaws.com/baltimorecity.gov.if-us-east-1/s3fs-public/2026-05/2026%20Mayor%27s%20Action%20Plan_0.pdf",
        target = "_blank",
        rel = "noopener noreferrer",
        "View the Action Plan Report"
      )
    ),
    div(
      class = "dashboard-grid action-plan-dashboard",
      action_plan_stat(length(strategic_plan), "Pillars"),
      action_plan_stat(sum(vapply(strategic_plan, function(pillar) length(pillar$goals), integer(1))), "Goals"),
      action_plan_stat(sum(vapply(strategic_plan, function(pillar) length(pillar$metrics), integer(1))), "Metrics")
    ),
    surface(
      "Pillars",
      "Open a pillar to review goals, strategies, metrics, agencies, services, and plan entities.",
      div(
        class = "pillar-grid",
        lapply(strategic_plan, function(pillar) {
          actionButton(
            inputId = paste0("open_pillar_", pillar$id),
            class = "pillar-card pillar-card-button",
            label = tagList(
            div(
              class = "pillar-card-topline",
              h3(paste("Pillar", pillar$id))
            ),
            h4(class = "pillar-card-title", pillar$title),
            p(pillar$summary),
            div(
              class = "pillar-card-meta",
              span(paste(length(pillar$goals), "goals")),
              span(paste(sum(vapply(pillar$goals, function(goal) length(goal$initiatives), integer(1))), "strategies")),
              span(paste(length(pillar$metrics), "metrics"))
            )
            )
          )
        })
      )
    )
  )
}

team_rows_for_plan <- function(db, agency_id) {
  plan <- current_plan(db, agency_id)
  agency_id <- plan_accounting_agency_id(db, plan)
  team <- db$access_user_agency_access[db$access_user_agency_access$agency_id == agency_id, , drop = FALSE]
  if (!nrow(team)) return(team)
  team <- team[order(team$full_name, team$agency_role), , drop = FALSE]
  team$performance_role <- vapply(seq_len(nrow(team)), function(i) {
    roles <- db$access_user_role[
      db$access_user_role$user_id == team$user_id[[i]] &
        (is.na(db$access_user_role$agency_id) | db$access_user_role$agency_id == agency_id),
      ,
      drop = FALSE
    ]
    roles <- unique(roles$app_role[!is.na(roles$app_role)])
    if (length(roles)) paste(roles, collapse = ", ") else "No performance role"
  }, character(1))
  team
}

team_role_modal_ui <- function(db, agency_id, access_id, can_edit = FALSE) {
  plan <- current_plan(db, agency_id)
  accounting_agency_id <- plan_accounting_agency_id(db, plan)
  access <- db$access_user_agency_access[db$access_user_agency_access$access_id == access_id, , drop = FALSE]
  if (!nrow(access)) return(NULL)
  user_roles <- db$access_user_role[
    db$access_user_role$user_id == access$user_id[[1]] &
      (is.na(db$access_user_role$agency_id) | db$access_user_role$agency_id == accounting_agency_id),
    ,
    drop = FALSE
  ]
  agency_role <- access$agency_role[[1]]
  performance_role <- if (nrow(user_roles)) user_roles$app_role[[1]] else "AgencyViewer"
  role_row <- if (nrow(user_roles)) user_roles[1, , drop = FALSE] else data.frame()
  disabled_attr <- if (can_edit) NULL else "disabled"
  div(
    class = "custom-modal-backdrop measure-modal-backdrop",
    `data-close-input` = "close_team_role_modal",
    div(
      class = "custom-modal measure-editor-modal team-role-modal",
      div(
        class = "custom-modal-header",
        div(
          class = "measure-modal-title-block",
          h2(access$full_name[[1]]),
          div(class = "chip-row measure-modal-status-row", status_chip(if (can_edit) "Editable" else "View only", if (can_edit) "success" else "warning"))
        ),
        actionButton("close_team_role_modal", "Close", class = "civic-button secondary small")
      ),
      div(
        class = "measure-form-stack",
        tags$section(
          class = "modal-section-block measure-form-section",
          h3("User Criteria"),
          if (!can_edit) p(class = "goal-field-instruction", "Only Agency Directors and Admin users can change role assignments."),
          div(
            class = "measure-form-grid",
            div(class = "measure-field", textInput("team_full_name", "Person name", value = access$full_name[[1]])),
            div(class = "measure-field", textInput("team_email", "Email", value = access$email[[1]])),
            div(class = "measure-field", selectInput("team_agency_role", "Agency role", choices = agency_role_choices, selected = agency_role, selectize = FALSE)),
            div(class = "measure-field", selectInput("team_performance_role", "Performance role", choices = performance_role_choices, selected = performance_role, selectize = FALSE)),
            div(class = "measure-field", checkboxInput("team_budget_access", "Budget access", value = if (nrow(role_row)) isTRUE(role_row$budget_access[[1]]) else FALSE)),
            div(class = "measure-field", checkboxInput("team_adaptive_planning", "Adaptive planning", value = if (nrow(role_row)) isTRUE(role_row$adaptive_planning[[1]]) else FALSE)),
            div(class = "measure-field", checkboxInput("team_performance_plan_access", "Performance plan access", value = if (nrow(role_row)) isTRUE(role_row$performance_plan_access[[1]]) else TRUE))
          )
        )
      ),
      div(
        class = "measure-modal-actions",
        div(),
        div(
          class = "measure-submit-group",
          tags$button(id = "save_team_role", type = "button", class = "civic-button primary", disabled = disabled_attr, "Save changes")
        )
      )
    )
  )
}

page_team <- function(db, agency_id, can_manage_team = FALSE) {
  team <- team_rows_for_plan(db, agency_id)
  if (nrow(team) == 0) {
    return(surface(
      "Team & Roles",
      "Review who owns plan sections, metric approvals, and final submission.",
      div(class = "empty-state", h3("No team members assigned"), p("Add user access rows to populate this page."))
    ))
  }
  surface(
    "Team & Roles",
    if (can_manage_team) "Review and update user role assignments for this plan." else "Review who owns plan sections, metric approvals, and final submission. Role edits are limited to Agency Directors and Admin users.",
    div(
      class = "app-table team-role-table",
      div(class = "table-row table-head", span("Person"), span("Agency role"), span("Performance role")),
      lapply(seq_len(nrow(team)), function(i) {
        div(
          class = "table-row",
          span(team$full_name[i]),
          span(team$agency_role[i]),
          span(
            tags$button(
              type = "button",
              class = paste("role-link-button", if (!can_manage_team) "view-only" else ""),
              `data-team-access-id` = team$access_id[i],
              team$performance_role[i]
            )
          )
        )
      })
    )
  )
}

plan_is_editable <- function(plan) {
  if (is.null(plan) || !nrow(plan)) return(FALSE)
  plan$plan_status[[1]] %in% c("Draft", "FeedbackReturned", "Returned", "AgencyRevised")
}

eligible_plan_measures <- function(measures, fiscal_year = 2027) {
  if (is.null(measures) || !nrow(measures)) return(measures[0, , drop = FALSE])
  change_mapping <- if ("change_mapping" %in% names(measures)) measures$change_mapping else rep(NA_character_, nrow(measures))
  approval_status <- if ("approval_status" %in% names(measures)) measures$approval_status else rep(NA_character_, nrow(measures))
  measure_fiscal_year <- if ("fiscal_year" %in% names(measures)) measures$fiscal_year else rep(fiscal_year, nrow(measures))
  measures[
    measures$active &
      measure_fiscal_year == fiscal_year &
      !approval_status %in% c("Deprecated") &
      !change_mapping %in% c("Removed", "Replaced"),
    ,
    drop = FALSE
  ]
}

goal_kpi_choice_rows <- function(db, plan, goals) {
  library_rows <- eligible_plan_measures(measure_library_rows(db, plan, include_ineligible = FALSE))
  if (is.null(goals) || !nrow(goals)) return(library_rows[order(library_rows$title), , drop = FALSE])

  goal_links <- db$performance_pm_goal_link[db$performance_pm_goal_link$agency_goal_id %in% goals$agency_goal_id, , drop = FALSE]
  if (!nrow(goal_links)) return(library_rows[order(library_rows$title), , drop = FALSE])

  linked_rows <- db$performance_performance_measure[
    db$performance_performance_measure$measure_id %in% unique(goal_links$measure_id),
    ,
    drop = FALSE
  ]
  linked_rows <- eligible_plan_measures(linked_rows)
  rows <- rbind(library_rows, linked_rows)
  rows <- rows[!duplicated(rows$measure_id), , drop = FALSE]
  rows[order(rows$title), , drop = FALSE]
}

measure_library_status <- function(measure) {
  if (is.null(measure) || !nrow(measure)) return(list(label = "Draft", tone = "warning"))
  change_mapping <- if ("change_mapping" %in% names(measure)) measure$change_mapping[[1]] else NA_character_
  approval_status <- if ("approval_status" %in% names(measure)) measure$approval_status[[1]] else "Draft"
  if (!is.na(change_mapping) && change_mapping %in% c("Removed", "Replaced")) {
    return(list(label = "Deprecated", tone = "warning"))
  }
  if (!is.na(approval_status) && approval_status == "Deprecated") {
    return(list(label = "Deprecated", tone = "warning"))
  }
  if ("active" %in% names(measure) && !isTRUE(measure$active[[1]])) {
    return(list(label = "Inactive", tone = "error"))
  }
  list(
    label = format_status(approval_status),
    tone = if (!is.na(approval_status) && approval_status == "Validated") "success" else if (!is.na(approval_status) && approval_status == "Rejected") "error" else "warning"
  )
}

agency_selector_choices <- function(db) {
  current_plans <- db$planning_agency_plan[db$planning_agency_plan$fiscal_year == 2027, , drop = FALSE]
  agency_ids <- unique(current_plans$agency_id[!is.na(current_plans$agency_id)])
  entity_ids <- unique(current_plans$entity_id[!is.na(current_plans$entity_id)])
  agencies <- db$reference_agency[db$reference_agency$agency_id %in% agency_ids & db$reference_agency$submit_plan, , drop = FALSE]
  agency_labels <- ifelse(
    !is.na(agencies$public_name) & nzchar(trimws(agencies$public_name)),
    agencies$public_name,
    agencies$agency_name
  )
  agency_choices <- setNames(paste0("agency:", agencies$agency_id), agency_labels)
  entities <- db$reference_plan_entity[db$reference_plan_entity$entity_id %in% entity_ids, , drop = FALSE]
  entity_choices <- character(0)
  if (!is.null(entities) && nrow(entities)) {
    entity_choices <- setNames(paste0("entity:", entities$entity_id), entities$public_name)
  }
  choices <- c(agency_choices, entity_choices)
  choices[order(names(choices))]
}

plan_uses_draft_payload <- function(plan) {
  if (is.null(plan) || !nrow(plan)) return(FALSE)
  !plan$plan_status[[1]] %in% c("Approved", "Published")
}

user_can_submit_plan <- function() {
  TRUE
}

section_draft_payload <- function(db, plan_id, section_key) {
  drafts <- db$planning_plan_section_draft[
    db$planning_plan_section_draft$plan_id == plan_id &
      db$planning_plan_section_draft$section_key == section_key,
    ,
    drop = FALSE
  ]
  if (!nrow(drafts)) return(NULL)
  payload <- tryCatch(jsonlite::fromJSON(drafts$payload[[1]], simplifyVector = FALSE), error = function(error) NULL)
  if (is.null(payload) || is.null(payload$values)) return(NULL)
  payload
}

draft_value <- function(draft, field_id, fallback = "") {
  if (is.null(draft) || is.null(draft$values) || is.null(draft$values[[field_id]])) return(fallback)
  value <- draft$values[[field_id]]
  if (is.null(value) || length(value) == 0 || is.na(value)) return(fallback)
  as.character(value)
}

builder_page <- function(title, description, body, plan_id, section_key, show_save = TRUE, show_status = TRUE, locked = FALSE) {
  rubric_note <- "Rubric criteria are provided at the bottom of this page for reference."
  description <- if (section_key %in% c("overview", "goals", "services")) {
    paste(description, rubric_note)
  } else {
    description
  }
  tagList(
    div(
      class = "briefing-header compact",
      div(
        div(class = "eyebrow", "Performance plan builder"),
        h1(title),
        p(description)
      ),
      if (show_status) status_chip("Draft", "warning")
    ),
    div(
      class = "builder-page-content",
      `data-builder-title` = title,
      `data-plan-id` = plan_id,
      `data-section-key` = section_key,
      `data-draft-revision` = 0,
      `data-plan-locked` = if (locked) "true" else "false",
      body
    ),
    if (locked) div(
      class = "sticky-save-bar compact-save-bar locked-save-bar",
      span("This plan has been submitted and fields are locked while it is in review.")
    ) else if (show_save) div(
      class = "sticky-save-bar compact-save-bar",
      span(id = "plan_save_status", "Loading the shared draft..."),
      tags$button(id = "save_plan_draft", type = "button", class = "civic-button primary small compact-save-button", icon("floppy-disk"), "Save draft")
    )
  )
}

plan_component_counts <- function(db, plan_id) {
  goals <- db$performance_agency_goal[db$performance_agency_goal$plan_id == plan_id, , drop = FALSE]
  services <- db$performance_plan_service[db$performance_plan_service$plan_id == plan_id, , drop = FALSE]
  risks <- db$performance_service_risk[db$performance_service_risk$plan_id == plan_id, , drop = FALSE]
  goal_measure_ids <- unique(db$performance_pm_goal_link$measure_id[db$performance_pm_goal_link$agency_goal_id %in% goals$agency_goal_id])
  service_measure_ids <- unique(db$performance_pm_service_link$measure_id[db$performance_pm_service_link$service_id %in% services$service_id])
  list(goals = nrow(goals), services = nrow(services), risks = nrow(risks), measures = length(unique(c(goal_measure_ids, service_measure_ids))))
}

review_summary_for_plan <- function(db, plan_id) {
  review <- db$review_plan_review[db$review_plan_review$plan_id == plan_id, , drop = FALSE]
  if (!nrow(review)) return(list(review = NULL, scores = data.frame(), feedback = data.frame()))
  review <- review[order(review$review_started_at, decreasing = TRUE, na.last = TRUE), , drop = FALSE][1, , drop = FALSE]
  scores <- db$review_section_score[db$review_section_score$review_id == review$review_id[[1]], , drop = FALSE]
  feedback <- db$review_section_feedback[db$review_section_feedback$review_id == review$review_id[[1]], , drop = FALSE]
  list(review = review, scores = scores, feedback = feedback)
}

draft_section_count <- function(db, plan_id) {
  drafts <- db$planning_plan_section_draft[db$planning_plan_section_draft$plan_id == plan_id, , drop = FALSE]
  nrow(drafts)
}

metric_export_summary <- function(db, measure_ids, current_fy = 2027) {
  measure_ids <- unique(measure_ids[!is.na(measure_ids)])
  if (!length(measure_ids)) return(NULL)
  measures <- db$performance_performance_measure[db$performance_performance_measure$measure_id %in% measure_ids, , drop = FALSE]
  lapply(seq_len(nrow(measures)), function(i) {
    measure <- measures[i, , drop = FALSE]
    history <- db$performance_measure_actuals[db$performance_measure_actuals$measure_id == measure$measure_id[[1]], , drop = FALSE]
    years <- (current_fy - 5):(current_fy - 1)
    actuals <- vapply(years, function(year) {
      row <- history[history$fiscal_year == year, , drop = FALSE]
      if (nrow(row)) format_measure_value(row$annual_actual[[1]], measure$format_type[[1]], measure$display_unit[[1]]) else "Not reported"
    }, character(1))
    targets <- vapply((current_fy - 1):current_fy, function(year) {
      row <- history[history$fiscal_year == year, , drop = FALSE]
      if (nrow(row)) format_measure_value(row$target_value[[1]], measure$format_type[[1]], measure$display_unit[[1]], "Not set") else "Not set"
    }, character(1))
    list(
      title = measure$title[[1]],
      type = measure$measure_type[[1]],
      direction = measure$desired_direction[[1]],
      actuals = actuals,
      targets = targets
    )
  })
}

agency_director_contact <- function(db, plan) {
  agency_id <- plan_accounting_agency_id(db, plan)
  director_rows <- db$access_user_agency_access[
    db$access_user_agency_access$agency_id == agency_id &
      db$access_user_agency_access$agency_role %in% c("Agency Director", "Agency Head"),
    ,
    drop = FALSE
  ]
  if (nrow(director_rows)) return(paste(director_rows$full_name[[1]], "-", director_rows$email[[1]]))
  approver_rows <- db$access_user_role[
    db$access_user_role$agency_id == agency_id & db$access_user_role$app_role == "AgencyApprover",
    ,
    drop = FALSE
  ]
  if (nrow(approver_rows)) return(paste(approver_rows$full_name[[1]], "-", approver_rows$email[[1]]))
  header <- db$performance_plan_header[db$performance_plan_header$plan_id == plan$plan_id[[1]], , drop = FALSE]
  if (nrow(header)) return(paste(header$primary_contact_name[[1]], "-", header$primary_contact_email[[1]]))
  "Director-level contact not assigned"
}

score_out_of_100 <- function(score) {
  if (is.na(score)) return("Not scored")
  paste0(round(as.numeric(score) * 25), "/100")
}

review_notes_summary <- function(review_bits) {
  feedback <- review_bits$feedback
  scores <- review_bits$scores
  notes <- character(0)
  if (nrow(feedback)) {
    priority_feedback <- feedback[feedback$return_required, , drop = FALSE]
    priority_feedback <- priority_feedback[order(!is.na(priority_feedback$resolved_at)), , drop = FALSE]
    notes <- c(notes, priority_feedback$feedback_text)
  }
  if (length(notes) < 3 && nrow(scores)) {
    low_scores <- scores[scores$score < 4, , drop = FALSE]
    low_scores <- low_scores[order(low_scores$score, low_scores$weighted_score), , drop = FALSE]
    score_notes <- paste(low_scores$section_code, low_scores$criterion_code, "-", low_scores$justification)
    notes <- c(notes, score_notes)
  }
  notes <- unique(notes[nzchar(notes)])
  if (!length(notes)) notes <- "No improvement notes have been released."
  head(notes, 3)
}

measure_history_card <- function(db, measure_id, current_fy = 2027, label = "Measure") {
  measure <- db$performance_performance_measure[db$performance_performance_measure$measure_id == measure_id, , drop = FALSE]
  if (!nrow(measure)) return(NULL)
  history <- db$performance_measure_actuals[db$performance_measure_actuals$measure_id == measure_id, , drop = FALSE]
  actual_years <- (current_fy - 5):(current_fy - 1)
  actual_values <- vapply(actual_years, function(year) {
    row <- history[history$fiscal_year == year, , drop = FALSE]
    if (nrow(row)) format_measure_value(row$annual_actual[[1]], measure$format_type[[1]], measure$display_unit[[1]]) else "Not reported"
  }, character(1))
  target_value_for <- function(year) {
    row <- history[history$fiscal_year == year, , drop = FALSE]
    if (nrow(row)) format_measure_value(row$target_value[[1]], measure$format_type[[1]], measure$display_unit[[1]], "Not set") else "Not set"
  }
  columns <- c(
    paste0("FY", actual_years[1:4], " Actual"),
    paste0("FY", current_fy - 1, " Target"),
    paste0("FY", current_fy - 1, " Actual"),
    paste0("FY", current_fy, " Target"),
    paste0("FY", current_fy + 1, " Target")
  )
  values <- c(
    actual_values[1:4],
    target_value_for(current_fy - 1),
    actual_values[5],
    target_value_for(current_fy),
    target_value_for(current_fy + 1)
  )
  div(
    class = "history-measure-card",
    h5(measure$title[[1]]),
    div(class = "chip-row", status_chip(measure$measure_type[[1]], "primary"), status_chip(measure$desired_direction[[1]], "success")),
    div(
      class = "metric-export-table history-measure-table",
      div(class = "metric-export-row metric-export-head", lapply(columns, span)),
      div(class = "metric-export-row", lapply(values, span))
    )
  )
}

measure_export_entry <- function(db, measure_id, current_fy = 2027) {
  measure <- db$performance_performance_measure[db$performance_performance_measure$measure_id == measure_id, , drop = FALSE]
  if (!nrow(measure)) return(NULL)
  history <- db$performance_measure_actuals[db$performance_measure_actuals$measure_id == measure_id, , drop = FALSE]
  actual_years <- (current_fy - 5):(current_fy - 1)
  actual_values <- vapply(actual_years, function(year) {
    row <- history[history$fiscal_year == year, , drop = FALSE]
    if (nrow(row)) format_measure_value(row$annual_actual[[1]], measure$format_type[[1]], measure$display_unit[[1]]) else "Not reported"
  }, character(1))
  target_value_for <- function(year) {
    row <- history[history$fiscal_year == year, , drop = FALSE]
    if (nrow(row)) format_measure_value(row$target_value[[1]], measure$format_type[[1]], measure$display_unit[[1]]) else "Not set"
  }
  list(
    title = measure$title[[1]],
    type = measure$measure_type[[1]],
    direction = measure$desired_direction[[1]],
    columns = as.list(c(
      paste0("FY", actual_years[1:4], " Actual"),
      paste0("FY", current_fy - 1, " Target"),
      paste0("FY", current_fy - 1, " Actual"),
      paste0("FY", current_fy, " Target"),
      paste0("FY", current_fy + 1, " Target")
    )),
    values = as.list(c(
      actual_values[1:4],
      target_value_for(current_fy - 1),
      actual_values[5],
      target_value_for(current_fy),
      target_value_for(current_fy + 1)
    ))
  )
}

plan_export_payload <- function(db, plan_id) {
  plan <- db$planning_agency_plan[db$planning_agency_plan$plan_id == plan_id, , drop = FALSE]
  if (!nrow(plan)) stop("Plan not found")
  agency <- db$reference_agency[db$reference_agency$agency_id == plan_accounting_agency_id(db, plan), , drop = FALSE]
  overview <- db$performance_overview_vision[db$performance_overview_vision$plan_id == plan_id, , drop = FALSE]
  goals <- db$performance_agency_goal[db$performance_agency_goal$plan_id == plan_id, , drop = FALSE]
  goals <- goals[order(goals$sort_order), , drop = FALSE]
  services <- db$performance_plan_service[db$performance_plan_service$plan_id == plan_id, , drop = FALSE]
  service_rows <- db$reference_service[db$reference_service$service_id %in% services$service_id, , drop = FALSE]
  risks <- db$performance_service_risk[db$performance_service_risk$plan_id == plan_id, , drop = FALSE]
  review_bits <- review_summary_for_plan(db, plan_id)
  current_fy <- max(db$planning_agency_plan$fiscal_year, na.rm = TRUE)

  goal_payload <- lapply(seq_len(nrow(goals)), function(i) {
    goal_id <- goals$agency_goal_id[i]
    linked_initiatives <- db$performance_agency_goal_initiative_link[db$performance_agency_goal_initiative_link$agency_goal_id == goal_id, , drop = FALSE]
    initiative_rows <- db$performance_initiative[db$performance_initiative$initiative_id %in% linked_initiatives$initiative_id, , drop = FALSE]
    linked_kpis <- db$performance_pm_goal_link[db$performance_pm_goal_link$agency_goal_id == goal_id, , drop = FALSE]
    list(
      title = goals$title[i],
      initiatives = as.list(initiative_rows$title),
      kpis = Filter(Negate(is.null), lapply(linked_kpis$measure_id, function(measure_id) measure_export_entry(db, measure_id, current_fy))),
      alignment = if (nzchar(goals$alignment[i])) goals$alignment[i] else NULL
    )
  })

  service_payload <- lapply(seq_len(nrow(service_rows)), function(i) {
    metric_ids <- service_metric_ids(db, plan, service_rows$service_id[i], include_ineligible = TRUE)
    list(
      name = service_rows$service_name[i],
      description = service_rows$service_description[i],
      metrics = Filter(Negate(is.null), lapply(metric_ids, function(measure_id) measure_export_entry(db, measure_id, current_fy)))
    )
  })

  list(
    fiscal_year = plan$fiscal_year[[1]],
    agency_name = plan_display_name(db, plan),
    status = agency_plan_status(plan$plan_status[[1]]),
    version = plan$version[[1]],
    agency_contact = agency_director_contact(db, plan),
    overview = if (nrow(overview)) list(overview = overview$overview[[1]], vision = overview$vision[[1]], web_address = overview$web_address[[1]]) else list(),
    review = list(
      reviewer = if (!is.null(review_bits$review)) review_bits$review$reviewer_name[[1]] else "Not assigned",
      score = if (!is.null(review_bits$review)) score_out_of_100(review_bits$review$overall_score[[1]]) else "Not scored",
      notes = as.list(review_notes_summary(review_bits))
    ),
    goals = goal_payload,
    services = service_payload,
    risks = as.list(risks$description)
  )
}

plan_export_python <- function() {
  configured <- Sys.getenv("PLAN_EXPORT_PYTHON")
  if (nzchar(configured) && file.exists(configured)) return(configured)
  bundled <- "C:/Users/melanie.lada/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe"
  if (file.exists(bundled)) return(bundled)
  python <- Sys.which("python")
  if (nzchar(python)) return(python)
  stop("No Python executable is available for plan exports.")
}

build_plan_export_file <- function(db, plan_id, output_file, export_type) {
  payload_file <- tempfile(fileext = ".json")
  jsonlite::write_json(plan_export_payload(db, plan_id), payload_file, auto_unbox = TRUE, null = "null", pretty = TRUE)
  script_path <- normalizePath(file.path("scripts", "build_plan_export.py"), winslash = "/", mustWork = TRUE)
  template_path <- "C:/Users/melanie.lada/AppData/Local/Temp/Agency Performance Plan Template.pptx"
  args <- c("--input", payload_file, "--output", output_file, "--type", export_type)
  if (identical(export_type, "pptx") && file.exists(template_path)) {
    args <- c(args, "--template", template_path)
  }
  status <- system2(plan_export_python(), shQuote(c(script_path, args)), stdout = TRUE, stderr = TRUE)
  if (!file.exists(output_file) || file.info(output_file)$size == 0) {
    stop(paste("Plan export failed:", paste(status, collapse = "\n")))
  }
  invisible(output_file)
}

history_plan_card <- function(db, plan, current_plan_id) {
  review_bits <- review_summary_for_plan(db, plan$plan_id[[1]])
  review <- review_bits$review
  feedback <- review_bits$feedback
  open_feedback <- if (nrow(feedback)) sum(feedback$return_required & is.na(feedback$resolved_at), na.rm = TRUE) else 0
  score_label <- if (!is.null(review)) score_out_of_100(review$overall_score[[1]]) else "No score yet"
  is_current <- plan$plan_id[[1]] == current_plan_id
  drafts <- db$planning_plan_section_draft[db$planning_plan_section_draft$plan_id == plan$plan_id[[1]], , drop = FALSE]
  latest_draft <- if (nrow(drafts)) max(drafts$updated_at, na.rm = TRUE) else NA
  updated_label <- if (is_current && plan_is_editable(plan) && !is.na(latest_draft)) "Draft updated" else "Updated"
  updated_value <- if (is_current && plan_is_editable(plan) && !is.na(latest_draft)) latest_draft else plan$updated_at[[1]]
  div(
    class = paste("history-plan-card", if (is_current) "current" else ""),
    div(
      class = "history-plan-card-header",
      div(
        div(class = "eyebrow", if (is_current) "Current cycle" else "Past plan"),
        h2(paste0("FY", plan$fiscal_year[[1]], " Performance Plan")),
        div(
          class = "chip-row",
          status_chip(agency_plan_status(plan$plan_status[[1]]), status_tone(plan$plan_status[[1]])),
          status_chip(paste("Version", plan$version[[1]]), "primary")
        )
      ),
      div(class = "history-plan-updated", span(updated_label), strong(as.character(updated_value)))
    ),
    div(
      class = "history-review-strip",
      div(span("Reviewer"), strong(if (!is.null(review)) review$reviewer_name[[1]] else "Not assigned")),
      div(span("Review status"), strong(if (!is.null(review) && isTRUE(review$review_complete[[1]])) "Complete" else if (!is.null(review)) "In progress" else "Not started")),
      div(span("Rubric grade"), strong(score_label)),
      div(span("Open feedback"), strong(open_feedback)),
      tags$button(type = "button", class = "civic-button secondary small history-review-detail-button", `data-review-plan` = plan$plan_id[[1]], icon("clipboard-check"), "Review details")
    ),
    div(
      class = "history-plan-actions",
      if (is_current && plan_is_editable(plan) && user_can_submit_plan()) tags$button(type = "button", class = "civic-button primary small", `data-submit-plan` = plan$plan_id[[1]], icon("paper-plane"), "Submit plan"),
      tags$button(type = "button", class = "civic-button secondary small", `data-review-plan` = plan$plan_id[[1]], icon("eye"), "Review plan"),
      tags$button(type = "button", class = "civic-button secondary small", `data-export-plan` = plan$plan_id[[1]], `data-export-type` = "pdf", icon("file-pdf"), "Export PDF"),
      tags$button(type = "button", class = "civic-button secondary small", `data-export-plan` = plan$plan_id[[1]], `data-export-type` = "pptx", icon("file-powerpoint"), "Export PowerPoint")
    )
  )
}

draft_json <- function(payload) {
  jsonlite::toJSON(payload, auto_unbox = TRUE, null = "null", na = "null", pretty = FALSE)
}

duplicate_plan_sections_to_draft <- function(connection, db, source_plan_id, target_plan_id) {
  now <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  source_plan_id <- as.integer(source_plan_id)
  target_plan_id <- as.integer(target_plan_id)

  source_overview <- db$performance_overview_vision[db$performance_overview_vision$plan_id == source_plan_id, , drop = FALSE]
  if (nrow(source_overview)) {
    overwrite_section_draft(
      connection,
      target_plan_id,
      "overview",
      draft_json(list(
        savedAt = now,
        values = list(
          agency_summary = source_overview$overview[[1]],
          agency_vision = source_overview$vision[[1]],
          agency_website = source_overview$web_address[[1]]
        )
      ))
    )
  }

  source_goals <- db$performance_agency_goal[db$performance_agency_goal$plan_id == source_plan_id, , drop = FALSE]
  if (nrow(source_goals)) {
    source_goals <- source_goals[order(source_goals$sort_order), , drop = FALSE]
    values <- list()
    initiatives <- list()
    kpis <- list()
    goal_ids <- as.character(source_goals$agency_goal_id)
    for (i in seq_len(nrow(source_goals))) {
      goal_id <- as.character(source_goals$agency_goal_id[i])
      values[[paste0("goal_statement_", goal_id)]] <- source_goals$title[i]
      values[[paste0("goal_alignment_", goal_id)]] <- source_goals$alignment_code[i]
      linked_initiatives <- db$performance_agency_goal_initiative_link[db$performance_agency_goal_initiative_link$agency_goal_id == source_goals$agency_goal_id[i], , drop = FALSE]
      initiative_rows <- db$performance_initiative[db$performance_initiative$initiative_id %in% linked_initiatives$initiative_id, , drop = FALSE]
      initiatives[[goal_id]] <- if (nrow(initiative_rows)) as.list(initiative_rows$title) else list("")
      linked_kpis <- db$performance_pm_goal_link[db$performance_pm_goal_link$agency_goal_id == source_goals$agency_goal_id[i], , drop = FALSE]
      kpis[[goal_id]] <- as.list(as.character(linked_kpis$measure_id))
    }
    overwrite_section_draft(
      connection,
      target_plan_id,
      "goals",
      draft_json(list(savedAt = now, values = values, kpis = kpis, initiatives = initiatives, goalIds = as.list(goal_ids)))
    )
  }

  source_services <- db$performance_plan_service[db$performance_plan_service$plan_id == source_plan_id, , drop = FALSE]
  if (nrow(source_services)) {
    values <- list()
    service_metrics <- list()
    source_plan <- db$planning_agency_plan[db$planning_agency_plan$plan_id == source_plan_id, , drop = FALSE]
    source_measures <- plan_measure_rows(db, source_plan, include_ineligible = FALSE)
    service_rows <- db$reference_service[db$reference_service$service_id %in% source_services$service_id, , drop = FALSE]
    for (i in seq_len(nrow(service_rows))) {
      service_id <- service_rows$service_id[i]
      values[[paste0("service_description_", service_id)]] <- service_rows$service_description[i]
      metric_ids <- service_metric_ids(db, source_plan, service_id, source_measures)
      service_metrics[[service_id]] <- as.list(as.character(metric_ids))
    }
    overwrite_section_draft(
      connection,
      target_plan_id,
      "services",
      draft_json(list(savedAt = now, values = values, serviceMetrics = service_metrics))
    )
  }

  invisible(TRUE)
}

page_plan_history <- function(db, agency_id) {
  selected <- parse_submitter_value(agency_id)
  if (identical(selected$type, "entity")) {
    plans <- db$planning_agency_plan[!is.na(db$planning_agency_plan$entity_id) & db$planning_agency_plan$entity_id == selected$id, , drop = FALSE]
  } else {
    plans <- db$planning_agency_plan[!is.na(db$planning_agency_plan$agency_id) & db$planning_agency_plan$agency_id == selected$id, , drop = FALSE]
  }
  plans <- plans[order(plans$fiscal_year, decreasing = TRUE), , drop = FALSE]
  plan <- current_plan(db, agency_id)
  builder_page(
    "Plan History & Status",
    "Review prior submissions, current draft state, reviewer feedback, and export-ready plan content.",
    tagList(
      surface(
        "Plan Records",
        "Open past plans, duplicate an approved plan into the current draft, and review released feedback beside the submitted content.",
        div(
          class = "history-plan-list",
          lapply(seq_len(nrow(plans)), function(i) history_plan_card(db, plans[i, , drop = FALSE], plan$plan_id[[1]]))
        )
      )
    ),
    plan_id = plan$plan_id,
    section_key = "history",
    show_save = FALSE,
    show_status = FALSE
  )
}

history_plan_modal <- function(db, plan_id) {
  plan <- db$planning_agency_plan[db$planning_agency_plan$plan_id == plan_id, , drop = FALSE]
  if (!nrow(plan)) return(NULL)
  payload_preview <- plan_uses_draft_payload(plan)
  overview_draft <- if (payload_preview) section_draft_payload(db, plan_id, "overview") else NULL
  goals_draft <- if (payload_preview) section_draft_payload(db, plan_id, "goals") else NULL
  services_draft <- if (payload_preview) section_draft_payload(db, plan_id, "services") else NULL
  overview <- db$performance_overview_vision[db$performance_overview_vision$plan_id == plan_id, , drop = FALSE]
  goals <- db$performance_agency_goal[db$performance_agency_goal$plan_id == plan_id, , drop = FALSE]
  goals <- goals[order(goals$sort_order), , drop = FALSE]
  services <- db$performance_plan_service[db$performance_plan_service$plan_id == plan_id, , drop = FALSE]
  service_rows <- db$reference_service[db$reference_service$service_id %in% services$service_id, , drop = FALSE]
  review_bits <- review_summary_for_plan(db, plan_id)
  risks <- db$performance_service_risk[db$performance_service_risk$plan_id == plan_id, , drop = FALSE]
  notes_summary <- review_notes_summary(review_bits)
  current_fy <- max(db$planning_agency_plan$fiscal_year, na.rm = TRUE)
  overview_text <- if (nrow(overview)) overview$overview[[1]] else ""
  vision_text <- if (nrow(overview)) overview$vision[[1]] else ""
  web_address <- if (nrow(overview)) overview$web_address[[1]] else ""
  overview_text <- draft_value(overview_draft, "agency_summary", overview_text)
  vision_text <- draft_value(overview_draft, "agency_vision", vision_text)
  web_address <- draft_value(overview_draft, "agency_website", web_address)
  saved_goal_ids <- if (!is.null(goals_draft) && !is.null(goals_draft$goalIds)) as.character(unlist(goals_draft$goalIds)) else as.character(goals$agency_goal_id)
  saved_goal_ids <- saved_goal_ids[nzchar(saved_goal_ids)]

  div(
    class = "custom-modal-backdrop history-modal-backdrop",
    `data-close-input` = "close_history_plan_modal",
    div(
      class = "custom-modal history-modal-panel",
      div(
        class = "custom-modal-header history-modal-header",
        div(
          div(class = "eyebrow", "Plan review"),
          h2(paste0("FY", plan$fiscal_year[[1]], " Performance Plan")),
          div(class = "chip-row", status_chip(agency_plan_status(plan$plan_status[[1]]), status_tone(plan$plan_status[[1]])), status_chip(paste("Version", plan$version[[1]]), "primary")),
          p(class = "history-modal-contact", tags$strong("Agency contact: "), agency_director_contact(db, plan))
        ),
        actionButton("close_history_plan_modal", "X", class = "icon-button history-modal-close", `aria-label` = "Close plan review")
      ),
      div(
        class = "history-modal-grid",
        div(
          class = "history-modal-section",
          h3("Overview & Vision"),
          if (nrow(overview) || !is.null(overview_draft)) tagList(
            p(tags$strong("Overview: "), overview_text),
            p(tags$strong("Vision: "), vision_text),
            p(tags$strong("Web address: "), web_address)
          ) else p("No overview record is available for this plan.")
        ),
        div(
          class = "history-modal-section",
          h3("Reviewer Feedback"),
          if (!is.null(review_bits$review)) tagList(
            p(tags$strong("Reviewer: "), review_bits$review$reviewer_name[[1]]),
            p(tags$strong("Overall score: "), score_out_of_100(review_bits$review$overall_score[[1]])),
            div(
              class = "notes-summary",
              h4("Notes summary"),
              tags$ol(lapply(notes_summary, tags$li))
            )
          ) else p("No reviewer notes have been released for this plan.")
        )
      ),
      div(
        class = "history-modal-section",
        h3("Agency Goals"),
        if (length(saved_goal_ids)) div(
          class = "history-modal-list",
          lapply(seq_along(saved_goal_ids), function(i) {
            goal_id <- saved_goal_ids[[i]]
            goal_row <- goals[as.character(goals$agency_goal_id) == goal_id, , drop = FALSE]
            linked_initiatives <- if (nrow(goal_row)) db$performance_agency_goal_initiative_link[db$performance_agency_goal_initiative_link$agency_goal_id == goal_row$agency_goal_id[[1]], , drop = FALSE] else data.frame()
            initiative_rows <- if (nrow(linked_initiatives)) db$performance_initiative[db$performance_initiative$initiative_id %in% linked_initiatives$initiative_id, , drop = FALSE] else data.frame(title = character())
            linked_kpis <- if (nrow(goal_row)) db$performance_pm_goal_link[db$performance_pm_goal_link$agency_goal_id == goal_row$agency_goal_id[[1]], , drop = FALSE] else data.frame(measure_id = integer())
            goal_statement <- draft_value(goals_draft, paste0("goal_statement_", goal_id), if (nrow(goal_row)) goal_row$title[[1]] else "Untitled goal")
            initiative_titles <- if (!is.null(goals_draft) && !is.null(goals_draft$initiatives[[goal_id]])) {
              as.character(unlist(goals_draft$initiatives[[goal_id]]))
            } else {
              initiative_rows$title
            }
            initiative_titles <- initiative_titles[nzchar(trimws(initiative_titles))]
            kpi_ids <- if (!is.null(goals_draft) && !is.null(goals_draft$kpis[[goal_id]])) {
              suppressWarnings(as.integer(unlist(goals_draft$kpis[[goal_id]])))
            } else {
              linked_kpis$measure_id
            }
            kpi_ids <- kpi_ids[!is.na(kpi_ids)]
            alignment_code <- draft_value(goals_draft, paste0("goal_alignment_", goal_id), if (nrow(goal_row)) goal_row$alignment_code[[1]] else "")
            alignment_row <- db$reference_pillar_goal[db$reference_pillar_goal$goal_code == alignment_code, , drop = FALSE]
            alignment <- if (nrow(alignment_row)) paste(alignment_row$goal_code[[1]], alignment_row$goal_title[[1]]) else if (nrow(goal_row)) goal_row$alignment[[1]] else ""
            div(
              class = "history-modal-record",
              div(class = "eyebrow", paste("Goal", i)),
              h4(goal_statement),
              if (length(initiative_titles)) tagList(div(class = "eyebrow", "Initiatives"), tags$ul(lapply(initiative_titles, tags$li))),
              if (length(kpi_ids)) tagList(
                div(class = "eyebrow", "Key Performance Indicators"),
                div(class = "history-measure-list", lapply(kpi_ids, function(measure_id) measure_history_card(db, measure_id, current_fy)))
              ),
              if (nzchar(alignment)) div(class = "history-alignment-note", status_chip("Action Plan Aligned", "success"), span(alignment))
            )
          })
        ) else p("No goals are available for this plan.")
      ),
      div(
        class = "history-modal-section",
        h3("Services"),
        if (nrow(service_rows)) div(
          class = "history-modal-list",
          lapply(seq_len(nrow(service_rows)), function(i) {
            service_id <- service_rows$service_id[i]
            description <- draft_value(services_draft, paste0("service_description_", service_id), service_rows$service_description[i])
            metric_ids <- if (!is.null(services_draft) && !is.null(services_draft$serviceMetrics[[service_id]])) {
              suppressWarnings(as.integer(unlist(services_draft$serviceMetrics[[service_id]])))
            } else {
              service_metric_ids(db, plan, service_id, include_ineligible = TRUE)
            }
            metric_ids <- metric_ids[!is.na(metric_ids)]
            div(
              class = "history-modal-record",
              h4(service_rows$service_name[i]),
              p(description),
              if (length(metric_ids)) tagList(
                div(class = "eyebrow", "Performance Metrics"),
                div(class = "history-measure-list", lapply(metric_ids, function(measure_id) measure_history_card(db, measure_id, current_fy)))
              )
            )
          })
        ) else p("No services are available for this plan.")
      ),
      div(
        class = "history-modal-section",
        h3("Risks"),
        if (nrow(risks)) div(
          class = "history-modal-list",
          lapply(seq_len(nrow(risks)), function(i) div(class = "history-modal-record", p(risks$description[i])))
        ) else p("No risks are available for this plan.")
      )
    )
  )
}

measure_label <- function(text, help, required = FALSE) {
  tags$span(
    class = "field-label-with-help",
    span(text),
    if (required) span(class = "required-marker", "Required"),
    tags$span(class = "field-help-icon", tabindex = "0", title = help, `aria-label` = paste(text, "guidance"), "?")
  )
}

measure_note_input <- function(input_id, label, value = "") {
  note_value <- if (is.null(value) || length(value) == 0 || is.na(value)) "" else as.character(value)
  div(
    class = "form-group shiny-input-container",
    tags$label(class = "control-label", `for` = input_id, label),
    tags$textarea(id = input_id, class = "form-control", rows = 3, maxlength = 200, note_value)
  )
}

measure_value_input <- function(input_id, label, value = NA, format_type = "Count") {
  format_class <- paste0("format-", tolower(format_type))
  input_value <- if (is.null(value) || length(value) == 0 || is.na(value)) NULL else as.character(value)
  input_attrs <- list(
    id = input_id,
    class = "form-control measure-value-input",
    type = "number",
    value = input_value,
    step = if (identical(format_type, "Percent")) "1" else "0.01",
    inputmode = if (identical(format_type, "Percent")) "numeric" else "decimal",
    `data-value-role` = if (grepl("_target_", input_id, fixed = TRUE)) "target" else "actual"
  )
  if (identical(format_type, "Percent")) {
    input_attrs$min <- "0"
    input_attrs$max <- "100"
  }
  div(
    class = paste("measure-number-field", format_class),
    div(
      class = "form-group shiny-input-container",
      tags$label(class = "control-label", `for` = input_id, label),
      do.call(tags$input, input_attrs)
    )
  )
}

display_unit_choices <- function(db, selected_unit = "") {
  standard_units <- c(
    "days",
    "hours",
    "minutes",
    "years",
    "linear feet",
    "linear miles",
    "tons",
    "millions of gallons",
    "million gallons per day",
    "per day",
    "per FTE",
    "out of 10"
  )
  existing_units <- character(0)
  if ("performance_performance_measure" %in% names(db) && "display_unit" %in% names(db$performance_performance_measure)) {
    existing_units <- trimws(as.character(db$performance_performance_measure$display_unit))
    existing_units <- existing_units[!is.na(existing_units) & nzchar(existing_units)]
  }
  units <- sort(unique(c(standard_units, existing_units, selected_unit[nzchar(selected_unit)])))
  c("No unit" = "", stats::setNames(units, units))
}

measure_modal_ui <- function(db, agency_id, measure_id = NULL, can_edit_scope = FALSE, target_fy = 2027) {
  measure <- if (is.null(measure_id)) data.frame() else db$performance_performance_measure[db$performance_performance_measure$measure_id == measure_id, , drop = FALSE]
  is_new <- nrow(measure) == 0
  value <- function(name, default = "") {
    if (is_new || !name %in% names(measure) || is.na(measure[[name]][1])) default else measure[[name]][1]
  }
  actuals <- if (is_new) data.frame() else db$performance_measure_actuals[db$performance_measure_actuals$measure_id == measure_id, , drop = FALSE]
  annual_value <- function(year, name, default = "") {
    row <- actuals[actuals$fiscal_year == year, , drop = FALSE]
    if (!nrow(row) || is.na(row[[name]][1])) default else row[[name]][1]
  }
  pillar_choices <- c("Not linked" = "", setNames(db$reference_pillar$pillar_id, db$reference_pillar$pillar_name))
  pillar_goal_choices <- c("Not linked" = "", setNames(db$reference_pillar_goal$pillar_goal_id, paste(db$reference_pillar_goal$goal_code, db$reference_pillar_goal$goal_title)))
  status <- value("approval_status", "Draft")
  status_meta <- if (is_new) list(label = "Draft", tone = "warning") else measure_library_status(measure)
  selected_format <- if (value("format_type", "Count") %in% c("Percent", "Count", "Currency", "N/A")) value("format_type", "Count") else "Count"
  format_choices <- if (identical(selected_format, "N/A")) c("N/A (legacy)" = "N/A", "Percent" = "Percent", "Count" = "Count", "Currency" = "Currency") else c("Percent", "Count", "Currency")
  selected_display_unit <- value("display_unit")
  latest_review <- if (is_new) data.frame() else latest_measure_review(db, measure_id)
  selected_pillar_id <- value("pillar_id")
  selected_pillar <- db$reference_pillar[db$reference_pillar$pillar_id == selected_pillar_id, , drop = FALSE]
  selected_pillar_goal_id <- value("pillar_goal_id")
  selected_pillar_goal <- db$reference_pillar_goal[db$reference_pillar_goal$pillar_goal_id == selected_pillar_goal_id, , drop = FALSE]
  pillar_label <- if (nrow(selected_pillar)) selected_pillar$pillar_name[[1]] else "Not linked"
  pillar_goal_label <- if (nrow(selected_pillar_goal)) paste(selected_pillar_goal$goal_code[[1]], selected_pillar_goal$goal_title[[1]]) else "Not linked"
  scope_city <- isTRUE(value("is_city", FALSE))
  scope_agency <- isTRUE(value("is_agency", FALSE))
  scope_service <- if (is_new) TRUE else isTRUE(value("is_service", FALSE))
  scope_label <- paste(
    c(if (scope_city) "Citywide", if (scope_agency) "Agency", if (scope_service) "Service"),
    collapse = ", "
  )
  if (!nzchar(scope_label)) scope_label <- "Service"

  div(
    class = "custom-modal-backdrop measure-modal-backdrop",
    `data-close-input` = "close_measure_modal",
    div(
      class = "custom-modal measure-editor-modal",
      div(
        class = "custom-modal-header",
        div(
          class = "measure-modal-title-block",
          h2(if (is_new) "Build a New Measure" else value("title")),
          div(
            class = "chip-row measure-modal-status-row",
            status_chip(status_meta$label, status_meta$tone)
          )
        ),
        actionButton("close_measure_modal", "Close", class = "civic-button secondary small")
      ),
      div(
        class = "measure-form-stack",
        div(class = "required-fields-note", "Fields marked Required must be completed before submitting a measure for approval. Drafts can still be saved while these fields are incomplete."),
        if (nrow(latest_review) && nzchar(trimws(latest_review$feedback[[1]] %||% ""))) {
          tags$section(
            class = "modal-section-block measure-review-feedback",
            h3("Reviewer Feedback"),
            div(
              class = "chip-row",
              status_chip(latest_review$decision[[1]], if (identical(latest_review$decision[[1]], "Approved")) "success" else "warning"),
              status_chip(if (is.na(latest_review$reviewed_at[[1]])) "Review date unavailable" else as.character(latest_review$reviewed_at[[1]]), "primary")
            ),
            p(latest_review$feedback[[1]])
          )
        },
        tags$section(
          class = "modal-section-block measure-form-section",
          h3("Definition"),
          div(
            class = "measure-form-grid",
            div(class = "measure-field full-width", textInput("measure_title", measure_label("Measure name", "Use a concise name that clearly identifies the outcome, output, efficiency, or effectiveness being tracked.", TRUE), value = value("title"))),
            div(class = "measure-field full-width", textAreaInput("measure_description", measure_label("Definition", "Define exactly what is being measured so a reviewer can understand the measure without additional context.", TRUE), rows = 3, value = value("description"))),
            div(class = "measure-field", selectInput("measure_type", measure_label("Measure type", "Classify the measure as output, efficiency, effectiveness, or outcome based on what it tells reviewers about performance.", TRUE), choices = c("Output", "Efficiency", "Effectiveness", "Outcome"), selected = value("measure_type", "Outcome"), selectize = FALSE)),
            div(class = "measure-field", selectInput("measure_direction", measure_label("Desired direction", "Select whether successful performance should increase, decrease, maintain, or not apply to this value.", TRUE), choices = c("Increase", "Decrease", "Maintain", "Not Applicable"), selected = value("desired_direction", "Increase"), selectize = FALSE)),
            div(class = "measure-field", selectInput("measure_format", measure_label("Format", "Select how this value should be displayed. New measures use Percent, Count, or Currency; N/A is preserved for legacy measures.", TRUE), choices = format_choices, selected = selected_format, selectize = FALSE)),
            div(class = "measure-field", selectInput("measure_unit", measure_label("Display unit", "Optional label for the unit shown with the value, such as residents, permits, or dollars."), choices = display_unit_choices(db, selected_display_unit), selected = selected_display_unit, selectize = FALSE)),
            div(class = "measure-field", numericInput("measure_baseline", measure_label("Baseline value", "Enter the starting value used to compare future progress."), value = value("baseline_value", NA))),
            div(class = "measure-field", numericInput("measure_baseline_fy", measure_label("Baseline fiscal year", "Enter the fiscal year for the baseline value."), value = value("baseline_fy", 2026), min = 2000, max = 2100))
          )
        ),
        tags$section(
          class = "modal-section-block measure-form-section",
          h3("Data Source & Ownership"),
          div(
            class = "measure-form-grid",
            div(class = "measure-field full-width", textInput("measure_data_source", measure_label("Data source", "Name the system, report, dataset, or official source used to produce this measure.", TRUE), value = value("data_source"))),
            div(class = "measure-field", textInput("measure_data_owner", measure_label("Data owner", "Name the person or team responsible for the source data.", TRUE), value = value("data_owner"))),
            div(class = "measure-field", textInput("measure_data_owner_role", measure_label("Data owner role", "Identify the title or role accountable for maintaining and validating the data.", TRUE), value = value("data_owner_role"))),
            div(class = "measure-field", textInput("measure_frequency", measure_label("Update frequency", "State how often the measure can be updated, such as monthly, quarterly, annually, or daily.", TRUE), value = value("update_frequency"))),
            div(class = "measure-field", textInput("measure_data_location", measure_label("Data location", "Describe where the underlying data lives, such as a database, spreadsheet, system export, or public report.", TRUE), value = value("data_location"))),
            div(class = "measure-field full-width", textAreaInput("measure_formula", measure_label("Formula or calculation", "Document the calculation clearly enough that another reviewer could reproduce the result.", TRUE), rows = 2, value = value("formula"))),
            div(class = "measure-field full-width", textAreaInput("measure_collection_method", measure_label("Collection method", "Describe how the data is collected, compiled, refreshed, or quality checked.", TRUE), rows = 2, value = value("collection_method")))
          )
        ),
        tags$section(
          class = "modal-section-block measure-form-section",
          h3("Validation Criteria"),
          div(
            class = "measure-form-grid",
            div(class = "measure-field full-width", textAreaInput("measure_context", measure_label("Context required for interpretation", "Note caveats, comparison limits, seasonality, policy changes, or other context needed to interpret the value responsibly."), rows = 2, value = value("context_required"))),
            div(class = "measure-field checkbox-field", checkboxInput("measure_replicability", "Calculation is replicable", value = isTRUE(value("replicability", FALSE))), p(class = "field-inline-help", "A reviewer should be able to recreate the value from the formula and source data.")),
            div(class = "measure-field", textInput("measure_disaggregation", measure_label("Disaggregation", "List available breakdowns, such as geography, demographic group, program, facility, district, or service type."), value = value("disaggregation"))),
            div(class = "measure-field full-width", textAreaInput("measure_how_used", measure_label("How the data is used", "Explain how the agency uses this measure for management, budgeting, service improvement, or public accountability.", TRUE), rows = 2, value = value("how_data_used"))),
            div(class = "measure-field full-width", textAreaInput("measure_why_meaningful", measure_label("Why this measure is meaningful", "Explain why this measure is a useful signal of resident outcomes, service quality, efficiency, or operational performance.", TRUE), rows = 2, value = value("why_meaningful"))),
            div(class = "measure-field full-width", textAreaInput("measure_proxy", measure_label("Proxy measure or limitations", "Describe whether this is a proxy for a harder-to-measure outcome and name important limitations."), rows = 2, value = value("proxy_measure"))),
            div(class = "measure-field full-width", textAreaInput("measure_improvement_notes", measure_label("Improvement notes", "Identify needed improvements to data quality, frequency, definition, validation, or reporting."), rows = 2, value = value("improvement_notes"))),
            if (can_edit_scope) {
              tagList(
                div(class = "measure-field", selectInput("measure_pillar", measure_label("Action Plan pillar", "Only system admins will be able to designate citywide metrics and match them to an Action Plan pillar."), choices = pillar_choices, selected = as.character(value("pillar_id")), selectize = FALSE)),
                div(class = "measure-field full-width", selectInput("measure_pillar_goal", measure_label("Action Plan pillar goal", "Only system admins will be able to designate citywide metrics and match them to an Action Plan goal."), choices = pillar_goal_choices, selected = as.character(value("pillar_goal_id")), selectize = FALSE))
              )
            } else {
              div(
                class = "measure-scope-options scope-derived full-width",
                tags$input(id = "measure_pillar", type = "hidden", value = if (is.na(selected_pillar_id)) "" else selected_pillar_id),
                tags$input(id = "measure_pillar_goal", type = "hidden", value = if (is.na(selected_pillar_goal_id)) "" else selected_pillar_goal_id),
                div(class = "scope-derived-grid", span("Action Plan pillar"), strong(pillar_label)),
                div(class = "scope-derived-grid", span("Action Plan goal"), strong(pillar_goal_label)),
                p(class = "scope-admin-note", "Action Plan metric alignment is system-admin managed.")
              )
            },
            if (can_edit_scope) {
              div(
                class = "measure-scope-options full-width",
                checkboxInput("measure_is_city", "Citywide measure", value = scope_city),
                checkboxInput("measure_is_agency", "Agency measure", value = scope_agency),
                checkboxInput("measure_is_service", "Service measure", value = scope_service),
                p(class = "scope-admin-note", "System admin only: scope determines whether this measure is citywide, agency-level, service-level, or a combination.")
              )
            } else {
              div(
                class = "measure-scope-options scope-derived full-width",
                tags$input(id = "measure_is_city", type = "hidden", value = if (scope_city) "true" else "false"),
                tags$input(id = "measure_is_agency", type = "hidden", value = if (scope_agency) "true" else "false"),
                tags$input(id = "measure_is_service", type = "hidden", value = if (scope_service) "true" else "false"),
                div(class = "scope-derived-grid", span("Scope"), strong(scope_label)),
                p(class = "scope-admin-note", "Scope is system-managed. It is determined by whether the measure is used in a service, an agency goal, or a citywide metric designation. Quasi-agency and mayoral service plans are service-scoped even when their plan includes goals.")
              )
            }
          )
        ),
        tags$section(
          class = "modal-section-block measure-form-section",
          h3("Fiscal Year Actuals & Targets"),
          p("Enter annual actuals and targets. Notes should explain revisions, data quality issues, or target rationale."),
          div(
            class = "measure-year-list",
            lapply(measure_entry_years(), function(year) {
              div(
                class = "measure-year-row",
                h4(paste0("FY", year)),
                measure_value_input(paste0("measure_actual_", year), measure_label("Actual", "Enter the reported annual value for this fiscal year."), annual_value(year, "annual_actual", NA), selected_format),
                measure_note_input(paste0("measure_actual_notes_", year), measure_label("Actual notes", "Optional note on data quality, revisions, unusual events, or interpretation. Maximum 200 characters."), annual_value(year, "annual_actual_notes")),
                measure_value_input(paste0("measure_target_", year), measure_label(if (year == target_fy) "Next Fiscal Year Target" else "Target", "Enter the target value for this fiscal year.", year == target_fy), annual_value(year, "target_value", NA), selected_format),
                measure_note_input(paste0("measure_target_notes_", year), measure_label("Target notes", "Optional note explaining target rationale, assumptions, or revisions. Maximum 200 characters."), annual_value(year, "target_value_notes"))
              )
            })
          )
        )
      ),
      div(
        class = "measure-modal-actions",
        div(if (!is_new && isTRUE(value("active", TRUE))) tags$button(id = "request_measure_deactivate", type = "button", class = "civic-button danger small", icon("ban"), "Make inactive"), if (!is_new && !isTRUE(value("active", TRUE))) actionButton("reactivate_measure", "Reactivate", class = "civic-button secondary small")),
        div(
          class = "measure-submit-group",
          p(class = "approval-workflow-note", "Submit for approval currently marks this measure pending. The system admin review panel will be added in a later workflow step."),
          div(
            tags$button(id = "save_measure", type = "button", class = "civic-button secondary", "Save"),
            tags$button(id = "submit_measure", type = "button", class = "civic-button primary", "Submit for approval")
          )
        )
      ),
      tags$dialog(
        id = "deactivate_measure_dialog",
        class = "confirmation-dialog",
        div(class = "confirmation-dialog-panel", div(class = "confirmation-dialog-icon", icon("triangle-exclamation")), h2("Are you sure you want to make this measure inactive?"), p("It will no longer be available for new Goal KPI or Service Metric selections. Its history will be retained."), div(class = "confirmation-dialog-actions", tags$button(id = "cancel_measure_deactivate", type = "button", class = "civic-button secondary small", "Cancel"), actionButton("confirm_deactivate_measure", "Make inactive", class = "civic-button danger small")))
      )
    )
  )
}

page_metrics <- function(db, agency_id, status_filter = "Validated") {
  plan <- current_plan(db, agency_id)
  measures <- measure_library_rows(db, plan, include_ineligible = TRUE)
  status_labels <- if (nrow(measures)) {
    vapply(seq_len(nrow(measures)), function(i) measure_library_status(measures[i, , drop = FALSE])$label, character(1))
  } else {
    character(0)
  }
  status_choices <- c("All statuses", sort(unique(status_labels)))
  selected_status <- status_filter %||% "Validated"
  if (!selected_status %in% status_choices) selected_status <- "All statuses"
  if (!identical(selected_status, "All statuses")) {
    measures <- measures[status_labels == selected_status, , drop = FALSE]
    status_labels <- status_labels[status_labels == selected_status]
  }
  snapshot_years <- fiscal_measure_snapshot_years()
  builder_page(
    "Measures",
    "Review, update, and submit agency performance measures for validation.",
    surface(
      "Measure Library",
      "Select a row to review its definition, validation criteria, and five-year data history.",
      div(
        class = "measure-library-toolbar",
        div(
          class = "measure-library-filter",
          selectInput("measure_status_filter", "Status", choices = status_choices, selected = selected_status, selectize = FALSE)
        ),
        span(class = "measure-library-count", paste(nrow(measures), if (nrow(measures) == 1) "measure" else "measures"))
      ),
      div(
        class = "app-table measure-library-table",
        div(
          class = "table-row table-head metrics-row",
          span("Measure"),
          span(paste0("FY", substr(snapshot_years$actual_fy, 3, 4), " Actual / FY", substr(snapshot_years$target_fy, 3, 4), " Target")),
          span("Status"),
          span("Updated")
        ),
        lapply(seq_len(nrow(measures)), function(i) {
          history <- db$performance_measure_actuals[db$performance_measure_actuals$measure_id == measures$measure_id[i], , drop = FALSE]
          actual_row <- history[history$fiscal_year == snapshot_years$actual_fy, , drop = FALSE]
          target_row <- history[history$fiscal_year == snapshot_years$target_fy, , drop = FALSE]
          actual <- if (nrow(actual_row)) format_measure_value(actual_row$annual_actual[1], measures$format_type[i], measures$display_unit[i], "Not reported") else "Not reported"
          target <- if (nrow(target_row)) format_measure_value(target_row$target_value[1], measures$format_type[i], measures$display_unit[i], "Not set") else "Not set"
          status_meta <- measure_library_status(measures[i, , drop = FALSE])
          tags$button(
            type = "button",
            class = "table-row metrics-row measure-library-row",
            `data-measure-id` = measures$measure_id[i],
            span(measures$title[i]),
            span(paste(actual, "/", target)),
            status_chip(status_meta$label, status_meta$tone),
            span(format(as.POSIXct(measures$last_updated[i]), "%b %d, %Y"))
          )
        })
      ),
      actions = tags$button(type = "button", class = "civic-button primary", `data-new-measure` = "true", icon("plus"), "Build a new measure")
    ),
    plan_id = plan$plan_id,
    section_key = "measures",
    show_save = FALSE,
    show_status = FALSE
  )
}

page_overview <- function(db, agency_id) {
  plan <- current_plan(db, agency_id)
  mv <- db$performance_overview_vision[db$performance_overview_vision$plan_id == plan$plan_id, , drop = FALSE]
  builder_page(
    "Agency Overview & Vision",
    "Define the agency's resident-facing purpose and the future it is working toward.",
    tagList(
      surface(
        "Overview & vision statements",
        "Use the guidance below to keep each statement concise, specific, and connected to resident outcomes.",
        div(
          class = "statement-editor",
          div(
            class = "statement-field",
            div(class = "statement-field-header", tags$label(`for` = "agency_summary", "Overview"), span("3-5 lines", class = "statement-length")),
            p(
              class = "field-guidance",
              "The agency overview should answer one question: what does your agency exist to achieve? In two to four sentences, describe your agency's core purpose in terms of the outcomes it produces for Baltimore residents - not the services it administers or the programs it runs. Avoid listing bureaus, divisions, or statutory functions. A strong overview names who the agency serves, what changes or conditions it is responsible for, and why that work matters to the city. If your overview could apply to any city agency, it is too broad; if it reads like an org chart, it is too operational."
            ),
            textAreaInput("agency_summary", label = NULL, rows = 6, value = mv$overview)
          ),
          div(
            class = "statement-field",
            div(class = "statement-field-header", tags$label(`for` = "agency_vision", "Vision"), span("2-3 lines", class = "statement-length")),
            p(
              class = "field-guidance",
              "Your vision statement should describe the future state your agency is working toward - the condition that would exist if your work were fully successful. It should be aspirational but grounded, and specific enough that someone outside city government could understand what success looks like for your agency. The vision should also reflect a clear connection to the Mayor's Action Plan: a reader should be able to look at your vision and your goals together and understand how your agency's work contributes to the administration's strategic priorities. You do not need to name a specific Action Plan goal, but the alignment should be genuine and apparent - not a passing reference or a restatement of the plan's language dropped in without context."
            ),
            textAreaInput("agency_vision", label = NULL, rows = 5, value = mv$vision)
          ),
          div(class = "website-field", textInput("agency_website", "Agency web address", value = mv$web_address))
        )
      ),
      surface(
        "Reference rubric",
        "Use these scoring descriptions to review the statements before submitting the plan.",
        div(
          class = "rubric-table-wrap",
          tags$table(
            class = "rubric-table",
            tags$caption(class = "sr-only", "Agency overview and vision scoring rubric"),
            tags$thead(tags$tr(
              tags$th(scope = "col", "Criterion"),
              tags$th(scope = "col", "Max points", span(class = "rubric-header-note", "Weighted score")),
              tags$th(scope = "col", "Needs revision"),
              tags$th(scope = "col", "Developing"),
              tags$th(scope = "col", "Meets expectations"),
              tags$th(scope = "col", "Strong")
            )),
            tags$tbody(
              tags$tr(
                tags$th(scope = "row", "Agency Overview"),
                tags$td(class = "rubric-points", "5"),
                tags$td("Missing, placeholder, or too vague to convey agency purpose."),
                tags$td("Describes activities or programs but does not articulate the agency's role in producing outcomes."),
                tags$td("Conveys agency purpose clearly but remains somewhat broad or operationally framed."),
                tags$td(class = "rubric-strong", "Clear, concise, outcome-oriented statement of why the agency exists and what it aims to achieve.")
              ),
              tags$tr(
                tags$th(scope = "row", "Vision & Linkage to Mayor's Action Plan"),
                tags$td(class = "rubric-points", "5"),
                tags$td("No connection to the Mayor's Action Plan is present, or the vision is missing entirely."),
                tags$td("A reference to the Action Plan is included but feels appended or generic; the connection to the agency's actual work is not clear."),
                tags$td("The vision reflects a plausible connection to the administration's strategic priorities, but the alignment is not fully developed."),
                tags$td(class = "rubric-strong", "The vision is clearly oriented toward the administration's strategic priorities; a reader can understand how the agency's work contributes to those priorities.")
              )
            )
          )
        )
      )
    ),
    plan_id = plan$plan_id,
    section_key = "overview",
    locked = !plan_is_editable(plan)
  )
}

page_goals <- function(db, agency_id) {
  plan <- current_plan(db, agency_id)
  goals <- db$performance_agency_goal[db$performance_agency_goal$plan_id == plan$plan_id, , drop = FALSE]
  goals <- goals[order(goals$sort_order), , drop = FALSE]
  agency_measures <- goal_kpi_choice_rows(db, plan, goals)
  goal_count <- nrow(goals)
  goal_readiness <- goal_draft_readiness(db, plan, goals)
  drafted_count <- goal_readiness$complete_count
  aligned_count <- goal_readiness$aligned_count
  minimum_goals <- goal_minimum_count(plan)
  maximum_goals <- goal_maximum_count(plan)
  minimum_goals_label <- goal_count_word(minimum_goals)
  maximum_goals_label <- goal_count_word(maximum_goals)
  remaining_count <- max(0, maximum_goals - goal_count)
  pillar_goal_codes <- db$reference_pillar_goal$goal_code
  pillar_goal_labels <- paste(db$reference_pillar_goal$goal_code, db$reference_pillar_goal$goal_title)
  alignment_choices <- c("Not aligned" = "", setNames(pillar_goal_codes, pillar_goal_labels))
  kpi_choices <- setNames(agency_measures$measure_id, agency_measures$title)
  history_years <- 2022:2026

  goal_rubric_row <- function(criterion, points, score_1, score_2, score_3, score_4, class = NULL) {
    tags$tr(
      class = class,
      tags$th(scope = "row", criterion),
      tags$td(class = "rubric-points", points),
      tags$td(score_1),
      tags$td(score_2),
      tags$td(score_3),
      tags$td(class = "rubric-strong", score_4)
    )
  }

  goal_rubric_table <- function(caption, rows) {
    div(
      class = "rubric-section-table-wrap",
      `aria-hidden` = "true",
      tags$table(
        class = "rubric-table goal-rubric-table",
        tags$caption(class = "sr-only", caption),
        tags$thead(tags$tr(
          tags$th(scope = "col", "Criterion"),
          tags$th(scope = "col", "Max points", span(class = "rubric-header-note", "Weighted score")),
          tags$th(scope = "col", "Score 1", span(class = "rubric-header-note", "Incomplete")),
          tags$th(scope = "col", "Score 2", span(class = "rubric-header-note", "Developing")),
          tags$th(scope = "col", "Score 3", span(class = "rubric-header-note", "Strong")),
          tags$th(scope = "col", "Score 4", span(class = "rubric-header-note", "Exemplary"))
        )),
        tags$tbody(rows)
      )
    )
  }

  builder_page(
    "Agency Goals, Initiatives & KPIs",
    paste0("Set ", minimum_goals_label, " to ", maximum_goals_label, " outcome-oriented goals and define how the agency will achieve and measure each one."),
    div(
      class = "goals-page",
      `data-agency-id` = agency_id,
      `data-plan-id` = plan$plan_id,
      `data-min-goals` = minimum_goals,
      `data-max-goals` = maximum_goals,
      surface(
        "Goal requirements",
        paste0("Write each goal as a SMART, outcome-based result. Then add an initiative, KPI, and optional Action Plan Pillar Goal. You must add at least ", minimum_goals_label, " goals, max is ", maximum_goals_label, "."),
        div(
          class = "goal-requirements",
          div(
            class = "goal-requirement-stat goals-drafted-stat",
            strong(class = "draft-goal-count", drafted_count),
            span("Goals drafted"),
            div(
              class = "goal-requirement-detail",
              status_chip(if (drafted_count >= minimum_goals) "Minimum met" else paste(minimum_goals - drafted_count, "more required"), if (drafted_count >= minimum_goals) "success" else "error")
            )
          ),
          div(
            class = "goal-requirement-stat pillar-alignment-stat",
            strong(class = "draft-aligned-count", aligned_count),
            span("Action Plan aligned"),
            status_chip(if (aligned_count >= 1) "Minimum met" else "One required", if (aligned_count >= 1) "success" else "error")
          )
        )
      ),
      surface(
        "Goals",
        paste0("Write each goal as a SMART, outcome-based result. Then add an initiative, KPI, and optional Action Plan Pillar Goal. You must add at least ", minimum_goals_label, " goals, max is ", maximum_goals_label, "."),
        div(
          class = "goal-editor-list",
          lapply(seq_len(goal_count), function(i) {
            goal_id <- goals$agency_goal_id[i]
            initiative_link <- db$performance_agency_goal_initiative_link[db$performance_agency_goal_initiative_link$agency_goal_id == goal_id, , drop = FALSE]
            initiative_values <- character(0)
            if (nrow(initiative_link) > 0) {
              initiative_rows <- db$performance_initiative[match(initiative_link$initiative_id, db$performance_initiative$initiative_id), , drop = FALSE]
              initiative_values <- initiative_rows$title[!is.na(initiative_rows$title)]
            }
            if (length(initiative_values) == 0) initiative_values <- ""
            initiative_input_rows <- lapply(seq_along(initiative_values), function(initiative_index) {
              initiative_input_id <- paste0("goal_initiative_", goal_id, if (initiative_index == 1) "" else paste0("_", initiative_index))
              div(
                class = "initiative-input-row",
                textAreaInput(initiative_input_id, label = NULL, rows = 3, value = initiative_values[initiative_index]),
                if (initiative_index > 1) tags$button(type = "button", class = "initiative-remove-button", title = "Remove initiative", `aria-label` = "Remove initiative", icon("xmark"))
              )
            })
            measure_link <- db$performance_pm_goal_link[db$performance_pm_goal_link$agency_goal_id == goal_id, , drop = FALSE]
            selected_measure <- if (nrow(measure_link) > 0) as.character(measure_link$measure_id) else character(0)
            initial_kpis <- if (length(selected_measure) > 0) selected_measure else ""
            kpi_selector_rows <- lapply(seq_along(initial_kpis), function(kpi_index) {
              div(
                class = "kpi-select-row",
                selectInput(
                  paste0("goal_kpi_", goal_id, "_", kpi_index),
                  label = NULL,
                  choices = c("Select a performance measure" = "", kpi_choices),
                  selected = initial_kpis[kpi_index],
                  selectize = FALSE
                ),
                if (kpi_index > 1) tags$button(type = "button", class = "kpi-remove-button", title = "Remove KPI", `aria-label` = "Remove KPI", icon("xmark"))
              )
            })

            kpi_previews <- lapply(seq_len(nrow(agency_measures)), function(measure_index) {
              measure <- agency_measures[measure_index, , drop = FALSE]
              history <- db$performance_measure_actuals[db$performance_measure_actuals$measure_id == measure$measure_id, , drop = FALSE]
              actual_values <- vapply(history_years, function(year) {
                row <- history[history$fiscal_year == year, , drop = FALSE]
                if (nrow(row) == 0) "Not reported" else format_measure_value(row$annual_actual[1], measure$format_type[1], measure$display_unit[1])
              }, character(1))
              target_values <- vapply(history_years, function(year) {
                row <- history[history$fiscal_year == year, , drop = FALSE]
                if (nrow(row) == 0) "Not set" else format_measure_value(row$target_value[1], measure$format_type[1], measure$display_unit[1], "Not set")
              }, character(1))

              div(
                class = paste("kpi-measure-preview", if (as.character(measure$measure_id) %in% selected_measure) "active" else ""),
                `data-measure-id` = as.character(measure$measure_id),
                div(
                  class = "kpi-preview-header",
                  div(span("Selected performance measure", class = "goal-number"), h4(measure$title)),
                  div(class = "chip-row", status_chip(measure$desired_direction, "success"), status_chip(measure$measure_type, "primary"))
                ),
                div(
                  class = "kpi-history-wrap",
                  tags$table(
                    class = "kpi-history-table",
                    tags$caption(class = "sr-only", paste(measure$title, "five-year actuals and targets")),
                    tags$thead(tags$tr(tags$th(scope = "col", "Series"), lapply(history_years, function(year) tags$th(scope = "col", paste0("FY", year))))),
                    tags$tbody(
                      tags$tr(tags$th(scope = "row", "Target"), lapply(target_values, tags$td)),
                      tags$tr(tags$th(scope = "row", "Actual"), lapply(actual_values, tags$td))
                    )
                  )
                )
              )
            })

            tags$details(
              class = "goal-editor",
              `data-goal-id` = goal_id,
              tags$summary(
                div(
                  class = "goal-editor-summary",
                  div(span(paste("Goal", i), class = "goal-number"), strong(goals$title[i])),
                  status_chip(if (nzchar(goals$alignment_code[i])) "Action Plan Aligned" else "Not Action Plan Aligned", if (nzchar(goals$alignment_code[i])) "success" else "primary")
                )
              ),
              div(
                class = "goal-editor-body",
                `aria-hidden` = "true",
                div(
                  class = "goal-form-field full-width goal-statement-field",
                  tags$label(class = "control-label", `for` = paste0("goal_statement_", goal_id), "Goal statement"),
                  p(class = "goal-field-instruction", "Describe what your agency intends to achieve this fiscal year, expressed as an outcome for Baltimore residents. Your goal should be specific, measurable, and time-bound - not a description of work your agency will do."),
                  textAreaInput(paste0("goal_statement_", goal_id), label = NULL, rows = 3, value = goals$title[i])
                ),
                div(
                  class = "goal-form-field full-width initiative-picker",
                  tags$label(class = "control-label", `for` = paste0("goal_initiative_", goal_id), "FY2027 initiatives"),
                  p(class = "goal-field-instruction", "Identify one key action or project your agency will undertake this year to advance this goal. Be specific about what will be done and who is responsible - avoid restating the goal in different words."),
                  div(class = "initiative-inputs", `data-goal-id` = goal_id, initiative_input_rows),
                  tags$button(type = "button", class = "civic-button secondary small add-initiative-button", icon("plus"), "Add initiative")
                ),
                div(
                  class = "goal-form-field",
                  selectInput(paste0("goal_alignment_", goal_id), "Action Plan Pillar Goal (optional, one agency goal must align)", choices = alignment_choices, selected = goals$alignment_code[i], selectize = FALSE)
                ),
                div(
                  class = "goal-form-field full-width kpi-picker",
                  tags$label(class = "control-label", `for` = paste0("goal_kpi_", goal_id, "_1"), "Key performance indicators"),
                  p(class = "goal-field-instruction", "Choose from the agency's validated performance measures. Review the measure definition and five-year history before selecting it."),
                  p(class = "goal-field-instruction", "Select the measure that best captures whether this goal is being achieved. Choose outcome or leading indicators where possible - avoid selecting measures that only count activity or workload. A KPI can also serve as a service-level metric; you may see the same measure appear in both places."),
                  div(class = "kpi-selectors", `data-goal-id` = goal_id, kpi_selector_rows),
                  div(
                    class = "goal-field-support",
                    strong("Add another KPI"),
                    p("Add a KPI if this goal requires more than one measure to capture success. Each measure can only be assigned to one goal - if a measure is already in use for another goal it will be greyed out and unavailable in your selection list."),
                    tags$button(type = "button", class = "civic-button secondary small add-kpi-button", icon("plus"), "Add another KPI")
                  ),
                  div(class = "kpi-preview-list", kpi_previews),
                  div(
                    class = "goal-field-support new-measure-support",
                    strong("Don't see the right measure?"),
                    p("If none of the available measures adequately captures progress toward this goal, you can build a new measure. You'll be taken to the measure builder to define it - once submitted, it will be added to your agency's measure library and available for selection here."),
                  tags$button(type = "button", class = "civic-button secondary small", `data-page` = "metrics", `data-new-measure` = "true", icon("plus"), "Build a new measure")
                  )
                ),
                div(
                  class = "goal-editor-actions",
                  tags$button(type = "button", class = "civic-button danger small remove-goal-button", icon("trash-can"), "Remove goal")
                )
              )
            )
          })
        ),
        actions = tags$button(id = "add_goal", type = "button", class = "civic-button primary", disabled = if (goal_count >= maximum_goals) "disabled" else NULL, icon("plus"), "Add goal")
      ),
      surface(
        "Goals scoring rubric",
        "Each goal is scored independently. The Pillar Goal Alignment criterion is optional; at least one agency goal must include it.",
        div(
          class = "rubric-sections",
          tags$details(
            class = "rubric-section",
            tags$summary(div(strong("Goal statement"), span("2 criteria"))),
            goal_rubric_table(
              "Goal statement scoring rubric",
              tagList(
              goal_rubric_row("Goal Quality (SMART & Outcome-Oriented)", "8", "Goal is vague, initiative-based, or describes an activity rather than an intended result.", "Goal names an intended result but is missing two or more SMART elements.", "Goal is outcome-oriented and meets at least four SMART elements; it may have a minor gap.", "Goal is fully SMART: specific, measurable, outcome-based, realistic, and explicitly time-bound."),
                goal_rubric_row("Pillar Goal Alignment (optional)", "7", "A Pillar Goal is named, but the agency goal has no discernible connection to it.", "The named Pillar Goal is a stretch; the connection requires significant inference.", "The named Pillar Goal is a reasonable match; the connection is logical but not precise.", "The named Pillar Goal is a clear and direct match for what the agency goal is trying to achieve.")
              )
            )
          ),
          tags$details(
            class = "rubric-section",
            tags$summary(div(strong("FY2027 initiatives"), span("2 criteria"))),
            goal_rubric_table(
              "FY2027 initiatives scoring rubric",
              tagList(
              goal_rubric_row("Strategic Coherence", "8", "The initiative is unrelated to the goal, or no initiative is identified.", "A connection can be inferred, but the logic requires assumptions to follow.", "A logical link is present, but the causal reasoning is not fully explained.", "The initiative clearly advances the goal, and the causal logic is explicit."),
                goal_rubric_row("Concreteness of Initiative", "7", "The initiative is missing, vague, or restates the goal.", "The initiative lacks scope, timeline, or ownership; feasibility is unclear.", "Scope is described and feasible; timeline or ownership may be implied.", "The initiative has clear scope, timeline, ownership, and an understandable delivery approach.")
              )
            )
          ),
          tags$details(
            class = "rubric-section",
            tags$summary(div(strong("Key performance indicators"), span("3 criteria"))),
            goal_rubric_table(
              "Key performance indicators scoring rubric",
              tagList(
              goal_rubric_row("KPI Quality", "10", "The KPI measures activity or outputs without connecting to the intended result.", "The KPI is partially aligned but primarily reflects workload, throughput, or a narrow service area.", "The KPI captures a meaningful outcome or leading indicator but may not fully reflect the goal.", "The KPI directly measures whether the goal is being achieved and emphasizes outcomes or leading indicators."),
              goal_rubric_row("KPI Definition & Validation Rigor", "10", "The KPI is missing, undefined, or its calculation method is unclear.", "Two or more required elements are absent, such as definition, source, formula, or direction of success.", "Most required elements are present, with one or two minor clarity or sourcing gaps.", "Definition, data source, calculation, ownership, and direction of success are clearly documented."),
              goal_rubric_row("KPI Baseline & Target Readiness", "10", "No baseline and no target are identified.", "Historical data is incomplete, undated, or unreliable, and no validated target is set.", "A baseline and target exist, but the target lacks validation, rationale, or a clear timeframe.", "A reliable baseline and time-bound target are documented with a clear rationale.")
              )
            )
          )
        )
      ),
      tags$dialog(
        id = "delete_goal_dialog",
        class = "confirmation-dialog",
        div(
          class = "confirmation-dialog-panel",
          div(class = "confirmation-dialog-icon", icon("triangle-exclamation")),
          h2("Are you sure you want to delete this goal?"),
          p("This removes the goal and its initiatives, alignment, and KPI selections from the current draft."),
          div(
            class = "confirmation-dialog-actions",
            tags$button(id = "cancel_goal_delete", type = "button", class = "civic-button secondary small", "Cancel"),
            tags$button(id = "confirm_goal_delete", type = "button", class = "civic-button danger small", icon("trash-can"), "Delete goal")
          )
        )
      )
    ),
    plan_id = plan$plan_id,
    section_key = "goals",
    locked = !plan_is_editable(plan)
  )
}

page_services <- function(db, agency_id) {
  plan <- current_plan(db, agency_id)
  service_rows <- plan_service_rows(db, plan)
  measures <- eligible_plan_measures(measure_library_rows(db, plan, include_ineligible = FALSE))
  metric_choices <- setNames(measures$measure_id, measures$title)
  history_years <- 2022:2026
  service_rubric_row <- function(criterion, points, score_1, score_2, score_3, score_4) {
    tags$tr(
      tags$th(scope = "row", criterion),
      tags$td(class = "rubric-points", points),
      tags$td(score_1),
      tags$td(score_2),
      tags$td(score_3),
      tags$td(class = "rubric-strong", score_4)
    )
  }
  service_rubric_table <- function(caption, rows) {
    div(
      class = "rubric-section-table-wrap",
      `aria-hidden` = "true",
      tags$table(
        class = "rubric-table goal-rubric-table",
        tags$caption(class = "sr-only", caption),
        tags$thead(tags$tr(
          tags$th(scope = "col", "Criterion"),
          tags$th(scope = "col", "Max points", span(class = "rubric-header-note", "Weighted score")),
          tags$th(scope = "col", "Score 1", span(class = "rubric-header-note", "Incomplete")),
          tags$th(scope = "col", "Score 2", span(class = "rubric-header-note", "Developing")),
          tags$th(scope = "col", "Score 3", span(class = "rubric-header-note", "Strong")),
          tags$th(scope = "col", "Score 4", span(class = "rubric-header-note", "Exemplary"))
        )),
        tags$tbody(rows)
      )
    )
  }
  builder_page(
    "Agency Services",
    "Review each service description and select the metrics that show whether the service is delivering results.",
    tagList(
      surface(
        "Services",
        "Open a service to review its description, select metrics, and inspect five years of actuals and targets.",
        div(
          class = "goal-editor-list service-editor-list services-page",
          `data-agency-id` = agency_id,
          `data-plan-id` = plan$plan_id,
          lapply(seq_len(nrow(service_rows)), function(i) {
          service_id <- service_rows$service_id[i]
          selected_metric_ids <- service_metric_ids(db, plan, service_id, measures)
          selected_metrics <- if (length(selected_metric_ids) > 0) as.character(selected_metric_ids) else ""
          metric_selector_rows <- lapply(seq_along(selected_metrics), function(metric_index) {
            div(
              class = "kpi-select-row",
              selectInput(
                paste0("service_metric_", service_id, "_", metric_index),
                label = NULL,
                choices = c("Select a metric" = "", metric_choices),
                selected = selected_metrics[metric_index],
                selectize = FALSE
              ),
              if (metric_index > 1) tags$button(type = "button", class = "kpi-remove-button", title = "Remove metric", `aria-label` = "Remove metric", icon("xmark"))
            )
          })
          metric_previews <- lapply(seq_len(nrow(measures)), function(measure_index) {
            measure <- measures[measure_index, , drop = FALSE]
            history <- db$performance_measure_actuals[db$performance_measure_actuals$measure_id == measure$measure_id, , drop = FALSE]
            actual_values <- vapply(history_years, function(year) {
              row <- history[history$fiscal_year == year, , drop = FALSE]
              if (nrow(row) == 0) "Not reported" else format_measure_value(row$annual_actual[1], measure$format_type[1], measure$display_unit[1])
            }, character(1))
            target_values <- vapply(history_years, function(year) {
              row <- history[history$fiscal_year == year, , drop = FALSE]
              if (nrow(row) == 0) "Not set" else format_measure_value(row$target_value[1], measure$format_type[1], measure$display_unit[1], "Not set")
            }, character(1))
            div(
              class = paste("kpi-measure-preview", if (as.character(measure$measure_id) %in% selected_metrics) "active" else ""),
              `data-measure-id` = as.character(measure$measure_id),
              div(
                class = "kpi-preview-header",
                div(span("Selected metric", class = "goal-number"), h4(measure$title)),
                div(class = "chip-row", status_chip(measure$desired_direction, "success"), status_chip(measure$measure_type, "primary"))
              ),
              div(
                class = "kpi-history-wrap",
                tags$table(
                  class = "kpi-history-table",
                  tags$caption(class = "sr-only", paste(measure$title, "five-year actuals and targets")),
                  tags$thead(tags$tr(tags$th(scope = "col", "Series"), lapply(history_years, function(year) tags$th(scope = "col", paste0("FY", year))))),
                  tags$tbody(
                    tags$tr(tags$th(scope = "row", "Target"), lapply(target_values, tags$td)),
                    tags$tr(tags$th(scope = "row", "Actual"), lapply(actual_values, tags$td))
                  )
                )
              )
            )
          })
          tags$details(
            class = "goal-editor service-editor",
            `data-service-id` = service_id,
            tags$summary(
              div(
                class = "goal-editor-summary",
                div(span(paste("Service", i), class = "goal-number"), strong(service_rows$service_name[i])),
                span(class = "status-chip tone-primary service-metric-count", paste(sum(nzchar(selected_metrics)), if (sum(nzchar(selected_metrics)) == 1) "Metric" else "Metrics"))
              )
            ),
            div(
              class = "goal-editor-body service-editor-body",
              `aria-hidden` = "true",
              div(
                class = "goal-form-field full-width",
                tags$label(class = "control-label", `for` = paste0("service_description_", service_id), "Service description"),
                p(class = "goal-field-instruction", "Describe the service in a consistent outcome-oriented structure: start with what the service provides, explain the goal or value it creates for the agency or residents, then name the core activities performed by the service."),
                p(class = "goal-field-instruction", "A strong description should avoid a simple task list. It should connect administrative, operational, or resident-facing work to the agency's strategic priorities, such as operational success, accountability, effective use of data, service excellence, or attracting and retaining talented people."),
                p(class = "goal-field-instruction", "Example structure: This service provides executive direction, communications and public relations, fiscal management, human capital management, and performance management for the department. The goal of this service is to drive innovation, promote the agency's strategic plan, and strengthen service excellence. Activities performed by this service include administrative direction, fiscal management, human resource support, performance management, communications, and change management."),
                textAreaInput(paste0("service_description_", service_id), label = NULL, rows = 4, value = service_rows$service_description[i])
              ),
              div(
                class = "goal-form-field full-width kpi-picker service-metric-picker",
                tags$label(class = "control-label", `for` = paste0("service_metric_", service_id, "_1"), "Metrics"),
                p(class = "goal-field-instruction", "Choose from the agency's validated performance measures. Review the measure definition and five-year history before selecting it."),
                p(class = "goal-field-instruction", "Select the metric that best captures the quality, timeliness, efficiency, or outcomes of this service. Choose outcome or leading indicators where possible - avoid selecting metrics that only count activity or workload. A metric can also serve as a goal-level KPI; you may see the same measure appear in both places."),
                div(class = "kpi-selectors service-metric-selectors", `data-service-id` = service_id, metric_selector_rows),
                div(
                  class = "goal-field-support",
                  strong("Add another metric"),
                  p("Add a metric if this service requires more than one measure to capture performance. Each measure can only be assigned to one service - if a measure is already in use for another service it will be greyed out and unavailable in your selection list."),
                  tags$button(type = "button", class = "civic-button secondary small add-kpi-button", icon("plus"), "Add another metric")
                ),
                div(class = "kpi-preview-list", metric_previews),
                div(
                  class = "goal-field-support new-measure-support",
                  strong("Don't see the right metric?"),
                  p("If none of the available measures adequately captures this service's performance, you can build a new metric. You'll be taken to the measure builder to define it - once submitted, it will be added to your agency's measure library and available for selection here."),
                  tags$button(type = "button", class = "civic-button secondary small", `data-page` = "metrics", `data-new-measure` = "true", icon("plus"), "Build a new metric")
                )
              )
            )
          )
          })
        )
      ),
      surface(
        "Services scoring rubric",
        "Use these scoring descriptions to review service descriptions and service-level metrics before submitting the plan.",
        div(
          class = "rubric-sections",
          tags$details(
            class = "rubric-section",
            tags$summary(div(strong("Service description"), span("2 criteria"))),
            service_rubric_table(
              "Service description scoring rubric",
              tagList(
                service_rubric_row("Service Purpose & Outcome Orientation", "5", "Description is missing, placeholder, or only names a bureau, division, or activity.", "Description lists activities or administrative functions but does not explain the service's purpose or value.", "Description identifies what the service provides and who or what it supports, but the intended outcome is broad or only partly clear.", "Description clearly explains what the service provides, the outcome or value it creates, and why the service matters to agency performance or residents."),
                service_rubric_row("Strategic Coherence & Activity Clarity", "5", "Activities are missing or disconnected from the service purpose.", "Activities are listed but read like an org chart or task inventory, with little connection to strategy or results.", "Core activities are described and generally connect to service purpose, but the link to agency priorities or operational success could be clearer.", "Core activities are specific, coherent, and clearly connected to agency priorities, operational success, accountability, effective data use, talent, or service excellence.")
              )
            )
          ),
          tags$details(
            class = "rubric-section",
            tags$summary(div(strong("Service metrics"), span("3 criteria"))),
            service_rubric_table(
              "Service metric scoring rubric",
              tagList(
                service_rubric_row("Metric Quality [service-level; distinct from goal-level KPIs]", "5", "Metrics are not aligned to the services being tracked, or only restate the KPI.", "Metrics are primarily workload or activity counts, such as number of permits issued or calls answered, and provide limited insight into service quality or performance.", "Metrics are aligned to the service and include useful process or service quality indicators; may lack leading measures or actionability for frontline managers.", "Metrics are highly actionable, clearly aligned to specific services or initiatives, and include at least one leading indicator that helps managers diagnose performance and explain KPI results."),
                service_rubric_row("Definition & Validation Rigor", "5", "Metrics are missing, undefined, or cannot be consistently calculated.", "Metrics are named but two or more required elements are absent, such as definition, data source, formula, direction, or owner.", "Most required elements are present; one or two have minor gaps in clarity or operationalization.", "All required elements are complete and clearly documented: definition, data source, formula, direction of success, frequency, and responsible owner; a reviewer outside the agency could replicate the measure."),
                service_rubric_row("Baseline & Target Readiness", "5", "No baseline or expected threshold identified for any metric.", "Some historical data exists but baselines are partial, undated, or inconsistent across metrics.", "Baselines are established for most metrics; targets or thresholds exist but may lack rationale, validation, or time-bound achievement dates.", "Baselines are documented and reliable; targets, thresholds, or SLAs are clearly defined with rationale, are time-bound, and are ready for management use.")
              )
            )
          )
        )
      )
    ),
    plan_id = plan$plan_id,
    section_key = "services",
    locked = !plan_is_editable(plan)
  )
}

page_risks <- function(db, agency_id) {
  plan <- current_plan(db, agency_id)
  risks <- db$performance_service_risk[db$performance_service_risk$plan_id == plan$plan_id, , drop = FALSE]
  builder_page(
    "Plan Risks",
    "Capture delivery risks, mitigations, and unresolved dependencies.",
    surface(
      "Risk register",
      NULL,
      div(
        class = "app-table risk-register-table",
        div(class = "table-row table-head risk-row", span("Type"), span("Risk")),
        lapply(seq_len(nrow(risks)), function(i) {
          tags$button(
            type = "button",
            class = "table-row risk-row risk-register-row",
            `data-risk-id` = risks$risk_id[i],
            span(risk_type_label(risks$risk_type[i])),
            span(risks$description[i])
          )
        })
      ),
      actions = tags$button(type = "button", class = "civic-button primary", `data-new-risk` = "true", icon("plus"), "Add risk")
    ),
    plan_id = plan$plan_id,
    section_key = "risks"
  )
}

risk_modal_ui <- function(db, agency_id, risk_id = NULL) {
  plan <- current_plan(db, agency_id)
  risk <- if (is.null(risk_id)) data.frame() else db$performance_service_risk[db$performance_service_risk$risk_id == risk_id & db$performance_service_risk$plan_id == plan$plan_id, , drop = FALSE]
  is_new <- nrow(risk) == 0
  value <- function(name, default = "") {
    if (is_new || !name %in% names(risk) || is.na(risk[[name]][1])) default else risk[[name]][1]
  }

  div(
    class = "custom-modal-backdrop risk-modal-backdrop",
    `data-close-input` = "close_risk_modal",
    div(
      class = "custom-modal risk-editor-modal",
      div(
        class = "custom-modal-header",
        div(
          class = "measure-modal-title-block",
          h2(if (is_new) "Add Risk" else "Edit Risk"),
          div(class = "chip-row measure-modal-status-row", status_chip("Plan risk", "warning"))
        ),
        actionButton("close_risk_modal", "Close", class = "civic-button secondary small")
      ),
      div(
        class = "measure-form-stack",
        tags$section(
          class = "modal-section-block measure-form-section",
          h3("Risk Details"),
          div(
            class = "measure-form-grid",
            div(
              class = "measure-field",
              selectInput(
                "risk_type",
                label = "Risk type",
                choices = risk_type_choices,
                selected = value("risk_type", "procurement"),
                selectize = FALSE
              )
            ),
            div(
              class = "measure-field full-width",
              tags$label(class = "control-label", `for` = "risk_description", "Risk description"),
              p(class = "goal-field-instruction", "Describe the delivery risk, unresolved dependency, capacity issue, funding risk, operational constraint, or external condition that could affect execution of the plan."),
              textAreaInput("risk_description", label = NULL, rows = 6, value = value("description"))
            )
          )
        )
      ),
      div(
        class = "measure-modal-actions",
        div(),
        div(
          class = "measure-submit-group",
          div(tags$button(id = "save_risk", type = "button", class = "civic-button primary", "Save risk"))
        )
      )
    )
  )
}

page_ui <- function(page, db, agency_id, measure_status_filter = "Validated", can_manage_team = FALSE) {
  if (identical(page, "services") && submitter_is_mayoral_service(db, agency_id)) {
    page <- "metrics"
  }
  switch(
    page,
    login = page_login(),
    landing = page_landing(db, agency_id),
    reviewer_dashboard = page_reviewer_dashboard(db),
    measure_review = page_measure_review(db),
    strategic_plan = page_strategic_plan(db, agency_id),
    team = page_team(db, agency_id, can_manage_team),
    plan_history = page_plan_history(db, agency_id),
    metrics = page_metrics(db, agency_id, measure_status_filter),
    overview = page_overview(db, agency_id),
    goals = page_goals(db, agency_id),
    services = page_services(db, agency_id),
    risks = page_risks(db, agency_id),
    page_landing(db, agency_id)
  )
}

ui <- tagList(
  tags$head(
    tags$title("B.O.B. Baltimore Outcome Budgeting"),
    tags$meta(name = "viewport", content = "width=device-width, initial-scale=1"),
    tags$link(rel = "stylesheet", href = "styles.css?v=20260701-12"),
    tags$script(src = "app.js?v=20260701-6", defer = "defer")
  ),
  div(
    class = "app-shell",
    tags$a(class = "skip-link", href = "#main-content", "Skip to content"),
    tags$header(
      class = "app-header",
      div(
        class = "header-inner",
        div(
        class = "brand-lockup",
          tags$img(class = "brand-mark", src = "baltimore-city-logo.png", alt = "City of Baltimore logo"),
          div(
            div(class = "brand-product", "B.O.B."),
            div(class = "brand-subtitle", "Baltimore Outcome Budgeting")
          )
        ),
        uiOutput("agency_selector_header")
      )
    ),
    div(
      class = "shell-body",
      tags$button(
        id = "toggle_desktop_nav_edge",
        type = "button",
        class = "desktop-drawer-edge-toggle",
        title = "Toggle navigation",
        `aria-label` = "Toggle navigation",
        `aria-expanded` = "true",
        span(class = "drawer-direction-icon drawer-icon-open", icon("angles-left")),
        span(class = "drawer-direction-icon drawer-icon-collapsed", icon("angles-right"))
      ),
      tags$aside(
        class = "desktop-drawer",
        div(
          class = "drawer-header",
          div(class = "drawer-title", "Navigation"),
          tags$button(
            id = "toggle_desktop_nav",
            type = "button",
            class = "icon-button desktop-drawer-toggle",
            title = "Collapse navigation",
            `aria-label` = "Collapse navigation",
            `aria-expanded` = "true",
            span(class = "drawer-direction-icon drawer-icon-open", icon("angles-left")),
            span(class = "drawer-direction-icon drawer-icon-collapsed", icon("angles-right"))
          )
        ),
        tags$nav(
          class = "drawer-nav",
          nav_item("landing", "Cycle home", icon("house")),
          nav_item("strategic_plan", "Action plan", icon("clipboard-list")),
          nav_item("team", "Team and roles", icon("users")),
          div(class = "nav-group-label performance-reviewing-nav-item", "Performance Reviewing"),
          nav_item("reviewer_dashboard", "Plan review", icon("clipboard-check"), item_class = "performance-reviewing-nav-item"),
          nav_item("measure_review", "Measure review", icon("chart-line"), item_class = "performance-reviewing-nav-item"),
          div(class = "nav-group-label", "Performance Planning"),
          nav_item("plan_history", "History & status", icon("clock-rotate-left"), "builder"),
          nav_item("overview", "Overview & vision", icon("eye"), "builder"),
          nav_item("goals", "Goals", icon("flag"), "builder"),
          nav_item("services", "Services", icon("briefcase"), "builder", "nav-services-item"),
          nav_item("metrics", "Measures", icon("chart-line"), "builder"),
          nav_item("risks", "Risks", icon("triangle-exclamation"), "builder")
        )
      ),
      tags$main(
        id = "main-content",
        class = "main-content",
        uiOutput("page")
      )
    ),
    div(
      class = "mobile-nav-backdrop",
      `data-close-mobile-nav` = "true"
    ),
    tags$nav(
      class = "mobile-nav",
      div(class = "mobile-nav-header", div(class = "drawer-title", "Navigation"), tags$button(id = "close_mobile_nav", type = "button", class = "icon-button", title = "Close navigation", `aria-label` = "Close navigation", icon("xmark"))),
      nav_item("landing", "Home", icon("house")),
      nav_item("strategic_plan", "Action plan", icon("clipboard-list")),
      nav_item("team", "Team and roles", icon("users")),
      div(class = "nav-group-label performance-reviewing-nav-item", "Performance Reviewing"),
      nav_item("reviewer_dashboard", "Plan review", icon("clipboard-check"), item_class = "performance-reviewing-nav-item"),
      nav_item("measure_review", "Measure review", icon("chart-line"), item_class = "performance-reviewing-nav-item"),
      div(class = "nav-group-label", "Performance Planning"),
      nav_item("plan_history", "History & status", icon("clock-rotate-left")),
      nav_item("overview", "Overview & vision", icon("eye")),
      nav_item("goals", "Goals", icon("flag")),
      nav_item("services", "Services", icon("briefcase"), item_class = "nav-services-item"),
      nav_item("metrics", "Measures", icon("chart-line")),
      nav_item("risks", "Risks", icon("triangle-exclamation"))
    ),
    div(
      class = "mobile-nav-toggle-bar",
      tags$button(id = "toggle_mobile_nav", type = "button", class = "mobile-nav-toggle-button", title = "Open navigation", `aria-label` = "Open navigation", `aria-expanded` = "false", icon("bars"), span("Menu"))
    ),
    tags$footer(
      class = "app-footer",
      div(
        class = "footer-inner",
        div(
          class = "footer-grid",
          div(
            class = "footer-brand-block",
            div(
              class = "footer-brand-lockup",
              tags$img(class = "footer-brand-mark", src = "baltimore-city-logo.png", alt = "City of Baltimore logo"),
              div(tags$strong("B.O.B."), span("Baltimore Outcome Budgeting"))
            ),
            tags$a(class = "footer-city-link", href = "https://baltimorecity.gov/", target = "_blank", rel = "noopener", "Baltimorecity.gov", icon("arrow-up-right-from-square"))
          ),
          div(
            class = "footer-column",
            tags$h2("Navigation"),
            tags$button(type = "button", class = "footer-link", `data-page` = "strategic_plan", "Action Plan"),
            tags$button(type = "button", class = "footer-link", `data-page` = "overview", "Overview & Vision"),
            tags$button(type = "button", class = "footer-link", `data-page` = "goals", "Goals"),
            tags$button(type = "button", class = "footer-link", `data-page` = "services", "Services"),
            tags$button(type = "button", class = "footer-link", `data-page` = "metrics", "Measures")
          ),
          div(
            class = "footer-column",
            tags$h2("City Hall"),
            span("100 N Holliday Street"),
            span("Baltimore, MD 21202"),
            span("(410) 396-5000")
          ),
          div(
            class = "footer-column footer-cta",
            tags$h2("Need Help?"),
            p("Questions about outcome budgeting, performance planning, or this workspace?"),
            tags$a(class = "footer-contact-button", href = "mailto:help@baltimorecity.gov", "Contact Support")
          )
        ),
        div(
          class = "footer-bottom",
          span("© 2026 Baltimore City Government. All rights reserved."),
          div(
            class = "footer-policy-links",
            tags$a(href = "https://baltimorecity.gov/privacy", target = "_blank", rel = "noopener", "Privacy Policy"),
            tags$a(href = "https://baltimorecity.gov/accessibility", target = "_blank", rel = "noopener", "Accessibility")
          )
        )
      )
    ),
    uiOutput("pillar_modal"),
    uiOutput("history_plan_modal"),
    uiOutput("measure_modal"),
    uiOutput("risk_modal"),
    uiOutput("team_role_modal"),
    div(
      class = "download-sink",
      downloadButton("download_plan_pdf", "Download PDF"),
      downloadButton("download_plan_pptx", "Download PowerPoint")
    )
  )
)

server <- function(input, output, session) {
  database <- connect_app_database()
  session$onSessionEnded(function() DBI::dbDisconnect(database))
  app_data <- reactiveVal(load_app_data(database))
  current_page <- reactiveVal("login")
  current_pillar_modal <- reactiveVal(NULL)
  current_measure_id <- reactiveVal(NULL)
  current_risk_id <- reactiveVal(NULL)
  current_history_plan_id <- reactiveVal(NULL)
  current_export_plan_id <- reactiveVal(NULL)
  current_workspace <- reactiveVal("agency")
  current_user_type <- reactiveVal("agency")
  current_team_access_id <- reactiveVal(NULL)

  refresh_app_data <- function() app_data(load_app_data(database))
  current_submitter_value <- function() {
    selected <- input$selected_agency
    data <- app_data()
    valid_values <- unlist(agency_selector_choices(data), use.names = FALSE)
    if (is.null(selected) || !selected %in% valid_values) "agency:AGC2600" else selected
  }
  current_agency_id <- function() {
    data <- app_data()
    plan <- current_plan(data, current_submitter_value())
    agency_id <- plan_accounting_agency_id(data, plan)
    if (is.na(agency_id) || !agency_id %in% data$reference_agency$agency_id) "AGC2600" else agency_id
  }
  current_user_is_system_admin <- function() {
    identical(current_workspace(), "admin")
  }
  current_user_can_manage_team <- function() {
    current_user_is_system_admin() || identical(current_user_type(), "agency_director")
  }

  output$agency_selector_header <- renderUI({
    data <- app_data()
    div(
      class = "header-agency-selector",
      selectInput(
        "selected_agency",
        label = NULL,
        choices = agency_selector_choices(data),
        selected = current_submitter_value(),
        selectize = TRUE,
        width = "100%"
      )
    )
  })
  observe({
    data <- app_data()
    submitter_value <- current_submitter_value()
    hide_services <- submitter_is_mayoral_service(data, submitter_value)
    session$sendCustomMessage("set-navigation-scope", list(
      hideServices = hide_services,
      showPerformanceReviewing = current_user_is_system_admin()
    ))
    if (hide_services && identical(current_page(), "services")) {
      current_page("metrics")
      session$sendCustomMessage("set-page", "metrics")
    }
    if (!current_user_is_system_admin() && current_page() %in% c("reviewer_dashboard", "measure_review")) {
      current_page("landing")
      session$sendCustomMessage("set-page", "landing")
    }
  })
  nullable_number <- function(value, integer = FALSE) {
    if (is.null(value) || length(value) == 0 || is.na(value) || identical(value, "")) return(if (integer) NA_integer_ else NA_real_)
    if (integer) as.integer(value) else as.numeric(value)
  }
  input_bool <- function(value) {
    isTRUE(value) || identical(tolower(as.character(value %||% "")), "true")
  }
  derive_measure_scope <- function(data, values) {
    values$is_city <- FALSE
    if (!is.null(values$measure_id)) {
      measure_id <- as.integer(values$measure_id)
      values$is_agency <- "performance_pm_goal_link" %in% names(data) &&
        any(data$performance_pm_goal_link$measure_id == measure_id, na.rm = TRUE)
      values$is_service <- (
        "performance_pm_service_link_all" %in% names(data) &&
          any(data$performance_pm_service_link_all$measure_id == measure_id, na.rm = TRUE)
      ) || (
        "performance_measure_entity_link" %in% names(data) &&
          any(data$performance_measure_entity_link$measure_id == measure_id, na.rm = TRUE)
      )
      if (!values$is_agency && !values$is_service) values$is_service <- TRUE
      return(values)
    }
    values$is_agency <- FALSE
    values$is_service <- TRUE
    values
  }
  limit_note <- function(value, limit = 200L) {
    if (is.null(value) || length(value) == 0 || is.na(value)) return("")
    substr(as.character(value), 1, limit)
  }
  has_two_or_fewer_decimals <- function(value) {
    is.na(value) || abs(value * 100 - round(value * 100)) < 0.000001
  }
  has_whole_number <- function(value) {
    is.na(value) || abs(value - round(value)) < 0.000001
  }
  validate_measure_values <- function(format_type, yearly_values) {
    values <- unlist(lapply(yearly_values, function(row) c(row$annual_actual, row$target_value)), use.names = FALSE)
    values <- values[!is.na(values)]
    if (!length(values)) return(NULL)
    if (identical(format_type, "Percent")) {
      if (any(values < 0 | values > 100) || any(!vapply(values, has_whole_number, logical(1)))) {
        return("For percent measures, actuals and targets must be whole numbers from 0 to 100.")
      }
    }
    if (format_type %in% c("Currency", "Count")) {
      if (any(!vapply(values, has_two_or_fewer_decimals, logical(1)))) {
        return(paste(format_type, "actuals and targets can use no more than two decimal places."))
      }
    }
    NULL
  }
  is_blank_value <- function(value) {
    is.null(value) || length(value) == 0 || is.na(value) || !nzchar(trimws(as.character(value)))
  }
  validate_measure_submit_requirements <- function(values, yearly_values, target_fy) {
    required_fields <- c(
      title = "Measure name",
      description = "Definition",
      measure_type = "Measure type",
      desired_direction = "Desired direction",
      format_type = "Format",
      data_source = "Data source",
      data_owner = "Data owner",
      data_owner_role = "Data owner role",
      update_frequency = "Update frequency",
      formula = "Formula or calculation",
      data_location = "Data location",
      collection_method = "Collection method",
      how_data_used = "How the data is used",
      why_meaningful = "Why this measure is meaningful"
    )
    missing <- unname(required_fields[vapply(names(required_fields), function(name) is_blank_value(values[[name]]), logical(1))])
    target_row <- yearly_values[vapply(yearly_values, function(row) identical(as.integer(row$fiscal_year), as.integer(target_fy)), logical(1))]
    target_missing <- !length(target_row) || is.na(target_row[[1]]$target_value)
    if (target_missing) missing <- c(missing, paste0("FY", target_fy, " Next Fiscal Year Target"))
    missing
  }
  collect_measure_form <- function() {
    data <- app_data()
    agency_id <- current_agency_id()
    plan <- current_plan(data, current_submitter_value())
    existing_id <- current_measure_id()
    existing <- if (is.null(existing_id) || identical(existing_id, "new")) data.frame() else data$performance_performance_measure[data$performance_performance_measure$measure_id == as.integer(existing_id), , drop = FALSE]
    values <- list(
      measure_id = if (nrow(existing)) existing$measure_id[[1]] else NULL,
      agency_id = agency_id,
      initial_cycle = plan$cycle_id[[1]],
      title = input$measure_title,
      measure_type = input$measure_type,
      description = input$measure_description,
      data_source = input$measure_data_source,
      data_owner = input$measure_data_owner,
      data_owner_role = input$measure_data_owner_role,
      update_frequency = input$measure_frequency,
      formula = input$measure_formula,
      desired_direction = input$measure_direction,
      baseline_value = nullable_number(input$measure_baseline),
      baseline_fy = nullable_number(input$measure_baseline_fy, TRUE),
      format_type = input$measure_format,
      display_unit = if (nzchar(trimws(input$measure_unit))) input$measure_unit else NA_character_,
      context_required = input$measure_context,
      replicability = isTRUE(input$measure_replicability),
      disaggregation = input$measure_disaggregation,
      data_location = input$measure_data_location,
      collection_method = input$measure_collection_method,
      how_data_used = input$measure_how_used,
      why_meaningful = input$measure_why_meaningful,
      proxy_measure = input$measure_proxy,
      improvement_notes = input$measure_improvement_notes,
      change_mapping = if (nrow(existing) && !is.na(existing$change_mapping[[1]])) existing$change_mapping[[1]] else "New",
      pillar_id = nullable_number(input$measure_pillar, TRUE),
      pillar_goal_id = nullable_number(input$measure_pillar_goal, TRUE),
      is_city = input_bool(input$measure_is_city),
      is_agency = input_bool(input$measure_is_agency),
      is_service = input_bool(input$measure_is_service),
      approval_status = if (nrow(existing)) existing$approval_status[[1]] else "Draft",
      submitted_for_approval_at = if (nrow(existing)) existing$submitted_for_approval_at[[1]] else as.POSIXct(NA)
    )
    if (!current_user_is_system_admin()) {
      values <- derive_measure_scope(data, values)
    }
    values
  }
  collect_measure_years <- function() {
    lapply(measure_entry_years(), function(year) list(
      fiscal_year = year,
      annual_actual = nullable_number(input[[paste0("measure_actual_", year)]]),
      annual_actual_notes = limit_note(input[[paste0("measure_actual_notes_", year)]]),
      target_value = nullable_number(input[[paste0("measure_target_", year)]]),
      target_value_notes = limit_note(input[[paste0("measure_target_notes_", year)]])
    ))
  }
  persist_measure <- function(submit = FALSE) {
    values <- collect_measure_form()
    yearly_values <- collect_measure_years()
    if (submit) {
      data <- app_data()
      plan <- current_plan(data, current_submitter_value())
      target_fy <- plan$fiscal_year[[1]]
      missing_fields <- validate_measure_submit_requirements(values, yearly_values, target_fy)
      if (length(missing_fields)) {
        showNotification(paste("Complete required fields before submitting:", paste(missing_fields, collapse = ", ")), type = "error", duration = 10)
        return()
      }
    }
    if (!nzchar(trimws(values$title))) values$title <- "Untitled measure"
    if (!nzchar(trimws(values$description))) values$description <- "Draft definition pending."
    if (!nzchar(trimws(values$data_source))) values$data_source <- "Draft data source pending."
    if (!nzchar(trimws(values$data_owner))) values$data_owner <- "Draft owner pending"
    if (!nzchar(trimws(values$data_owner_role))) values$data_owner_role <- "Draft owner role pending"
    if (!nzchar(trimws(values$update_frequency))) values$update_frequency <- "Draft"
    if (!nzchar(trimws(values$formula))) values$formula <- "Draft formula pending."
    if (!values$is_city && !values$is_agency && !values$is_service) {
      showNotification("Select at least one measure scope.", type = "error")
      return()
    }
    value_error <- validate_measure_values(values$format_type, yearly_values)
    if (!is.null(value_error)) {
      showNotification(value_error, type = "error", duration = 8)
      return()
    }
    data <- app_data()
    user_rows <- data$access_user_agency_access[data$access_user_agency_access$agency_id == values$agency_id, , drop = FALSE]
    if (!nrow(user_rows) && !nrow(data$access_user_agency_access)) {
      showNotification("No user is available to report measure actuals. Please add a user access row before saving measure data.", type = "error", duration = 8)
      return()
    }
    reported_by <- if (nrow(user_rows)) user_rows$user_id[[1]] else data$access_user_agency_access$user_id[[1]]
    result <- tryCatch(save_measure_record(database, values, yearly_values, reported_by, submit), error = function(error) error)
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data()
    current_measure_id(as.character(result))
    showNotification(if (submit) "Measure submitted for approval." else "Measure saved.", type = "message")
  }

  observeEvent(input$open_measure_id, {
    current_measure_id(as.character(input$open_measure_id))
  }, ignoreInit = TRUE)

  observeEvent(input$close_measure_modal, current_measure_id(NULL), ignoreInit = TRUE)
  observeEvent(input$measure_save_request, persist_measure(FALSE), ignoreInit = TRUE)
  observeEvent(input$measure_submit_request, persist_measure(TRUE), ignoreInit = TRUE)
  observeEvent(input$guidance_download_started, {
    showNotification("Performance planning guidance download started.", type = "message")
  }, ignoreInit = TRUE)
  observeEvent(input$measure_review_decision, {
    decision <- input$measure_review_decision
    if (is.null(decision$measureId) || is.null(decision$action)) return()
    measure_id <- as.integer(decision$measureId)
    action <- as.character(decision$action)
    feedback <- input[[paste0("measure_review_feedback_", measure_id)]] %||% ""
    data <- app_data()
    reviewer_rows <- data$access_user_role[data$access_user_role$app_role %in% c("OPIReviewer", "SystemAdmin"), , drop = FALSE]
    reviewer_id <- if (nrow(reviewer_rows)) reviewer_rows$user_id[[1]] else NA_integer_
    result <- tryCatch(
      review_measure_record(database, measure_id, action, feedback, reviewer_id),
      error = function(error) error
    )
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data()
    showNotification(if (identical(action, "approve")) "Measure approved." else "Measure returned to agency with feedback.", type = "message")
  }, ignoreInit = TRUE)
  observeEvent(input$confirm_deactivate_measure, {
    measure_id <- current_measure_id()
    if (is.null(measure_id) || identical(measure_id, "new")) return()
    tryCatch({
      set_measure_active(database, measure_id, current_agency_id(), FALSE)
      refresh_app_data()
      showNotification("Measure made inactive.", type = "message")
    }, error = function(error) showNotification(conditionMessage(error), type = "error"))
  }, ignoreInit = TRUE)
  observeEvent(input$reactivate_measure, {
    set_measure_active(database, current_measure_id(), current_agency_id(), TRUE)
    refresh_app_data()
    showNotification("Measure reactivated.", type = "message")
  }, ignoreInit = TRUE)

  observeEvent(input$open_risk_id, {
    current_risk_id(as.character(input$open_risk_id))
  }, ignoreInit = TRUE)

  observeEvent(input$close_risk_modal, current_risk_id(NULL), ignoreInit = TRUE)
  observeEvent(input$open_team_access_id, {
    request <- input$open_team_access_id
    access_id <- suppressWarnings(as.integer(request$accessId))
    if (is.na(access_id)) return()
    current_team_access_id(access_id)
  }, ignoreInit = TRUE)
  observeEvent(input$close_team_role_modal, current_team_access_id(NULL), ignoreInit = TRUE)
  observeEvent(input$team_role_save_request, {
    if (!current_user_can_manage_team()) {
      showNotification("Only Agency Directors and Admin users can change team roles.", type = "error", duration = 8)
      return()
    }
    access_id <- current_team_access_id()
    if (is.null(access_id) || is.na(access_id)) return()
    result <- tryCatch(
      save_team_role_assignment(
        database,
        access_id,
        input$team_full_name,
        input$team_email,
        input$team_agency_role,
        input$team_performance_role,
        isTRUE(input$team_budget_access),
        isTRUE(input$team_adaptive_planning),
        isTRUE(input$team_performance_plan_access)
      ),
      error = function(error) error
    )
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data()
    showNotification("Team role updated.", type = "message")
  }, ignoreInit = TRUE)
  observeEvent(input$risk_save_request, {
    data <- app_data()
    plan <- current_plan(data, current_submitter_value())
    risk_id <- current_risk_id()
    risk_id <- if (is.null(risk_id) || identical(risk_id, "new")) NA_integer_ else as.integer(risk_id)
    result <- tryCatch(
      save_service_risk(database, risk_id, plan$plan_id[[1]], input$risk_type, input$risk_description),
      error = function(error) error
    )
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data()
    current_risk_id(as.character(result))
    showNotification("Risk saved.", type = "message")
  }, ignoreInit = TRUE)

  observeEvent(input$duplicate_plan_from, {
    request <- input$duplicate_plan_from
    source_plan_id <- suppressWarnings(as.integer(request$planId))
    data <- app_data()
    target_plan <- current_plan(data, current_submitter_value())
    if (is.na(source_plan_id) || is.null(target_plan) || source_plan_id == target_plan$plan_id[[1]]) return()
    source_plan <- data$planning_agency_plan[data$planning_agency_plan$plan_id == source_plan_id & submitter_value_for_plan(data$planning_agency_plan[data$planning_agency_plan$plan_id == source_plan_id, , drop = FALSE]) == current_submitter_value(), , drop = FALSE]
    if (!nrow(source_plan)) {
      showNotification("That plan is not available for the selected agency.", type = "error")
      return()
    }
    result <- tryCatch({
      DBI::dbWithTransaction(database, {
        duplicate_plan_sections_to_draft(database, data, source_plan_id, target_plan$plan_id[[1]])
      })
      TRUE
    }, error = function(error) error)
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data()
    showNotification(paste0("FY", source_plan$fiscal_year[[1]], " plan copied into the current shared draft."), type = "message", duration = 8)
  }, ignoreInit = TRUE)

  observeEvent(input$review_plan_request, {
    request <- input$review_plan_request
    plan_id <- suppressWarnings(as.integer(request$planId))
    if (is.na(plan_id)) return()
    current_history_plan_id(plan_id)
  }, ignoreInit = TRUE)

  observeEvent(input$close_history_plan_modal, current_history_plan_id(NULL), ignoreInit = TRUE)

  observeEvent(input$export_plan_request, {
    request <- input$export_plan_request
    plan_id <- suppressWarnings(as.integer(request$planId))
    export_type <- tolower(as.character(request$exportType))
    if (is.na(plan_id) || !export_type %in% c("pdf", "pptx")) return()
    current_export_plan_id(plan_id)
    session$sendCustomMessage("trigger-plan-download", list(type = export_type))
  }, ignoreInit = TRUE)

  observeEvent(input$submit_plan_request, {
    request <- input$submit_plan_request
    plan_id <- suppressWarnings(as.integer(request$planId))
    if (is.na(plan_id)) return()
    result <- tryCatch(submit_agency_plan(database, plan_id), error = function(error) error)
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data()
    showNotification("Plan submitted. Builder fields are locked while the plan is in review.", type = "message", duration = 8)
  }, ignoreInit = TRUE)

  output$download_plan_pdf <- downloadHandler(
    filename = function() {
      data <- app_data()
      plan <- data$planning_agency_plan[data$planning_agency_plan$plan_id == current_export_plan_id(), , drop = FALSE]
      paste0("FY", if (nrow(plan)) plan$fiscal_year[[1]] else "plan", "-performance-plan.pdf")
    },
    content = function(file) {
      plan_id <- current_export_plan_id()
      if (is.null(plan_id)) stop("No plan selected for export")
      build_plan_export_file(app_data(), plan_id, file, "pdf")
      showNotification("PDF downloaded successfully.", type = "message")
    }
  )

  output$download_plan_pptx <- downloadHandler(
    filename = function() {
      data <- app_data()
      plan <- data$planning_agency_plan[data$planning_agency_plan$plan_id == current_export_plan_id(), , drop = FALSE]
      paste0("FY", if (nrow(plan)) plan$fiscal_year[[1]] else "plan", "-performance-plan.pptx")
    },
    content = function(file) {
      plan_id <- current_export_plan_id()
      if (is.null(plan_id)) stop("No plan selected for export")
      build_plan_export_file(app_data(), plan_id, file, "pptx")
      showNotification("PowerPoint downloaded successfully.", type = "message")
    }
  )

  observeEvent(input$shared_draft_load, {
    request <- input$shared_draft_load
    plan_id <- suppressWarnings(as.integer(request$planId))
    section_key <- as.character(request$sectionKey)
    if (is.na(plan_id) || !grepl("^[a-z][a-z0-9_-]{0,59}$", section_key)) return()

    draft <- get_section_draft(database, plan_id, section_key)
    session$sendCustomMessage("shared-draft-loaded", list(
      planId = plan_id,
      sectionKey = section_key,
      found = !is.null(draft),
      payloadJson = if (is.null(draft)) NULL else draft$payload[[1]],
      revision = if (is.null(draft)) 0L else draft$revision[[1]],
      updatedAt = if (is.null(draft)) NULL else format(draft$updated_at[[1]], "%Y-%m-%dT%H:%M:%S")
    ))
  }, ignoreInit = TRUE)

  observeEvent(input$shared_draft_save, {
    request <- input$shared_draft_save
    plan_id <- suppressWarnings(as.integer(request$planId))
    section_key <- as.character(request$sectionKey)
    revision <- suppressWarnings(as.integer(request$revision))
    payload_json <- as.character(request$payloadJson)
    if (is.na(plan_id) || is.na(revision) || !grepl("^[a-z][a-z0-9_-]{0,59}$", section_key)) return()

    result <- tryCatch(
      save_section_draft(database, plan_id, section_key, payload_json, revision),
      error = function(error) list(ok = FALSE, error = conditionMessage(error))
    )
    if (isTRUE(result$ok)) {
      refresh_app_data()
      session$sendCustomMessage("shared-draft-result", list(
        ok = TRUE,
        planId = plan_id,
        sectionKey = section_key,
        revision = result$row$revision[[1]],
        updatedAt = format(result$row$updated_at[[1]], "%Y-%m-%dT%H:%M:%S")
      ))
    } else if (!is.null(result$conflict)) {
      session$sendCustomMessage("shared-draft-result", list(
        ok = FALSE,
        conflict = TRUE,
        planId = plan_id,
        sectionKey = section_key,
        revision = result$conflict$revision[[1]],
        updatedAt = format(result$conflict$updated_at[[1]], "%Y-%m-%dT%H:%M:%S")
      ))
    } else {
      session$sendCustomMessage("shared-draft-result", list(
        ok = FALSE,
        conflict = FALSE,
        planId = plan_id,
        sectionKey = section_key,
        message = result$error
      ))
    }
  }, ignoreInit = TRUE)

  observeEvent(input$current_page, {
    current_page(input$current_page)
  }, ignoreInit = TRUE)

  observeEvent(input$login_agency, {
    current_workspace("agency")
    current_user_type("agency")
    current_page("landing")
    session$sendCustomMessage("set-page", "landing")
  })

  observeEvent(input$login_agency_director, {
    current_workspace("agency")
    current_user_type("agency_director")
    current_page("landing")
    session$sendCustomMessage("set-page", "landing")
  })

  observeEvent(input$login_reviewer, {
    current_workspace("admin")
    current_user_type("admin")
    current_page("reviewer_dashboard")
    session$sendCustomMessage("set-page", "reviewer_dashboard")
  })

  observeEvent(input$login_staff, {
    current_workspace("agency")
    current_user_type("agency")
    current_page("landing")
    session$sendCustomMessage("set-page", "landing")
  })

  observeEvent(input$login_admin, {
    current_workspace("admin")
    current_user_type("admin")
    current_page("reviewer_dashboard")
    session$sendCustomMessage("set-page", "reviewer_dashboard")
  })

  initial_data <- isolate(app_data())
  lapply(seq_along(initial_data$strategic_plan), function(index) {
    local({
      pillar_id <- initial_data$strategic_plan[[index]]$id
      observeEvent(input[[paste0("open_pillar_", pillar_id)]], {
        current_pillar_modal(pillar_id)
      }, ignoreInit = TRUE)
    })
  })

  observeEvent(input$close_pillar_modal, {
    current_pillar_modal(NULL)
  }, ignoreInit = TRUE)

  output$page <- renderUI({
    page_ui(current_page(), app_data(), current_submitter_value(), input$measure_status_filter %||% "Validated", current_user_can_manage_team())
  })

  output$pillar_modal <- renderUI({
    pillar_id <- current_pillar_modal()
    if (is.null(pillar_id)) {
      return(NULL)
    }
    pillar_modal(pillar_id, app_data())
  })

  output$measure_modal <- renderUI({
    measure_id <- current_measure_id()
    if (is.null(measure_id)) return(NULL)
    data <- app_data()
    plan <- current_plan(data, current_submitter_value())
    target_fy <- if (is.null(plan) || !nrow(plan)) 2027 else plan$fiscal_year[[1]]
    measure_modal_ui(data, current_agency_id(), if (identical(measure_id, "new")) NULL else as.integer(measure_id), current_user_is_system_admin(), target_fy)
  })

  output$history_plan_modal <- renderUI({
    plan_id <- current_history_plan_id()
    if (is.null(plan_id)) return(NULL)
    history_plan_modal(app_data(), as.integer(plan_id))
  })

  output$risk_modal <- renderUI({
    risk_id <- current_risk_id()
    if (is.null(risk_id)) return(NULL)
    risk_modal_ui(app_data(), current_submitter_value(), if (identical(risk_id, "new")) NULL else as.integer(risk_id))
  })
  output$team_role_modal <- renderUI({
    access_id <- current_team_access_id()
    if (is.null(access_id)) return(NULL)
    team_role_modal_ui(app_data(), current_submitter_value(), as.integer(access_id), current_user_can_manage_team())
  })
}

shinyApp(ui, server)
