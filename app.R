library(shiny)
library(DBI)
library(RPostgres)

source(file.path("R", "database.R"), local = TRUE)


pages <- list(
  login = "Login",
  landing = "Cycle home",
  strategic_plan = "City action plan",
  team = "Performance team",
  plan_history = "Plan history & status",
  metrics = "Measures review",
  overview = "Agency overview",
  goals = "Agency goals",
  services = "Agency services",
  risks = "Plan risks"
)

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

format_measure_value <- function(value, format_type, display_unit = NA) {
  if (is.na(value)) {
    return("Not reported")
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

current_plan <- function(db, agency_id) {
  plan <- db$planning_agency_plan[db$planning_agency_plan$agency_id == agency_id & db$planning_agency_plan$fiscal_year == 2027, , drop = FALSE]
  if (nrow(plan) == 0) {
    return(NULL)
  }
  plan[1, , drop = FALSE]
}

agency_name <- function(db, agency_id) {
  agency <- db$reference_agency[db$reference_agency$agency_id == agency_id, , drop = FALSE]
  agency$agency_name[1]
}

selected_context <- function(db, agency_id) {
  plan <- current_plan(db, agency_id)
  agency <- db$reference_agency[db$reference_agency$agency_id == agency_id, , drop = FALSE]
  header <- db$performance_plan_header[db$performance_plan_header$plan_id == plan$plan_id, , drop = FALSE]
  list(agency = agency, plan = plan, header = header)
}


nav_item <- function(id, label, icon_tag, section = NULL) {
  tags$button(
    type = "button",
    class = paste("nav-item", if (!is.null(section)) "nav-subitem" else ""),
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
              metric_tile("Initiatives", sum(vapply(pillar$goals, function(goal) length(goal$initiatives), integer(1)))),
              metric_tile("Services", nrow(service_rows)))
        ),
        tags$section(
          class = "modal-section-block",
          h3("Goals & Initiatives"),
          div(class = "goal-list", lapply(pillar$goals, goal_panel))
        ),
        tags$section(
          class = "modal-section-block",
          h3("Performance Measures"),
          p("These are Action Plan performance measures with dummy prototype values and targets."),
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
          div(class = "brand-product", "Beacon"),
          div(class = "brand-subtitle", "Baltimore Outcome Budgeting")
        )
      ),
      h1("Sign in to continue"),
      p("Use your City staff account to review plans, manage metrics, and submit cycle updates."),
      div(
        class = "login-actions",
        actionButton("login_staff", "Continue with Microsoft Entra", class = "civic-button primary"),
        actionButton("login_admin", "Admin sign in", class = "civic-button secondary")
      ),
      div(class = "support-note", "Need access? Contact 311 Support at help@baltimorecity.gov.")
    )
  )
}

page_landing <- function(db, agency_id) {
  ctx <- selected_context(db, agency_id)
  plan <- ctx$plan
  agency <- ctx$agency
  header <- ctx$header
  services <- db$performance_plan_service[db$performance_plan_service$plan_id == plan$plan_id, , drop = FALSE]
  measures <- db$performance_performance_measure[db$performance_performance_measure$agency_id == agency_id, , drop = FALSE]
  goals <- db$performance_agency_goal[db$performance_agency_goal$plan_id == plan$plan_id, , drop = FALSE]
  risks <- db$performance_service_risk[db$performance_service_risk$plan_id == plan$plan_id, , drop = FALSE]
  validated_count <- sum(measures$validated)

  tagList(
    div(
      class = "briefing-header",
      div(
        div(class = "eyebrow", "Performance cycle"),
        h1(paste0("FY", plan$fiscal_year, " performance planning")),
        p(paste("Track", agency$agency_name, "plan status, assigned contacts, services, measures, and risks before moving into the builder.")),
        div(
          class = "chip-row",
          status_chip(format_status(plan$plan_status), status_tone(plan$plan_status)),
          status_chip(paste("Budget", format_status(plan$budget_status)), status_tone(plan$budget_status)),
          status_chip(paste("Version", plan$version), "primary")
        )
      ),
      div(class = "briefing-meta", paste("Updated", plan$updated_at))
    ),
    div(
      class = "dashboard-grid",
      metric_tile("Current agency", agency$agency_id, agency$deputy_mayor_pillar),
      metric_tile("Services in plan", nrow(services), "performance.plan_service"),
      metric_tile(
        "KPI measures",
        length(unique(db$performance_pm_goal_link$measure_id[db$performance_pm_goal_link$agency_goal_id %in% goals$agency_goal_id])),
        paste(validated_count, "validated")
      ),
      metric_tile("Open risks", nrow(risks), "performance.service_risk", if (nrow(risks) > 0) "warning" else NULL)
    ),
    surface(
      "Plan record",
      "Prototype view of the current planning.agency_plan and performance.plan_header rows.",
      div(
        class = "app-table",
        div(class = "table-row table-head", span("Field"), span("Value"), span("Source table")),
        div(class = "table-row", span("Plan status"), status_chip(format_status(plan$plan_status), status_tone(plan$plan_status)), span("planning.agency_plan")),
        div(class = "table-row", span("Primary contact"), span(header$primary_contact_name), span("performance.plan_header")),
        div(class = "table-row", span("Contact email"), span(header$primary_contact_email), span("performance.plan_header"))
      )
    ),
    surface(
      "Current plan snapshot",
      "A quick read on the plan sections that are ready or still need work.",
      div(
        class = "progress-list",
        div(class = "progress-row", span("Agency overview"), div(class = "progress-track", div(style = "width: 100%;")), tags$strong("Loaded")),
        div(class = "progress-row", span("Goals and KPIs"), div(class = "progress-track", div(style = paste0("width: ", min(100, nrow(goals) * 35 + nrow(measures) * 15), "%;"))), tags$strong(paste(nrow(goals), "goals"))),
        div(class = "progress-row", span("Services"), div(class = "progress-track", div(style = paste0("width: ", min(100, nrow(services) * 45), "%;"))), tags$strong(paste(nrow(services), "services"))),
        div(class = "progress-row", span("Risks"), div(class = "progress-track", div(style = paste0("width: ", min(100, nrow(risks) * 40), "%;"))), tags$strong(paste(nrow(risks), "risks")))
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
        p("Each priority is supported by specific, measurable goals and targeted strategies that City agencies incorporate into their work. A performance framework tracks progress on key metrics through regular public reporting, promoting transparency and holding the City accountable to residents as it works toward a stronger, more resilient, and equitable Baltimore. Click through the pillars below to explore each priority area's goals, initiatives, metrics, and services.")
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
      "Open a pillar to review goals, initiatives, metrics, agencies, services, and plan entities.",
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
              span(paste(sum(vapply(pillar$goals, function(goal) length(goal$initiatives), integer(1))), "initiatives")),
              span(paste(length(pillar$metrics), "metrics"))
            )
            )
          )
        })
      )
    )
  )
}

page_team <- function(db, agency_id) {
  team <- db$access_user_agency_access[db$access_user_agency_access$agency_id == agency_id, , drop = FALSE]
  if (nrow(team) == 0) {
    team <- data.frame(full_name = "Unassigned", email = "Needs access record", agency_role = "Performance Lead", stringsAsFactors = FALSE)
  }
  surface(
    "Review Performance Team and Roles",
    "Confirm who owns plan sections, metric approvals, and final submission.",
    div(
      class = "app-table",
      div(class = "table-row table-head", span("Role"), span("Owner"), span("Status")),
      lapply(seq_len(nrow(team)), function(i) {
        div(class = "table-row", span(team$agency_role[i]), span(team$full_name[i]), status_chip("Access active", "success"))
      }),
      div(class = "table-row", span("Metric data steward"), span(team$full_name[1]), status_chip("Confirm backup", "warning"))
    )
  )
}

builder_page <- function(title, description, body, plan_id, section_key, show_save = TRUE, show_status = TRUE) {
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
      body
    ),
    if (show_save) div(
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
      if (nrow(row)) format_measure_value(row$target_value[[1]], measure$format_type[[1]], measure$display_unit[[1]]) else "Not set"
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
  agency_id <- plan$agency_id[[1]]
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
    if (nrow(row)) format_measure_value(row$target_value[[1]], measure$format_type[[1]], measure$display_unit[[1]]) else "Not set"
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

history_plan_card <- function(db, plan, current_plan_id) {
  counts <- plan_component_counts(db, plan$plan_id[[1]])
  review_bits <- review_summary_for_plan(db, plan$plan_id[[1]])
  review <- review_bits$review
  feedback <- review_bits$feedback
  scores <- review_bits$scores
  open_feedback <- if (nrow(feedback)) sum(feedback$return_required & is.na(feedback$resolved_at), na.rm = TRUE) else 0
  score_label <- if (!is.null(review)) score_out_of_100(review$overall_score[[1]]) else "No score yet"
  is_current <- plan$plan_id[[1]] == current_plan_id
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
          status_chip(paste("Version", plan$version[[1]]), "primary"),
          if (draft_section_count(db, plan$plan_id[[1]]) > 0) status_chip(paste(draft_section_count(db, plan$plan_id[[1]]), "draft sections"), "warning")
        )
      ),
      div(class = "history-plan-updated", span("Updated"), strong(as.character(plan$updated_at[[1]])))
    ),
    div(
      class = "history-plan-stats",
      metric_tile("Goals", counts$goals),
      metric_tile("Services", counts$services),
      metric_tile("Measures", counts$measures),
      metric_tile("Risks", counts$risks)
    ),
    div(
      class = "history-review-strip",
      div(span("Reviewer"), strong(if (!is.null(review)) review$reviewer_name[[1]] else "Not assigned")),
      div(span("Review status"), strong(if (!is.null(review) && isTRUE(review$review_complete[[1]])) "Complete" else if (!is.null(review)) "In progress" else "Not started")),
      div(span("Rubric grade"), strong(score_label)),
      div(span("Open feedback"), strong(open_feedback))
    ),
    if (nrow(scores)) div(
      class = "history-score-list",
      lapply(seq_len(nrow(scores)), function(i) {
        div(
          class = "history-score-row",
          span(paste(scores$section_code[i], scores$criterion_code[i])),
          status_chip(paste("Score", scores$score[i]), if (scores$score[i] >= 3) "success" else "warning"),
          span(scores$justification[i])
        )
      })
    ),
    if (nrow(feedback)) div(
      class = "history-feedback-list",
      lapply(seq_len(nrow(feedback)), function(i) {
        div(
          class = "history-feedback-row",
          status_chip(feedback$section_code[i], "primary"),
          p(feedback$feedback_text[i]),
          if (isTRUE(feedback$return_required[i]) && is.na(feedback$resolved_at[i])) status_chip("Action needed", "warning") else status_chip("Reference note", "success")
        )
      })
    ),
    div(
      class = "history-plan-actions",
      tags$button(type = "button", class = "civic-button secondary small", `data-review-plan` = plan$plan_id[[1]], icon("eye"), "Review plan"),
      if (!is_current) tags$button(type = "button", class = "civic-button primary small", `data-duplicate-plan` = plan$plan_id[[1]], icon("copy"), "Duplicate into current draft"),
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
    service_rows <- db$reference_service[db$reference_service$service_id %in% source_services$service_id, , drop = FALSE]
    for (i in seq_len(nrow(service_rows))) {
      service_id <- service_rows$service_id[i]
      values[[paste0("service_description_", service_id)]] <- service_rows$service_description[i]
      linked_metrics <- db$performance_pm_service_link[db$performance_pm_service_link$service_id == service_id, , drop = FALSE]
      service_metrics[[service_id]] <- as.list(as.character(linked_metrics$measure_id))
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
  plans <- db$planning_agency_plan[db$planning_agency_plan$agency_id == agency_id, , drop = FALSE]
  plans <- plans[order(plans$fiscal_year, decreasing = TRUE), , drop = FALSE]
  plan <- current_plan(db, agency_id)
  current_drafts <- db$planning_plan_section_draft[db$planning_plan_section_draft$plan_id == plan$plan_id[[1]], , drop = FALSE]
  builder_page(
    "Plan History & Status",
    "Review prior submissions, current draft state, reviewer feedback, and export-ready plan content.",
    tagList(
      surface(
        "Current Draft",
        "Shared draft sections are stored in the dummy database until the agency is ready to submit.",
        div(
          class = "history-draft-summary",
          metric_tile("Draft sections", nrow(current_drafts), "planning.plan_section_draft"),
          metric_tile("Plan status", agency_plan_status(plan$plan_status[[1]]), "planning.agency_plan"),
          metric_tile("Current FY", paste0("FY", plan$fiscal_year[[1]]), paste("version", plan$version[[1]]))
        )
      ),
      surface(
        "Plan Records",
        "Open past plans, duplicate an approved plan into the current draft, and review released feedback beside the submitted content.",
        div(
          class = "history-plan-list",
          lapply(seq_len(nrow(plans)), function(i) history_plan_card(db, plans[i, , drop = FALSE], plan$plan_id[[1]]))
        )
      ),
      surface(
        "Export Content Standard",
        "PDF and PowerPoint exports should use the same plan source data. Metric sections will show the metric name, type, desired direction, five years of actuals, and current/next fiscal year targets.",
        div(
          class = "export-standard-grid",
          div(class = "export-standard-card", h3("PDF plan"), p("Use the PowerPoint color language and a more polished report layout for the Word/PDF template.")),
          div(class = "export-standard-card", h3("PowerPoint"), p("Use the supplied deck as the base template, then refine typography, spacing, and metric tables.")),
          div(class = "export-standard-card", h3("Metrics"), p("For FY2027 exports: actuals for FY2022-FY2026 and targets for FY2026-FY2027."))
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
  overview <- db$performance_overview_vision[db$performance_overview_vision$plan_id == plan_id, , drop = FALSE]
  goals <- db$performance_agency_goal[db$performance_agency_goal$plan_id == plan_id, , drop = FALSE]
  goals <- goals[order(goals$sort_order), , drop = FALSE]
  services <- db$performance_plan_service[db$performance_plan_service$plan_id == plan_id, , drop = FALSE]
  service_rows <- db$reference_service[db$reference_service$service_id %in% services$service_id, , drop = FALSE]
  review_bits <- review_summary_for_plan(db, plan_id)
  risks <- db$performance_service_risk[db$performance_service_risk$plan_id == plan_id, , drop = FALSE]
  notes_summary <- review_notes_summary(review_bits)
  current_fy <- max(db$planning_agency_plan$fiscal_year, na.rm = TRUE)

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
          if (nrow(overview)) tagList(
            p(tags$strong("Overview: "), overview$overview[[1]]),
            p(tags$strong("Vision: "), overview$vision[[1]]),
            p(tags$strong("Web address: "), overview$web_address[[1]])
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
        if (nrow(goals)) div(
          class = "history-modal-list",
          lapply(seq_len(nrow(goals)), function(i) {
            goal_id <- goals$agency_goal_id[i]
            linked_initiatives <- db$performance_agency_goal_initiative_link[db$performance_agency_goal_initiative_link$agency_goal_id == goal_id, , drop = FALSE]
            initiative_rows <- db$performance_initiative[db$performance_initiative$initiative_id %in% linked_initiatives$initiative_id, , drop = FALSE]
            linked_kpis <- db$performance_pm_goal_link[db$performance_pm_goal_link$agency_goal_id == goal_id, , drop = FALSE]
            div(
              class = "history-modal-record",
              div(class = "eyebrow", paste("Goal", goals$sort_order[i])),
              h4(goals$title[i]),
              if (nrow(initiative_rows)) tagList(h5("Initiatives"), tags$ul(lapply(initiative_rows$title, tags$li))),
              if (nrow(linked_kpis)) tagList(
                h5("Key Performance Indicators"),
                div(class = "history-measure-list", lapply(linked_kpis$measure_id, function(measure_id) measure_history_card(db, measure_id, current_fy)))
              ),
              if (nzchar(goals$alignment[i])) div(class = "history-alignment-note", status_chip("Action Plan Aligned", "success"), span(goals$alignment[i]))
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
            linked_metrics <- db$performance_pm_service_link[db$performance_pm_service_link$service_id == service_rows$service_id[i], , drop = FALSE]
            div(
              class = "history-modal-record",
              h4(service_rows$service_name[i]),
              p(service_rows$service_description[i]),
              if (nrow(linked_metrics)) tagList(
                h5("Performance Metrics"),
                div(class = "history-measure-list", lapply(linked_metrics$measure_id, function(measure_id) measure_history_card(db, measure_id, current_fy)))
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

measure_label <- function(text, help) {
  tags$span(
    class = "field-label-with-help",
    span(text),
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

measure_modal_ui <- function(db, agency_id, measure_id = NULL) {
  plan <- current_plan(db, agency_id)
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
  selected_format <- if (value("format_type", "Count") %in% c("Percent", "Count", "Currency")) value("format_type", "Count") else "Count"

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
            if (!is_new && !isTRUE(value("active", TRUE))) {
              status_chip("Inactive", "error")
            } else {
              status_chip(if (is_new) "Draft" else format_status(status), if (status == "Validated") "success" else if (status == "Rejected") "error" else "warning")
            }
          )
        ),
        actionButton("close_measure_modal", "Close", class = "civic-button secondary small")
      ),
      div(
        class = "measure-form-stack",
        tags$section(
          class = "modal-section-block measure-form-section",
          h3("Definition"),
          div(
            class = "measure-form-grid",
            div(class = "measure-field full-width", textInput("measure_title", measure_label("Measure name", "Use a concise name that clearly identifies the outcome, output, efficiency, or effectiveness being tracked."), value = value("title"))),
            div(class = "measure-field full-width", textAreaInput("measure_description", measure_label("Definition", "Define exactly what is being measured so a reviewer can understand the measure without additional context."), rows = 3, value = value("description"))),
            div(class = "measure-field", selectInput("measure_type", measure_label("Measure type", "Classify the measure as output, efficiency, effectiveness, or outcome based on what it tells reviewers about performance."), choices = c("Output", "Efficiency", "Effectiveness", "Outcome"), selected = value("measure_type", "Outcome"), selectize = FALSE)),
            div(class = "measure-field", selectInput("measure_direction", measure_label("Desired direction", "Select whether successful performance should increase, decrease, or maintain this value."), choices = c("Increase", "Decrease", "Maintain"), selected = value("desired_direction", "Increase"), selectize = FALSE)),
            div(class = "measure-field", selectInput("measure_format", measure_label("Format", "Select how this value should be displayed. New measures use Percent, Count, or Currency."), choices = c("Percent", "Count", "Currency"), selected = selected_format, selectize = FALSE)),
            div(class = "measure-field", textInput("measure_unit", measure_label("Display unit", "Optional label for the unit shown with the value, such as residents, permits, or dollars."), value = value("display_unit"))),
            div(class = "measure-field", numericInput("measure_baseline", measure_label("Baseline value", "Enter the starting value used to compare future progress."), value = value("baseline_value", NA))),
            div(class = "measure-field", numericInput("measure_baseline_fy", measure_label("Baseline fiscal year", "Enter the fiscal year for the baseline value."), value = value("baseline_fy", 2026), min = 2000, max = 2100))
          )
        ),
        tags$section(
          class = "modal-section-block measure-form-section",
          h3("Data Source & Ownership"),
          div(
            class = "measure-form-grid",
            div(class = "measure-field full-width", textInput("measure_data_source", measure_label("Data source", "Name the system, report, dataset, or official source used to produce this measure."), value = value("data_source"))),
            div(class = "measure-field", textInput("measure_data_owner", measure_label("Data owner", "Name the person or team responsible for the source data."), value = value("data_owner"))),
            div(class = "measure-field", textInput("measure_data_owner_role", measure_label("Data owner role", "Identify the title or role accountable for maintaining and validating the data."), value = value("data_owner_role"))),
            div(class = "measure-field", textInput("measure_frequency", measure_label("Update frequency", "State how often the measure can be updated, such as monthly, quarterly, annually, or daily."), value = value("update_frequency"))),
            div(class = "measure-field", textInput("measure_data_location", measure_label("Data location", "Describe where the underlying data lives, such as a database, spreadsheet, system export, or public report."), value = value("data_location"))),
            div(class = "measure-field full-width", textAreaInput("measure_formula", measure_label("Formula or calculation", "Document the calculation clearly enough that another reviewer could reproduce the result."), rows = 2, value = value("formula"))),
            div(class = "measure-field full-width", textAreaInput("measure_collection_method", measure_label("Collection method", "Describe how the data is collected, compiled, refreshed, or quality checked."), rows = 2, value = value("collection_method")))
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
            div(class = "measure-field full-width", textAreaInput("measure_how_used", measure_label("How the data is used", "Explain how the agency uses this measure for management, budgeting, service improvement, or public accountability."), rows = 2, value = value("how_data_used"))),
            div(class = "measure-field full-width", textAreaInput("measure_why_meaningful", measure_label("Why this measure is meaningful", "Explain why this measure is a useful signal of resident outcomes, service quality, efficiency, or operational performance."), rows = 2, value = value("why_meaningful"))),
            div(class = "measure-field full-width", textAreaInput("measure_proxy", measure_label("Proxy measure or limitations", "Describe whether this is a proxy for a harder-to-measure outcome and name important limitations."), rows = 2, value = value("proxy_measure"))),
            div(class = "measure-field full-width", textAreaInput("measure_improvement_notes", measure_label("Improvement notes", "Identify needed improvements to data quality, frequency, definition, validation, or reporting."), rows = 2, value = value("improvement_notes"))),
            div(class = "measure-field", selectInput("measure_pillar", measure_label("Action Plan pillar", "Only system admins will be able to designate citywide metrics and match them to an Action Plan pillar."), choices = pillar_choices, selected = as.character(value("pillar_id")), selectize = FALSE)),
            div(class = "measure-field full-width", selectInput("measure_pillar_goal", measure_label("Action Plan pillar goal", "Only system admins will be able to designate citywide metrics and match them to an Action Plan goal."), choices = pillar_goal_choices, selected = as.character(value("pillar_goal_id")), selectize = FALSE)),
            div(
              class = "measure-scope-options full-width",
              checkboxInput("measure_is_city", "Citywide measure", value = isTRUE(value("is_city", FALSE))),
              checkboxInput("measure_is_agency", "Agency measure", value = isTRUE(value("is_agency", TRUE))),
              checkboxInput("measure_is_service", "Service measure", value = isTRUE(value("is_service", FALSE))),
              p(class = "scope-admin-note", "Note: only system admins will be able to make metrics citywide and match them to an Action Plan pillar or goal.")
            )
          )
        ),
        tags$section(
          class = "modal-section-block measure-form-section",
          h3("Past Five Fiscal Years"),
          p("Enter annual actuals and targets. Notes should explain revisions, data quality issues, or target rationale."),
          div(
            class = "measure-year-list",
            lapply(2022:2026, function(year) {
              div(
                class = "measure-year-row",
                h4(paste0("FY", year)),
                measure_value_input(paste0("measure_actual_", year), measure_label("Actual", "Enter the reported annual value for this fiscal year."), annual_value(year, "annual_actual", NA), selected_format),
                measure_note_input(paste0("measure_actual_notes_", year), measure_label("Actual notes", "Optional note on data quality, revisions, unusual events, or interpretation. Maximum 200 characters."), annual_value(year, "annual_actual_notes")),
                measure_value_input(paste0("measure_target_", year), measure_label("Target", "Enter the target value for this fiscal year."), annual_value(year, "target_value", NA), selected_format),
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

page_metrics <- function(db, agency_id) {
  plan <- current_plan(db, agency_id)
  measures <- db$performance_performance_measure[db$performance_performance_measure$agency_id == agency_id, , drop = FALSE]
  builder_page(
    "Measures",
    "Review, update, and submit agency performance measures for validation.",
    surface(
      "Measure Library",
      "Select a row to review its definition, validation criteria, and five-year data history.",
      div(
        class = "app-table measure-library-table",
        div(class = "table-row table-head metrics-row", span("Measure"), span("Actual / target"), span("Status"), span("Updated")),
        lapply(seq_len(nrow(measures)), function(i) {
          history <- db$performance_measure_actuals[db$performance_measure_actuals$measure_id == measures$measure_id[i], , drop = FALSE]
          latest <- if (nrow(history)) history[which.max(history$fiscal_year), , drop = FALSE] else data.frame()
          actual <- if (nrow(latest)) format_measure_value(latest$annual_actual[1], measures$format_type[i], measures$display_unit[i]) else "Not reported"
          target <- if (nrow(latest)) format_measure_value(latest$target_value[1], measures$format_type[i], measures$display_unit[i]) else "Not set"
          status <- if (!measures$active[i]) "Inactive" else format_status(measures$approval_status[i])
          tone <- if (!measures$active[i]) "error" else if (measures$approval_status[i] == "Validated") "success" else "warning"
          tags$button(
            type = "button",
            class = "table-row metrics-row measure-library-row",
            `data-measure-id` = measures$measure_id[i],
            span(measures$title[i]),
            span(paste(actual, "/", target)),
            status_chip(status, tone),
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
      p(class = "rubric-reference-note", "Rubric criteria are provided at the bottom of this page for reference."),
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
    section_key = "overview"
  )
}

page_goals <- function(db, agency_id) {
  plan <- current_plan(db, agency_id)
  goals <- db$performance_agency_goal[db$performance_agency_goal$plan_id == plan$plan_id, , drop = FALSE]
  goals <- goals[order(goals$sort_order), , drop = FALSE]
  agency_measures <- db$performance_performance_measure[db$performance_performance_measure$agency_id == agency_id & db$performance_performance_measure$active, , drop = FALSE]
  goal_count <- nrow(goals)
  drafted_count <- sum(vapply(seq_len(goal_count), function(i) {
    goal_id <- goals$agency_goal_id[i]
    initiative_links <- db$performance_agency_goal_initiative_link[db$performance_agency_goal_initiative_link$agency_goal_id == goal_id, , drop = FALSE]
    initiative_titles <- db$performance_initiative$title[match(initiative_links$initiative_id, db$performance_initiative$initiative_id)]
    measure_links <- db$performance_pm_goal_link[db$performance_pm_goal_link$agency_goal_id == goal_id, , drop = FALSE]
    nzchar(trimws(goals$title[i])) && any(!is.na(initiative_titles) & nzchar(trimws(initiative_titles))) && nrow(measure_links) > 0
  }, logical(1)))
  aligned_count <- sum(!is.na(goals$alignment_code) & nzchar(goals$alignment_code))
  remaining_count <- max(0, 5 - goal_count)
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
    "Set three to five outcome-oriented goals and define how the agency will achieve and measure each one.",
    div(
      class = "goals-page",
      `data-agency-id` = agency_id,
      `data-plan-id` = plan$plan_id,
      p(class = "rubric-reference-note", "Rubric criteria are provided at the bottom of this page for reference."),
      surface(
        "Goal requirements",
        "Each agency plan must include at least three goals and no more than five. A goal counts as drafted when it includes a goal statement, at least one initiative, and at least one KPI. At least one goal must align to a Mayor's Action Plan Pillar Goal.",
        div(
          class = "goal-requirements",
          div(
            class = "goal-requirement-stat goals-drafted-stat",
            strong(class = "draft-goal-count", drafted_count),
            span("Goals drafted"),
            div(
              class = "goal-requirement-detail",
              status_chip(if (drafted_count >= 3) "Minimum met" else paste(3 - drafted_count, "more required"), if (drafted_count >= 3) "success" else "error"),
              p(class = "remaining-goal-count", if (remaining_count > 0) paste("You can add", remaining_count, "more", if (remaining_count == 1) "goal." else "goals.") else "The five-goal maximum has been reached.")
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
        "Write each goal as a SMART, outcome-based result. Then connect it to an initiative, KPI, and optional Action Plan Pillar Goal.",
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
                if (nrow(row) == 0) "Not set" else format_measure_value(row$target_value[1], measure$format_type[1], measure$display_unit[1])
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
        actions = tags$button(id = "add_goal", type = "button", class = "civic-button primary", disabled = if (goal_count >= 5) "disabled" else NULL, icon("plus"), "Add goal")
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
    section_key = "goals"
  )
}

page_services <- function(db, agency_id) {
  plan <- current_plan(db, agency_id)
  plan_services <- db$performance_plan_service[db$performance_plan_service$plan_id == plan$plan_id, , drop = FALSE]
  service_rows <- merge(plan_services, db$reference_service, by = "service_id", all.x = TRUE)
  measures <- db$performance_performance_measure[db$performance_performance_measure$agency_id == agency_id & db$performance_performance_measure$active, , drop = FALSE]
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
      p(class = "rubric-reference-note", "Rubric criteria are provided at the bottom of this page for reference."),
      surface(
        "Services",
        "Open a service to review its description, select metrics, and inspect five years of actuals and targets.",
        div(
          class = "goal-editor-list service-editor-list services-page",
          `data-agency-id` = agency_id,
          `data-plan-id` = plan$plan_id,
          lapply(seq_len(nrow(service_rows)), function(i) {
          service_id <- service_rows$service_id[i]
          metric_links <- db$performance_pm_service_link[db$performance_pm_service_link$service_id == service_id, , drop = FALSE]
          selected_metrics <- if (nrow(metric_links) > 0) as.character(metric_links$measure_id) else ""
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
              if (nrow(row) == 0) "Not set" else format_measure_value(row$target_value[1], measure$format_type[1], measure$display_unit[1])
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
    section_key = "services"
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
        div(class = "table-row table-head risk-row", span("Risk"), span("Status")),
        lapply(seq_len(nrow(risks)), function(i) {
          tags$button(
            type = "button",
            class = "table-row risk-row risk-register-row",
            `data-risk-id` = risks$risk_id[i],
            span(risks$description[i]),
            status_chip("Open", "warning")
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

page_ui <- function(page, db, agency_id) {
  switch(
    page,
    login = page_login(),
    landing = page_landing(db, agency_id),
    strategic_plan = page_strategic_plan(db, agency_id),
    team = page_team(db, agency_id),
    plan_history = page_plan_history(db, agency_id),
    metrics = page_metrics(db, agency_id),
    overview = page_overview(db, agency_id),
    goals = page_goals(db, agency_id),
    services = page_services(db, agency_id),
    risks = page_risks(db, agency_id),
    page_landing(db, agency_id)
  )
}

ui <- tagList(
  tags$head(
    tags$title("Beacon: Baltimore Outcome Budgeting"),
    tags$meta(name = "viewport", content = "width=device-width, initial-scale=1"),
    tags$link(rel = "stylesheet", href = "styles.css?v=20260625-05"),
    tags$script(src = "app.js?v=20260625-05", defer = "defer")
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
            div(class = "brand-product", "Beacon"),
            div(class = "brand-subtitle", "Baltimore Outcome Budgeting")
          )
        ),
        div(class = "header-agency-name", "Department of General Services")
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
          div(class = "nav-group-label", "Performance Planning"),
          nav_item("plan_history", "History & status", icon("clock-rotate-left"), "builder"),
          nav_item("overview", "Overview & vision", icon("eye"), "builder"),
          nav_item("goals", "Goals", icon("flag"), "builder"),
          nav_item("services", "Services", icon("briefcase"), "builder"),
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
      div(class = "nav-group-label", "Performance Planning"),
      nav_item("plan_history", "History & status", icon("clock-rotate-left")),
      nav_item("overview", "Overview & vision", icon("eye")),
      nav_item("goals", "Goals", icon("flag")),
      nav_item("services", "Services", icon("briefcase")),
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
              div(tags$strong("Beacon"), span("Baltimore Outcome Budgeting"))
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
    uiOutput("risk_modal")
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

  refresh_app_data <- function() app_data(load_app_data(database))
  current_agency_id <- function() {
    agency_id <- input$selected_agency
    data <- app_data()
    if (is.null(agency_id) || !agency_id %in% data$reference_agency$agency_id) "AGC2600" else agency_id
  }
  nullable_number <- function(value, integer = FALSE) {
    if (is.null(value) || length(value) == 0 || is.na(value) || identical(value, "")) return(if (integer) NA_integer_ else NA_real_)
    if (integer) as.integer(value) else as.numeric(value)
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
  collect_measure_form <- function() {
    data <- app_data()
    agency_id <- current_agency_id()
    plan <- current_plan(data, agency_id)
    existing_id <- current_measure_id()
    existing <- if (is.null(existing_id) || identical(existing_id, "new")) data.frame() else data$performance_performance_measure[data$performance_performance_measure$measure_id == as.integer(existing_id), , drop = FALSE]
    list(
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
      is_city = isTRUE(input$measure_is_city),
      is_agency = isTRUE(input$measure_is_agency),
      is_service = isTRUE(input$measure_is_service),
      approval_status = if (nrow(existing)) existing$approval_status[[1]] else "Draft",
      submitted_for_approval_at = if (nrow(existing)) existing$submitted_for_approval_at[[1]] else as.POSIXct(NA)
    )
  }
  collect_measure_years <- function() {
    lapply(2022:2026, function(year) list(
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
    if (submit && (!nzchar(trimws(values$title)) || !nzchar(trimws(values$description)) || !nzchar(trimws(values$data_source)) || !nzchar(trimws(values$formula)))) {
      showNotification("Measure name, definition, data source, and formula are required.", type = "error")
      return()
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
  observeEvent(input$risk_save_request, {
    data <- app_data()
    plan <- current_plan(data, current_agency_id())
    risk_id <- current_risk_id()
    risk_id <- if (is.null(risk_id) || identical(risk_id, "new")) NA_integer_ else as.integer(risk_id)
    result <- tryCatch(
      save_service_risk(database, risk_id, plan$plan_id[[1]], input$risk_description),
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
    target_plan <- current_plan(data, current_agency_id())
    if (is.na(source_plan_id) || is.null(target_plan) || source_plan_id == target_plan$plan_id[[1]]) return()
    source_plan <- data$planning_agency_plan[data$planning_agency_plan$plan_id == source_plan_id & data$planning_agency_plan$agency_id == current_agency_id(), , drop = FALSE]
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
    export_type <- toupper(as.character(request$exportType))
    showNotification(paste(export_type, "export wiring is ready for the template generator step."), type = "message", duration = 8)
  }, ignoreInit = TRUE)

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

  observeEvent(input$login_staff, {
    current_page("landing")
    session$sendCustomMessage("set-page", "landing")
  })

  observeEvent(input$login_admin, {
    current_page("landing")
    session$sendCustomMessage("set-page", "landing")
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
    page_ui(current_page(), app_data(), current_agency_id())
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
    measure_modal_ui(app_data(), current_agency_id(), if (identical(measure_id, "new")) NULL else as.integer(measure_id))
  })

  output$history_plan_modal <- renderUI({
    plan_id <- current_history_plan_id()
    if (is.null(plan_id)) return(NULL)
    history_plan_modal(app_data(), as.integer(plan_id))
  })

  output$risk_modal <- renderUI({
    risk_id <- current_risk_id()
    if (is.null(risk_id)) return(NULL)
    risk_modal_ui(app_data(), current_agency_id(), if (identical(risk_id, "new")) NULL else as.integer(risk_id))
  })
}

shinyApp(ui, server)
