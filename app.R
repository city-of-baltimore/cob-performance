library(shiny)
library(DBI)
library(RPostgres)
library(future)
library(promises)

# Full database reloads (refresh_app_data(), ~36 queries) run in a background
# worker so one user's save/submit/approve doesn't block every other
# connected session -- Shiny normally runs as a single process/thread, so a
# synchronous reload here would freeze the whole app for its duration.
#
# Dropped from 3 workers to 2 on 2026-08-07: the new MEMLOG diagnostic
# traces (see refresh_app_data()) showed a single full reload settles at
# ~2.6GB resident on real production data (vs. ~150MB against the local
# dev seed DB, which is why earlier local stress testing never reproduced
# this). Long-lived multisession workers never release that once touched,
# so 3 workers each eventually holding a full reload sums to ~8GB+ on
# their own, at or over the 8GB machine ceiling with zero margin left for
# the main process or a concurrent second reload -- exactly what produced
# the OOM/health-check-flap pattern during a concurrent-heavy day. 2
# workers keeps worst case near ~5.7GB, leaving real headroom. This is a
# stopgap trading some concurrency for safety; the actual fix is reducing
# how often a *full* reload happens at all (extend the CLS-style
# domain-scoped refresh in refresh_domain_loaders below to more domains).
future::plan(future::multisession, workers = 2)

source(file.path("R", "database.R"), local = TRUE)
source(file.path("R", "auth.R"), local = TRUE)

# Diagnostic trace for the 2026-08-07 OOM crash loop -- logs the MAIN
# Shiny process's own RSS on a timer, independent of any session or save
# action, so it's possible to tell "main process slowly bloating from
# concurrent sessions" apart from "a worker process spiking on one call"
# (see the per-load MEMLOG in refresh_app_data() below). Self-reschedules
# on the process's own event loop; runs once per process, not per session.
log_main_process_memory <- function() {
  rss_kb <- process_rss_kb()
  if (!is.na(rss_kb)) {
    cat(sprintf(
      "MEMLOG scope=main pid=%s rss_kb=%s at=%s\n",
      Sys.getpid(), rss_kb, format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC")
    ))
  }
  later::later(log_main_process_memory, delay = 300)
}
log_main_process_memory()

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0) return(y)
  missing <- tryCatch(all(is.na(x)), error = function(error) FALSE)
  if (isTRUE(missing)) y else x
}


pages <- list(
  login = "Login",
  landing = "Timeline",
  reviewer_dashboard = "Plan review",
  plan_review_detail = "Plan review detail",
  approval_queue = "Plan approval queue",
  publishing_queue = "Publishing queue",
  measure_review = "Measure review",
  action_plan_measures = "Action Plan Measures",
  bug_fix = "Bug/Fix",
  role_preview = "Role preview",
  strategic_plan = "City action plan",
  team = "Performance team",
  plan_history = "View plan",
  metrics = "Measures review",
  overview = "Agency overview",
  goals = "Agency goals",
  services = "Agency services",
  risks = "Plan risks",
  cls_requests = "CLS requests",
  cls_request_detail = "CLS request detail",
  cls_review = "CLS review"
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

# AgencyApprover is retired and deliberately absent: access.user_role's CHECK
# constraint no longer accepts it, so offering it here would hand the admin a
# choice the database rejects. AgencySubmitter is the approving agency role.
performance_role_choices <- c(
  "AgencySubmitter",
  "AgencyWriter",
  "AgencyViewer",
  "OPIReviewer",
  "BBMRReviewer",
  "DeputyMayor",
  "CAOffice",
  "SystemAdmin"
)

access_policy <- list(
  role_edit_app_roles = c("SystemAdmin", "OPIReviewer", "BBMRReviewer", "CAOffice", "DeputyMayor", "AgencySubmitter"),
  role_edit_agency_roles = c("Agency Head", "Agency Director", "Chief of Staff"),
  plan_edit_app_roles = c("AgencySubmitter", "AgencyWriter", "SystemAdmin", "OPIReviewer"),
  submitter_assignment_app_roles = c("SystemAdmin", "CAOffice", "DeputyMayor"),
  submitter_assignment_agency_roles = c("Agency Head", "Agency Director", "Chief of Staff", "Admin"),
  measure_review_app_roles = c("SystemAdmin", "OPIReviewer"),
  measure_submit_app_roles = c("AgencySubmitter", "AgencyWriter", "SystemAdmin", "OPIReviewer"),
  measure_submit_agency_roles = c("Performance Lead", "Chief of Staff", "Agency Director", "Agency Head", "Admin"),
  plan_review_app_roles = c("SystemAdmin", "OPIReviewer", "BBMRReviewer", "CAOffice", "DeputyMayor"),
  final_plan_approval_app_roles = c("SystemAdmin")
)

role_grant_policy <- list(
  system_admin = performance_role_choices,
  reviewer_admin = c("AgencySubmitter", "AgencyWriter", "AgencyViewer"),
  portfolio_admin = c("AgencySubmitter", "AgencyWriter", "AgencyViewer"),
  agency_leadership = c("AgencySubmitter", "AgencyWriter", "AgencyViewer"),
  agency_submitter = c("AgencyWriter", "AgencyViewer")
)

has_any_role <- function(values, allowed) {
  any(values %in% allowed)
}

split_stored_roles <- function(value) {
  if (is.null(value) || !length(value)) return(character(0))
  value <- as.character(value)
  value <- value[!is.na(value)]
  roles <- unlist(strsplit(value, "\\|\\||;", perl = TRUE), use.names = FALSE)
  roles <- unique(trimws(roles))
  roles[nzchar(roles)]
}

can_edit_roles <- function(app_roles, agency_roles) {
  has_any_role(app_roles, access_policy$role_edit_app_roles) ||
    has_any_role(agency_roles, access_policy$role_edit_agency_roles)
}

can_assign_submitter <- function(app_roles, agency_roles) {
  has_any_role(app_roles, access_policy$submitter_assignment_app_roles) ||
    has_any_role(agency_roles, access_policy$submitter_assignment_agency_roles)
}

grantable_performance_roles <- function(app_roles, agency_roles) {
  if (has_any_role(app_roles, "SystemAdmin")) {
    return(role_grant_policy$system_admin)
  }
  allowed <- character(0)
  if (has_any_role(app_roles, c("OPIReviewer", "BBMRReviewer"))) {
    allowed <- c(allowed, role_grant_policy$reviewer_admin)
  }
  if (has_any_role(app_roles, c("CAOffice", "DeputyMayor"))) {
    allowed <- c(allowed, role_grant_policy$portfolio_admin)
  }
  if (has_any_role(agency_roles, access_policy$role_edit_agency_roles)) {
    allowed <- c(allowed, role_grant_policy$agency_leadership)
  }
  if (has_any_role(app_roles, "AgencySubmitter")) {
    allowed <- c(allowed, role_grant_policy$agency_submitter)
  }
  unique(allowed[allowed %in% performance_role_choices])
}

can_grant_performance_role <- function(app_roles, agency_roles, target_role) {
  target_role <- as.character(target_role %||% "")
  nzchar(target_role) && target_role %in% grantable_performance_roles(app_roles, agency_roles)
}

can_edit_plan_sections <- function(app_roles) {
  has_any_role(app_roles, access_policy$plan_edit_app_roles)
}

can_review_measures <- function(app_roles) {
  has_any_role(app_roles, access_policy$measure_review_app_roles)
}

can_view_plan_approval_queue <- function(app_roles) {
  has_any_role(app_roles, c("SystemAdmin", "DeputyMayor", "CAOffice"))
}

can_review_plans <- function(app_roles) {
  has_any_role(app_roles, access_policy$plan_review_app_roles)
}

can_route_plan_reviews <- function(app_roles) {
  has_any_role(app_roles, c("SystemAdmin", "OPIReviewer"))
}

can_submit_measures <- function(app_roles, agency_roles) {
  has_any_role(app_roles, access_policy$measure_submit_app_roles) ||
    has_any_role(agency_roles, access_policy$measure_submit_agency_roles)
}

can_submit_plans <- function(app_roles) {
  has_any_role(app_roles, c("AgencySubmitter", "SystemAdmin"))
}

can_finalize_plans <- function(app_roles) {
  has_any_role(app_roles, access_policy$final_plan_approval_app_roles)
}

can_view_application_admin <- function(app_roles) {
  has_any_role(app_roles, "SystemAdmin")
}

can_delete_measures <- function(app_roles) {
  has_any_role(app_roles, "SystemAdmin")
}

can_edit_locked_measure_data <- function(app_roles) {
  has_any_role(app_roles, "SystemAdmin")
}

can_view_performance_reviewing <- function(app_roles) {
  has_any_role(app_roles, c("SystemAdmin", "OPIReviewer", "BBMRReviewer", "CAOffice", "DeputyMayor"))
}

# Budget Planning (CLS) opened to BBMR's analysts on 2026-08-03, on Sarah's
# instruction. It is still NOT open to agencies: the gate admits BBMRReviewer
# (the 14-strong analyst roster) and SystemAdmin only, so BBMR can work the
# review queue while the placeholder spend-category list is still in place.
# Agency roles stay out until that list is replaced.
#
# The role functions below (can_view_cls_requests(), can_review_cls(), etc.)
# encode the real long-term permission model; this remains a single override to
# remove entirely once the feature opens to agencies.
can_access_budget_planning <- function(app_roles) {
  has_any_role(app_roles, c("BBMRReviewer", "SystemAdmin"))
}

# CLS requests are an agency-facing budget tool. Viewers can see them; writers,
# writers and submitters (agency leadership) can create/edit/delete. SystemAdmin
# has access for support and testing. AgencySubmitter is the approving role -
# there is no AgencyApprover; see cls-schema-reconciliation.md Q11.
# The agency-facing CLS Requests page. BBMR reviewers were originally excluded -
# they worked from CLS Review and reached a request through "Open request" - but
# they now need both Budget Planning pages so they can exercise the agency side
# of the workflow against the test agencies (2026-08-03). Their agency switcher
# offers only the test agencies, so this does not put a real agency's list in
# front of them.
can_view_cls_requests <- function(app_roles) {
  has_any_role(app_roles, c("AgencyViewer", "AgencyWriter", "AgencySubmitter", "BBMRReviewer", "SystemAdmin"))
}

# Who may open a single request page (agency users plus BBMR reviewers).
can_open_cls_request <- function(app_roles) {
  can_view_cls_requests(app_roles) || can_review_cls(app_roles)
}

can_edit_cls_requests <- function(app_roles) {
  has_any_role(app_roles, c("AgencyWriter", "AgencySubmitter", "BBMRReviewer", "SystemAdmin"))
}

# Agency Submitters (agency leadership, and admins) send requests on for BBMR
# review. This is the role with final agency approval per USER_TYPES.
can_approve_cls <- function(app_roles) {
  has_any_role(app_roles, c("AgencySubmitter", "SystemAdmin"))
}

# The BBMR review workspace.
can_review_cls <- function(app_roles) {
  has_any_role(app_roles, c("BBMRReviewer", "SystemAdmin"))
}

uses_review_administration_mode <- function(app_roles) {
  has_any_role(app_roles, c("CAOffice", "DeputyMayor"))
}

# A shared service's description (see service_is_shared()) is locked to
# admins/BBMR analysts, not agency users -- everyone else can view but not
# edit it, regardless of their own agency's edit permissions.
can_edit_shared_service_description <- function(app_roles) {
  has_any_role(app_roles, c("SystemAdmin", "BBMRReviewer"))
}

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

measure_status_filter_choices <- function() {
  c(
    "All except deprecated",
    "All statuses",
    "Draft",
    "Pending Approval",
    "Returned",
    "Validated",
    "Inactive",
    "Deprecated"
  )
}

agency_plan_status <- function(status) {
  switch(
    as.character(status),
    Draft = "Drafting",
    AgencyRevised = "Drafting",
    FeedbackReturned = "Returned",
    Returned = "Returned",
    UnderReview = "Reviewer review",
    DirectorSignOff = "Agency sign-off",
    DeputyMayorReview = "Deputy Mayor review",
    CAReview = "CA Office review",
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
  format_number <- function(number) {
    format(round(number, 2), big.mark = ",", trim = TRUE, scientific = FALSE)
  }
  format_percent <- function(number) {
    percent_value <- if (!is.na(number) && abs(number) > 0 && abs(number) < 1) number * 100 else number
    paste0(format_number(percent_value), "%")
  }
  formatted <- switch(
    format_type,
    Percent = format_percent(value),
    Currency = paste0("$", format_number(value)),
    Count = format_number(value),
    Days = paste(format_number(value), "days"),
    Decimal = format_number(value),
    Rate = format_number(value),
    Score = format_number(value),
    format_number(value)
  )
  if (!is.na(display_unit) && !format_type %in% c("Percent", "Days")) {
    formatted <- paste(formatted, display_unit)
  }
  formatted
}

# Built on current_fiscal_year() (R/database.R) so there's one shared
# implementation of the July-1 rollover, not a second copy that could
# drift from it -- this just relabels the same number for this page's
# "last complete actual / this year's target" summary column.
fiscal_measure_snapshot_years <- function(today = Sys.Date()) {
  target_fy <- current_fiscal_year(today)
  list(actual_fy = target_fy - 1L, target_fy = target_fy)
}

fy_label <- function(year) {
  year <- suppressWarnings(as.integer(year))
  ifelse(is.na(year), "FY", sprintf("FY%02d", year %% 100L))
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

assignment_key <- function(value) {
  value <- as.character(value)
  value[is.na(value)] <- ""
  value <- tolower(trimws(value))
  gsub("[^a-z0-9]+", "", value)
}

entity_role_assignment_rows <- function(db = NULL) {
  if (!is.null(db) && "workflow_entity_role_assignment" %in% names(db) && nrow(db$workflow_entity_role_assignment)) {
    rows <- db$workflow_entity_role_assignment
    return(data.frame(
      entity_type = rows$entity_type,
      agency_id = rows$agency_id,
      agency = rows$agency,
      entity_id = as.character(rows$entity_id),
      public_name = rows$public_name,
      submitter = rows$submitter_name,
      reviewer = rows$reviewer_name,
      deputy_mayor = rows$deputy_mayor_name,
      ca_office = rows$ca_office_name,
      submitter_user_id = rows$submitter_user_id,
      reviewer_user_id = rows$reviewer_user_id,
      deputy_mayor_user_id = rows$deputy_mayor_user_id,
      ca_office_user_id = rows$ca_office_user_id,
      stringsAsFactors = FALSE
    ))
  }
  path <- file.path("database", "seed", "entity_role_assignments.csv")
  if (!file.exists(path)) {
    return(data.frame(
      entity_type = character(),
      agency_id = character(),
      agency = character(),
      entity_id = character(),
      public_name = character(),
      reviewer = character(),
      deputy_mayor = character(),
      ca_office = character(),
      submitter = character(),
      stringsAsFactors = FALSE
    ))
  }
  read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
}

plan_role_assignment <- function(db, plan) {
  assignments <- entity_role_assignment_rows(db)
  if (is.null(plan) || !nrow(plan) || !nrow(assignments)) return(assignments[0, , drop = FALSE])
  if (!is.na(plan$entity_id[[1]]) && "entity_id" %in% names(assignments)) {
    entity_match <- !is.na(assignments$entity_id) & as.character(assignments$entity_id) == as.character(plan$entity_id[[1]])
    rows <- assignments[entity_match, , drop = FALSE]
    if (nrow(rows)) return(rows[1, , drop = FALSE])
  }
  display_key <- assignment_key(plan_display_name(db, plan))
  rows <- assignments[assignment_key(assignments$public_name) == display_key, , drop = FALSE]
  if (nrow(rows)) return(rows[1, , drop = FALSE])
  if (!is.na(plan$agency_id[[1]]) && "agency_id" %in% names(assignments)) {
    agency_match <- !is.na(assignments$agency_id) & assignments$agency_id == plan$agency_id[[1]]
    no_entity <- is.na(assignments$entity_id) | !nzchar(trimws(as.character(assignments$entity_id)))
    rows <- assignments[agency_match & no_entity, , drop = FALSE]
    if (nrow(rows)) return(rows[1, , drop = FALSE])
  }
  assignments[0, , drop = FALSE]
}

plan_deputy_mayor_label <- function(db, plan) {
  assignment <- plan_role_assignment(db, plan)
  if (nrow(assignment) && "deputy_mayor" %in% names(assignment)) {
    value <- trimws(as.character(assignment$deputy_mayor[[1]] %||% ""))
    if (nzchar(value)) return(value)
  }
  agency_id <- plan_accounting_agency_id(db, plan)
  agency <- db$reference_agency[db$reference_agency$agency_id == agency_id, , drop = FALSE]
  if (!nrow(agency) || !"deputy_mayor_pillar" %in% names(agency)) return("Unassigned")
  value <- trimws(as.character(agency$deputy_mayor_pillar[[1]] %||% ""))
  if (!nzchar(value)) "Unassigned" else value
}

plan_ca_office_label <- function(db, plan) {
  assignment <- plan_role_assignment(db, plan)
  if (nrow(assignment) && "ca_office" %in% names(assignment)) {
    value <- trimws(as.character(assignment$ca_office[[1]] %||% ""))
    if (nzchar(value)) return(value)
  }
  "Unassigned"
}

plan_submitter_label <- function(db, plan) {
  assignment <- plan_role_assignment(db, plan)
  if (nrow(assignment) && "submitter" %in% names(assignment)) {
    value <- trimws(as.character(assignment$submitter[[1]] %||% ""))
    if (nzchar(value)) return(value)
  }
  agency_id <- plan_accounting_agency_id(db, plan)
  submitters <- db$access_user_role[
    db$access_user_role$agency_id == agency_id &
      db$access_user_role$app_role == "AgencySubmitter",
    ,
    drop = FALSE
  ]
  if (nrow(submitters)) {
    labels <- unique(trimws(submitters$full_name[!is.na(submitters$full_name) & nzchar(trimws(submitters$full_name))]))
    if (length(labels)) return(paste(labels, collapse = "; "))
  }
  "Unassigned"
}

plan_reviewer_label <- function(db, plan) {
  if (!is.null(plan) && nrow(plan) && "assigned_reviewer_name" %in% names(plan)) {
    value <- trimws(as.character(plan$assigned_reviewer_name[[1]] %||% ""))
    if (nzchar(value)) return(value)
  }
  reviews <- db$review_plan_review[db$review_plan_review$plan_id == plan$plan_id[[1]], , drop = FALSE]
  if (nrow(reviews)) {
    reviews <- reviews[order(reviews$review_started_at, reviews$review_id, decreasing = TRUE, na.last = TRUE), , drop = FALSE]
    value <- trimws(as.character(reviews$reviewer_name[[1]] %||% ""))
    if (nzchar(value)) return(value)
  }
  assignment <- plan_role_assignment(db, plan)
  if (nrow(assignment) && "reviewer" %in% names(assignment)) {
    value <- trimws(as.character(assignment$reviewer[[1]] %||% ""))
    if (nzchar(value)) return(value)
  }
  "Unassigned"
}

performance_plan_title <- function(db, plan, suffix = NULL) {
  base <- paste(plan_display_name(db, plan), "Performance Plan")
  if (is.null(suffix) || !nzchar(trimws(suffix))) base else paste(base, suffix, sep = ": ")
}

plan_export_filename <- function(db, plan, extension, include_review = TRUE) {
  display_name <- if (!is.null(plan) && nrow(plan)) plan_display_name(db, plan) else "Plan"
  safe_name <- gsub("[^A-Za-z0-9 _.-]+", "", display_name)
  safe_name <- gsub("\\s+", " ", trimws(safe_name))
  safe_name <- gsub("\\s+", "-", safe_name)
  if (!nzchar(safe_name)) safe_name <- "Plan"
  paste0(safe_name, "-Performance-Plan", if (isTRUE(include_review)) "-Review" else "", ".", extension)
}

plan_accounting_agency_id <- function(db, plan) {
  if (is.null(plan) || !nrow(plan)) return(NA_character_)
  if (!is.na(plan$agency_id[[1]])) return(plan$agency_id[[1]])
  entity <- db$reference_plan_entity[db$reference_plan_entity$entity_id == plan$entity_id[[1]], , drop = FALSE]
  if (nrow(entity)) entity$parent_agency_id[[1]] else NA_character_
}

# The BBMR analyst assigned to an agency's portfolio. Keyed on the agency so
# both callers can use it: plan-based screens resolve their plan to an agency
# first, and CLS - which is organised by agency throughout - already has one.
agency_budget_analyst <- function(db, agency_id) {
  agency_id <- as.character(agency_id %||% "")
  if (!nzchar(agency_id) || is.na(agency_id)) return(NA_character_)
  if (!"reference_agency" %in% names(db) || !"budget_analyst" %in% names(db$reference_agency)) return(NA_character_)
  agency <- db$reference_agency[db$reference_agency$agency_id == agency_id, , drop = FALSE]
  if (!nrow(agency)) return(NA_character_)
  value <- trimws(as.character(agency$budget_analyst[[1]] %||% ""))
  if (!nzchar(value)) return(NA_character_)
  value
}

plan_budget_analyst <- function(db, plan) {
  agency_budget_analyst(db, plan_accounting_agency_id(db, plan))
}

plan_budget_analyst_label <- function(db, plan) {
  value <- plan_budget_analyst(db, plan)
  if (is.na(value)) "Unassigned" else value
}

plan_service_rows <- function(db, plan) {
  if (is.null(plan) || !nrow(plan)) return(db$reference_service[0, , drop = FALSE])
  if (is.na(plan$plan_id[[1]])) return(db$reference_service[0, , drop = FALSE])
  plan_services <- db$performance_plan_service[db$performance_plan_service$plan_id == plan$plan_id[[1]], , drop = FALSE]
  service_rows <- merge(plan_services, db$reference_service, by = "service_id", all.x = TRUE)
  # Plan links to services missing from the active reference list (e.g. a
  # service deactivated after the plan was seeded) merge to NA rows; drop them
  # rather than letting NA subscripts crash every page that counts services.
  service_rows <- service_rows[!is.na(service_rows$active), , drop = FALSE]
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
    missing_entity_service_ids <- setdiff(pes$service_id, service_rows$service_id)
    if (length(missing_entity_service_ids)) {
      extra_services <- db$reference_service[db$reference_service$service_id %in% missing_entity_service_ids, , drop = FALSE]
      if (nrow(extra_services)) {
        extra_services$plan_service_id <- NA_integer_
        extra_services$plan_id <- plan$plan_id[[1]]
        extra_services$sort_order <- seq_len(nrow(extra_services)) + ifelse(nrow(service_rows), max(service_rows$sort_order, na.rm = TRUE), 0)
        service_rows <- rbind(service_rows[, names(extra_services), drop = FALSE], extra_services)
      }
    }
    service_rows <- merge(service_rows, pes[, c("service_id", "is_primary"), drop = FALSE], by = "service_id", all.x = TRUE)
    service_rows$is_primary[is.na(service_rows$is_primary)] <- FALSE
    service_rows <- service_rows[service_rows$active, , drop = FALSE]
    service_rows <- service_rows[order(-as.integer(service_rows$is_primary), service_rows$sort_order, service_rows$service_name), , drop = FALSE]
  } else {
    entity_service_ids <- character(0)
    self_entity_service_ids <- character(0)
    if ("reference_plan_entity_service" %in% names(db) && "reference_plan_entity" %in% names(db)) {
      agency_public_name <- db$reference_agency$public_name[db$reference_agency$agency_id == plan$agency_id[[1]]]
      agency_public_name <- agency_public_name[!is.na(agency_public_name) & nzchar(trimws(agency_public_name))]
      self_entities <- db$reference_plan_entity[
        db$reference_plan_entity$parent_agency_id == plan$agency_id[[1]] &
          db$reference_plan_entity$active &
          db$reference_plan_entity$has_own_plan &
          db$reference_plan_entity$public_name %in% agency_public_name,
        ,
        drop = FALSE
      ]
      if (nrow(self_entities)) {
        self_entity_service_ids <- unique(db$reference_plan_entity_service$service_id[
          db$reference_plan_entity_service$entity_id %in% self_entities$entity_id
        ])
        missing_self_service_ids <- setdiff(self_entity_service_ids, service_rows$service_id)
        if (length(missing_self_service_ids)) {
          extra_services <- db$reference_service[db$reference_service$service_id %in% missing_self_service_ids, , drop = FALSE]
          if (nrow(extra_services)) {
            extra_services$plan_service_id <- NA_integer_
            extra_services$plan_id <- plan$plan_id[[1]]
            extra_services$sort_order <- seq_len(nrow(extra_services)) + ifelse(nrow(service_rows), max(service_rows$sort_order, na.rm = TRUE), 0)
            service_rows <- rbind(service_rows[, names(extra_services), drop = FALSE], extra_services)
          }
        }
      }
      child_entities <- db$reference_plan_entity[
        db$reference_plan_entity$parent_agency_id == plan$agency_id[[1]] &
          db$reference_plan_entity$has_own_plan &
          db$reference_plan_entity$active &
          !db$reference_plan_entity$entity_id %in% self_entities$entity_id,
        ,
        drop = FALSE
      ]
      if (nrow(child_entities)) {
        entity_service_ids <- unique(db$reference_plan_entity_service$service_id[
          db$reference_plan_entity_service$entity_id %in% child_entities$entity_id
        ])
      }
    }
    service_rows <- service_rows[
      service_rows$active &
        (service_rows$service_type == "Performance" | service_rows$service_id %in% self_entity_service_ids),
      ,
      drop = FALSE
    ]
    service_rows <- service_rows[!service_rows$service_id %in% entity_service_ids, , drop = FALSE]
    service_rows <- service_rows[order(service_rows$service_name), , drop = FALSE]
  }
  service_rows
}

is_administration_service <- function(service_rows) {
  if (is.null(service_rows) || !nrow(service_rows) || !"service_type" %in% names(service_rows)) return(rep(FALSE, if (is.null(service_rows)) 0 else nrow(service_rows)))
  !is.na(service_rows$service_type) & tolower(trimws(service_rows$service_type)) == "administrative"
}

scorable_service_rows <- function(service_rows) {
  if (is.null(service_rows) || !nrow(service_rows)) return(service_rows)
  service_rows[!is_administration_service(service_rows), , drop = FALSE]
}

ensure_measure_current_entity_link <- function(connection, measure_id, data, plan) {
  if (is.null(plan) || !nrow(plan) || is.na(plan$entity_id[[1]])) return(invisible(FALSE))
  entity <- data$reference_plan_entity[data$reference_plan_entity$entity_id == plan$entity_id[[1]], , drop = FALSE]
  if (!nrow(entity)) return(invisible(FALSE))
  # A measure must never link to an entity outside its own owning agency
  # -- e.g. saving an EXISTING DGS measure while the current viewer
  # happens to be acting as OPI's plan (a common admin/testing scenario)
  # must not silently relabel it as an OPI-owned measure. Reported
  # 2026-07-31: "Average Age of Fleet" (agency_id AGC2600/DGS) picked up
  # a stray link to OPI's entity this way, and the Action Plan Measures
  # list -- which shows the linked entity's name over the bare agency
  # name -- started displaying it as owned by OPI instead of DGS.
  measure_row <- data$performance_performance_measure[data$performance_performance_measure$measure_id == as.integer(measure_id), , drop = FALSE]
  if (!nrow(measure_row)) return(invisible(FALSE))
  if (!identical(as.character(measure_row$agency_id[[1]]), as.character(plan_accounting_agency_id(data, plan)))) return(invisible(FALSE))
  services <- plan_service_rows(data, plan)
  services <- services[!is_administration_service(services), , drop = FALSE]
  if (!nrow(services)) services <- plan_service_rows(data, plan)
  # Reported 2026-08-06: a Mayoral Office with zero services (by design --
  # see submitter_is_mayoral_service()) could never get a measure linked
  # into its library at all -- this used to return FALSE here with no
  # error, so the Save button appeared to do nothing even though the
  # measure itself saved correctly. A 'mayoral service'/'quasi agency'
  # link is entity-scoped, not service-scoped (measure_entity_link.
  # service_id is nullable for exactly this reason), so falling back to
  # NA_character_ instead of bailing out is the fix.
  primary_service_id <- if (nrow(services)) {
    candidate <- services$service_id[[1]]
    if ("is_primary" %in% names(services)) {
      primary <- services[!is.na(services$is_primary) & services$is_primary, , drop = FALSE]
      if (nrow(primary)) candidate <- primary$service_id[[1]]
    }
    candidate
  } else {
    NA_character_
  }
  link_entity_type <- switch(
    as.character(entity$entity_type[[1]]),
    MayoraltyOffice = "mayoral service",
    `mayoral service` = "mayoral service",
    QuasiAgency = "quasi agency",
    `quasi agency` = "quasi agency",
    Other = "quasi agency",
    "quasi agency"
  )
  agency_id <- plan_accounting_agency_id(data, plan)
  entity_id <- as.integer(entity$entity_id[[1]])
  public_name <- as.character(entity$public_name[[1]])
  if (is.na(primary_service_id)) {
    # Postgres treats NULL as distinct from NULL under a UNIQUE
    # constraint, so ON CONFLICT (..., service_id, ...) can never detect
    # an existing NULL-service_id row as a duplicate -- every save would
    # otherwise INSERT a fresh row instead of updating the one already
    # there. Check-then-act manually for this one case instead.
    existing <- DBI::dbGetQuery(
      connection,
      paste(
        "SELECT link_id FROM performance.measure_entity_link",
        "WHERE measure_id = $1 AND agency_id = $2 AND service_id IS NULL AND entity_type = $3 AND entity_id = $4"
      ),
      params = list(as.integer(measure_id), agency_id, link_entity_type, entity_id)
    )
    if (nrow(existing)) {
      DBI::dbExecute(
        connection,
        "UPDATE performance.measure_entity_link SET public_name = $2, updated_at = now() WHERE link_id = $1",
        params = list(existing$link_id[[1]], public_name)
      )
    } else {
      DBI::dbExecute(
        connection,
        paste(
          "INSERT INTO performance.measure_entity_link",
          "(measure_id, agency_id, service_id, entity_type, entity_id, public_name)",
          "VALUES ($1, $2, NULL, $3, $4, $5)"
        ),
        params = list(as.integer(measure_id), agency_id, link_entity_type, entity_id, public_name)
      )
    }
  } else {
    DBI::dbExecute(
      connection,
      paste(
        "INSERT INTO performance.measure_entity_link",
        "(measure_id, agency_id, service_id, entity_type, entity_id, public_name)",
        "VALUES ($1, $2, $3, $4, $5, $6)",
        "ON CONFLICT (measure_id, agency_id, service_id, entity_type, entity_id)",
        "DO UPDATE SET public_name = EXCLUDED.public_name, updated_at = now()"
      ),
      params = list(as.integer(measure_id), agency_id, primary_service_id, link_entity_type, entity_id, public_name)
    )
  }
  invisible(TRUE)
}

measure_preview_years <- function(current_fy = current_fiscal_year()) {
  # Matches the budget book: the four most recently completed actual years,
  # then this year's target and next year's -- we're always planning one
  # fiscal year ahead of whichever one is currently executing (e.g. FY27
  # executing now means FY27-FY28 Target, FY23-FY26 Actual). The two
  # ranges must not overlap (a repeated year showed up as a duplicate
  # column).
  list(
    actual_years = seq.int(current_fy - 4L, current_fy - 1L),
    target_years = seq.int(current_fy, current_fy + 1L)
  )
}

# Builds one <tr>'s cells for a kpi-history-table, highlighting the cell for
# highlight_year -- the past fiscal year's actual and the next fiscal
# year's target are the two boxes users most need to keep current, so they
# get a visual callout instead of blending into the rest of the row.
history_row_cells <- function(values, years, highlight_year) {
  Map(function(value, year) {
    tags$td(class = if (identical(year, highlight_year)) "kpi-history-highlight", value)
  }, values, years)
}

service_body_output_id <- function(service_id) {
  paste0("service_body_", gsub("[^A-Za-z0-9_]", "_", as.character(service_id)))
}

service_editor_body_ui <- function(db, plan, service_row, measures = NULL, metric_choices = NULL, locked = FALSE, can_edit_shared_description = FALSE) {
  if (is.null(service_row) || !nrow(service_row)) return(NULL)
  service_id <- service_row$service_id[[1]]
  service_is_admin <- is_administration_service(service_row)
  # A service shared by multiple entities (e.g. a grant program with
  # several peer grantee agencies) has one description but many editors --
  # lock it to system admins/BBMR analysts (can_edit_shared_description)
  # regardless of plan-editability so no single grantee can overwrite the
  # others' shared text. Each entity still manages its OWN metric
  # selection below via measure_entity_link.
  service_shared <- service_is_shared(db, service_id)
  description_locked <- isTRUE(locked) || (service_shared && !isTRUE(can_edit_shared_description))
  if (is.null(measures)) {
    measures <- eligible_plan_measures(measure_library_rows(db, plan, include_ineligible = FALSE))
  }
  if (is.null(metric_choices)) {
    metric_choices <- setNames(measures$measure_id, measures$title)
  }
  services_draft <- if (plan_uses_draft_payload(plan)) section_draft_payload(db, plan$plan_id[[1]], "services") else NULL
  description <- draft_value(services_draft, paste0("service_description_", service_id), service_row$service_description[[1]])
  selected_metric_ids <- if (!is.null(services_draft) && !is.null(services_draft$serviceMetrics[[service_id]])) {
    suppressWarnings(as.integer(unlist(services_draft$serviceMetrics[[service_id]])))
  } else if (service_is_admin) {
    integer(0)
  } else {
    service_metric_ids(db, plan, service_id, measures)
  }
  selected_metric_ids <- selected_metric_ids[!is.na(selected_metric_ids)]
  selected_metrics <- if (length(selected_metric_ids) > 0) as.character(selected_metric_ids) else ""
  other_service_metric_ids <- service_metric_ids_for_other_services(db, plan, service_id)
  service_metric_select <- function(metric_index, selected_value) {
    selected_value <- as.character(selected_value %||% "")
    select_id <- paste0("service_metric_", service_id, "_", metric_index)
    tags$select(
      id = select_id,
      name = select_id,
      class = "form-control service-metric-select",
      tags$option(value = "", selected = if (!nzchar(selected_value)) "selected", "Select a metric"),
      lapply(seq_along(metric_choices), function(choice_index) {
        value <- as.character(metric_choices[[choice_index]])
        label <- names(metric_choices)[[choice_index]]
        tags$option(
          value = value,
          selected = if (identical(value, selected_value)) "selected",
          label
        )
      })
    )
  }
  metric_selector_rows <- lapply(seq_along(selected_metrics), function(metric_index) {
    div(
      class = "kpi-select-row",
      service_metric_select(metric_index, selected_metrics[metric_index]),
      if (metric_index > 1 || nzchar(selected_metrics[metric_index])) tags$button(type = "button", class = "kpi-remove-button", title = "Remove metric", `aria-label` = "Remove metric", icon("xmark"))
    )
  })
  preview_years <- measure_preview_years()
  preview_all_years <- c(preview_years$actual_years, preview_years$target_years)
  recent_actual_fy <- preview_years$actual_years[length(preview_years$actual_years)]
  upcoming_target_fy <- preview_years$target_years[length(preview_years$target_years)]
  metric_previews <- if (service_is_admin) list() else lapply(seq_len(nrow(measures)), function(measure_index) {
    measure <- measures[measure_index, , drop = FALSE]
    history <- db$performance_measure_actuals[db$performance_measure_actuals$measure_id == measure$measure_id, , drop = FALSE]
    actual_values <- vapply(preview_all_years, function(year) {
      row <- history[history$fiscal_year == year, , drop = FALSE]
      value <- if (nrow(row)) row$annual_actual[[1]] else NA_real_
      format_measure_value(value, measure$format_type[1], measure$display_unit[1])
    }, character(1))
    target_values <- vapply(preview_all_years, function(year) {
      row <- history[history$fiscal_year == year, , drop = FALSE]
      value <- if (nrow(row)) row$target_value[[1]] else NA_real_
      format_measure_value(value, measure$format_type[1], measure$display_unit[1], "Not set")
    }, character(1))
    div(
      class = paste("kpi-measure-preview", if (as.character(measure$measure_id) %in% selected_metrics) "active" else ""),
      `data-measure-id` = as.character(measure$measure_id),
      title = "Click to review or edit this measure",
      div(
        class = "kpi-preview-header",
        div(h4(measure$title)),
        div(
          class = "chip-row",
          status_chip(measure$measure_type, "primary"),
          status_chip(measure$desired_direction, "success"),
          measure_validation_chip(measure)
        )
      ),
      div(
        class = "kpi-history-wrap",
        tags$table(
          class = "kpi-history-table",
          tags$caption(class = "sr-only", paste(measure$title, "actuals and targets by fiscal year")),
          tags$thead(tags$tr(
            tags$th(scope = "col", "Series"),
            lapply(preview_all_years, function(year) tags$th(scope = "col", fy_label(year)))
          )),
          tags$tbody(
            tags$tr(tags$th(scope = "row", "Actual"), history_row_cells(actual_values, preview_all_years, recent_actual_fy)),
            tags$tr(tags$th(scope = "row", "Target"), history_row_cells(target_values, preview_all_years, upcoming_target_fy))
          )
        ),
        p(class = "kpi-history-click-hint", icon("arrow-up-right-from-square"), "Click to review or edit this measure")
      )
    )
  })
  tagList(
    div(
      class = "goal-form-field full-width",
      tags$label(class = "control-label", `for` = paste0("service_description_", service_id), "Service description"),
      p(class = "goal-field-instruction", "Describe the service in a consistent outcome-oriented structure: start with what the service provides, explain the goal or value it creates for the agency or residents, then name the core activities performed by the service."),
      p(class = "goal-field-instruction", "A strong description should avoid a simple task list. It should connect administrative, operational, or resident-facing work to the agency's strategic priorities, such as operational success, accountability, effective use of data, service excellence, or attracting and retaining talented people."),
      p(class = "goal-field-instruction", "Example structure: This service provides executive direction, communications and public relations, fiscal management, human capital management, and performance management for the department. The goal of this service is to drive innovation, promote the agency's strategic plan, and strengthen service excellence. Activities performed by this service include administrative direction, fiscal management, human resource support, performance management, communications, and change management."),
      if (description_locked) div(
        class = "measure-validated-lock-note",
        icon("lock"),
        if (service_shared) "This service is shared by multiple entities, so its description is locked to system admins and BBMR analysts." else "This plan is no longer editable."
      ),
      disable_input_tag(textAreaInput(paste0("service_description_", service_id), label = NULL, rows = 4, value = description), description_locked)
    ),
    if (service_is_admin) div(
      class = "goal-form-field full-width",
      div(class = "required-fields-note", "Administration services are visible for planning context, but they do not require metric selection and are not scored in this cycle.")
    ) else div(
      class = "goal-form-field full-width kpi-picker service-metric-picker",
      tags$label(class = "control-label", `for` = paste0("service_metric_", service_id, "_1"), "Metrics"),
      p(class = "goal-field-instruction", "Choose from the agency's validated performance measures. Review the measure definition and five-year history before selecting it."),
      p(class = "goal-field-instruction", "Select the metric that best captures the quality, timeliness, efficiency, or outcomes of this service. Choose outcome or leading indicators where possible - avoid selecting metrics that only count activity or workload. A metric can also serve as a goal-level KPI; you may see the same measure appear in both places."),
      if (length(selected_metric_ids) > 5) div(class = "required-fields-note error-note", "This service has more than 5 metrics selected. Remove metrics until 5 or fewer remain before saving."),
      div(
        class = "kpi-selectors service-metric-selectors",
        `data-service-id` = service_id,
        `data-service-disabled-metrics` = paste(other_service_metric_ids, collapse = ","),
        metric_selector_rows
      ),
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
        tags$button(type = "button", class = "civic-button secondary small", `data-page` = "metrics", `data-new-measure` = "true", icon("plus"), "Build a new measure")
      )
    )
  )
}

plan_measure_rows <- function(db, plan, include_ineligible = FALSE) {
  if (is.null(plan) || !nrow(plan)) return(db$performance_performance_measure[0, , drop = FALSE])
  if (is.na(plan$plan_id[[1]])) return(db$performance_performance_measure[0, , drop = FALSE])
  services <- plan_service_rows(db, plan)
  # Reported 2026-08-06: bailing out here whenever a plan has zero services
  # also hid every measure reachable ONLY through the entity_id-based
  # match in performance_measure_entity_link below, which doesn't depend on
  # services at all for an entity submitter -- a Mayoral Office with zero
  # services (by design) could never see a measure in its own library even
  # after ensure_measure_current_entity_link() successfully linked it. Only
  # the bare-agency (else) branch below actually needs `services` to mean
  # anything.
  # Reported 2026-08-05: a QuasiAgency sharing a service with sibling
  # grantees (e.g. Civic Promotion Grants -- Baltimore Heritage Area,
  # Baltimore Public Markets, Lexington Market) saw every sibling's
  # measures on its own Measures page, not just its own. Without
  # entity_scoped_only, legacy_service_measure_ids() treats a shared
  # service's whole measure catalog as valid for every grantee via the
  # bare agency_id match (all grantees share their parent agency's
  # agency_id) -- previously relied on as a fallback so a brand-new
  # grantee with no measures yet had *something* to pick from. That
  # fallback is no longer needed: any entity can always create its own
  # brand-new measure (ensure_measure_current_entity_link() correctly
  # attaches it), so showing siblings' measures here was pure leakage,
  # not a safety net. service_metric_ids() already passes
  # entity_scoped_only = TRUE for the same reason.
  measure_ids <- if (nrow(services)) legacy_service_measure_ids(db, plan, services$service_id, include_ineligible = include_ineligible, entity_scoped_only = TRUE) else integer(0)
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
    measure_ids <- unique(c(measure_ids, entity_links$measure_id))
  }
  measure_ids <- measure_ids[!is.na(measure_ids)]
  if (!length(measure_ids)) return(db$performance_performance_measure[0, , drop = FALSE])
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

legacy_service_measure_ids <- function(db, plan, service_ids, include_ineligible = FALSE, entity_scoped_only = FALSE) {
  link_table <- if (include_ineligible && "performance_pm_service_link_all" %in% names(db)) db$performance_pm_service_link_all else db$performance_pm_service_link
  if (is.null(link_table) || !nrow(link_table) || !length(service_ids)) return(integer(0))
  link_rows <- link_table[as.character(link_table$service_id) %in% as.character(service_ids), , drop = FALSE]
  if (!nrow(link_rows)) return(integer(0))
  measure_ids <- unique(link_rows$measure_id)
  measure_ids <- measure_ids[!is.na(measure_ids)]
  if (!length(measure_ids) || is.null(plan) || !nrow(plan)) return(measure_ids)

  measure_rows <- db$performance_performance_measure[db$performance_performance_measure$measure_id %in% measure_ids, , drop = FALSE]
  if (!nrow(measure_rows)) return(integer(0))

  accounting_agency_id <- plan_accounting_agency_id(db, plan)
  # A shared service's measures (a grant program with several peer
  # quasi-agency grantees, etc.) remain valid CANDIDATES for every
  # grantee via the bare agency_id match -- they all draw from the same
  # program's measure catalog. But when computing what's CURRENTLY
  # selected/attached for one specific entity (entity_scoped_only, used by
  # service_metric_ids()), that same bare match must not apply --
  # grantees typically share their parent agency's agency_id, so it would
  # show every OTHER entity's picks as already selected too. Only an
  # explicit entity-specific link (below) counts as "selected" for a
  # shared service.
  keep_ids <- measure_rows$measure_id[measure_rows$agency_id == accounting_agency_id]
  if (entity_scoped_only) {
    service_ids_unique <- unique(as.character(service_ids))
    shared_service_ids <- service_ids_unique[vapply(service_ids_unique, function(sid) service_is_shared(db, sid), logical(1))]
    measures_on_shared_service <- if (length(shared_service_ids)) unique(link_rows$measure_id[as.character(link_rows$service_id) %in% shared_service_ids]) else integer(0)
    keep_ids <- keep_ids[!keep_ids %in% measures_on_shared_service]
  }

  if ("performance_measure_entity_link" %in% names(db) && nrow(db$performance_measure_entity_link) && !is.na(plan$entity_id[[1]])) {
    scoped_links <- db$performance_measure_entity_link[
      !is.na(db$performance_measure_entity_link$entity_id) &
        db$performance_measure_entity_link$entity_id == plan$entity_id[[1]] &
        as.character(db$performance_measure_entity_link$service_id) %in% as.character(service_ids),
      ,
      drop = FALSE
    ]
    keep_ids <- unique(c(keep_ids, scoped_links$measure_id))
  }

  unique(measure_ids[measure_ids %in% keep_ids])
}

measure_library_rows <- function(db, plan, include_ineligible = FALSE) {
  if (is.null(plan) || !nrow(plan)) return(db$performance_performance_measure[0, , drop = FALSE])
  agency_id <- plan_accounting_agency_id(db, plan)
  # Must not require the entity_link table to already have rows SOMEWHERE
  # (nrow() > 0 is a global check, not scoped to this plan) -- a shared
  # service with no entity links created yet for ANY entity would
  # otherwise skip the entity-aware branch below and fall through to the
  # unscoped blanket agency dump further down, showing every grantee the
  # exact same unfiltered agency-wide catalog.
  if ("performance_measure_entity_link" %in% names(db)) {
    if (include_ineligible && is.na(plan$entity_id[[1]])) {
      library_links <- db$performance_measure_entity_link[
        db$performance_measure_entity_link$agency_id == plan$agency_id[[1]] &
          db$performance_measure_entity_link$entity_type == "service",
        ,
        drop = FALSE
      ]
      if (nrow(library_links)) {
        linked_ids <- unique(library_links$measure_id)
        agency_ids <- db$performance_performance_measure$measure_id[
          db$performance_performance_measure$agency_id == agency_id
        ]
        rows <- db$performance_performance_measure[
          db$performance_performance_measure$measure_id %in% unique(c(linked_ids, agency_ids)),
          ,
          drop = FALSE
        ]
        return(rows[order(rows$title), , drop = FALSE])
      }
    }
    linked_rows <- plan_measure_rows(db, plan, include_ineligible = include_ineligible)
    if (is.na(plan$entity_id[[1]])) {
      agency_rows <- db$performance_performance_measure[db$performance_performance_measure$agency_id == agency_id, , drop = FALSE]
      linked_rows <- unique(rbind(linked_rows, agency_rows))
    }
    if (nrow(linked_rows) || !include_ineligible || !is.na(plan$entity_id[[1]])) {
      if (!include_ineligible && nrow(linked_rows)) {
        linked_rows <- eligible_plan_measures(linked_rows)
      }
      return(linked_rows[order(linked_rows$title), , drop = FALSE])
    }
  }
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
  linked_ids <- legacy_service_measure_ids(db, plan, service_id, include_ineligible = include_ineligible, entity_scoped_only = TRUE)
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
    linked_ids <- unique(c(linked_ids, entity_links$measure_id))
  }
  linked_ids <- linked_ids[!is.na(linked_ids)]
  if (!include_ineligible && length(linked_ids)) {
    eligible_ids <- measure_library_rows(db, plan, include_ineligible = FALSE)$measure_id
    linked_ids <- linked_ids[linked_ids %in% eligible_ids]
  }
  linked_ids
}

service_metric_ids_for_other_services <- function(db, plan, service_id) {
  if (is.null(plan) || !nrow(plan)) return(character(0))
  services <- scorable_service_rows(plan_service_rows(db, plan))
  other_service_ids <- setdiff(as.character(services$service_id), as.character(service_id))
  if (!length(other_service_ids)) return(character(0))
  services_draft <- if (plan_uses_draft_payload(plan)) section_draft_payload(db, plan$plan_id[[1]], "services") else NULL
  ids <- unlist(lapply(other_service_ids, function(other_service_id) {
    draft_values <- if (!is.null(services_draft) && !is.null(services_draft$serviceMetrics[[other_service_id]])) {
      suppressWarnings(as.integer(unlist(services_draft$serviceMetrics[[other_service_id]])))
    } else {
      service_metric_ids(db, plan, other_service_id, include_ineligible = TRUE)
    }
    draft_values[!is.na(draft_values)]
  }), use.names = FALSE)
  unique(as.character(ids[!is.na(ids)]))
}

performance_planning_timeline <- function() {
  data.frame(
    start_date = as.Date(c("2026-06-30", "2026-07-01", "2026-07-06", "2026-08-05", "2026-08-05", "2026-08-26")),
    end_date = as.Date(c("2026-06-30", "2026-08-05", "2026-07-17", "2026-08-12", "2026-09-04", "2026-09-30")),
    date_label = c(
      "June 30",
      "Due August 5",
      "July 6 - July 17",
      "Upon submission - August 12",
      "August 5 - September 4",
      "August 26 - September 30"
    ),
    milestone = c(
      "Agency Performance Plan Guidance is Released and Application Open",
      "First draft due. Agencies submit the first draft and set up individual meetings with their assigned analyst for in-depth support.",
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

timeline_all_items <- function(today = Sys.Date()) {
  timeline <- performance_planning_timeline()
  timeline$status <- ifelse(
    timeline$end_date < today,
    "Completed",
    ifelse(timeline$start_date <= today & timeline$end_date >= today, "Current", "Upcoming")
  )
  timeline
}

timeline_step_card <- function(row) {
  status_class <- switch(
    as.character(row$status[[1]]),
    "Current" = "current-step",
    "Current step" = "current-step",
    "Last step" = "last-step",
    "Next step" = "next-step",
    "Following step" = "following-step",
    tolower(gsub(" ", "-", row$status[[1]]))
  )
  div(
    class = paste("timeline-step-card", status_class),
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

role_capability_row <- function(label, detail, enabled = FALSE) {
  div(
    class = paste("role-capability-row", if (enabled) "enabled" else "disabled"),
    span(class = paste("snapshot-check-icon", if (enabled) "complete" else "missing"), `aria-hidden` = "true"),
    div(strong(label), span(detail))
  )
}

role_preview_panel <- function(db, app_roles, agency_roles, selected_user_id = "", selected_agency = "", id_prefix = "", agency_input_id = "role_preview_selected_agency", compact = FALSE) {
  app_role <- app_roles[[1]]
  agency_roles <- unique(as.character(agency_roles))
  agency_roles <- agency_roles[agency_roles %in% agency_role_choices]
  agency_role_selected <- if (length(agency_roles)) agency_roles else "None"
  agency_role_label <- if (length(agency_roles)) paste(agency_roles, collapse = ", ") else "No agency title selected"
  user_choices <- role_preview_user_choices(db)
  if (!nzchar(selected_user_id) || !selected_user_id %in% unname(user_choices)) {
    selected_user_id <- default_role_preview_user_id(db)
  }
  agency_choices <- if (has_any_role(app_roles, c("SystemAdmin", "OPIReviewer"))) {
    agency_selector_choices(db)
  } else {
    user_submitter_choices(db, selected_user_id)
  }
  if (!length(agency_choices)) {
    agency_choices <- setNames(character(0), character(0))
    selected_agency <- ""
  } else if (!nzchar(selected_agency) || !selected_agency %in% unname(agency_choices)) {
    selected_agency <- unname(agency_choices)[[1]]
  }
  user_input_id <- paste0(id_prefix, "role_preview_user_id")
  app_role_input_id <- paste0(id_prefix, "role_preview_app_role")
  agency_role_input_id <- paste0(id_prefix, "role_preview_agency_role")
  panel_class <- paste("role-preview-panel", if (isTRUE(compact)) "role-preview-panel-compact" else "")
  div(
    class = panel_class,
    div(
      class = "role-preview-selection-panel",
      div(class = "eyebrow", "Preview context"),
      div(
        class = "role-preview-controls",
        div(
          class = "measure-field role-preview-lookup",
          selectInput(
            user_input_id,
            "Preview by user",
            choices = user_choices,
            selected = selected_user_id,
            selectize = TRUE
          )
        ),
        div(
          class = "measure-field role-preview-lookup",
          selectInput(
            agency_input_id,
            "Agency, mayoral service, or quasi",
            choices = agency_choices,
            selected = selected_agency,
            selectize = TRUE,
            width = "100%"
          )
        ),
        div(
          class = "measure-field",
          selectInput(app_role_input_id, "Performance role", choices = performance_role_choices, selected = app_role, selectize = FALSE)
        ),
        div(
          class = "measure-field",
          selectInput(agency_role_input_id, "Agency role/title", choices = c("None", agency_role_choices), selected = agency_role_selected, multiple = TRUE, selectize = TRUE)
        )
      )
    ),
    div(
      class = "role-preview-summary",
      div(class = "eyebrow", "Selected access"),
      h3(paste(app_role, "|", agency_role_label)),
      p("This preview uses the selected agency/entity plus the role combination here.")
    ),
    div(
      class = "role-capability-grid",
      role_capability_row("Plan submission", "Submit the current performance plan.", can_submit_plans(app_roles)),
      role_capability_row("Measure submission", "Submit new or edited measures for approval.", can_submit_measures(app_roles, agency_roles)),
      role_capability_row("Measure review", "Approve/validate or return measures with feedback.", can_review_measures(app_roles)),
      role_capability_row("Performance reviewing", "Open plan/measure review workspaces.", can_view_performance_reviewing(app_roles)),
      role_capability_row("Team role editing", "Add users and edit team role assignments.", can_edit_roles(app_roles, agency_roles)),
      role_capability_row("Assign submitters", "Grant AgencySubmitter access to another user.", can_assign_submitter(app_roles, agency_roles)),
      role_capability_row("Admin measure fields", "Edit citywide scope and Action Plan measure alignment.", can_review_measures(app_roles)),
      role_capability_row("Final plan approval", "Finalize approval and move payload data into database records.", can_finalize_plans(app_roles)),
      role_capability_row("Downloads", "Download plan exports and review materials.", TRUE),
      role_capability_row("Review notes", "View reviewer scores, returned notes, and feedback.", TRUE)
    )
  )
}

role_preview_user_choices <- function(db) {
  user_rows <- rbind(
    db$access_user_agency_access[, intersect(c("user_id", "full_name", "email"), names(db$access_user_agency_access)), drop = FALSE],
    db$access_user_role[, intersect(c("user_id", "full_name", "email"), names(db$access_user_role)), drop = FALSE]
  )
  if (!nrow(user_rows)) {
    return(c("Choose a user" = ""))
  }
  user_rows <- user_rows[!is.na(user_rows$user_id), , drop = FALSE]
  user_rows <- user_rows[!duplicated(user_rows$user_id), , drop = FALSE]
  user_rows <- user_rows[order(tolower(user_rows$full_name), tolower(user_rows$email)), , drop = FALSE]
  emails <- ifelse(is.na(user_rows$email), "", as.character(user_rows$email))
  names <- ifelse(is.na(user_rows$full_name), emails, as.character(user_rows$full_name))
  labels <- ifelse(
    nzchar(trimws(emails)),
    paste0(names, " - ", emails),
    names
  )
  c("Choose a user" = "", stats::setNames(as.character(user_rows$user_id), labels))
}

matched_user_role_defaults <- function(db, user_id) {
  agency_rows <- db$access_user_agency_access
  role_rows <- db$access_user_role
  matched_roles <- role_rows[as.character(role_rows$user_id) == as.character(user_id), , drop = FALSE]
  matched_agency_roles <- agency_rows[as.character(agency_rows$user_id) == as.character(user_id), , drop = FALSE]

  app_role <- if (nrow(matched_roles) && matched_roles$app_role[[1]] %in% performance_role_choices) {
    matched_roles$app_role[[1]]
  } else {
    "AgencyViewer"
  }
  agency_role <- if (nrow(matched_agency_roles) && matched_agency_roles$agency_role[[1]] %in% agency_role_choices) {
    matched_agency_roles$agency_role[[1]]
  } else {
    "None"
  }
  agency_roles <- if (nrow(matched_agency_roles)) {
    unique(unlist(lapply(seq_len(nrow(matched_agency_roles)), function(i) {
      split_stored_roles(if ("agency_roles" %in% names(matched_agency_roles)) matched_agency_roles$agency_roles[[i]] else matched_agency_roles$agency_role[[i]])
    }), use.names = FALSE))
  } else {
    character(0)
  }
  agency_roles <- agency_roles[agency_roles %in% agency_role_choices]
  if (!length(agency_roles) && !identical(agency_role, "None")) agency_roles <- agency_role
  list(app_role = app_role, agency_role = agency_role, agency_roles = agency_roles)
}

matched_user_submitter_value <- function(db, user_id) {
  choices <- user_submitter_choices(db, user_id)
  if (length(choices)) unname(choices)[[1]] else NULL
}

plan_reviewer_choices <- function(db) {
  reviewer_role_ids <- if ("access_user_role" %in% names(db) && nrow(db$access_user_role)) {
    db$access_user_role$user_id[db$access_user_role$app_role %in% c("SystemAdmin", "OPIReviewer")]
  } else {
    integer(0)
  }
  assigned_ids <- c(
    if ("planning_agency_plan" %in% names(db) && nrow(db$planning_agency_plan)) db$planning_agency_plan$assigned_reviewer else integer(0),
    if ("review_plan_review" %in% names(db) && nrow(db$review_plan_review)) db$review_plan_review$reviewer_id else integer(0)
  )
  reviewer_ids <- unique(c(reviewer_role_ids, assigned_ids))
  reviewer_ids <- reviewer_ids[!is.na(reviewer_ids)]
  if (!length(reviewer_ids)) return(c("Choose a reviewer" = ""))

  user_rows <- if ("access_user" %in% names(db) && nrow(db$access_user)) {
    db$access_user[db$access_user$user_id %in% reviewer_ids, , drop = FALSE]
  } else {
    unique(rbind(
      db$access_user_role[db$access_user_role$user_id %in% reviewer_ids, intersect(c("user_id", "full_name", "email"), names(db$access_user_role)), drop = FALSE],
      db$access_user_agency_access[db$access_user_agency_access$user_id %in% reviewer_ids, intersect(c("user_id", "full_name", "email"), names(db$access_user_agency_access)), drop = FALSE]
    ))
  }
  user_rows <- user_rows[!is.na(user_rows$user_id), , drop = FALSE]
  user_rows <- user_rows[!duplicated(user_rows$user_id), , drop = FALSE]
  user_rows <- user_rows[order(tolower(user_rows$full_name), tolower(user_rows$email)), , drop = FALSE]
  labels <- ifelse(
    !is.na(user_rows$email) & nzchar(trimws(user_rows$email)),
    paste0(user_rows$full_name, " - ", user_rows$email),
    user_rows$full_name
  )
  c("Choose a reviewer" = "", stats::setNames(as.character(user_rows$user_id), labels))
}

default_role_preview_user_id <- function(db) {
  user_rows <- rbind(
    db$access_user_agency_access[, intersect(c("user_id", "full_name", "email"), names(db$access_user_agency_access)), drop = FALSE],
    db$access_user_role[, intersect(c("user_id", "full_name", "email"), names(db$access_user_role)), drop = FALSE]
  )
  if (!nrow(user_rows) || !"email" %in% names(user_rows)) return("")
  matches <- user_rows[!is.na(user_rows$email) & tolower(user_rows$email) == "melanie.lada@baltimorecity.gov", , drop = FALSE]
  if (!nrow(matches)) return("")
  as.character(matches$user_id[[1]])
}

user_email_for_id <- function(db, user_id) {
  user_id <- suppressWarnings(as.integer(user_id %||% NA_integer_))
  if (is.na(user_id)) return("")
  user_rows <- rbind(
    db$access_user[, intersect(c("user_id", "email"), names(db$access_user)), drop = FALSE],
    db$access_user_role[, intersect(c("user_id", "email"), names(db$access_user_role)), drop = FALSE],
    db$access_user_agency_access[, intersect(c("user_id", "email"), names(db$access_user_agency_access)), drop = FALSE],
    db$access_user_entity_access[, intersect(c("user_id", "email"), names(db$access_user_entity_access)), drop = FALSE]
  )
  if (!nrow(user_rows) || !"email" %in% names(user_rows)) return("")
  matches <- user_rows[user_rows$user_id == user_id & !is.na(user_rows$email), , drop = FALSE]
  if (!nrow(matches)) return("")
  tolower(trimws(as.character(matches$email[[1]])))
}

can_manage_opi_approval_stamp <- function(db, user_id) {
  user_email_for_id(db, user_id) %in% c(
    "melanie.lada@baltimorecity.gov",
    "danny.heller@baltimorecity.gov"
  )
}

nonblank_text <- function(value) {
  !is.null(value) && length(value) > 0 && !is.na(value) && nzchar(trimws(as.character(value)))
}

goal_draft_readiness <- function(db, plan, goals) {
  if (is.null(plan) || !nrow(plan)) {
    return(list(complete_count = 0L, aligned_count = 0L))
  }
  goals_draft <- if (plan_uses_draft_payload(plan)) section_draft_payload(db, plan$plan_id[[1]], "goals") else NULL

  # A goal only becomes a performance.agency_goal row once the plan is
  # Approved (apply_plan_drafts_to_records() promotes the draft at that
  # point) -- for every plan still Draft/Submitted/UnderReview/Returned,
  # goals live only in the draft payload's goalIds list. Iterating just the
  # published rows meant this always reported 0 complete goals for any
  # agency still drafting, no matter how much they'd actually written.
  draft_goal_ids <- if (!is.null(goals_draft) && !is.null(goals_draft$goalIds)) as.character(unlist(goals_draft$goalIds)) else character(0)
  published_goal_ids <- if (nrow(goals)) as.character(goals$agency_goal_id) else character(0)
  goal_ids <- union(published_goal_ids, draft_goal_ids)

  complete <- 0L
  aligned <- 0L
  for (goal_id in goal_ids) {
    published_row <- goals[as.character(goals$agency_goal_id) == goal_id, , drop = FALSE]
    fallback_title <- if (nrow(published_row)) published_row$title[[1]] else ""
    statement <- draft_value(goals_draft, paste0("goal_statement_", goal_id), fallback_title)
    initiative_values <- if (!is.null(goals_draft) && !is.null(goals_draft$initiatives[[goal_id]])) {
      as.character(unlist(goals_draft$initiatives[[goal_id]]))
    } else if (nrow(published_row)) {
      initiative_links <- db$performance_agency_goal_initiative_link[db$performance_agency_goal_initiative_link$agency_goal_id == published_row$agency_goal_id[[1]], , drop = FALSE]
      db$performance_initiative$title[match(initiative_links$initiative_id, db$performance_initiative$initiative_id)]
    } else {
      character(0)
    }
    kpi_values <- if (!is.null(goals_draft) && !is.null(goals_draft$kpis[[goal_id]])) {
      as.character(unlist(goals_draft$kpis[[goal_id]]))
    } else if (nrow(published_row)) {
      measure_links <- db$performance_pm_goal_link[db$performance_pm_goal_link$agency_goal_id == published_row$agency_goal_id[[1]], , drop = FALSE]
      as.character(measure_links$measure_id)
    } else {
      character(0)
    }
    fallback_alignment <- if (nrow(published_row) && "alignment_code" %in% names(published_row) && !is.na(published_row$alignment_code[[1]])) published_row$alignment_code[[1]] else ""
    alignment <- draft_value(goals_draft, paste0("goal_alignment_", goal_id), fallback_alignment)
    has_initiative <- any(nzchar(trimws(initiative_values[!is.na(initiative_values)])))
    has_kpi <- any(nzchar(trimws(kpi_values[!is.na(kpi_values)])))
    if (nonblank_text(statement) && has_initiative && has_kpi) complete <- complete + 1L
    if (nonblank_text(alignment)) aligned <- aligned + 1L
  }
  list(complete_count = complete, aligned_count = aligned)
}

# Reported 2026-08-05: a reviewer's score/notes entered under a goal
# ("Grow the capacity of our local Minority Business Enterprise and Women
# Business Enterprise...") silently never saved, even though the autosave
# indicator said it had. A goal only gets a real, positive agency_goal_id
# once its plan is Approved (see goal_draft_readiness()'s comment above) --
# a plan still under active review (Submitted/UnderReview/etc., which is
# exactly when reviewers are scoring it) has its goals living only in the
# draft payload, with string ids like "draft-1784904475724".
# review.section_score.target_id is a real integer column, so a draft-only
# goal needs a synthetic placeholder -- this assigns one by position
# (-1, -2, ...) among the plan's current goal list. Must be computed
# IDENTICALLY wherever a goal's review controls are rendered
# (history_plan_modal()) and wherever they're collected for saving
# (collect_plan_review_scores()), or a score/note entered under one goal
# silently attributes to a different one. The previous code
# (`suppressWarnings(as.integer(goal_id)) %||% -i`) intended exactly this
# fallback, but never actually triggered it: base R's own `%||%` (R 4.4+)
# only substitutes on NULL, not NA, so every draft-only goal's target_id
# silently stayed NA -- which review_input_id() treats as "plan"-level,
# collapsing every draft goal's score/notes controls onto the same widget
# IDs. Separately, collect_plan_review_scores() only ever iterated the
# live performance.agency_goal table, so for a plan with zero live goal
# rows (any plan not yet Approved) it never attempted to save ANY
# goal-level score/note at all, regardless of the ID collision above.
plan_review_goal_target_ids <- function(db, plan, goals) {
  if (is.null(plan) || !nrow(plan)) return(data.frame(goal_id = character(0), target_id = integer(0), stringsAsFactors = FALSE))
  goals_draft <- if (plan_uses_draft_payload(plan)) section_draft_payload(db, plan$plan_id[[1]], "goals") else NULL
  goal_ids <- if (!is.null(goals_draft) && !is.null(goals_draft$goalIds)) {
    as.character(unlist(goals_draft$goalIds))
  } else if (!is.null(goals) && nrow(goals)) {
    as.character(goals$agency_goal_id)
  } else {
    character(0)
  }
  goal_ids <- goal_ids[nzchar(goal_ids)]
  target_ids <- vapply(seq_along(goal_ids), function(i) {
    numeric_id <- suppressWarnings(as.integer(goal_ids[[i]]))
    if (is.na(numeric_id)) -i else numeric_id
  }, integer(1))
  data.frame(goal_id = goal_ids, target_id = target_ids, stringsAsFactors = FALSE)
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

performance_reviewing_nav_items <- function(approval_first = FALSE) {
  measure_review <- nav_item("measure_review", "Measure review", icon("chart-line"), item_class = "performance-reviewing-nav-item measure-review-nav-item")
  action_plan_measures <- nav_item("action_plan_measures", "Action Plan Measures", icon("bullseye"), item_class = "performance-reviewing-nav-item action-plan-measures-nav-item")
  plan_review <- nav_item("reviewer_dashboard", "Plan review", icon("clipboard-check"), item_class = "performance-reviewing-nav-item")
  approval_queue <- nav_item("approval_queue", "Plan approval queue", icon("stamp"), item_class = "performance-reviewing-nav-item approval-queue-nav-item")
  publishing_queue <- nav_item("publishing_queue", "Publishing queue", icon("upload"), item_class = "performance-reviewing-nav-item publishing-nav-item")
  if (isTRUE(approval_first)) {
    tagList(measure_review, action_plan_measures, approval_queue, plan_review, publishing_queue)
  } else {
    tagList(measure_review, action_plan_measures, plan_review, approval_queue, publishing_queue)
  }
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
  format_type <- metric$format_type %||% "Count"
  # format_measure_value() checks is.na(display_unit) to detect "no unit",
  # but metric$unit is NULL (not NA) when absent -- is.na(NULL) is
  # logical(0), which throws in an `if`, so coalesce it to NA first.
  metric_unit <- metric$unit %||% NA_character_
  label_for <- function(value) format_measure_value(value, format_type, metric_unit, "Not set")
  current_value <- if (is.null(metric$current) || length(metric$current) == 0) NA_real_ else metric$current
  target_value <- if (is.null(metric$target) || length(metric$target) == 0) NA_real_ else metric$target
  max_value <- suppressWarnings(max(current_value, target_value, na.rm = TRUE))
  if (!is.finite(max_value) || max_value == 0) max_value <- 1
  current_width <- if (is.na(current_value)) 0 else max(3, round(current_value / max_value * 100))
  target_position <- if (is.na(target_value)) 0 else min(100, max(3, round(target_value / max_value * 100)))
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
        `aria-label` = paste("Current", label_for(current_value), "target", label_for(target_value)),
        if (!is.na(current_value)) div(class = "metric-bar current", style = paste0("width: ", current_width, "%;")),
        if (!is.na(target_value)) div(class = "target-marker", style = paste0("left: ", target_position, "%;"))
      ),
      if (!is.na(current_value)) span(class = "metric-bar-value current-value", style = paste0("left: ", current_label_position, "%;"), label_for(current_value)),
      if (!is.na(target_value)) span(class = "metric-bar-value target-value", style = paste0("left: ", target_label_position, "%;"), label_for(target_value))
    )
  )
}

# Renders one Citywide measure in a pillar's "Performance Measures"
# section: a current-vs-target bar chart (metric_visual()) once it has at
# least one recorded value, otherwise a plain placeholder -- a measure can
# be marked Citywide and linked to a pillar before any actual/target for
# the current snapshot years has been entered.
action_plan_measure_item <- function(metric) {
  has_data <- !is.na(metric$current) || !is.na(metric$target)
  if (has_data) return(metric_visual(metric))
  div(
    class = "action-plan-measure-item",
    div(
      tags$strong(metric$name),
      if (!is.null(metric$direction) && !is.na(metric$direction) && nzchar(trimws(metric$direction))) {
        span(class = "measure-direction-note", metric$direction)
      }
    ),
    status_chip("Awaiting data", "warning")
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
          p("Citywide measures assigned to this pillar, with the most recently reported actual and current target."),
          if (length(pillar$metrics)) {
            div(class = "action-plan-measure-list", lapply(pillar$metrics, action_plan_measure_item))
          } else {
            p(class = "action-plan-measure-empty", "No measures are marked Citywide for this pillar yet.")
          }
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

login_notice <- function(notice, tone = "warning") {
  if (is.null(notice)) return(NULL)
  div(class = "chip-row login-notice", status_chip(notice, tone))
}

login_notice_from_state <- function(state, default_tone = "warning") {
  login_notice(state$notice, state$notice_tone %||% default_tone)
}

login_view_login <- function(state) {
  tagList(
    h1("Sign in to continue"),
    p("Sign in with your work email. Accounts are provisioned by the performance team; use “First time here” below to set your password."),
    login_notice_from_state(state),
    div(
      class = "login-email-panel",
      div(
        class = "measure-field login-email-field",
        textInput("login_email", "Email address", placeholder = "name@baltimorecity.gov")
      ),
      div(class = "measure-field login-password-field", passwordInput("login_password", "Password")),
      actionButton("login_email_continue", "Sign in", class = "civic-button primary")
    ),
    div(
      class = "login-links",
      actionLink("goto_first_time", "First time here? Set your password"),
      actionLink("goto_forgot", "Forgot your password?")
    )
  )
}

login_view_request <- function(state) {
  first_time <- isTRUE(state$first_time)
  tagList(
    h1(if (first_time) "Set your password" else "Reset your password"),
    p(paste(
      "Enter the work email your account was provisioned with.",
      "We will send a one-time link for choosing", if (first_time) "your password." else "a new password."
    )),
    login_notice_from_state(state),
    div(
      class = "measure-field login-email-field",
      textInput("request_email", "Work email", placeholder = "name@baltimorecity.gov")
    ),
    actionButton("request_submit", "Send me a link", class = "civic-button primary"),
    div(class = "login-links", actionLink("goto_login", "Back to sign in"))
  )
}

login_entity_request_choices <- function(db) {
  entity_table <- if (!is.null(db) && "reference_access_entity" %in% names(db)) {
    db$reference_access_entity
  } else if (!is.null(db) && "reference_plan_entity" %in% names(db)) {
    db$reference_plan_entity
  } else {
    data.frame()
  }
  if (!nrow(entity_table)) {
    return(c("Not sure" = ""))
  }
  rows <- entity_table
  rows <- rows[order(tolower(rows$public_name)), , drop = FALSE]
  c("Not sure" = "", stats::setNames(rows$public_name, rows$public_name))
}

login_view_access_request <- function(state, db = NULL) {
  email <- trimws(as.character(state$email %||% ""))
  tagList(
    h1("Request Beacon access"),
    p("That email is not connected to an active Beacon account. Tell us which entity and role you need so Melanie can review the request."),
    login_notice_from_state(state),
    div(
      class = "login-access-request-grid",
      div(
        class = "measure-field",
        textInput("access_request_email", "Email address", value = email, placeholder = "name@baltimorecity.gov")
      ),
      div(
        class = "measure-field",
        selectInput("access_request_entity", "Agency, mayoral service, or quasi", choices = login_entity_request_choices(db), selected = state$requested_entity %||% "")
      ),
      div(
        class = "measure-field",
        selectInput("access_request_agency_role", "Agency role/title", choices = c("Not sure" = "", agency_role_choices), selected = state$requested_agency_role %||% "")
      )
    ),
    div(
      class = "login-access-request-actions",
      actionButton("access_request_submit", "Send access request", class = "civic-button primary")
    ),
    div(class = "login-links", actionLink("goto_login", "Back to sign in"))
  )
}

login_view_sent <- function(state) {
  tagList(
    h1("Check your email"),
    p("If that address is registered, a password link is on its way. It expires in 60 minutes."),
    if (!is.null(state$dev_link)) div(
      class = "login-dev-link",
      login_notice("Local demo mode (AUTH_DEV_LINKS): the link is shown here instead of being emailed.", "warning"),
      tags$a(href = state$dev_link, state$dev_link)
    ),
    div(class = "login-links", actionLink("goto_login", "Back to sign in"))
  )
}

login_view_reset <- function(state) {
  tagList(
    h1("Choose a new password"),
    p("Passwords must be at least 10 characters."),
    login_notice(state$notice),
    div(
      class = "measure-field login-email-field",
      passwordInput("reset_password", "New password"),
      passwordInput("reset_confirm", "Confirm new password")
    ),
    actionButton("reset_submit", "Save password", class = "civic-button primary")
  )
}

login_view_reset_done <- function(state) {
  tagList(
    h1("Password saved"),
    p("Your password is set. Sign in with your work email to continue."),
    div(class = "login-links", actionLink("goto_login", "Go to sign in"))
  )
}

page_login <- function(state = list(view = "login"), db = NULL) {
  view <- if (is.null(state$view)) "login" else state$view
  body <- switch(
    view,
    request = login_view_request(state),
    access_request = login_view_access_request(state, db),
    sent = login_view_sent(state),
    reset = login_view_reset(state),
    reset_done = login_view_reset_done(state),
    login_view_login(state)
  )
  div(
    class = "login-page",
    div(
      class = "login-panel",
      div(
        class = "brand-lockup brand-large",
        tags$img(class = "brand-mark", src = "baltimore-city-logo.png", alt = "City of Baltimore logo"),
        div(
          div(class = "brand-product", "Beacon"),
          div(class = "brand-subtitle", "Baltimore City Performance & Budgeting")
        )
      ),
      body
    )
  )
}

reviewer_assignment_key <- function(value) {
  value <- as.character(value)
  value[is.na(value)] <- ""
  value <- tolower(trimws(value))
  gsub("[^a-z0-9]+", "", value)
}

# reviewer_assignments.csv used to be consulted here too, as a name-matched
# fallback for plans with no assigned_reviewer -- removed once
# scripts/backfill_assigned_reviewer_from_csv.R backfilled the proper
# ID-keyed planning.agency_plan.assigned_reviewer column for every plan the
# CSV covered (2026-07-23). entity_assignments (workflow.entity_role_assignment)
# remains as its own, separate, table-backed fallback for entity-scoped plans.
apply_reviewer_assignments <- function(db, joined) {
  entity_assignments <- entity_role_assignment_rows(db)
  joined$assignment_reviewer_name <- NA_character_
  joined$assignment_agency_type <- NA_character_
  if (!nrow(joined) || !"submitter_name" %in% names(joined)) {
    return(joined)
  }
  if (nrow(entity_assignments)) {
    plan_keys <- reviewer_assignment_key(joined$submitter_name)
    entity_keys <- reviewer_assignment_key(entity_assignments$public_name)
    entity_match <- match(plan_keys, entity_keys)
    matched <- !is.na(entity_match)
    joined$assignment_reviewer_name[matched] <- entity_assignments$reviewer[entity_match[matched]]
    joined$assignment_agency_type[matched] <- entity_assignments$entity_type[entity_match[matched]]
  }
  joined
}

plan_action_pillar_names <- function(db, plan_id) {
  plan_services <- db$performance_plan_service[db$performance_plan_service$plan_id == plan_id, , drop = FALSE]
  service_pillar_ids <- integer(0)
  if (nrow(plan_services)) {
    services <- db$reference_service[db$reference_service$service_id %in% plan_services$service_id, , drop = FALSE]
    service_pillar_ids <- services$pillar_id[!is.na(services$pillar_id)]
  }
  goals <- db$performance_agency_goal[db$performance_agency_goal$plan_id == plan_id, , drop = FALSE]
  goal_pillar_ids <- integer(0)
  if (nrow(goals) && "alignment_code" %in% names(goals)) {
    aligned_goals <- db$reference_pillar_goal[db$reference_pillar_goal$goal_code %in% goals$alignment_code, , drop = FALSE]
    goal_pillar_ids <- aligned_goals$pillar_id[!is.na(aligned_goals$pillar_id)]
  }
  pillar_ids <- unique(c(service_pillar_ids, goal_pillar_ids))
  pillars <- db$reference_pillar[db$reference_pillar$pillar_id %in% pillar_ids, , drop = FALSE]
  if (!nrow(pillars)) return(character(0))
  pillars <- pillars[order(pillars$sort_order), , drop = FALSE]
  pillars$pillar_name
}

plan_review_joined_rows <- function(db) {
  plans <- db$planning_agency_plan
  plans <- plans[order(plans$fiscal_year, plans$updated_at, decreasing = TRUE), , drop = FALSE]
  agency_lookup <- db$reference_agency[, c("agency_id", "agency_name", "deputy_mayor_pillar"), drop = FALSE]
  reviewer_lookup <- unique(db$review_plan_review[, c("plan_id", "reviewer_name", "overall_score", "review_complete"), drop = FALSE])
  joined <- merge(plans, agency_lookup, by = "agency_id", all.x = TRUE)
  joined <- merge(joined, reviewer_lookup, by = "plan_id", all.x = TRUE)
  joined$submitter_name <- vapply(seq_len(nrow(joined)), function(i) plan_display_name(db, joined[i, , drop = FALSE]), character(1))
  joined <- apply_reviewer_assignments(db, joined)
  joined$reviewer_display <- ifelse(
    !is.na(joined$reviewer_name) & nzchar(joined$reviewer_name),
    joined$reviewer_name,
    ifelse(
      !is.na(joined$assigned_reviewer_name) & nzchar(joined$assigned_reviewer_name),
      joined$assigned_reviewer_name,
      joined$assignment_reviewer_name
    )
  )
  joined$reviewer_display[is.na(joined$reviewer_display) | !nzchar(joined$reviewer_display)] <- "Unassigned"
  joined$status_label <- vapply(joined$plan_status, agency_plan_status, character(1))
  pillar_name_sets <- lapply(joined$plan_id, function(plan_id) plan_action_pillar_names(db, plan_id))
  joined$action_pillar_label <- vapply(pillar_name_sets, function(names) if (length(names)) paste(names, collapse = ", ") else "No pillar scope assigned", character(1))
  joined$ca_office_display <- vapply(seq_len(nrow(joined)), function(i) plan_ca_office_label(db, joined[i, , drop = FALSE]), character(1))
  joined$search_blob <- paste(joined$submitter_name, joined$agency_name, joined$action_pillar_label, joined$plan_status, joined$reviewer_display, joined$ca_office_display)
  joined
}

filter_review_rows_for_user <- function(db, rows, app_roles, user_id = NA_integer_) {
  if (!nrow(rows)) return(rows)
  portfolio_approver <- user_is_portfolio_approver(db, user_id)
  if ((!has_any_role(app_roles, "DeputyMayor") && !portfolio_approver) || has_any_role(app_roles, c("SystemAdmin", "OPIReviewer", "BBMRReviewer", "CAOffice"))) {
    return(rows)
  }
  user_id <- suppressWarnings(as.integer(user_id))
  role_rows <- db$access_user_role[
    !is.na(user_id) &
      db$access_user_role$user_id == user_id &
      db$access_user_role$app_role == "DeputyMayor",
    ,
    drop = FALSE
  ]
  agency_ids <- unique(role_rows$agency_id[!is.na(role_rows$agency_id) & nzchar(as.character(role_rows$agency_id))])
  if (length(agency_ids)) {
    return(rows[rows$agency_id %in% agency_ids, , drop = FALSE])
  }
  pillar_ids <- unique(role_rows$pillar_id[!is.na(role_rows$pillar_id)])
  if (length(pillar_ids) && "deputy_mayor_pillar" %in% names(rows)) {
    pillar_names <- db$reference_pillar$pillar_name[db$reference_pillar$pillar_id %in% pillar_ids]
    return(rows[rows$action_pillar_label %in% pillar_names, , drop = FALSE])
  }
  if (portfolio_approver && "deputy_mayor_pillar" %in% names(rows)) {
    portfolio_matches <- vapply(seq_len(nrow(rows)), function(i) {
      user_name_matches_text(db, user_id, plan_deputy_mayor_label(db, rows[i, , drop = FALSE]))
    }, logical(1))
    return(rows[portfolio_matches, , drop = FALSE])
  }
  rows[0, , drop = FALSE]
}

user_name_matches_text <- function(db, user_id, text) {
  user_id <- suppressWarnings(as.integer(user_id))
  if (is.na(user_id) || is.na(text) || !nzchar(trimws(as.character(text)))) return(FALSE)
  users <- db$access_user[db$access_user$user_id == user_id, , drop = FALSE]
  if (!nrow(users)) return(FALSE)
  name_parts <- unlist(strsplit(tolower(users$full_name[[1]]), "\\s+"))
  name_parts <- name_parts[nzchar(name_parts)]
  if (!length(name_parts)) return(FALSE)
  text_key <- tolower(as.character(text))
  all(vapply(name_parts[c(1, length(name_parts))], function(part) grepl(part, text_key, fixed = TRUE), logical(1)))
}

user_name_matches_portfolio <- function(db, user_id, portfolio) {
  user_name_matches_text(db, user_id, portfolio)
}

user_is_portfolio_approver <- function(db, user_id) {
  user_id <- suppressWarnings(as.integer(user_id))
  if (is.na(user_id)) return(FALSE)
  assignments <- entity_role_assignment_rows(db)
  assignment_match <- nrow(assignments) &&
    any(vapply(assignments$deputy_mayor, function(approver) user_name_matches_text(db, user_id, approver), logical(1)), na.rm = TRUE)
  reference_match <- "deputy_mayor_pillar" %in% names(db$reference_agency) &&
    any(vapply(db$reference_agency$deputy_mayor_pillar, function(portfolio) user_name_matches_portfolio(db, user_id, portfolio), logical(1)), na.rm = TRUE)
  assignment_match || reference_match
}

can_view_plan_approval_queue_context <- function(db, app_roles, user_id = NA_integer_) {
  can_view_plan_approval_queue(app_roles) || user_is_portfolio_approver(db, user_id)
}

can_approve_plan_gate_context <- function(db, plan, app_roles, user_id = NA_integer_) {
  if (is.null(plan) || !nrow(plan)) return(FALSE)
  status <- as.character(plan$plan_status[[1]])
  if (identical(status, "CAReview")) {
    if (
      has_any_role(app_roles, "DeputyMayor") &&
        user_name_matches_text(db, user_id, plan_deputy_mayor_label(db, plan)) &&
        plan_has_approval_stamp(db, plan$plan_id[[1]], "DeputyMayor")
    ) {
      return(TRUE)
    }
    return(has_any_role(app_roles, "CAOffice") && user_name_matches_text(db, user_id, plan_ca_office_label(db, plan)))
  }
  if (identical(status, "DeputyMayorReview")) {
    return((has_any_role(app_roles, "DeputyMayor") || has_any_role(app_roles, "CAOffice")) && user_name_matches_text(db, user_id, plan_deputy_mayor_label(db, plan)))
  }
  FALSE
}

can_manage_plan_stamp_context <- function(db, plan, stage, app_roles, user_id = NA_integer_) {
  stage <- as.character(stage)
  if (identical(stage, "OPIApproval")) return(can_manage_opi_approval_stamp(db, user_id))
  if (has_any_role(app_roles, "SystemAdmin")) return(TRUE)
  if (identical(stage, "Reviewer")) return(has_any_role(app_roles, c("OPIReviewer", "BBMRReviewer")))
  if (identical(stage, "DeputyMayor")) {
    return((has_any_role(app_roles, "DeputyMayor") || has_any_role(app_roles, "CAOffice")) && user_name_matches_text(db, user_id, plan_deputy_mayor_label(db, plan)))
  }
  if (identical(stage, "CAOffice")) return(has_any_role(app_roles, "CAOffice") && user_name_matches_text(db, user_id, plan_ca_office_label(db, plan)))
  FALSE
}

page_reviewer_dashboard <- function(db, can_view_publish_queue = FALSE, app_roles = character(0), user_id = NA_integer_) {
  joined <- filter_review_rows_for_user(db, plan_review_joined_rows(db), app_roles, user_id)
  publishing_rows <- joined[joined$plan_status == "Approved", , drop = FALSE]
  review_rows <- if (isTRUE(can_view_publish_queue)) {
    joined[!joined$plan_status %in% c("Approved", "Published", "Amended"), , drop = FALSE]
  } else {
    joined
  }
  status_choices <- sort(unique(review_rows$status_label))
  reviewer_choices <- sort(unique(review_rows$reviewer_display[!is.na(review_rows$reviewer_display) & nzchar(review_rows$reviewer_display)]))
  tagList(
    div(
      class = "briefing-header compact",
      div(
        div(class = "eyebrow", "Reviewer front end"),
        h1("Plan Review"),
        p("Review plan submissions across agencies, monitor returned plans, and prepare rubric-based feedback.")
      ),
      status_chip("Plan review", "primary")
    ),
    div(
      class = "dashboard-grid reviewer-dashboard-grid",
      metric_tile("Plans in queue", sum(joined$plan_status %in% c("Submitted", "UnderReview", "DirectorSignOff", "DeputyMayorReview", "CAReview"), na.rm = TRUE), "Submitted or under review"),
      metric_tile("Returned", sum(joined$plan_status %in% c("FeedbackReturned", "Returned"), na.rm = TRUE), "Needs agency action", "warning"),
      metric_tile("Approved or published", sum(joined$plan_status %in% c("Approved", "Published", "Amended"), na.rm = TRUE), "Completed review")
    ),
    surface(
      "Review Queue",
      "Search and filter plan records by status and assigned reviewer.",
      div(
        class = "reviewer-filter-bar",
        div(class = "measure-field", tags$label(`for` = "reviewer_plan_search", "Search"), tags$input(id = "reviewer_plan_search", class = "form-control", type = "search", placeholder = "Agency, pillar, status, reviewer")),
        div(class = "measure-field", tags$label(`for` = "reviewer_status_filter", "Status"), tags$select(id = "reviewer_status_filter", class = "form-control", c(tags$option(value = "", "All statuses"), lapply(status_choices, function(choice) tags$option(value = choice, choice))))),
        div(class = "measure-field", tags$label(`for` = "reviewer_assignee_filter", "Assigned reviewer"), tags$select(id = "reviewer_assignee_filter", class = "form-control", c(tags$option(value = "", "All reviewers"), lapply(reviewer_choices, function(choice) tags$option(value = choice, choice))))),
        tags$button(type = "button", id = "clear_reviewer_filters", class = "civic-button secondary small reviewer-clear-filters", "Clear filters")
      ),
      div(
        class = "reviewer-plan-list",
        lapply(seq_len(nrow(review_rows)), function(i) {
          div(
            class = "reviewer-plan-row",
            `data-reviewer-search` = tolower(review_rows$search_blob[i]),
            `data-reviewer-status` = review_rows$status_label[i],
            `data-reviewer-assignee` = review_rows$reviewer_display[i],
            div(
              h3(review_rows$submitter_name[i]),
              p(review_rows$action_pillar_label[i])
            ),
            div(class = "chip-row", status_chip(agency_plan_status(review_rows$plan_status[i]), status_tone(review_rows$plan_status[i])), status_chip(paste("Version", review_rows$version[i]), "primary")),
            div(
              class = "reviewer-plan-meta",
              span("Reviewer"),
              strong(review_rows$reviewer_display[i])
            ),
            div(
              class = "reviewer-plan-meta",
              span("Score"),
              strong(if (!is.na(review_rows$overall_score[i])) score_out_of_100(review_rows$overall_score[i]) else "Not scored")
            ),
            div(
              class = "reviewer-plan-actions",
              tags$button(type = "button", class = "civic-button secondary small", `data-review-plan` = review_rows$plan_id[i], icon("clipboard-check"), "Open review"),
              tags$button(type = "button", class = "civic-button secondary small", `data-export-plan` = review_rows$plan_id[i], `data-export-type` = "pdf", `data-include-review` = "true", icon("file-pdf"), "Export PDF")
            )
          )
        })
      )
    )
  )
}

page_publishing_queue <- function(db) {
  joined <- plan_review_joined_rows(db)
  publishing_rows <- joined[joined$plan_status == "Approved", , drop = FALSE]
  tagList(
    div(
      class = "briefing-header compact",
      div(
        div(class = "eyebrow", "System Admin"),
        h1("Publishing Queue"),
        p("Review plans approved through the performance review workflow and ready for final publish.")
      ),
      status_chip(paste(nrow(publishing_rows), "ready"), "success")
    ),
    surface(
      "Ready to Publish",
      "Plans in this queue have been routed to ready for publish. Publishing is the final System Admin step that moves approved payload content into database records.",
      div(
        class = "reviewer-plan-list publishing-plan-list",
        if (!nrow(publishing_rows)) {
          p(class = "empty-state-copy", "No plans are ready for publish.")
        } else {
          lapply(seq_len(nrow(publishing_rows)), function(i) {
            div(
              class = "reviewer-plan-row publishing-plan-row",
              div(
                h3(publishing_rows$submitter_name[i]),
                p(publishing_rows$action_pillar_label[i])
              ),
              div(class = "chip-row", status_chip(agency_plan_status(publishing_rows$plan_status[i]), status_tone(publishing_rows$plan_status[i])), status_chip(paste("Version", publishing_rows$version[i]), "primary")),
              div(
                class = "reviewer-plan-meta",
                span("Deputy Mayor / portfolio"),
                strong(plan_deputy_mayor_label(db, publishing_rows[i, , drop = FALSE]))
              ),
              div(
                class = "reviewer-plan-meta",
                span("Score"),
                strong(if (!is.na(publishing_rows$overall_score[i])) score_out_of_100(publishing_rows$overall_score[i]) else "Not scored")
              ),
              tags$button(type = "button", class = "civic-button primary small", `data-review-plan` = publishing_rows$plan_id[i], icon("eye"), "Open")
            )
          })
        }
      )
    )
  )
}

page_plan_approval_queue <- function(db, app_roles = character(0), user_id = NA_integer_) {
  joined <- filter_review_rows_for_user(db, plan_review_joined_rows(db), app_roles, user_id)
  portfolio_approver <- user_is_portfolio_approver(db, user_id)
  if (has_any_role(app_roles, "SystemAdmin")) {
    approval_rows <- joined[joined$plan_status %in% c("DeputyMayorReview", "CAReview"), , drop = FALSE]
  } else if (has_any_role(app_roles, "CAOffice")) {
    ca_rows <- joined[joined$plan_status == "CAReview", , drop = FALSE]
    if (nrow(ca_rows)) {
      ca_matches <- vapply(seq_len(nrow(ca_rows)), function(i) {
        user_name_matches_text(db, user_id, plan_ca_office_label(db, ca_rows[i, , drop = FALSE]))
      }, logical(1))
      ca_rows <- ca_rows[ca_matches, , drop = FALSE]
    }
    deputy_rows <- joined[joined$plan_status == "DeputyMayorReview", , drop = FALSE]
    if (nrow(deputy_rows)) {
      portfolio_matches <- vapply(seq_len(nrow(deputy_rows)), function(i) {
        user_name_matches_text(db, user_id, plan_deputy_mayor_label(db, deputy_rows[i, , drop = FALSE]))
      }, logical(1))
      deputy_rows <- deputy_rows[portfolio_matches, , drop = FALSE]
    }
    approval_rows <- rbind(ca_rows, deputy_rows)
  } else if (has_any_role(app_roles, "DeputyMayor") || portfolio_approver) {
    approval_rows <- joined[joined$plan_status == "DeputyMayorReview", , drop = FALSE]
  } else {
    approval_rows <- joined[0, , drop = FALSE]
  }
  tagList(
    div(
      class = "briefing-header compact",
      div(
        div(class = "eyebrow", "Plan approval"),
        h1("Plan Approval Queue"),
        p("Review plans routed to Deputy Mayor or CA Office approval before final publishing.")
      ),
      status_chip(paste(nrow(approval_rows), "waiting"), "primary")
    ),
    surface(
      "Approval Queue",
      NULL,
      div(
        class = "reviewer-plan-list",
        if (!nrow(approval_rows)) {
          p(class = "empty-state-copy", "No plans are currently waiting for this approval step.")
        } else {
          lapply(seq_len(nrow(approval_rows)), function(i) {
            div(
              class = "reviewer-plan-row",
              div(
                h3(approval_rows$submitter_name[i]),
                p(approval_rows$action_pillar_label[i])
              ),
              div(class = "chip-row", status_chip(agency_plan_status(approval_rows$plan_status[i]), status_tone(approval_rows$plan_status[i])), status_chip(paste("Version", approval_rows$version[i]), "primary")),
              div(
                class = "reviewer-plan-meta",
                span("Deputy Mayor / portfolio"),
                strong(plan_deputy_mayor_label(db, approval_rows[i, , drop = FALSE]))
              ),
              div(
                class = "reviewer-plan-meta",
                span("Score"),
                strong(if (!is.na(approval_rows$overall_score[i])) score_out_of_100(approval_rows$overall_score[i]) else "Not scored")
              ),
              div(
                class = "reviewer-plan-actions",
                tags$button(type = "button", class = "civic-button primary small", `data-review-plan` = approval_rows$plan_id[i], icon("eye"), "Open"),
                tags$button(type = "button", class = "civic-button secondary small", `data-export-plan` = approval_rows$plan_id[i], `data-export-type` = "pdf", `data-include-review` = "true", icon("file-pdf"), "Export PDF")
              )
            )
          })
        }
      )
    )
  )
}

page_plan_review_detail <- function(db, plan_id, can_edit_review = FALSE, can_assign_reviewer = FALSE, include_review = TRUE, can_route_review = FALSE, can_approve_gate = FALSE, can_manage_deputy_stamp = FALSE, can_manage_ca_stamp = FALSE) {
  plan_id <- suppressWarnings(as.integer(plan_id))
  if (is.na(plan_id)) {
    return(tagList(
      div(
        class = "briefing-header compact",
        div(
          div(class = "eyebrow", "Plan review"),
          h1("Select a Plan"),
          p("Choose a plan from the review queue to open the full-page review workspace.")
        ),
        actionButton("back_to_review_queue", label = tagList(icon("arrow-left"), "Back to queue"), class = "civic-button secondary small")
      )
    ))
  }
  history_plan_modal(
    db,
    plan_id,
    can_edit_review = can_edit_review,
    can_assign_reviewer = can_assign_reviewer,
    include_review = include_review,
    full_page = TRUE,
    can_route_review = can_route_review,
    can_approve_gate = can_approve_gate,
    can_manage_deputy_stamp = can_manage_deputy_stamp,
    can_manage_ca_stamp = can_manage_ca_stamp
  )
}

measure_reviews_for <- function(db, measure_id) {
  if (!"review_measure_review" %in% names(db) || !nrow(db$review_measure_review)) return(data.frame())
  rows <- db$review_measure_review[db$review_measure_review$measure_id == measure_id, , drop = FALSE]
  if (!nrow(rows)) return(rows)
  rows[order(rows$reviewed_at, rows$measure_review_id, decreasing = TRUE), , drop = FALSE]
}

latest_measure_review <- function(db, measure_id) {
  measure_reviews_for(db, measure_id)[1, , drop = FALSE]
}

# One block per past review decision that actually left feedback, newest
# first -- a measure returned more than once used to only ever show the
# latest round's comment (latest_measure_review()'s [1,] slice), losing
# the context of what earlier rounds asked for. All of the underlying rows
# were already loaded into db$review_measure_review; this just stops
# throwing the older ones away before they reach the UI.
measure_review_history_blocks <- function(reviews) {
  if (!nrow(reviews)) return(NULL)
  has_feedback <- !is.na(reviews$feedback) & nzchar(trimws(reviews$feedback))
  reviews <- reviews[has_feedback, , drop = FALSE]
  if (!nrow(reviews)) return(NULL)
  lapply(seq_len(nrow(reviews)), function(i) {
    div(
      class = paste("measure-review-history-entry", if (i > 1) "measure-review-history-entry-past" else ""),
      div(
        class = "chip-row",
        status_chip(reviews$decision[i], if (identical(reviews$decision[i], "Approved")) "success" else "warning"),
        status_chip(if (is.na(reviews$reviewed_at[i])) "Review date unavailable" else as.character(reviews$reviewed_at[i]), "primary")
      ),
      p(reviews$feedback[i])
    )
  })
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
          tags$button(type = "button", class = "civic-button secondary", `data-measure-id` = measure$measure_id[[1]], icon("list-check"), "Review criteria"),
          tags$button(type = "button", class = "civic-button secondary", `data-measure-review-action` = "return", `data-measure-id` = measure$measure_id[[1]], icon("rotate-left"), "Return with feedback"),
          tags$button(type = "button", class = "civic-button primary", `data-measure-review-action` = "approve", `data-measure-id` = measure$measure_id[[1]], icon("check"), "Approve")
        )
      )
    }
  )
}

measure_validation_export_rows <- function(db) {
  measures <- db$performance_performance_measure
  agency_names <- vapply(measures$agency_id, function(id) agency_name(db, id), character(1))
  rows <- data.frame(
    measure_id = measures$measure_id,
    title = measures$title,
    agency_id = measures$agency_id,
    agency_name = agency_names,
    approval_status = measures$approval_status,
    validated = measures$validated,
    active = measures$active,
    submitted_for_approval_at = measures$submitted_for_approval_at,
    last_updated = measures$last_updated,
    stringsAsFactors = FALSE
  )
  rows[order(rows$agency_name, rows$title), ]
}

measure_data_export_rows <- function(db) {
  actuals <- db$performance_measure_actuals
  measures <- db$performance_performance_measure
  idx <- match(actuals$measure_id, measures$measure_id)
  agency_ids <- measures$agency_id[idx]
  agency_names <- vapply(agency_ids, function(id) agency_name(db, id), character(1))
  rows <- data.frame(
    measure_id = actuals$measure_id,
    title = measures$title[idx],
    agency_id = agency_ids,
    agency_name = agency_names,
    format_type = measures$format_type[idx],
    display_unit = measures$display_unit[idx],
    fiscal_year = actuals$fiscal_year,
    annual_actual = actuals$annual_actual,
    annual_actual_notes = actuals$annual_actual_notes,
    target_value = actuals$target_value,
    target_value_notes = actuals$target_value_notes,
    stringsAsFactors = FALSE
  )
  rows[order(rows$agency_name, rows$title, rows$fiscal_year), ]
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
      div(
        class = "measure-review-header-actions",
        downloadButton("download_measure_validation_csv", "Export Validation", class = "civic-button secondary small"),
        downloadButton("download_measure_data_csv", "Export Data", class = "civic-button secondary small"),
        status_chip("OPI / System Admin", "primary")
      )
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

feedback_category_choices <- c("Uncategorized", "Bug", "Feature")
feedback_priority_choices <- c("Unassigned", "Low", "Medium", "High", "Urgent")
feedback_status_choices <- c("New", "Open", "In Review", "Complete", "Archived")
default_feedback_status_filter <- c("New", "Open", "In Review")

feedback_system_admin_choices <- function(db) {
  if (!"access_user_role" %in% names(db) || !nrow(db$access_user_role)) return(c("Unassigned" = ""))
  admin_rows <- db$access_user_role[db$access_user_role$app_role == "SystemAdmin", , drop = FALSE]
  admin_rows <- admin_rows[!is.na(admin_rows$user_id), , drop = FALSE]
  admin_rows <- admin_rows[!duplicated(admin_rows$user_id), , drop = FALSE]
  if (!nrow(admin_rows)) return(c("Unassigned" = ""))
  labels <- ifelse(
    !is.na(admin_rows$email) & nzchar(trimws(admin_rows$email)),
    paste0(admin_rows$full_name, " - ", admin_rows$email),
    admin_rows$full_name
  )
  c("Unassigned" = "", stats::setNames(as.character(admin_rows$user_id), labels))
}

feedback_admin_card <- function(row, admin_choices) {
  feedback_id <- row$feedback_id[[1]]
  screenshot <- row$screenshot_data[[1]]
  comment <- row$comment[[1]]
  assigned_admin_id <- if ("assigned_admin_id" %in% names(row) && !is.na(row$assigned_admin_id[[1]])) as.character(row$assigned_admin_id[[1]]) else ""
  assigned_admin_label <- if ("assigned_admin_name" %in% names(row) && !is.na(row$assigned_admin_name[[1]])) row$assigned_admin_name[[1]] else "Unassigned"
  search_text <- paste(row$user_email[[1]], row$comment[[1]], row$page_key[[1]], row$page_url[[1]], assigned_admin_label, collapse = " ")
  div(
    class = "feedback-admin-card",
    `data-feedback-row` = feedback_id,
    `data-feedback-category` = row$category[[1]],
    `data-feedback-priority` = row$priority[[1]],
    `data-feedback-status` = row$status[[1]],
    `data-feedback-search` = tolower(search_text),
    div(
      class = "feedback-admin-card-header",
      div(
        div(class = "eyebrow", paste("Feedback #", feedback_id, sep = "")),
        h3(if (nzchar(trimws(row$user_email[[1]] %||% ""))) row$user_email[[1]] else "No email provided"),
        span(class = "feedback-admin-date", paste("Submitted", row$created_at[[1]])),
        span(class = "feedback-admin-date", paste("Assigned to", assigned_admin_label))
      ),
      div(
        class = "feedback-status-stack",
        status_chip(row$status[[1]], if (identical(row$status[[1]], "Complete")) "success" else if (identical(row$status[[1]], "Archived")) "neutral" else "primary"),
        status_chip(row$priority[[1]], if (row$priority[[1]] %in% c("High", "Urgent")) "warning" else "primary")
      )
    ),
    p(class = "feedback-comment", comment),
    if (!is.na(screenshot) && nzchar(trimws(screenshot))) {
      tags$a(
        class = "feedback-screenshot-link",
        href = screenshot,
        target = "_blank",
        rel = "noopener",
        tags$img(src = screenshot, alt = "Submitted screenshot"),
        span("Open screenshot")
      )
    },
    if (!is.na(row$page_url[[1]]) && nzchar(trimws(row$page_url[[1]]))) {
      tags$a(class = "feedback-page-link", href = row$page_url[[1]], target = "_blank", rel = "noopener", row$page_url[[1]])
    },
    div(
      class = "feedback-admin-controls",
      div(
        class = "measure-field",
        tags$label(`for` = paste0("feedback_category_", feedback_id), "Category"),
        tags$select(
          id = paste0("feedback_category_", feedback_id),
          lapply(feedback_category_choices, function(choice) {
            tags$option(value = choice, selected = identical(choice, row$category[[1]]), choice)
          })
        )
      ),
      div(
        class = "measure-field",
        tags$label(`for` = paste0("feedback_priority_", feedback_id), "Priority"),
        tags$select(
          id = paste0("feedback_priority_", feedback_id),
          lapply(feedback_priority_choices, function(choice) {
            tags$option(value = choice, selected = identical(choice, row$priority[[1]]), choice)
          })
        )
      ),
      div(
        class = "measure-field",
        tags$label(`for` = paste0("feedback_status_", feedback_id), "Status"),
        tags$select(
          id = paste0("feedback_status_", feedback_id),
          lapply(feedback_status_choices, function(choice) {
            tags$option(value = choice, selected = identical(choice, row$status[[1]]), choice)
          })
        )
      ),
      div(
        class = "measure-field",
        tags$label(`for` = paste0("feedback_assigned_admin_", feedback_id), "Assigned System Admin"),
        tags$select(
          id = paste0("feedback_assigned_admin_", feedback_id),
          lapply(names(admin_choices), function(label) {
            value <- admin_choices[[label]]
            tags$option(value = value, selected = identical(value, assigned_admin_id), label)
          })
        )
      )
    ),
    div(
      class = "feedback-admin-actions",
      tags$button(type = "button", class = "civic-button secondary", `data-feedback-complete` = feedback_id, icon("check"), "Mark complete"),
      tags$button(type = "button", class = "civic-button secondary", `data-feedback-archive` = feedback_id, icon("box-archive"), "Archive"),
      tags$button(type = "button", class = "civic-button danger", `data-feedback-delete` = feedback_id, icon("trash"), "Delete")
    )
  )
}

feedback_normalize_filters <- function(search = "", category_filter = character(0), priority_filter = character(0), status_filter = character(0)) {
  search <- if (is.null(search) || length(search) == 0 || is.na(search[[1]])) "" else as.character(search[[1]])
  search <- tolower(trimws(search))
  category_filter <- if (is.null(category_filter) || length(category_filter) == 0) character(0) else as.character(category_filter)
  priority_filter <- if (is.null(priority_filter) || length(priority_filter) == 0) character(0) else as.character(priority_filter)
  status_filter <- if (is.null(status_filter) || length(status_filter) == 0) character(0) else as.character(status_filter)
  category_filter <- category_filter[nzchar(category_filter)]
  priority_filter <- priority_filter[nzchar(priority_filter)]
  status_filter <- status_filter[nzchar(status_filter)]
  # An empty selection means "no filter" (show every status), exactly like
  # category/priority. It must never get silently rewritten to
  # default_feedback_status_filter here -- see feedback_list_ui()'s comment
  # for why.
  status_filter <- status_filter[status_filter %in% feedback_status_choices]
  list(search = search, category_filter = category_filter, priority_filter = priority_filter, status_filter = status_filter)
}

feedback_filtered_rows <- function(feedback, search = "", category_filter = character(0), priority_filter = character(0), status_filter = character(0)) {
  filters <- feedback_normalize_filters(search, category_filter, priority_filter, status_filter)
  filtered_feedback <- feedback
  if (nrow(filtered_feedback) && nzchar(filters$search)) {
    haystack <- tolower(paste(
      filtered_feedback$user_email,
      filtered_feedback$comment,
      filtered_feedback$page_key,
      filtered_feedback$page_url,
      filtered_feedback$assigned_admin_name,
      sep = " "
    ))
    filtered_feedback <- filtered_feedback[grepl(filters$search, haystack, fixed = TRUE), , drop = FALSE]
  }
  if (nrow(filtered_feedback) && length(filters$category_filter)) {
    filtered_feedback <- filtered_feedback[filtered_feedback$category %in% filters$category_filter, , drop = FALSE]
  }
  if (nrow(filtered_feedback) && length(filters$priority_filter)) {
    filtered_feedback <- filtered_feedback[filtered_feedback$priority %in% filters$priority_filter, , drop = FALSE]
  }
  if (nrow(filtered_feedback) && length(filters$status_filter)) {
    filtered_feedback <- filtered_feedback[filtered_feedback$status %in% filters$status_filter, , drop = FALSE]
  }
  filtered_feedback
}

# Rendered by its own uiOutput("feedback_admin_list") (see server()), kept
# separate from page_bug_fix()'s filter controls on purpose -- see the
# comment on that uiOutput call for why the two must not share a render
# cycle.
feedback_list_ui <- function(db, search = "", category_filter = character(0), priority_filter = character(0), status_filter = character(0)) {
  feedback <- db$application_feedback_request
  admin_choices <- feedback_system_admin_choices(db)
  filtered_feedback <- feedback_filtered_rows(feedback, search, category_filter, priority_filter, status_filter)
  if (!nrow(feedback)) {
    div(class = "empty-state", h3("No feedback yet"), p("Submitted feedback will appear here for System Admin review."))
  } else if (!nrow(filtered_feedback)) {
    div(class = "empty-state", h3("No matching feedback"), p("Clear or adjust the filters to see more requests."))
  } else {
    div(class = "feedback-admin-list", lapply(seq_len(nrow(filtered_feedback)), function(i) feedback_admin_card(filtered_feedback[i, , drop = FALSE], admin_choices)))
  }
}

page_bug_fix <- function(db, search = "", category_filter = character(0), priority_filter = character(0), status_filter = character(0), active_sessions = NA_integer_, active_users = NA_integer_) {
  feedback <- db$application_feedback_request
  status_counts <- if (nrow(feedback)) table(feedback$status) else integer(0)
  feedback_status_count <- function(status) {
    if (!length(status_counts) || !status %in% names(status_counts)) return(0L)
    as.integer(status_counts[[status]])
  }
  filters <- feedback_normalize_filters(search, category_filter, priority_filter, status_filter)
  tagList(
    div(
      class = "briefing-header compact",
      div(
        div(class = "eyebrow", "Application"),
        h1("Bug/Fix"),
        p("Review feedback, categorize requests, set priority, and close out completed fixes.")
      ),
      status_chip("System Admin", "primary")
    ),
    div(
      class = "dashboard-grid reviewer-dashboard-grid",
      metric_tile("New", feedback_status_count("New"), "Fresh requests"),
      metric_tile("Open", feedback_status_count("Open"), "Feedback needing triage"),
      metric_tile("In review", feedback_status_count("In Review"), "Being worked"),
      metric_tile("Complete", feedback_status_count("Complete"), "Closed requests", "success"),
      metric_tile("Archived", feedback_status_count("Archived"), "Stored for reference", "primary"),
      metric_tile(
        "Active sessions",
        if (is.na(active_sessions)) "—" else active_sessions,
        if (is.na(active_users)) "Open tabs, last 10 min" else paste0(active_users, " distinct user", if (active_users == 1) "" else "s", ", last 10 min"),
        "primary"
      )
    ),
    surface(
      "Feedback Requests",
      "Filter, categorize, prioritize, archive, delete, or mark requests complete.",
      div(
        class = "feedback-filter-grid",
        div(class = "measure-field", textInput("feedback_search", "Search", value = filters$search, placeholder = "Search email, page, or comment")),
        div(class = "measure-field", selectInput("feedback_category_filter", "Category", choices = feedback_category_choices, selected = filters$category_filter, multiple = TRUE)),
        div(class = "measure-field", selectInput("feedback_priority_filter", "Priority", choices = feedback_priority_choices, selected = filters$priority_filter, multiple = TRUE)),
        div(class = "measure-field", selectInput("feedback_status_filter", "Status", choices = feedback_status_choices, selected = filters$status_filter, multiple = TRUE))
      ),
      uiOutput("feedback_admin_list")
    )
  )
}

feedback_modal_ui <- function(user_email = "", page_label = "") {
  div(
    class = "custom-modal-backdrop feedback-modal-backdrop",
    `data-close-input` = "close_feedback_modal",
    div(
      class = "custom-modal feedback-modal-panel",
      role = "dialog",
      `aria-modal` = "true",
      `aria-labelledby` = "feedback_modal_title",
      div(
        class = "modal-header",
        div(
          div(class = "eyebrow", "Application feedback"),
          h2(id = "feedback_modal_title", "Send Feedback"),
          p("Tell us what happened, what you expected, or what would make the app easier to use.")
        ),
        tags$button(id = "close_feedback_modal", type = "button", class = "icon-button", `aria-label` = "Close feedback", icon("xmark"))
      ),
      div(
        class = "feedback-form-grid",
        div(class = "measure-field", textInput("feedback_email", "Email", value = user_email)),
        div(class = "measure-field", textInput("feedback_page_label", "Current page", value = page_label))
      ),
      textAreaInput("feedback_comment", "Comment", rows = 5, placeholder = "Describe the bug, fix, or feature request."),
      div(
        class = "feedback-screenshot-tools",
        tags$label(class = "civic-button secondary feedback-upload-label", icon("paperclip"), span("Upload image"), tags$input(id = "feedback_screenshot_file", type = "file", accept = "image/*")),
        span("You can also paste a screenshot while this form is open.")
      ),
      tags$input(id = "feedback_screenshot_data", type = "hidden", value = ""),
      div(id = "feedback_screenshot_preview", class = "feedback-screenshot-preview", "No screenshot attached"),
      div(
        class = "modal-actions",
        tags$button(type = "button", id = "submit_feedback", class = "civic-button primary", icon("paper-plane"), "Submit feedback")
      )
    )
  )
}

page_role_preview <- function(db, app_roles = c("AgencyViewer"), agency_roles = character(0), selected_user_id = "", selected_agency = "") {
  div(
    class = "builder-page role-preview-page",
    div(
      class = "briefing-header",
      div(
        class = "briefing-copy",
        div(class = "eyebrow", "Application"),
        h1("Role preview"),
        p("Preview user access, role permissions, and working plan context.")
      )
    ),
    role_preview_panel(db, app_roles, agency_roles, selected_user_id, selected_agency)
  )
}

page_landing <- function(db, agency_id, app_roles = c("AgencyViewer"), agency_roles = character(0)) {
  ctx <- selected_context(db, agency_id)
  plan <- ctx$plan
  agency <- ctx$agency
  header <- ctx$header
  services <- plan_service_rows(db, plan)
  goals <- db$performance_agency_goal[db$performance_agency_goal$plan_id == plan$plan_id, , drop = FALSE]
  risks <- db$performance_service_risk[db$performance_service_risk$plan_id == plan$plan_id, , drop = FALSE]
  risks_draft <- if (plan_uses_draft_payload(plan)) section_draft_payload(db, plan$plan_id[[1]], "risks") else NULL
  risks <- risks_with_draft_overlay(risks, plan$plan_id[[1]], risks_draft)
  selected_measure_ids <- plan_selected_measure_ids(db, plan, goals, services)
  selected_measures <- db$performance_performance_measure[db$performance_performance_measure$measure_id %in% selected_measure_ids, , drop = FALSE]
  invalid_selected_measures <- selected_measures[is.na(selected_measures$approval_status) | selected_measures$approval_status != "Validated", , drop = FALSE]
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
  review_admin_mode <- uses_review_administration_mode(app_roles)
  timeline_items <- timeline_all_items(Sys.Date())
  scorable_services <- scorable_service_rows(services)
  goal_readiness <- goal_draft_readiness(db, plan, goals)
  complete_goal_count <- goal_readiness$complete_count
  aligned_goal_count <- goal_readiness$aligned_count
  minimum_goals <- goal_minimum_count(plan)
  goal_measure_counts <- plan_goal_measure_counts(db, plan, goals)
  service_measure_counts <- plan_service_measure_counts(db, plan, scorable_services)
  service_metric_service_ids <- service_measure_counts$service_id[service_measure_counts$measure_count > 0]
  services_with_metrics <- sum(scorable_services$service_id %in% service_metric_service_ids)
  goals_over_measure_limit <- goal_measure_counts[goal_measure_counts$measure_count > 5, , drop = FALSE]
  services_over_measure_limit <- service_measure_counts[service_measure_counts$measure_count > 5, , drop = FALSE]
  over_limit_service_names <- if (nrow(services_over_measure_limit)) {
    scorable_services$service_name[match(services_over_measure_limit$service_id, scorable_services$service_id)]
  } else {
    character(0)
  }
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
    if (aligned_goal_count < 1) "one Action Plan alignment",
    if (nrow(goals_over_measure_limit)) paste(nrow(goals_over_measure_limit), "goal(s) over 5 KPIs")
  )
  maximum_goals <- goal_maximum_count(plan)
  goals_complete <- complete_goal_count >= minimum_goals && complete_goal_count <= maximum_goals && aligned_goal_count >= 1 && !nrow(goals_over_measure_limit)
  missing_service_names <- if (nrow(scorable_services)) scorable_services$service_name[!scorable_services$service_id %in% service_metric_service_ids] else character(0)
  services_complete <- submitter_is_mayoral_service(db, agency_id) || (nrow(scorable_services) == 0 || (services_with_metrics == nrow(scorable_services) && !nrow(services_over_measure_limit)))
  measures_complete <- length(selected_measure_ids) > 0 && !nrow(invalid_selected_measures)
  risks_complete <- nrow(risks) > 0
  service_detail <- if (submitter_is_mayoral_service(db, agency_id)) {
    "Not required for mayoral service plans"
  } else if (nrow(services_over_measure_limit)) {
    listed_services <- paste(head(over_limit_service_names, 3), collapse = ", ")
    more_services <- if (length(over_limit_service_names) > 3) paste("and", length(over_limit_service_names) - 3, "more") else ""
    paste(nrow(services_over_measure_limit), "service(s) over 5 metrics:", listed_services, more_services)
  } else if (!nrow(scorable_services)) {
    "No service metrics required for Administration services"
  } else if (services_complete) {
    paste("All", nrow(scorable_services), "scored services have metrics")
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
        p(if (review_admin_mode) "Track the full performance planning timeline and move into review queues or team administration." else "View the current timeline and performance planning guidance.")
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
      action_plan_stat(sum(vapply(strategic_plan, function(pillar) length(pillar$goals), integer(1))), "Goals")
      ,
      action_plan_stat(sum(vapply(strategic_plan, function(pillar) length(pillar$metrics), integer(1))), "Measures")
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

plan_team_service_ids <- function(db, plan) {
  if (is.null(plan) || !nrow(plan) || is.na(plan$entity_id[[1]])) return(character(0))
  links <- db$reference_plan_entity_service[db$reference_plan_entity_service$entity_id == plan$entity_id[[1]], , drop = FALSE]
  unique(links$service_id[!is.na(links$service_id) & nzchar(trimws(links$service_id))])
}

# Reported 2026-08-03: the plan review/scoring page rendered whatever
# happened to be in performance.plan_service for a plan with no regard for
# whether that service actually belongs to the plan's entity, and Mayoral
# Offices -- which are exempt from having any services at all
# (submitter_is_mayoral_service()) -- showed a service anyway. Used to scope
# plan_service/service_rows in the review page to only the services this
# specific plan is actually allowed to have.
plan_review_allowed_service_ids <- function(db, plan, all_service_ids) {
  if (submitter_is_mayoral_service(db, submitter_value_for_plan(plan))) return(character(0))
  if (!plan_is_entity_submitter(plan)) return(all_service_ids)
  entity_service_ids <- plan_team_service_ids(db, plan)
  all_service_ids[all_service_ids %in% entity_service_ids]
}

# Reported 2026-08-05: a Mayoral Office scored 4/4 on every criterion still
# came out capped at 85/100. plan_service_rows() can synthesize "extra"
# service rows for a plan from reference_plan_entity_service/
# performance_measure_entity_link even when performance.plan_service has
# zero rows for it, and scorable_service_rows() only strips
# Administrative-type services -- neither checks
# submitter_is_mayoral_service(), unlike plan_review_allowed_service_ids()
# above. collect_plan_review_scores() (server(), submits scores on save)
# used to build its service list from plan_service_rows()/
# scorable_service_rows() alone, so a Mayoral Office's phantom (unscored)
# service row made the S3 scoring formula take the 5+15 split path
# instead of folding the full 20 points into Family of Measures --
# history_plan_modal()'s rendering and plan_export_payload() were already
# correctly filtered through plan_review_allowed_service_ids(); this
# gives collect_plan_review_scores() (and any other future caller) the
# same one-line-correct service list instead of duplicating the filter.
plan_review_scorable_services <- function(db, plan) {
  services <- plan_service_rows(db, plan)
  services <- scorable_service_rows(services)
  services[services$service_id %in% plan_review_allowed_service_ids(db, plan, services$service_id), , drop = FALSE]
}

# Reported 2026-08-04: a plan's row in the review queue/publishing/approval
# list pages showed overall_score exactly as of the last full
# refresh_app_data() -- scoring a plan and navigating back to a list still
# showed the pre-save score. review_snapshot_cache holds a fresher
# per-plan snapshot written on every autosave (see the comment on
# plan_review_save_request in server()), but list pages read
# review_plan_review directly with no single plan_id to key off of, so
# every outstanding snapshot needs merging in, not just the one plan
# actively open in the detail view. Takes `cache` as a plain argument
# (rather than closing over review_snapshot_cache) so this is testable
# outside of a live Shiny session.
merge_cached_review_snapshots <- function(data, cache) {
  keys <- ls(cache)
  if (!length(keys) || !"review_plan_review" %in% names(data)) return(data)
  for (key in keys) {
    plan_id <- suppressWarnings(as.integer(key))
    if (is.na(plan_id)) next
    snapshot <- get(key, envir = cache, inherits = FALSE)
    old_review_ids <- data$review_plan_review$review_id[data$review_plan_review$plan_id == plan_id]
    data$review_plan_review <- rbind(
      data$review_plan_review[data$review_plan_review$plan_id != plan_id, , drop = FALSE],
      snapshot$review
    )
    if ("review_section_score" %in% names(data)) {
      data$review_section_score <- rbind(
        data$review_section_score[!data$review_section_score$review_id %in% old_review_ids, , drop = FALSE],
        snapshot$scores
      )
    }
  }
  data
}

# A "shared" service is used by more than one active entity that submits
# its own plan (reference.plan_entity_service) -- e.g. a single grant
# program (Art and Culture Grants) funding several peer quasi-agency
# grantees (BMA, Symphony, Zoo, Walters), none of which individually owns
# it. Reported 2026-07-31: grantees under a shared service typically share
# their parent agency's agency_id, so every entity could see (and
# overwrite) every OTHER entity's service description and metric
# selections. Distinct from plan_team_unique_service_ids(), which is
# scoped to one plan's own team and returns the OPPOSITE (non-shared)
# subset.
service_is_shared <- function(db, service_id) {
  if (is.null(service_id) || length(service_id) != 1 || is.na(service_id) || !nzchar(trimws(as.character(service_id)))) return(FALSE)
  links <- db$reference_plan_entity_service[as.character(db$reference_plan_entity_service$service_id) == as.character(service_id), , drop = FALSE]
  if (!nrow(links)) return(FALSE)
  entities <- db$reference_plan_entity[
    !is.na(db$reference_plan_entity$active) & db$reference_plan_entity$active &
      !is.na(db$reference_plan_entity$has_own_plan) & db$reference_plan_entity$has_own_plan,
    ,
    drop = FALSE
  ]
  length(unique(links$entity_id[links$entity_id %in% entities$entity_id])) > 1
}

# A shared service's own measures aren't just shared for description/
# metric-selection purposes -- performance.measure_actuals has no
# per-entity column, so two grantees editing the SAME measure_id's
# definition or fiscal-year data would clobber each other. Reported
# 2026-07-31: an AgencyWriter previewing as one grantee (Walters) could
# still open and edit another grantee's measure under the same shared
# service, since the measure modal's edit permission was a pure role
# check with no ownership check at all. Locked to SystemAdmin/BBMR
# (can_edit_shared_service_description()) the same as the description,
# until each measure is attributed to its own specific entity via
# measure_entity_link and this can be scoped more narrowly.
measure_belongs_to_shared_service <- function(db, measure_id) {
  # measure_id can legitimately be NULL -- current_measure_id() is a
  # nullable reactiveVal (cleared when the modal closes) -- which as.integer()
  # turns into a zero-length vector, not NA; is.na(integer(0)) is itself
  # zero-length, so `if` on it errors "argument is of length zero" rather
  # than evaluating to FALSE. Reported 2026-08-05 in production, traced to
  # persist_measure() reading a stale current_measure_id() after a rapid
  # repeat Save click -- see measure_save_in_progress's reentrancy guard,
  # which closes off that specific race. This length check just makes the
  # function itself safe for any NULL/zero-length input regardless.
  if (!length(measure_id)) return(FALSE)
  measure_id <- suppressWarnings(as.integer(measure_id))
  if (is.na(measure_id)) return(FALSE)
  linked_service_ids <- unique(db$performance_pm_service_link$service_id[db$performance_pm_service_link$measure_id == measure_id])
  if (!length(linked_service_ids)) return(FALSE)
  any(vapply(linked_service_ids, function(service_id) service_is_shared(db, service_id), logical(1)))
}

plan_team_unique_service_ids <- function(db, plan) {
  service_ids <- plan_team_service_ids(db, plan)
  if (!length(service_ids)) return(character(0))
  links <- db$reference_plan_entity_service[
    db$reference_plan_entity_service$service_id %in% service_ids,
    ,
    drop = FALSE
  ]
  entities <- db$reference_plan_entity[
    !is.na(db$reference_plan_entity$active) & db$reference_plan_entity$active &
      !is.na(db$reference_plan_entity$has_own_plan) & db$reference_plan_entity$has_own_plan,
    ,
    drop = FALSE
  ]
  links <- links[links$entity_id %in% entities$entity_id, , drop = FALSE]
  if (!nrow(links)) return(service_ids)
  counts <- table(as.character(links$service_id))
  service_ids[as.integer(counts[service_ids]) <= 1]
}

plan_team_primary_service_id <- function(db, plan) {
  service_ids <- plan_team_service_ids(db, plan)
  if (!length(service_ids)) return(NA_character_)
  links <- db$reference_plan_entity_service[
    db$reference_plan_entity_service$entity_id == plan$entity_id[[1]] &
      db$reference_plan_entity_service$service_id %in% service_ids,
    ,
    drop = FALSE
  ]
  primary <- links$service_id[!is.na(links$is_primary) & links$is_primary]
  if (length(primary)) primary[[1]] else service_ids[[1]]
}

plan_team_primary_access_service_id <- function(db, plan) {
  service_ids <- plan_team_unique_service_ids(db, plan)
  if (!length(service_ids)) return(NA_character_)
  links <- db$reference_plan_entity_service[
    db$reference_plan_entity_service$entity_id == plan$entity_id[[1]] &
      db$reference_plan_entity_service$service_id %in% service_ids,
    ,
    drop = FALSE
  ]
  primary <- links$service_id[!is.na(links$is_primary) & links$is_primary]
  if (length(primary)) primary[[1]] else service_ids[[1]]
}

plan_team_public_name <- function(db, plan) {
  if (is.null(plan) || !nrow(plan)) return("Public name")
  if (!is.na(plan$entity_id[[1]])) {
    entity <- db$reference_plan_entity[db$reference_plan_entity$entity_id == plan$entity_id[[1]], , drop = FALSE]
    if (nrow(entity)) {
      label <- trimws(as.character(entity$public_name[[1]] %||% ""))
      if (nzchar(label)) return(label)
    }
  }
  agency_name(db, plan_accounting_agency_id(db, plan))
}

agency_plan_entity_id <- function(db, agency_id) {
  agency_id <- trimws(as.character(agency_id %||% ""))
  if (!nzchar(agency_id) || !"reference_plan_entity" %in% names(db)) return(NA_integer_)
  entity <- db$reference_plan_entity[
    db$reference_plan_entity$parent_agency_id == agency_id &
      db$reference_plan_entity$entity_type == "Agency" &
      !is.na(db$reference_plan_entity$active) & db$reference_plan_entity$active,
    ,
    drop = FALSE
  ]
  if (!nrow(entity)) return(NA_integer_)
  entity$entity_id[[1]]
}

plan_team_entity_context_id <- function(db, plan) {
  if (is.null(plan) || !nrow(plan)) return(NA_integer_)
  if (!is.na(plan$entity_id[[1]])) return(plan$entity_id[[1]])
  agency_plan_entity_id(db, plan_accounting_agency_id(db, plan))
}

assignment_submitter_team_row <- function(db, plan, agency_id) {
  assignment <- plan_role_assignment(db, plan)
  if (!nrow(assignment)) return(db$access_user_agency_access[0, , drop = FALSE])

  submitter_name <- trimws(as.character(assignment$submitter[[1]] %||% ""))
  submitter_user_id <- suppressWarnings(as.integer(assignment$submitter_user_id[[1]] %||% NA_integer_))
  users <- db$access_user[0, , drop = FALSE]
  if (!is.na(submitter_user_id)) {
    users <- db$access_user[db$access_user$user_id == submitter_user_id, , drop = FALSE]
  }
  if (!nrow(users) && nzchar(submitter_name)) {
    user_key <- assignment_key(db$access_user$full_name)
    users <- db$access_user[user_key == assignment_key(submitter_name), , drop = FALSE]
  }

  if (nrow(users)) {
    user_id <- users$user_id[[1]]
    full_name <- users$full_name[[1]]
    email <- users$email[[1]]
  } else {
    user_id <- NA_integer_
    full_name <- submitter_name
    email <- ""
  }
  if (!nzchar(trimws(full_name %||% ""))) return(db$access_user_agency_access[0, , drop = FALSE])

  row <- data.frame(
    access_id = NA_integer_,
    user_id = user_id,
    agency_id = agency_id,
    service_id = plan_team_primary_access_service_id(db, plan),
    full_name = full_name,
    email = email,
    agency_role = "Agency Staff",
    agency_roles = "Agency Staff",
    access_level = "Submit",
    budget_access = FALSE,
    performance_plan_access = TRUE,
    stringsAsFactors = FALSE
  )
  row[, names(db$access_user_agency_access), drop = FALSE]
}

is_entity_access_id <- function(access_id) {
  startsWith(as.character(access_id %||% ""), "entity:")
}

entity_access_numeric_id <- function(access_id) {
  suppressWarnings(as.integer(sub("^entity:", "", as.character(access_id %||% ""))))
}

team_rows_for_plan <- function(db, submitter_value) {
  plan <- current_plan(db, submitter_value)
  if (is.null(plan) || !nrow(plan)) {
    # A NULL plan must short-circuit here: every downstream agency_id/entity_id
    # comparison below is `== NA`, and R's `df[logical_with_NA, ]` indexing
    # returns the WHOLE table back as all-NA rows (not zero rows) rather than
    # erroring, so without this guard the team table renders as a wall of NA
    # placeholder rows instead of nothing.
    return(db$access_user_agency_access[0, , drop = FALSE])
  }
  agency_id <- plan_accounting_agency_id(db, plan)
  if (!is.null(plan) && nrow(plan) && !is.na(plan$entity_id[[1]])) {
    if (!"access_user_entity_access" %in% names(db)) {
      team <- db$access_user_agency_access[0, , drop = FALSE]
    } else {
      team <- db$access_user_entity_access[db$access_user_entity_access$entity_id == plan$entity_id[[1]], , drop = FALSE]
    }
  } else {
    agency_entity_id <- agency_plan_entity_id(db, agency_id)
    if (!is.na(agency_entity_id) && "access_user_entity_access" %in% names(db)) {
      team <- db$access_user_entity_access[db$access_user_entity_access$entity_id == agency_entity_id, , drop = FALSE]
    } else {
      team <- db$access_user_agency_access[db$access_user_agency_access$agency_id == agency_id, , drop = FALSE]
      team <- team[is.na(team$service_id) | !nzchar(trimws(as.character(team$service_id))), , drop = FALSE]
    }
  }
  assignment <- plan_role_assignment(db, plan)
  if (nrow(assignment) && "user_id" %in% names(team)) {
    approver_ids <- unique(suppressWarnings(as.integer(c(
      assignment$reviewer_user_id[[1]] %||% NA_integer_,
      assignment$deputy_mayor_user_id[[1]] %||% NA_integer_,
      assignment$ca_office_user_id[[1]] %||% NA_integer_
    ))))
    submitter_id <- suppressWarnings(as.integer(assignment$submitter_user_id[[1]] %||% NA_integer_))
    approver_ids <- approver_ids[!is.na(approver_ids) & approver_ids != submitter_id]
    if (length(approver_ids)) {
      team <- team[!team$user_id %in% approver_ids, , drop = FALSE]
    }
  }
  if (!nrow(team)) return(team)
  team$agency_role_display <- vapply(seq_len(nrow(team)), function(i) {
    roles <- split_stored_roles(if ("agency_roles" %in% names(team)) team$agency_roles[[i]] else team$agency_role[[i]])
    if (length(roles)) paste(roles, collapse = "; ") else team$agency_role[[i]]
  }, character(1))
  team <- team[order(team$full_name, team$agency_role_display), , drop = FALSE]
  team$public_name <- plan_team_public_name(db, plan)
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

team_role_modal_ui <- function(db, submitter_value, access_id, can_edit = FALSE, grantable_roles = performance_role_choices) {
  plan <- current_plan(db, submitter_value)
  accounting_agency_id <- plan_accounting_agency_id(db, plan)
  parent_agency_name <- agency_name(db, accounting_agency_id)
  public_name <- plan_team_public_name(db, plan)
  team_entity_id <- plan_team_entity_context_id(db, plan)
  current_service_id <- plan_team_primary_access_service_id(db, plan)
  is_new <- identical(as.character(access_id), "new")
  access <- if (is_new) {
    data.frame(
      access_id = NA_integer_,
      entity_access_id = NA_integer_,
      user_id = NA_integer_,
      entity_id = team_entity_id,
      agency_id = accounting_agency_id,
      service_id = current_service_id,
      full_name = "",
      email = "",
      agency_role = "Agency Staff",
      stringsAsFactors = FALSE
    )
  } else if (is_entity_access_id(access_id)) {
    db$access_user_entity_access[db$access_user_entity_access$entity_access_id == entity_access_numeric_id(access_id), , drop = FALSE]
  } else {
    db$access_user_agency_access[db$access_user_agency_access$access_id == as.integer(access_id), , drop = FALSE]
  }
  if (!nrow(access)) return(NULL)
  user_roles <- if (is_new) {
    data.frame()
  } else {
    db$access_user_role[
      db$access_user_role$user_id == access$user_id[[1]] &
        (is.na(db$access_user_role$agency_id) | db$access_user_role$agency_id == accounting_agency_id),
      ,
      drop = FALSE
    ]
  }
  agency_roles <- split_stored_roles(if ("agency_roles" %in% names(access)) access$agency_roles[[1]] else access$agency_role[[1]])
  if (!length(agency_roles)) agency_roles <- access$agency_role[[1]]
  agency_role_display <- paste(agency_roles, collapse = "; ")
  performance_role <- if (nrow(user_roles)) user_roles$app_role[[1]] else "AgencyViewer"
  role_choices <- unique(c(grantable_roles, performance_role))
  role_choices <- role_choices[role_choices %in% performance_role_choices]
  if (!length(role_choices)) role_choices <- performance_role
  role_row <- if (nrow(user_roles)) user_roles[1, , drop = FALSE] else data.frame()
  readonly_field <- function(label, value) {
    div(
      class = "measure-field team-readonly-field",
      tags$span(class = "team-readonly-label", label),
      tags$span(class = "team-readonly-value", value %||% "Not set")
    )
  }
  access_fields <- if (can_edit) {
    div(
      class = "measure-form-grid",
      div(class = "measure-field", textInput("team_full_name", "Person name", value = access$full_name[[1]])),
      div(class = "measure-field", textInput("team_email", "Email", value = access$email[[1]])),
      div(class = "measure-field", selectInput("team_agency_role", "Agency role", choices = agency_role_choices, selected = agency_roles, multiple = TRUE)),
      div(class = "measure-field", selectInput("team_performance_role", "Performance role", choices = role_choices, selected = performance_role, selectize = FALSE)),
      div(class = "form-note team-access-note full-width", "Check which performance and budget apps/components this user needs access to."),
      div(class = "measure-field", checkboxInput("team_budget_access", "Budget access", value = if (nrow(role_row)) isTRUE(role_row$budget_access[[1]]) else FALSE)),
      div(class = "measure-field", checkboxInput("team_adaptive_planning", "Adaptive planning", value = if (nrow(role_row)) isTRUE(role_row$adaptive_planning[[1]]) else FALSE)),
      div(class = "measure-field", checkboxInput("team_performance_plan_access", "Performance plan access", value = if (nrow(role_row)) isTRUE(role_row$performance_plan_access[[1]]) else TRUE))
    )
  } else {
    div(
      class = "measure-form-grid team-readonly-grid",
      readonly_field("Person name", access$full_name[[1]]),
      readonly_field("Email", access$email[[1]]),
      readonly_field("Agency role", agency_role_display),
      readonly_field("Performance role", performance_role),
      readonly_field("Budget access", if (nrow(role_row) && isTRUE(role_row$budget_access[[1]])) "Yes" else "No"),
      readonly_field("Adaptive planning", if (nrow(role_row) && isTRUE(role_row$adaptive_planning[[1]])) "Yes" else "No"),
      readonly_field("Performance plan access", if (!nrow(role_row) || isTRUE(role_row$performance_plan_access[[1]])) "Yes" else "No")
    )
  }
  delete_action <- if (can_edit && !is_new) {
    div(
      class = "measure-submit-group team-delete-group",
      tags$button(id = "delete_team_role", type = "button", class = "civic-button danger", icon("trash-can"), "Delete user")
    )
  } else {
    div()
  }
  save_actions <- if (can_edit) {
    div(
      class = "measure-submit-group",
      tags$button(id = "save_team_role", type = "button", class = "civic-button primary", if (is_new) "Add team member" else "Save changes")
    )
  } else {
    div(class = "measure-submit-group", actionButton("close_team_role_modal_footer", "Close", class = "civic-button secondary"))
  }
  div(
    class = "custom-modal-backdrop measure-modal-backdrop",
    `data-close-input` = "close_team_role_modal",
    div(
      class = "custom-modal measure-editor-modal team-role-modal",
      div(
        class = "custom-modal-header",
        div(
          class = "measure-modal-title-block",
          h2(if (is_new) "Add team member" else access$full_name[[1]]),
          div(class = "chip-row measure-modal-status-row", status_chip(if (can_edit) "Editable" else "View only", if (can_edit) "success" else "warning"))
        ),
        actionButton("close_team_role_modal", "Close", class = "civic-button secondary small")
      ),
      div(
        class = "measure-form-stack",
        tags$section(
          class = "modal-section-block measure-form-section",
          h3("User Criteria"),
          div(
            class = "goal-field-instruction",
            p(tags$strong("Parent agency: "), parent_agency_name),
            p(tags$strong("Public name: "), public_name)
          ),
          if (!can_edit) p(class = "goal-field-instruction", "Role assignment changes are limited by app role, agency role, and scope."),
          access_fields
        )
      ),
      div(
        class = "measure-modal-actions",
        delete_action,
        save_actions
      )
    )
  )
}

page_team <- function(db, submitter_value, can_manage_team = FALSE, team_scope_choices = NULL) {
  if (!is.null(team_scope_choices) && length(team_scope_choices) > 0 && !submitter_value %in% unname(team_scope_choices)) {
    submitter_value <- unname(team_scope_choices)[[1]]
  }
  plan <- current_plan(db, submitter_value)
  page_title <- performance_plan_title(db, plan, "Team & Roles")
  page_description <- if (can_manage_team) {
    "Review and update user role assignments for this plan."
  } else {
    "Review who owns plan sections, metric approvals, and final submission. Role edits are limited by app role, agency role, and scope."
  }
  plan_id <- if (!is.null(plan) && nrow(plan)) plan$plan_id[[1]] else NA_integer_
  team <- team_rows_for_plan(db, submitter_value)
  add_button <- if (can_manage_team) {
    tags$button(type = "button", class = "civic-button primary small", `data-team-access-id` = "new", icon("user-plus"), "Add team member")
  }
  team_scope_dropdown <- if (!is.null(team_scope_choices) && length(team_scope_choices) > 1) {
    selected_team_scope <- if (submitter_value %in% unname(team_scope_choices)) submitter_value else unname(team_scope_choices)[[1]]
    div(
      class = "team-scope-selector",
      selectInput(
        "team_scope_agency",
        "Agency team scope",
        choices = team_scope_choices,
        selected = selected_team_scope,
        selectize = TRUE,
        width = "100%"
      )
    )
  }
  if (nrow(team) == 0) {
    return(builder_page(
      page_title,
      page_description,
      surface(
        "Team members",
        "Review role assignments and access for this plan.",
        div(class = "team-page-actions", team_scope_dropdown, add_button),
        div(class = "empty-state", h3("No team members assigned"), p("Add user access rows to populate this page."))
      ),
      plan_id = plan_id,
      section_key = "team",
      show_save = FALSE,
      show_status = FALSE
    ))
  }
  builder_page(
    page_title,
    page_description,
    surface(
      "Team members",
      "Review role assignments and access for this plan.",
      div(class = "team-page-actions", team_scope_dropdown, add_button),
      div(
        class = "app-table team-role-table",
        div(class = "table-row table-head", span("Person"), span("Public name"), span("Agency role"), span("Performance role")),
        lapply(seq_len(nrow(team)), function(i) {
          has_access_row <- !is.na(team$access_id[i])
          div(
            class = paste("table-row team-role-row", if (!has_access_row) "assignment-only" else ""),
            role = if (has_access_row) "button" else NULL,
            tabindex = if (has_access_row) "0" else NULL,
            `data-team-access-id` = if (has_access_row) team$access_id[i] else NULL,
            span(team$full_name[i]),
            span(team$public_name[i]),
            span(team$agency_role_display[i]),
            span(
              class = paste("role-link-button", if (!can_manage_team || !has_access_row) "view-only" else ""),
              team$performance_role[i]
            )
          )
        })
      )
    ),
    plan_id = plan_id,
    section_key = "team",
    show_save = FALSE,
    show_status = FALSE
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

# Reported 2026-08-05: a Returned plan's "Plan readiness" checklist flagged
# a goal as over the 5-KPI limit when the KPI list actually shown to the
# agency (in the Goals editor and the View-plan modal, both of which read
# goals_draft$kpis) was at or under 5. Root cause: this only ever counted
# performance_pm_goal_link rows -- the live table, last updated whenever the
# goal was previously Approved/Published -- with no awareness that the
# agency may have since trimmed the KPI list in their current draft.
# Mirrors plan_service_measure_counts()'s draft-aware pattern just below.
plan_goal_measure_counts <- function(db, plan, goals) {
  if (is.null(goals) || !nrow(goals)) return(data.frame(agency_goal_id = integer(), measure_count = integer()))
  goals_draft <- if (!is.null(plan) && nrow(plan) && plan_uses_draft_payload(plan)) section_draft_payload(db, plan$plan_id[[1]], "goals") else NULL
  measure_count <- vapply(goals$agency_goal_id, function(goal_id) {
    draft_values <- if (!is.null(goals_draft) && !is.null(goals_draft$kpis[[as.character(goal_id)]])) {
      suppressWarnings(as.integer(unlist(goals_draft$kpis[[as.character(goal_id)]])))
    } else {
      NULL
    }
    if (!is.null(draft_values)) {
      draft_values <- draft_values[!is.na(draft_values)]
      return(length(unique(draft_values)))
    }
    length(unique(db$performance_pm_goal_link$measure_id[db$performance_pm_goal_link$agency_goal_id == goal_id]))
  }, integer(1))
  data.frame(agency_goal_id = goals$agency_goal_id, measure_count = unname(measure_count))
}

plan_service_measure_counts <- function(db, plan, services) {
  if (is.null(services) || !nrow(services)) return(data.frame(plan_service_id = integer(), service_id = character(), measure_count = integer()))
  services_draft <- if (!is.null(plan) && nrow(plan) && plan_uses_draft_payload(plan)) section_draft_payload(db, plan$plan_id[[1]], "services") else NULL
  counts <- data.frame(
    plan_service_id = services$plan_service_id,
    service_id = services$service_id,
    # unname: vapply carries service_id names, and data.frame would adopt them
    # as row names, which errors if any are NA
    measure_count = unname(vapply(services$service_id, function(service_id) {
      draft_values <- if (!is.null(services_draft) && !is.null(services_draft$serviceMetrics[[service_id]])) {
        suppressWarnings(as.integer(unlist(services_draft$serviceMetrics[[service_id]])))
      } else {
        NULL
      }
      if (!is.null(draft_values)) {
        draft_values <- draft_values[!is.na(draft_values)]
        return(length(unique(draft_values)))
      }
      length(unique(service_metric_ids(db, plan, service_id, include_ineligible = TRUE)))
    }, integer(1))),
    stringsAsFactors = FALSE
  )
  counts
}

plan_selected_measure_ids <- function(db, plan, goals, services) {
  # Reported 2026-08-05: Overdose Response's readiness checklist said
  # "missing at least one plan measure" despite 4 KPIs genuinely picked on
  # its (still-Drafting) goals. A goal only becomes a
  # performance.agency_goal row once the plan is Approved
  # (apply_plan_drafts_to_records() promotes the draft then) -- see
  # goal_draft_readiness()'s comment -- so for every Draft/Submitted/
  # UnderReview/Returned plan, goals and their KPI picks live only in the
  # goals draft payload. This read only the live agency_goal/pm_goal_link
  # tables, same class of bug plan_goal_measure_counts() was already fixed
  # for (the "over 5 KPIs" flag) -- but that fix was never applied here.
  goals_draft <- if (!is.null(plan) && nrow(plan) && plan_uses_draft_payload(plan)) section_draft_payload(db, plan$plan_id[[1]], "goals") else NULL
  published_goal_ids <- if (is.null(goals) || !nrow(goals)) character(0) else as.character(goals$agency_goal_id)
  draft_goal_ids <- if (!is.null(goals_draft) && !is.null(goals_draft$goalIds)) as.character(unlist(goals_draft$goalIds)) else character(0)
  goal_ids <- union(published_goal_ids, draft_goal_ids)
  goal_measure_ids <- unique(unlist(lapply(goal_ids, function(goal_id) {
    draft_values <- if (!is.null(goals_draft) && !is.null(goals_draft$kpis[[goal_id]])) {
      suppressWarnings(as.integer(unlist(goals_draft$kpis[[goal_id]])))
    } else {
      NULL
    }
    if (!is.null(draft_values)) {
      return(draft_values[!is.na(draft_values)])
    }
    db$performance_pm_goal_link$measure_id[as.character(db$performance_pm_goal_link$agency_goal_id) == goal_id]
  }), use.names = FALSE))
  scorable_services <- scorable_service_rows(services)
  services_draft <- if (!is.null(plan) && nrow(plan) && plan_uses_draft_payload(plan)) section_draft_payload(db, plan$plan_id[[1]], "services") else NULL
  service_measure_ids <- if (is.null(scorable_services) || !nrow(scorable_services)) {
    integer(0)
  } else {
    unique(unlist(lapply(scorable_services$service_id, function(service_id) {
      draft_values <- if (!is.null(services_draft) && !is.null(services_draft$serviceMetrics[[service_id]])) {
        suppressWarnings(as.integer(unlist(services_draft$serviceMetrics[[service_id]])))
      } else {
        NULL
      }
      if (!is.null(draft_values)) {
        return(draft_values[!is.na(draft_values)])
      }
      service_metric_ids(db, plan, service_id, include_ineligible = TRUE)
    }), use.names = FALSE))
  }
  unique(c(goal_measure_ids, service_measure_ids))
}

# Measures selected as this plan's goal KPIs or service metrics that are
# missing either the most recently completed fiscal year's actual (e.g.
# FY26 actual while FY27 is executing) or the upcoming budget year's
# target (e.g. FY28). Both are required to publish the *plan* -- neither
# is required to save or submit an individual measure for approval (see
# measure_missing_required_fields()). Measures marked "New" this
# cycle are exempt -- they weren't tracked yet, so there's nothing to report.
plan_measures_missing_required_fiscal_data <- function(db, plan, goals, services) {
  empty <- db$performance_performance_measure[0, , drop = FALSE]
  if (is.null(plan) || !nrow(plan)) return(empty)
  selected_measure_ids <- plan_selected_measure_ids(db, plan, goals, services)
  if (!length(selected_measure_ids)) return(empty)
  measures <- db$performance_performance_measure[db$performance_performance_measure$measure_id %in% selected_measure_ids, , drop = FALSE]
  change_mapping <- ifelse(is.na(measures$change_mapping), "", measures$change_mapping)
  measures <- measures[change_mapping != "New", , drop = FALSE]
  if (!nrow(measures)) return(measures)
  actual_fy <- fiscal_measure_snapshot_years()$actual_fy
  next_target_fy <- current_fiscal_year() + 1L
  actuals <- db$performance_measure_actuals
  nonblank <- function(x) !is.na(x) & nzchar(trimws(x))
  reported_actual_ids <- unique(actuals$measure_id[
    actuals$fiscal_year == actual_fy & !is.na(actuals$annual_actual) & nonblank(actuals$annual_actual_notes)
  ])
  reported_target_ids <- unique(actuals$measure_id[
    actuals$fiscal_year == next_target_fy & !is.na(actuals$target_value) & nonblank(actuals$target_value_notes)
  ])
  measures[!(measures$measure_id %in% reported_actual_ids & measures$measure_id %in% reported_target_ids), , drop = FALSE]
}

plan_readiness_summary <- function(db, submitter_value, plan) {
  if (is.null(plan) || !nrow(plan)) return(list(rows = list(), has_errors = TRUE))
  services <- plan_service_rows(db, plan)
  goals <- db$performance_agency_goal[db$performance_agency_goal$plan_id == plan$plan_id, , drop = FALSE]
  risks <- db$performance_service_risk[db$performance_service_risk$plan_id == plan$plan_id, , drop = FALSE]
  risks_draft <- if (plan_uses_draft_payload(plan)) section_draft_payload(db, plan$plan_id[[1]], "risks") else NULL
  risks <- risks_with_draft_overlay(risks, plan$plan_id[[1]], risks_draft)
  selected_measure_ids <- plan_selected_measure_ids(db, plan, goals, services)
  selected_measures <- db$performance_performance_measure[db$performance_performance_measure$measure_id %in% selected_measure_ids, , drop = FALSE]
  invalid_selected_measures <- selected_measures[is.na(selected_measures$approval_status) | selected_measures$approval_status != "Validated", , drop = FALSE]
  overview <- db$performance_overview_vision[db$performance_overview_vision$plan_id == plan$plan_id, , drop = FALSE]
  overview_draft <- if (plan_uses_draft_payload(plan)) section_draft_payload(db, plan$plan_id[[1]], "overview") else NULL
  overview_text <- draft_value(overview_draft, "agency_summary", if (nrow(overview)) overview$overview[[1]] else "")
  vision_text <- draft_value(overview_draft, "agency_vision", if (nrow(overview)) overview$vision[[1]] else "")
  web_address <- draft_value(overview_draft, "agency_website", if (nrow(overview)) overview$web_address[[1]] else "")
  goal_readiness <- goal_draft_readiness(db, plan, goals)
  complete_goal_count <- goal_readiness$complete_count
  aligned_goal_count <- goal_readiness$aligned_count
  minimum_goals <- goal_minimum_count(plan)
  maximum_goals <- goal_maximum_count(plan)
  goal_measure_counts <- plan_goal_measure_counts(db, plan, goals)
  scorable_services <- scorable_service_rows(services)
  service_measure_counts <- plan_service_measure_counts(db, plan, scorable_services)
  goals_over_measure_limit <- goal_measure_counts[goal_measure_counts$measure_count > 5, , drop = FALSE]
  services_over_measure_limit <- service_measure_counts[service_measure_counts$measure_count > 5, , drop = FALSE]
  service_metric_service_ids <- service_measure_counts$service_id[service_measure_counts$measure_count > 0]
  services_with_metrics <- sum(scorable_services$service_id %in% service_metric_service_ids)
  missing_service_names <- if (nrow(scorable_services)) scorable_services$service_name[!scorable_services$service_id %in% service_metric_service_ids] else character(0)
  over_limit_service_names <- if (nrow(services_over_measure_limit)) {
    scorable_services$service_name[match(services_over_measure_limit$service_id, scorable_services$service_id)]
  } else {
    character(0)
  }
  overview_missing <- c(
    if (!nonblank_text(overview_text)) "overview",
    if (!nonblank_text(vision_text)) "vision",
    if (!nonblank_text(web_address)) "website"
  )
  overview_complete <- !length(overview_missing)
  goals_missing <- c(
    if (complete_goal_count < minimum_goals) paste(minimum_goals - complete_goal_count, "more complete goals"),
    if (complete_goal_count > maximum_goals) paste("reduce to", maximum_goals, "goals"),
    if (aligned_goal_count < 1) "one Action Plan alignment",
    if (nrow(goals_over_measure_limit)) paste(nrow(goals_over_measure_limit), "goal(s) over 5 KPIs")
  )
  goals_complete <- !length(goals_missing)
  services_complete <- submitter_is_mayoral_service(db, submitter_value) || (nrow(scorable_services) == 0 || (services_with_metrics == nrow(scorable_services) && !nrow(services_over_measure_limit)))
  service_detail <- if (submitter_is_mayoral_service(db, submitter_value)) {
    "Not required for mayoral service plans"
  } else if (nrow(services_over_measure_limit)) {
    listed_services <- paste(head(over_limit_service_names, 3), collapse = ", ")
    more_services <- if (length(over_limit_service_names) > 3) paste("and", length(over_limit_service_names) - 3, "more") else ""
    paste(nrow(services_over_measure_limit), "service(s) over 5 metrics:", listed_services, more_services)
  } else if (!nrow(scorable_services)) {
    "No service metrics required for Administration services"
  } else if (services_complete) {
    paste("All", nrow(scorable_services), "scored services have metrics")
  } else {
    listed_services <- paste(head(missing_service_names, 3), collapse = ", ")
    more_services <- if (length(missing_service_names) > 3) paste("and", length(missing_service_names) - 3, "more") else ""
    paste("Missing metrics:", listed_services, more_services)
  }
  recent_actual_fy <- fiscal_measure_snapshot_years()$actual_fy
  next_target_fy <- current_fiscal_year() + 1L
  missing_fiscal_data <- plan_measures_missing_required_fiscal_data(db, plan, goals, services)
  measures_complete <- length(selected_measure_ids) > 0 && !nrow(invalid_selected_measures) && !nrow(missing_fiscal_data)
  measures_missing_notes <- c(
    if (!length(selected_measure_ids)) "at least one plan measure",
    if (nrow(invalid_selected_measures)) {
      paste0(
        "validation for ", paste(head(invalid_selected_measures$title, 3), collapse = ", "),
        if (nrow(invalid_selected_measures) > 3) paste0(" and ", nrow(invalid_selected_measures) - 3, " more") else ""
      )
    },
    if (nrow(missing_fiscal_data)) {
      paste0(
        fy_label(recent_actual_fy), " actual or ", fy_label(next_target_fy), " target for ",
        paste(head(missing_fiscal_data$title, 3), collapse = ", "),
        if (nrow(missing_fiscal_data) > 3) paste0(" and ", nrow(missing_fiscal_data) - 3, " more") else ""
      )
    }
  )
  measures_detail <- if (measures_complete) {
    paste("All", length(selected_measure_ids), "plan measures validated and reporting", fy_label(recent_actual_fy), "actual and", fy_label(next_target_fy), "target")
  } else {
    paste("Missing:", paste(measures_missing_notes, collapse = "; "))
  }
  risks_complete <- nrow(risks) > 0
  rows <- list(
    list(label = "Agency overview and vision", detail = if (overview_complete) "Overview, vision, and website are complete" else paste("Missing:", paste(overview_missing, collapse = ", ")), complete = overview_complete),
    list(label = "Goals and KPIs", detail = if (goals_complete) paste(complete_goal_count, "complete goals with Action Plan alignment") else paste("Missing:", paste(goals_missing, collapse = ", ")), complete = goals_complete),
    list(label = "Services", detail = service_detail, complete = services_complete),
    list(label = "Measures", detail = measures_detail, complete = measures_complete),
    list(label = "Risks", detail = if (risks_complete) paste(nrow(risks), "risks registered") else "Missing: at least one risk", complete = risks_complete)
  )
  list(rows = rows, has_errors = any(!vapply(rows, function(row) isTRUE(row$complete), logical(1))))
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

agency_choices_only <- function(db) {
  choices <- agency_selector_choices(db)
  choices[startsWith(unname(choices), "agency:")]
}

resolve_owning_agency_id <- function(db, value) {
  submitter <- parse_submitter_value(value)
  if (identical(submitter$type, "entity")) {
    entity <- db$reference_plan_entity[db$reference_plan_entity$entity_id == submitter$id, , drop = FALSE]
    if (nrow(entity)) return(entity$parent_agency_id[[1]])
    return(NA_character_)
  }
  submitter$id
}

# A brand-new measure created via the owning-entity picker (measure_modal_ui's
# show_owning_entity_picker) must have its measure_entity_link scoped to
# whichever entity the picker selected, not to whatever plan the current user
# happens to be viewing -- e.g. a SystemAdmin looking at Mayoralty's own plan
# who picks "OPI" as the owner must link the new measure to OPI, not to
# Mayoralty. This applies even when OPI is left at its default selection --
# OPI is meant to administratively hold measures with no other single clear
# owner, so those should still link (and surface) specifically under OPI,
# not sit unlinked at the bare Mayoralty agency level. Editing an existing
# measure (no picker involved) keeps the prior current-submitter behavior.
resolve_link_submitter_value <- function(existing_measure_id, owning_picker_value, current_submitter_value) {
  is_new <- is.null(existing_measure_id) || identical(existing_measure_id, "new")
  picker_usable <- !is.null(owning_picker_value) && length(owning_picker_value) == 1 && nzchar(owning_picker_value)
  if (is_new && picker_usable) return(owning_picker_value)
  current_submitter_value
}

# Default selection for the new-measure owning-agency picker: OPI when it's
# in the choice list (it resolves to Mayoralty's agency_id, AGC4301, via
# resolve_owning_agency_id()), else the Mayor's Office agency choice itself,
# else just the first available choice.
default_owning_measure_choice <- function(choices) {
  opi_match <- unname(choices[names(choices) == "Mayor's Office of Performance and Innovation"])
  if (length(opi_match)) return(opi_match[[1]])
  if ("agency:AGC4301" %in% choices) return("agency:AGC4301")
  if (length(choices)) return(unname(choices[[1]]))
  "agency:AGC4301"
}

user_submitter_choices <- function(db, user_id) {
  valid_choices <- agency_selector_choices(db)
  valid_values <- unname(valid_choices)
  user_id <- as.character(user_id %||% "")
  if (!nzchar(user_id)) return(valid_choices[0])
  numeric_user_id <- suppressWarnings(as.integer(user_id))
  agency_rows <- db$access_user_agency_access[as.character(db$access_user_agency_access$user_id) == user_id, , drop = FALSE]
  role_rows <- db$access_user_role[as.character(db$access_user_role$user_id) == user_id, , drop = FALSE]
  values <- character(0)

  if (nrow(agency_rows)) {
    service_ids <- unique(agency_rows$service_id[!is.na(agency_rows$service_id)])
    if (length(service_ids) && "reference_plan_entity_service" %in% names(db) && "reference_plan_entity" %in% names(db)) {
      entity_links <- db$reference_plan_entity_service[db$reference_plan_entity_service$service_id %in% service_ids, , drop = FALSE]
      entities <- db$reference_plan_entity[
        db$reference_plan_entity$entity_id %in% entity_links$entity_id &
          db$reference_plan_entity$active &
          db$reference_plan_entity$has_own_plan,
        ,
        drop = FALSE
      ]
      values <- c(values, paste0("entity:", entities$entity_id))
    }
    agency_ids <- unique(agency_rows$agency_id[!is.na(agency_rows$agency_id)])
    values <- c(values, paste0("agency:", agency_ids))
  }

  if (nrow(role_rows)) {
    role_agency_ids <- unique(role_rows$agency_id[!is.na(role_rows$agency_id)])
    values <- c(values, paste0("agency:", role_agency_ids))
  }

  if ("access_user_entity_access" %in% names(db) && "reference_plan_entity" %in% names(db)) {
    entity_access_rows <- db$access_user_entity_access[as.character(db$access_user_entity_access$user_id) == user_id, , drop = FALSE]
    if (nrow(entity_access_rows)) {
      entity_ids <- unique(entity_access_rows$entity_id[!is.na(entity_access_rows$entity_id)])
      entities <- db$reference_plan_entity[
        db$reference_plan_entity$entity_id %in% entity_ids &
          db$reference_plan_entity$active &
          db$reference_plan_entity$has_own_plan,
        ,
        drop = FALSE
      ]
      values <- c(values, paste0("entity:", entities$entity_id))
    }
  }

  assignments <- entity_role_assignment_rows(db)
  if (nrow(assignments)) {
    assignment_matches <- rep(FALSE, nrow(assignments))
    if ("submitter_user_id" %in% names(assignments) && !is.na(numeric_user_id)) {
      submitter_user_ids <- suppressWarnings(as.integer(assignments$submitter_user_id))
      assignment_matches <- assignment_matches | (!is.na(submitter_user_ids) & submitter_user_ids == numeric_user_id)
    }
    if ("submitter" %in% names(assignments)) {
      assignment_matches <- assignment_matches | vapply(
        assignments$submitter,
        function(submitter) user_name_matches_text(db, user_id, submitter),
        logical(1)
      )
    }
    assignment_rows <- assignments[assignment_matches, , drop = FALSE]
    if (nrow(assignment_rows)) {
      entity_ids <- suppressWarnings(as.integer(assignment_rows$entity_id))
      entity_ids <- entity_ids[!is.na(entity_ids)]
      values <- c(values, paste0("entity:", entity_ids))

      agency_assignment_rows <- assignment_rows[
        is.na(suppressWarnings(as.integer(assignment_rows$entity_id))) |
          !nzchar(trimws(as.character(assignment_rows$entity_id))),
        ,
        drop = FALSE
      ]
      if (nrow(agency_assignment_rows)) {
        agency_ids <- unique(agency_assignment_rows$agency_id[!is.na(agency_assignment_rows$agency_id) & nzchar(trimws(agency_assignment_rows$agency_id))])
        values <- c(values, paste0("agency:", agency_ids))
      }
    }
  }

  # Some agencies (e.g. BCIT) have an agency-scoped plan (agency_id set,
  # entity_id NULL) that is ALSO represented by a same-named "Agency"-type
  # plan_entity row, and access can be granted through either form. Only the
  # agency form appears in valid_values (agency_selector_choices() only lists
  # "entity:" for plans whose own row has entity_id set), so an entity-form
  # value for one of these dual-registered agencies would otherwise get
  # silently dropped by the validity filter below even though it points at a
  # real, valid plan. Canonicalize it back to the agency form first.
  values <- vapply(values, function(value) {
    if (startsWith(value, "entity:") && !value %in% valid_values) {
      entity_id <- suppressWarnings(as.integer(sub("^entity:", "", value)))
      if (!is.na(entity_id)) {
        entity_row <- db$reference_plan_entity[db$reference_plan_entity$entity_id == entity_id, , drop = FALSE]
        if (nrow(entity_row) && !is.na(entity_row$parent_agency_id[[1]])) {
          canonical <- paste0("agency:", entity_row$parent_agency_id[[1]])
          if (canonical %in% valid_values) return(canonical)
        }
      }
    }
    value
  }, character(1))
  values <- unique(values[nzchar(values) & values %in% valid_values])
  valid_choices[valid_values %in% values]
}


plan_uses_draft_payload <- function(plan) {
  if (is.null(plan) || !nrow(plan)) return(FALSE)
  !plan$plan_status[[1]] %in% c("Approved", "Published")
}

section_draft_payload <- function(db, plan_id, section_key) {
  drafts <- db$planning_plan_section_draft[
    db$planning_plan_section_draft$plan_id == plan_id &
      db$planning_plan_section_draft$section_key == section_key,
    ,
    drop = FALSE
  ]
  if (!nrow(drafts)) return(NULL)
  payload <- parse_stored_draft_payload(drafts$payload[[1]], context = paste0("plan_id=", plan_id, " section_key=", section_key))
  if (is.null(payload) || !is.list(payload)) return(NULL)
  payload
}

draft_value <- function(draft, field_id, fallback = "") {
  if (is.null(draft) || is.null(draft$values) || is.null(draft$values[[field_id]])) return(fallback)
  value <- draft$values[[field_id]]
  if (is.null(value) || length(value) == 0 || is.na(value)) return(fallback)
  as.character(value)
}

# Applies a risks section draft (see merge_risks_draft_payload() in
# R/database.R for the payload shape) on top of the live service_risk rows
# for a plan -- edits overwrite in place, deletes drop the row, adds append
# a synthetic row keyed by its temp id. risk_id becomes character throughout
# the result (real ids included) since a temp "new-<epoch>" id can't be
# coerced to integer -- every caller comparing against risk_id needs to
# compare as character after this, not with numeric ==.
risks_with_draft_overlay <- function(risks, plan_id, draft) {
  if (is.null(draft)) return(risks)
  risks$risk_id <- as.character(risks$risk_id)
  if (nrow(risks)) {
    keep <- !risks$risk_id %in% unlist(draft$deletes %||% list())
    risks <- risks[keep, , drop = FALSE]
  }
  edits <- draft$edits %||% list()
  for (id in names(edits)) {
    idx <- which(risks$risk_id == id)
    if (length(idx)) {
      risks$risk_type[idx] <- edits[[id]]$risk_type
      risks$description[idx] <- edits[[id]]$description
    }
  }
  adds <- draft$adds %||% list()
  if (length(adds)) {
    added <- do.call(rbind, lapply(names(adds), function(id) {
      data.frame(
        risk_id = id,
        plan_id = plan_id,
        risk_type = adds[[id]]$risk_type,
        description = adds[[id]]$description,
        stringsAsFactors = FALSE
      )
    }))
    common <- intersect(names(risks), names(added))
    risks <- rbind(risks[, common, drop = FALSE], added[, common, drop = FALSE])
  }
  risks
}

validate_measure_selection_limit <- function(payload_json, section_key, limit = 5L) {
  payload <- tryCatch(jsonlite::fromJSON(payload_json, simplifyVector = FALSE), error = function(error) NULL)
  if (is.null(payload)) return(NULL)
  # Autosave must accept in-progress drafts, including seeded plans that start
  # over the metric/KPI cap. The page-level readiness checks surface those
  # issues while still allowing users to remove their way back into compliance.
  NULL
}

builder_page <- function(title, description, body, plan_id, section_key, show_save = TRUE, show_status = TRUE, locked = FALSE, locked_message = NULL) {
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
      div(
        class = "builder-header-actions",
        if (show_status) status_chip("Draft", "warning"),
        if (locked) span(class = "header-autosave-status locked", locked_message %||% "This plan is view-only right now. Fields are locked.")
        else if (show_save) span(id = "plan_save_status", class = "header-autosave-status", "Loading the shared draft...")
      )
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
    NULL
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

filter_review_scores_to_scorable_services <- function(scores, scorable_plan_service_ids) {
  if (is.null(scores) || !nrow(scores)) return(scores)
  scores[
    scores$target_type != "service" |
      (!is.na(scores$target_id) & scores$target_id %in% scorable_plan_service_ids),
    ,
    drop = FALSE
  ]
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

# overall_score has exactly one writer (save_plan_review_scores(), in
# R/database.R) and it's always already a 0-100 weighted score -- there is
# no remaining code path that stores a raw 1-4 average into it. The old
# "score <= 4 means it's still on a 1-4 scale, multiply by 25" heuristic
# below was therefore pure guesswork by value alone, and it actively
# misfired on any plan that was genuinely, correctly scored low (a raw
# weighted score of 3 is a real "3/100", not a "75/100").
score_out_of_100 <- function(score) {
  if (is.na(score)) return("Not scored")
  paste0(round(as.numeric(score)), "/100")
}

plan_review_expected_count <- function(goal_count, service_count) {
  nrow(plan_review_criteria("plan_overview")) +
    nrow(plan_review_criteria("plan_measures")) +
    nrow(plan_review_criteria("plan_risks")) +
    nrow(plan_review_criteria("plan_data")) +
    goal_count * nrow(plan_review_criteria("goal")) +
    service_count * nrow(plan_review_criteria("service"))
}

plan_review_scored_count <- function(scores) {
  if (is.null(scores) || !nrow(scores)) return(0L)
  sum(!is.na(scores$score))
}

submitted_plan_statuses <- function() {
  c("Submitted", "UnderReview", "DirectorSignOff", "DeputyMayorReview", "CAReview", "Approved", "Published", "Amended")
}

review_approvable_statuses <- function() {
  c("Submitted", "UnderReview", "FeedbackReturned", "Returned", "AgencyRevised")
}

plan_gate_stage <- function(plan_status) {
  switch(
    as.character(plan_status),
    DeputyMayorReview = "DeputyMayor",
    CAReview = "CAOffice",
    NA_character_
  )
}

plan_gate_next_status <- function(plan_status) {
  switch(
    as.character(plan_status),
    DeputyMayorReview = "CAReview",
    CAReview = "Approved",
    NA_character_
  )
}

route_target_label <- function(role, person) {
  person <- trimws(as.character(person %||% ""))
  if (!nzchar(person) || identical(tolower(person), "unassigned")) role else paste(role, "-", person)
}

plan_review_route_choices <- function(db = NULL, plan = NULL) {
  submitter_label <- "Entity"
  deputy_label <- if (!is.null(db) && !is.null(plan)) route_target_label("Deputy Mayor", plan_deputy_mayor_label(db, plan)) else "Deputy Mayor"
  ca_label <- if (!is.null(db) && !is.null(plan)) route_target_label("CA Office", plan_ca_office_label(db, plan)) else "CA Office"
  c(
    stats::setNames("Returned", submitter_label),
    stats::setNames("DeputyMayorReview", deputy_label),
    stats::setNames("CAReview", ca_label),
    "Ready for publish" = "Approved"
  )
}

admin_plan_review_route_choices <- function(db = NULL, plan = NULL) {
  submitter_label <- "Entity"
  reviewer_label <- if (!is.null(db) && !is.null(plan)) route_target_label("Reviewer", plan_reviewer_label(db, plan)) else "Reviewer"
  deputy_label <- if (!is.null(db) && !is.null(plan)) route_target_label("Deputy Mayor", plan_deputy_mayor_label(db, plan)) else "Deputy Mayor"
  ca_label <- if (!is.null(db) && !is.null(plan)) route_target_label("CA Office", plan_ca_office_label(db, plan)) else "CA Office"
  c(
    stats::setNames("Returned", submitter_label),
    stats::setNames("UnderReview", reviewer_label),
    stats::setNames("DeputyMayorReview", deputy_label),
    stats::setNames("CAReview", ca_label),
    "Ready for publish" = "Approved"
  )
}

plan_review_default_route <- function(plan_status) {
  plan_status <- as.character(plan_status %||% "")
  if (identical(plan_status, "CAReview")) return("Approved")
  if (identical(plan_status, "DeputyMayorReview")) return("CAReview")
  "DeputyMayorReview"
}

publishing_route_choices <- function(db = NULL, plan = NULL) {
  submitter_label <- if (!is.null(db) && !is.null(plan)) route_target_label("Submitter", plan_submitter_label(db, plan)) else "Submitter"
  reviewer_label <- if (!is.null(db) && !is.null(plan)) route_target_label("Reviewer", plan_reviewer_label(db, plan)) else "Reviewer"
  deputy_label <- if (!is.null(db) && !is.null(plan)) route_target_label("Deputy Mayor", plan_deputy_mayor_label(db, plan)) else "Deputy Mayor"
  ca_label <- if (!is.null(db) && !is.null(plan)) route_target_label("CA Office", plan_ca_office_label(db, plan)) else "CA Office"
  c(
    stats::setNames("Returned", submitter_label),
    stats::setNames("UnderReview", reviewer_label),
    stats::setNames("DeputyMayorReview", deputy_label),
    stats::setNames("CAReview", ca_label)
  )
}

approval_return_route_choices <- function(stage, db = NULL, plan = NULL) {
  reviewer_label <- if (!is.null(db) && !is.null(plan)) route_target_label("Reviewer", plan_reviewer_label(db, plan)) else "Reviewer"
  submitter_label <- if (!is.null(db) && !is.null(plan)) route_target_label("Submitter", plan_submitter_label(db, plan)) else "Submitter"
  deputy_label <- if (!is.null(db) && !is.null(plan)) route_target_label("Deputy Mayor", plan_deputy_mayor_label(db, plan)) else "Deputy Mayor"
  if (identical(as.character(stage), "CAOffice")) {
    choices <- c("DeputyMayorReview", "UnderReview", "Returned")
    names(choices) <- c(deputy_label, reviewer_label, submitter_label)
    return(choices)
  }
  choices <- c("UnderReview", "Returned")
  names(choices) <- c(reviewer_label, submitter_label)
  choices
}

measure_validation_chip <- function(measure) {
  approval_status <- if (!is.null(measure) && nrow(measure) && "approval_status" %in% names(measure)) measure$approval_status[[1]] else NA_character_
  if (!is.na(approval_status) && identical(approval_status, "Validated")) {
    status_chip("Validated", "success")
  } else {
    status_chip("Not Validated", "error")
  }
}

approval_stage_label <- function(stage) {
  switch(
    as.character(stage),
    Reviewer = "Reviewer",
    OPIApproval = "OPI",
    DeputyMayor = "Deputy Mayor",
    CAOffice = "CA Office",
    format_status(stage)
  )
}

approval_stage_stamp_label <- function(stage) {
  switch(
    as.character(stage),
    Reviewer = "Reviewer Approved",
    OPIApproval = "OPI Approved",
    DeputyMayor = "Deputy Mayor Approved",
    CAOffice = "CA Office Approved",
    paste(approval_stage_label(stage), "Approved")
  )
}

plan_has_approval_stamp <- function(db, plan_id, stage) {
  stamps <- db$workflow_plan_approval_stamp[db$workflow_plan_approval_stamp$plan_id == plan_id & db$workflow_plan_approval_stamp$approval_stage == stage, , drop = FALSE]
  nrow(stamps) > 0
}

plan_workflow_history_panel <- function(db, plan_id, can_add_admin_stamps = FALSE) {
  stamps <- db$workflow_plan_approval_stamp[db$workflow_plan_approval_stamp$plan_id == plan_id, , drop = FALSE]
  history <- db$workflow_plan_status_history[db$workflow_plan_status_history$plan_id == plan_id, , drop = FALSE]
  if (nrow(stamps)) stamps <- stamps[order(stamps$approved_at, stamps$stamp_id, decreasing = TRUE), , drop = FALSE]
  if (nrow(history)) history <- history[order(history$changed_at, history$history_id, decreasing = TRUE), , drop = FALSE]
  stamp_card <- function(stage) {
    rows <- stamps[stamps$approval_stage == stage, , drop = FALSE]
    if (!nrow(rows)) {
      return(div(class = "approval-stamp-card missing", div(class = "eyebrow", approval_stage_stamp_label(stage)), strong("Not stamped"), span("Awaiting approval stamp")))
    }
    row <- rows[1, , drop = FALSE]
    actor <- row$approved_by_name[[1]] %||% row$added_by_name[[1]] %||% "User not recorded"
    added_by <- row$added_by_name[[1]] %||% "User not recorded"
    div(
      class = "approval-stamp-card",
      div(class = "eyebrow", approval_stage_stamp_label(stage)),
      strong(actor),
      span(paste("Stamped", as.character(row$approved_at[[1]]))),
      if (!identical(actor, added_by)) span(paste("Added by", added_by))
    )
  }
  div(
    class = "history-modal-section history-modal-section-wide workflow-history-panel",
    h3("Plan Routing & Approval History"),
    div(
      class = "approval-stamp-grid",
      stamp_card("Reviewer"),
      stamp_card("OPIApproval"),
      stamp_card("DeputyMayor"),
      stamp_card("CAOffice")
    ),
    if (isTRUE(can_add_admin_stamps)) div(
      class = "admin-stamp-actions",
      lapply(c("Reviewer", "OPIApproval", "DeputyMayor", "CAOffice"), function(stage) {
        has_stamp <- plan_has_approval_stamp(db, plan_id, stage)
        tags$button(
          type = "button",
          class = paste("civic-button secondary small", if (has_stamp) "danger-lite" else ""),
          `data-plan-stamp-stage` = stage,
          `data-plan-stamp-action` = if (has_stamp) "remove" else "add",
          `data-plan-id` = plan_id,
          icon(if (has_stamp) "rotate-left" else "stamp"),
          paste(if (has_stamp) "Remove" else "Add", approval_stage_label(stage), "stamp")
        )
      })
    ),
    tags$details(
      class = "workflow-history-details",
      tags$summary("Routing history"),
      if (!nrow(history)) {
        p(class = "empty-state-copy", "No routing history has been recorded.")
      } else {
        div(
          class = "workflow-history-list",
          lapply(seq_len(nrow(history)), function(i) {
            div(
              class = "workflow-history-row",
              strong(paste(agency_plan_status(history$from_status[i]), "to", agency_plan_status(history$to_status[i]))),
              span(paste(as.character(history$changed_at[i]), "-", history$changed_by_name[i] %||% "User not recorded")),
              if (!is.na(history$notes[i]) && nzchar(history$notes[i])) p(history$notes[i])
            )
          })
        )
      }
    )
  )
}

review_score_legend <- function() {
  div(
    class = "review-score-legend",
    div(strong("1"), span("Incomplete")),
    div(strong("2"), span("Developing")),
    div(strong("3"), span("Strong")),
    div(strong("4"), span("Exemplary"))
  )
}

plan_review_criteria <- function(level) {
  criterion_rows <- function(section_code, criterion_code, label, weight, score1, score2, score3, score4) {
    data.frame(
      section_code = section_code,
      criterion_code = criterion_code,
      label = label,
      weight = weight,
      score1 = score1,
      score2 = score2,
      score3 = score3,
      score4 = score4,
      stringsAsFactors = FALSE
    )
  }
  goal_score1 <- c(
    "Goal is vague, initiative-based, or describes an activity rather than an intended result",
    "A Pillar Goal is named but the agency goal has no discernible connection to it",
    "Initiative is unrelated to the goal, or no initiative is identified",
    "Initiative is missing, a single vague phrase, or a restatement of the goal",
    "KPI measures only activity counts or outputs with no connection to the goal's intended result",
    "KPI is missing, undefined, or the calculation method is unclear",
    "No baseline and no target identified"
  )
  goal_score2 <- c(
    "Goal names an intended result but is missing two or more SMART elements (specific, measurable, achievable, relevant, time-bound); or mixes outcomes with activities",
    "The named Pillar Goal is a stretch; the connection requires significant inference or is only tangentially related",
    "A connection to the goal can be inferred but is not stated; the logic requires assumptions to follow",
    "Initiative is named but lacks scope, timeline, or ownership; feasibility is unclear",
    "KPI is partially aligned to the goal but primarily reflects workload, throughput, or a single narrow service area",
    "KPI is named but two or more required elements are absent (e.g., definition, data source, formula, direction of success, responsible owner)",
    "Some historical data exists but the baseline is incomplete, undated, or unreliable; no validated target is set"
  )
  goal_score3 <- c(
    "Goal is outcome-oriented and meets at least four SMART elements; may lack a clear time-bound element or have minor specificity gaps",
    "The named Pillar Goal is a reasonable match; the connection is logical but not a precise fit",
    "A logical link between the initiative and goal is present but the causal reasoning is not fully spelled out",
    "Initiative has a described scope and is generally feasible; timeline or ownership may be implied rather than explicit",
    "KPI is aligned to the goal and captures at least one meaningful outcome or leading indicator; may not fully reflect performance across all services or units contributing to the goal",
    "Most required elements are present; one or two have minor gaps in clarity, sourcing, or operationalization",
    "A baseline is established and a target exists, but the target lacks validation, a rationale for the level chosen, or a clear time-bound achievement date"
  )
  goal_score4 <- c(
    "Goal is fully SMART: specific, measurable, clearly outcome-based, realistic, and explicitly time-bound",
    "The named Pillar Goal is a clear and direct match for what the agency goal is trying to achieve",
    "The initiative clearly advances the goal; the causal logic - how this work produces the intended result - is explicitly stated",
    "Initiative has a clear scope, a defined or implied timeline, and explicit ownership; a reviewer could understand what is being done, by whom, and roughly when",
    "KPI clearly and directly measures whether the goal is being achieved; emphasizes outcomes and leading indicators; reflects performance across the services, initiatives, or units the goal encompasses",
    "All required elements are complete and clearly documented: definition, data source, formula or calculation method, direction of success, frequency, and responsible owner; a reviewer outside the agency could replicate the measure",
    "A reliable baseline is documented; a target, threshold, or SLA is clearly defined with a rationale, is time-bound, and is ready for management use"
  )
  criteria <- list(
    plan_overview = criterion_rows(
      "S1",
      c("OVERVIEW", "VISION"),
      c("Agency Overview", "Vision & Linkage to Mayor's Action Plan"),
      c(5, 5),
      c("Missing, placeholder, or too vague to convey agency purpose", "No connection to the Mayor's Action Plan is present, or the vision is missing entirely"),
      c("Describes activities or programs but does not articulate the agency's role in producing outcomes", "A reference to the Action Plan is included but feels appended or generic; the connection to the agency's actual work is not apparent"),
      c("Conveys agency purpose clearly but remains somewhat broad or operationally framed", "The vision reflects a plausible connection to the administration's strategic priorities, but the alignment is indirect or requires inference to follow"),
      c("Clear, concise, outcome-oriented statement of why the agency exists and what it aims to achieve", "The vision is clearly oriented toward the administration's strategic priorities; a reader can understand how the agency's work contributes to the Mayor's Action Plan without needing additional explanation")
    ),
    goal = criterion_rows(
      "S2",
      c("GOALQUAL", "PILLAR", "INITCOH", "INITCON", "KPIQUAL", "KPIDFN", "KPITGT"),
      c("Goal Quality", "Pillar Goal Alignment", "Strategic Coherence", "Concreteness of Initiative", "KPI Quality", "KPI Definition & Validation Rigor", "KPI Baseline & Target Readiness"),
      c(10, 7, 8, 7, 10, 10, 10),
      goal_score1,
      goal_score2,
      goal_score3,
      goal_score4
    ),
    service = criterion_rows(
      "S3",
      c("METQUAL", "METDFN", "METTGT"),
      c("Metric Quality", "Definition & Validation Rigor", "Baseline & Target Readiness"),
      c(5, 5, 5),
      c("Metrics are not aligned to the services being tracked, or only restate the KPI", "Metrics are missing, undefined, or cannot be consistently calculated", "No baseline or expected threshold identified for any metric"),
      c("Metrics are primarily workload or activity counts (e.g., number of permits issued, calls answered); provide limited insight into service quality or performance", "Metrics are named but two or more required elements are absent (definition, data source, formula, direction, owner)", "Some historical data exists but baselines are partial, undated, or inconsistent across metrics"),
      c("Metrics are aligned to the service and include useful process or service quality indicators; may lack leading measures or actionability for frontline managers", "Most required elements are present; one or two have minor gaps in clarity or operationalization", "Baselines are established for most metrics; targets or thresholds exist but may lack rationale, validation, or time-bound achievement dates"),
      c("Metrics are highly actionable, clearly aligned to specific services or initiatives, and include at least one leading indicator that helps managers diagnose performance and explain KPI results", "All required elements are complete and clearly documented: definition, data source, formula, direction of success, frequency, and responsible owner; a reviewer outside the agency could replicate the measure", "Baselines are documented and reliable; targets, thresholds, or SLAs are clearly defined with rationale, are time-bound, and are ready for management use")
    ),
    plan_measures = criterion_rows(
      "S3",
      "FAMMEAS",
      "Family of Measures",
      5,
      "All measures come from a single category (e.g., all outputs, all activity counts); no variation in measure type",
      "Measures span two categories (e.g., outputs and efficiency) but do not include effectiveness or outcome-level measures",
      "Measures span three or more categories (e.g., outputs, efficiency, and outcomes or quality); breadth is present but the highest-order measure for the service is not clearly identified",
      "Measures span as many categories as appropriate for the service; the highest-order measure type is used whenever possible."
    ),
    plan_risks = criterion_rows(
      "S5",
      "RISK",
      "Risk Identification",
      5,
      "No risk section is present, or risks listed are budget/staffing enhancement requests rather than genuine operational or external risks",
      "Risks are listed but are generic, boilerplate, or interchangeable across agencies (e.g., 'staff turnover,' 'budget cuts') with no agency-specific context",
      "Risks are generally plausible and agency-specific; some include context about likelihood or impact, but mitigations are absent or surface-level",
      "Risks are specific, realistic, and grounded in the agency's operating environment; each includes enough context to understand the potential impact, and at least some mitigations or contingencies are identified"
    ),
    plan_data = criterion_rows(
      "S6",
      "DATAREADY",
      "Data Infrastructure & Stewardship",
      10,
      "No data stewards identified and no description of how performance data is collected or maintained",
      "Data stewards are identified but are senior executives or directors rather than the staff who actually own and maintain the data; reporting pathway is unclear",
      "Data stewards are identified and are generally the correct operational owners of the data; reporting pathway is described but may have gaps in frequency, format, or accountability",
      "Clearly accountable data stewards who are knowledgeable about the data are identified by name or role; reporting pathway, frequency, and format are clearly described; the plan demonstrates data is ready to support ongoing performance management"
    )
  )
  criteria[[level]]
}

review_input_id <- function(prefix, section_code, criterion_code, target_type, target_id) {
  paste(prefix, section_code, criterion_code, target_type, if (is.na(target_id) || is.null(target_id)) "plan" else target_id, sep = "__")
}

review_existing_score <- function(scores, section_code, criterion_code, target_type = "plan", target_id = NA_integer_) {
  if (!nrow(scores)) return(data.frame())
  target_id_value <- if (is.na(target_id) || is.null(target_id)) NA_integer_ else as.integer(target_id)
  target_match <- if (is.na(target_id_value)) is.na(scores$target_id) else !is.na(scores$target_id) & scores$target_id == target_id_value
  rows <- scores[
    scores$section_code == section_code &
      scores$criterion_code == criterion_code &
      scores$target_type == target_type &
      target_match,
    ,
    drop = FALSE
  ]
  if (!nrow(rows)) return(rows)
  rows[1, , drop = FALSE]
}

review_criterion_reference <- function(criterion) {
  score_labels <- c(
    "1" = criterion$score1[[1]],
    "2" = criterion$score2[[1]],
    "3" = criterion$score3[[1]],
    "4" = criterion$score4[[1]]
  )
  tags$details(
    class = "review-criterion-reference",
    tags$summary("Rubric reference"),
    tags$ul(lapply(names(score_labels), function(score) tags$li(tags$strong(paste0(score, ": ")), score_labels[[score]])))
  )
}

review_score_controls <- function(scores, criteria, target_type = "plan", target_id = NA_integer_, editable = FALSE) {
  lapply(seq_len(nrow(criteria)), function(i) {
    criterion <- criteria[i, , drop = FALSE]
    existing <- review_existing_score(scores, criterion$section_code[[1]], criterion$criterion_code[[1]], target_type, target_id)
    score_value <- if (nrow(existing) && !is.na(existing$score[[1]])) as.character(existing$score[[1]]) else ""
    note_value <- if (nrow(existing) && !is.na(existing$justification[[1]])) existing$justification[[1]] else ""
    score_id <- review_input_id("review_score", criterion$section_code[[1]], criterion$criterion_code[[1]], target_type, target_id)
    notes_id <- review_input_id("review_notes", criterion$section_code[[1]], criterion$criterion_code[[1]], target_type, target_id)
    div(
      class = "review-score-row",
      `data-section-code` = criterion$section_code[[1]],
      `data-criterion-code` = criterion$criterion_code[[1]],
      `data-target-type` = target_type,
      `data-target-id` = if (is.na(target_id) || is.null(target_id)) "" else target_id,
      `data-weight` = criterion$weight[[1]],
      div(
        class = "review-score-label",
        strong(criterion$label[[1]]),
        span(paste0(criterion$weight[[1]], " pts")),
        review_criterion_reference(criterion)
      ),
      selectInput(score_id, "Score", choices = c("Not scored" = "", "1", "2", "3", "4"), selected = score_value, selectize = FALSE, width = "100%"),
      textAreaInput(notes_id, "Reviewer notes", value = note_value, rows = 2, width = "100%"),
      if (!editable) tags$script(HTML(sprintf("setTimeout(function(){var a=document.getElementById('%s');var b=document.getElementById('%s'); if(a)a.disabled=true; if(b)b.disabled=true;},0);", score_id, notes_id)))
    )
  })
}

review_score_block <- function(title, scores, criteria, target_type = "plan", target_id = NA_integer_, editable = FALSE, open = FALSE) {
  tags$details(
    class = "review-score-block",
    open = if (open) TRUE else NULL,
    tags$summary(title),
    div(class = "review-score-grid", review_score_controls(scores, criteria, target_type, target_id, editable))
  )
}

review_score_export_entries <- function(scores, criteria, target_type = "plan", target_id = NA_integer_) {
  lapply(seq_len(nrow(criteria)), function(i) {
    criterion <- criteria[i, , drop = FALSE]
    existing <- review_existing_score(scores, criterion$section_code[[1]], criterion$criterion_code[[1]], target_type, target_id)
    score_value <- if (nrow(existing) && !is.na(existing$score[[1]])) paste0(existing$score[[1]], "/4") else "Not scored"
    weighted_value <- if (nrow(existing) && "weighted_score" %in% names(existing) && !is.na(existing$weighted_score[[1]])) round(existing$weighted_score[[1]], 1) else ""
    note_value <- if (nrow(existing) && !is.na(existing$justification[[1]])) existing$justification[[1]] else ""
    list(
      criterion = criterion$label[[1]],
      score = score_value,
      weighted_score = weighted_value,
      notes = note_value
    )
  })
}

review_notes_summary <- function(review_bits) {
  feedback <- review_bits$feedback
  scores <- review_bits$scores
  notes <- character(0)
  if (nrow(feedback)) {
    # resolved_at IS NULL means "still outstanding on the plan's current
    # review round" -- submit_agency_plan() (R/database.R) stamps it on
    # resubmission, so a plan reviewed more than once doesn't keep
    # surfacing feedback from an earlier round it already addressed.
    priority_feedback <- feedback[feedback$return_required & is.na(feedback$resolved_at), , drop = FALSE]
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
    paste(fy_label(actual_years[1:4]), "Actual"),
    paste(fy_label(current_fy - 1), "Target"),
    paste(fy_label(current_fy - 1), "Actual"),
    paste(fy_label(current_fy), "Target"),
    paste(fy_label(current_fy + 1), "Target")
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
    div(
      class = "chip-row",
      status_chip(measure$measure_type[[1]], "primary"),
      status_chip(measure$desired_direction[[1]], "success"),
      measure_validation_chip(measure)
    ),
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
    validation_status = if (isTRUE(measure$validated[[1]]) && identical(measure$approval_status[[1]], "Validated")) "Validated" else "Not Validated",
    approval_status = measure$approval_status[[1]],
    columns = as.list(c(
      paste(fy_label(actual_years[1:4]), "Actual"),
      paste(fy_label(current_fy - 1), "Target"),
      paste(fy_label(current_fy - 1), "Actual"),
      paste(fy_label(current_fy), "Target"),
      paste(fy_label(current_fy + 1), "Target")
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

plan_export_payload <- function(db, plan_id, include_review = TRUE) {
  plan <- db$planning_agency_plan[db$planning_agency_plan$plan_id == plan_id, , drop = FALSE]
  if (!nrow(plan)) stop("Plan not found")
  agency <- db$reference_agency[db$reference_agency$agency_id == plan_accounting_agency_id(db, plan), , drop = FALSE]
  payload_preview <- plan_uses_draft_payload(plan)
  overview_draft <- if (payload_preview) section_draft_payload(db, plan_id, "overview") else NULL
  goals_draft <- if (payload_preview) section_draft_payload(db, plan_id, "goals") else NULL
  services_draft <- if (payload_preview) section_draft_payload(db, plan_id, "services") else NULL
  risks_draft <- if (payload_preview) section_draft_payload(db, plan_id, "risks") else NULL
  overview <- db$performance_overview_vision[db$performance_overview_vision$plan_id == plan_id, , drop = FALSE]
  goals <- db$performance_agency_goal[db$performance_agency_goal$plan_id == plan_id, , drop = FALSE]
  goals <- goals[order(goals$sort_order), , drop = FALSE]
  services <- db$performance_plan_service[db$performance_plan_service$plan_id == plan_id, , drop = FALSE]
  service_rows <- db$reference_service[db$reference_service$service_id %in% services$service_id, , drop = FALSE]
  # Reported 2026-08-05: a Mayoral Office's PDF/PPTX export showed a service
  # that shouldn't exist for it at all. plan_review_allowed_service_ids()
  # (app.R ~2930) already excludes exactly this case for the review page
  # (history_plan_modal(), added 2026-08-03) -- export never got the same
  # filter, so it rendered whatever raw performance.plan_service rows
  # existed regardless of whether the plan's entity is actually allowed to
  # have services.
  allowed_service_ids <- plan_review_allowed_service_ids(db, plan, service_rows$service_id)
  services <- services[services$service_id %in% allowed_service_ids, , drop = FALSE]
  service_rows <- service_rows[service_rows$service_id %in% allowed_service_ids, , drop = FALSE]
  risks <- db$performance_service_risk[db$performance_service_risk$plan_id == plan_id, , drop = FALSE]
  risks <- risks_with_draft_overlay(risks, plan_id, risks_draft)
  review_bits <- if (isTRUE(include_review)) review_summary_for_plan(db, plan_id) else list(review = NULL, scores = data.frame(), feedback = data.frame())
  scorable_plan_service_ids <- services$plan_service_id[services$service_id %in% scorable_service_rows(service_rows)$service_id]
  review_bits$scores <- filter_review_scores_to_scorable_services(review_bits$scores, scorable_plan_service_ids)
  current_fy <- max(db$planning_agency_plan$fiscal_year, na.rm = TRUE)
  overview_text <- if (nrow(overview)) overview$overview[[1]] else ""
  vision_text <- if (nrow(overview)) overview$vision[[1]] else ""
  web_address <- if (nrow(overview)) overview$web_address[[1]] else ""
  overview_text <- draft_value(overview_draft, "agency_summary", overview_text)
  vision_text <- draft_value(overview_draft, "agency_vision", vision_text)
  web_address <- draft_value(overview_draft, "agency_website", web_address)
  goal_targets <- plan_review_goal_target_ids(db, plan, goals)
  saved_goal_ids <- goal_targets$goal_id

  goal_payload <- lapply(seq_along(saved_goal_ids), function(i) {
    goal_key <- saved_goal_ids[[i]]
    goal_row <- goals[as.character(goals$agency_goal_id) == goal_key, , drop = FALSE]
    goal_id <- goal_targets$target_id[[i]]
    linked_initiatives <- if (nrow(goal_row)) {
      db$performance_agency_goal_initiative_link[db$performance_agency_goal_initiative_link$agency_goal_id == goal_row$agency_goal_id[[1]], , drop = FALSE]
    } else {
      data.frame()
    }
    initiative_rows <- if (nrow(linked_initiatives)) {
      db$performance_initiative[db$performance_initiative$initiative_id %in% linked_initiatives$initiative_id, , drop = FALSE]
    } else {
      data.frame(title = character())
    }
    linked_kpis <- if (nrow(goal_row)) {
      db$performance_pm_goal_link[db$performance_pm_goal_link$agency_goal_id == goal_row$agency_goal_id[[1]], , drop = FALSE]
    } else {
      data.frame(measure_id = integer())
    }
    goal_statement <- draft_value(goals_draft, paste0("goal_statement_", goal_key), if (nrow(goal_row)) goal_row$title[[1]] else "Untitled goal")
    initiative_titles <- if (!is.null(goals_draft) && !is.null(goals_draft$initiatives[[goal_key]])) {
      as.character(unlist(goals_draft$initiatives[[goal_key]]))
    } else {
      initiative_rows$title
    }
    initiative_titles <- initiative_titles[nzchar(trimws(initiative_titles))]
    kpi_ids <- if (!is.null(goals_draft) && !is.null(goals_draft$kpis[[goal_key]])) {
      suppressWarnings(as.integer(unlist(goals_draft$kpis[[goal_key]])))
    } else {
      linked_kpis$measure_id
    }
    kpi_ids <- kpi_ids[!is.na(kpi_ids)]
    alignment_code <- draft_value(goals_draft, paste0("goal_alignment_", goal_key), if (nrow(goal_row)) goal_row$alignment_code[[1]] else "")
    alignment_row <- db$reference_pillar_goal[db$reference_pillar_goal$goal_code == alignment_code, , drop = FALSE]
    alignment <- if (nrow(alignment_row)) {
      paste(alignment_row$goal_code[[1]], alignment_row$goal_title[[1]])
    } else if (nrow(goal_row)) {
      goal_row$alignment[[1]]
    } else {
      ""
    }
    list(
      title = goal_statement,
      initiatives = as.list(initiative_titles),
      kpis = Filter(Negate(is.null), lapply(kpi_ids, function(measure_id) measure_export_entry(db, measure_id, current_fy))),
      alignment = if (nzchar(alignment)) alignment else NULL,
      review_scores = if (isTRUE(include_review)) review_score_export_entries(review_bits$scores, plan_review_criteria("goal"), "goal", goal_id) else list()
    )
  })

  service_payload <- lapply(seq_len(nrow(service_rows)), function(i) {
    service_id <- service_rows$service_id[i]
    metric_ids <- if (!is.null(services_draft) && !is.null(services_draft$serviceMetrics[[service_id]])) {
      suppressWarnings(as.integer(unlist(services_draft$serviceMetrics[[service_id]])))
    } else {
      service_metric_ids(db, plan, service_id, include_ineligible = TRUE)
    }
    metric_ids <- metric_ids[!is.na(metric_ids)]
    plan_service <- services[services$service_id == service_rows$service_id[i], , drop = FALSE]
    plan_service_id <- if (nrow(plan_service)) plan_service$plan_service_id[[1]] else NA_integer_
    service_is_admin <- is_administration_service(service_rows[i, , drop = FALSE])
    description <- draft_value(services_draft, paste0("service_description_", service_id), service_rows$service_description[i])
    list(
      name = service_rows$service_name[i],
      description = description,
      service_type = service_rows$service_type[i],
      scoring_exempt = isTRUE(service_is_admin),
      metrics = if (service_is_admin) list() else Filter(Negate(is.null), lapply(metric_ids, function(measure_id) measure_export_entry(db, measure_id, current_fy))),
      review_scores = if (isTRUE(include_review) && !service_is_admin) review_score_export_entries(review_bits$scores, plan_review_criteria("service"), "service", plan_service_id) else list()
    )
  })

  list(
    fiscal_year = plan$fiscal_year[[1]],
    agency_name = plan_display_name(db, plan),
    status = agency_plan_status(plan$plan_status[[1]]),
    version = plan$version[[1]],
    budget_analyst = plan_budget_analyst_label(db, plan),
    performance_analyst = plan_reviewer_label(db, plan),
    deputy_mayor = plan_deputy_mayor_label(db, plan),
    ca_office = plan_ca_office_label(db, plan),
    overview = if (nrow(overview) || !is.null(overview_draft)) list(overview = overview_text, vision = vision_text, web_address = web_address) else list(),
    overview_scores = if (isTRUE(include_review)) review_score_export_entries(review_bits$scores, plan_review_criteria("plan_overview"), "plan", NA_integer_) else list(),
    include_review = isTRUE(include_review),
    review = if (isTRUE(include_review)) list(
      score = if (!is.null(review_bits$review)) score_out_of_100(review_bits$review$overall_score[[1]]) else "Not scored",
      notes = as.list(review_notes_summary(review_bits))
    ) else list(),
    goals = goal_payload,
    services = service_payload,
    risk_scores = if (isTRUE(include_review)) review_score_export_entries(review_bits$scores, plan_review_criteria("plan_risks"), "plan", NA_integer_) else list(),
    plan_scores = if (isTRUE(include_review)) c(
      review_score_export_entries(review_bits$scores, plan_review_criteria("plan_measures"), "plan", NA_integer_),
      review_score_export_entries(review_bits$scores, plan_review_criteria("plan_data"), "plan", NA_integer_)
    ) else list(),
    risks = lapply(seq_len(nrow(risks)), function(i) {
      list(
        category = risk_type_label(risks$risk_type[[i]]),
        description = risks$description[[i]]
      )
    })
  )
}

plan_export_python <- function() {
  configured <- Sys.getenv("PLAN_EXPORT_PYTHON")
  if (nzchar(configured) && file.exists(configured)) return(configured)
  for (candidate in c("python3", "python")) {
    python <- Sys.which(candidate)
    if (nzchar(python)) return(python)
  }
  stop("No Python executable is available for plan exports. Set PLAN_EXPORT_PYTHON or install python3.")
}

plan_export_pptx_template <- function() {
  configured <- Sys.getenv("PLAN_EXPORT_PPTX_TEMPLATE")
  if (nzchar(configured)) return(configured)
  file.path("templates", "agency-performance-plan-template.pptx")
}

build_plan_export_file <- function(db, plan_id, output_file, export_type, include_review = TRUE) {
  payload_file <- tempfile(fileext = ".json")
  jsonlite::write_json(plan_export_payload(db, plan_id, include_review), payload_file, auto_unbox = TRUE, null = "null", pretty = TRUE)
  script_path <- normalizePath(file.path("scripts", "build_plan_export.py"), winslash = "/", mustWork = TRUE)
  template_path <- plan_export_pptx_template()
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

history_plan_card <- function(db, plan, current_plan_id, submitter_value, can_submit_plan = FALSE) {
  review_bits <- review_summary_for_plan(db, plan$plan_id[[1]])
  review <- review_bits$review
  score_label <- if (!is.null(review)) score_out_of_100(review$overall_score[[1]]) else "No score yet"
  reviewer_label <- plan_reviewer_label(db, plan)
  is_current <- plan$plan_id[[1]] == current_plan_id
  drafts <- db$planning_plan_section_draft[db$planning_plan_section_draft$plan_id == plan$plan_id[[1]], , drop = FALSE]
  latest_draft <- if (nrow(drafts)) max(drafts$updated_at, na.rm = TRUE) else NA
  updated_label <- if (is_current && plan_is_editable(plan) && !is.na(latest_draft)) "Draft updated" else "Updated"
  updated_value <- if (is_current && plan_is_editable(plan) && !is.na(latest_draft)) latest_draft else plan$updated_at[[1]]
  readiness <- plan_readiness_summary(db, submitter_value, plan)
  div(
    class = paste("history-plan-card", if (is_current) "current" else ""),
    div(
      class = "history-plan-card-header",
      div(
        div(class = "eyebrow", if (is_current) "Current cycle" else "Past plan"),
        div(
          class = "history-plan-title-row",
          h2(performance_plan_title(db, plan)),
          div(
            class = "history-title-actions",
            tags$button(type = "button", class = "civic-button secondary small", `data-review-plan` = plan$plan_id[[1]], `data-include-review` = "false", icon("eye"), "View"),
            tags$button(type = "button", class = "civic-button secondary small", `data-export-plan` = plan$plan_id[[1]], `data-export-type` = "pdf", `data-include-review` = "false", icon("file-pdf"), "Export"),
            if (is_current && plan_is_editable(plan) && can_submit_plan) {
              tags$button(type = "button", class = "civic-button primary small", `data-submit-plan` = plan$plan_id[[1]], icon("paper-plane"), "Submit")
            }
          )
        ),
        div(
          class = "chip-row",
          status_chip(agency_plan_status(plan$plan_status[[1]]), status_tone(plan$plan_status[[1]])),
          status_chip(paste("Version", plan$version[[1]]), "primary")
        )
      ),
      div(class = "history-plan-updated", span(updated_label), strong(as.character(updated_value)))
    ),
    div(
      class = "history-modal-contact-stack history-card-contacts",
      p(class = "history-modal-contact", tags$strong("Budget Analyst: "), plan_budget_analyst_label(db, plan)),
      p(class = "history-modal-contact", tags$strong("Performance Analyst: "), plan_reviewer_label(db, plan)),
      p(class = "history-modal-contact", tags$strong("Deputy Mayor: "), plan_deputy_mayor_label(db, plan)),
      p(class = "history-modal-contact", tags$strong("CA Office Approver: "), plan_ca_office_label(db, plan))
    ),
    div(
      class = "history-review-box",
      div(class = "eyebrow", "Review"),
      div(
        class = "history-review-strip",
        div(span("Reviewer"), strong(reviewer_label)),
        div(span("Review status"), strong(if (!is.null(review) && isTRUE(review$review_complete[[1]])) "Complete" else if (!is.null(review)) "In progress" else "Not started")),
        div(span("Rubric grade"), strong(score_label)),
        div(
          class = "history-review-actions",
          tags$button(type = "button", class = "civic-button secondary small history-review-detail-button", `data-review-plan` = plan$plan_id[[1]], `data-include-review` = "true", icon("eye"), "View"),
          tags$button(type = "button", class = "civic-button secondary small", `data-export-plan` = plan$plan_id[[1]], `data-export-type` = "pdf", `data-include-review` = "true", icon("file-pdf"), "Export")
        )
      )
    ),
    div(
      class = "history-readiness-list",
      div(class = "eyebrow", "Plan readiness"),
      lapply(readiness$rows, function(row) snapshot_check_row(row$label, row$detail, row$complete))
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

page_plan_history <- function(db, agency_id, can_submit_plan = FALSE) {
  selected <- parse_submitter_value(agency_id)
  if (identical(selected$type, "entity")) {
    plans <- db$planning_agency_plan[!is.na(db$planning_agency_plan$entity_id) & db$planning_agency_plan$entity_id == selected$id, , drop = FALSE]
  } else {
    plans <- db$planning_agency_plan[!is.na(db$planning_agency_plan$agency_id) & db$planning_agency_plan$agency_id == selected$id, , drop = FALSE]
  }
  plans <- plans[order(plans$fiscal_year, decreasing = TRUE), , drop = FALSE]
  plan <- current_plan(db, agency_id)
  builder_page(
    performance_plan_title(db, plan, "Review Plan"),
    "Review prior submissions, current draft state, and export-ready plan content.",
    tagList(
      surface(
        "Plan Records",
        "Open plan details, review submitted content, and export the current plan.",
        div(
          class = "history-plan-list",
          lapply(seq_len(nrow(plans)), function(i) history_plan_card(db, plans[i, , drop = FALSE], plan$plan_id[[1]], agency_id, can_submit_plan))
        )
      )
    ),
    plan_id = plan$plan_id,
    section_key = "history",
    show_save = FALSE,
    show_status = FALSE
  )
}

history_plan_modal <- function(db, plan_id, can_edit_review = FALSE, can_assign_reviewer = FALSE, include_review = TRUE, full_page = FALSE, can_route_review = FALSE, can_approve_gate = FALSE, can_manage_deputy_stamp = FALSE, can_manage_ca_stamp = FALSE) {
  plan <- db$planning_agency_plan[db$planning_agency_plan$plan_id == plan_id, , drop = FALSE]
  if (!nrow(plan)) return(NULL)
  payload_preview <- plan_uses_draft_payload(plan)
  overview_draft <- if (payload_preview) section_draft_payload(db, plan_id, "overview") else NULL
  goals_draft <- if (payload_preview) section_draft_payload(db, plan_id, "goals") else NULL
  services_draft <- if (payload_preview) section_draft_payload(db, plan_id, "services") else NULL
  risks_draft <- if (payload_preview) section_draft_payload(db, plan_id, "risks") else NULL
  overview <- db$performance_overview_vision[db$performance_overview_vision$plan_id == plan_id, , drop = FALSE]
  goals <- db$performance_agency_goal[db$performance_agency_goal$plan_id == plan_id, , drop = FALSE]
  goals <- goals[order(goals$sort_order), , drop = FALSE]
  services <- db$performance_plan_service[db$performance_plan_service$plan_id == plan_id, , drop = FALSE]
  service_rows <- db$reference_service[db$reference_service$service_id %in% services$service_id, , drop = FALSE]
  allowed_service_ids <- plan_review_allowed_service_ids(db, plan, service_rows$service_id)
  services <- services[services$service_id %in% allowed_service_ids, , drop = FALSE]
  service_rows <- service_rows[service_rows$service_id %in% allowed_service_ids, , drop = FALSE]
  review_bits <- if (isTRUE(include_review)) review_summary_for_plan(db, plan_id) else list(review = NULL, scores = data.frame(), feedback = data.frame())
  risks <- db$performance_service_risk[db$performance_service_risk$plan_id == plan_id, , drop = FALSE]
  risks <- risks_with_draft_overlay(risks, plan_id, risks_draft)
  notes_summary <- review_notes_summary(review_bits)
  current_fy <- max(db$planning_agency_plan$fiscal_year, na.rm = TRUE)
  overview_text <- if (nrow(overview)) overview$overview[[1]] else ""
  vision_text <- if (nrow(overview)) overview$vision[[1]] else ""
  web_address <- if (nrow(overview)) overview$web_address[[1]] else ""
  overview_text <- draft_value(overview_draft, "agency_summary", overview_text)
  vision_text <- draft_value(overview_draft, "agency_vision", vision_text)
  web_address <- draft_value(overview_draft, "agency_website", web_address)
  goal_targets <- plan_review_goal_target_ids(db, plan, goals)
  saved_goal_ids <- goal_targets$goal_id
  selected_measure_ids <- plan_selected_measure_ids(db, plan, goals, service_rows)
  selected_measures <- db$performance_performance_measure[db$performance_performance_measure$measure_id %in% selected_measure_ids, , drop = FALSE]
  invalid_selected_measures <- selected_measures[is.na(selected_measures$approval_status) | selected_measures$approval_status != "Validated", , drop = FALSE]
  show_measure_validation_warning <- plan$plan_status[[1]] %in% submitted_plan_statuses() && nrow(invalid_selected_measures) > 0
  scorable_service_count <- nrow(scorable_service_rows(service_rows))
  scorable_plan_service_ids <- services$plan_service_id[services$service_id %in% scorable_service_rows(service_rows)$service_id]
  review_bits$scores <- filter_review_scores_to_scorable_services(review_bits$scores, scorable_plan_service_ids)
  expected_review_items <- plan_review_expected_count(length(saved_goal_ids), scorable_service_count)
  scored_review_items <- plan_review_scored_count(review_bits$scores)
  action_plan_alignment_met <- nrow(review_bits$scores) &&
    any(review_bits$scores$criterion_code == "PILLAR" & !is.na(review_bits$scores$score), na.rm = TRUE)
  assigned_reviewer_id <- if (!is.null(review_bits$review) && !is.na(review_bits$review$reviewer_id[[1]])) {
    as.character(review_bits$review$reviewer_id[[1]])
  } else if (!is.na(plan$assigned_reviewer[[1]])) {
    as.character(plan$assigned_reviewer[[1]])
  } else {
    ""
  }

  backdrop_attrs <- if (isTRUE(full_page)) {
    list(class = "plan-review-workspace")
  } else {
    list(class = "custom-modal-backdrop history-modal-backdrop", `data-close-input` = "close_history_plan_modal")
  }
  panel_class <- if (isTRUE(full_page)) "history-modal-panel plan-review-full-page" else "custom-modal history-modal-panel"
  panel <- div(
      class = panel_class,
      div(
        class = "custom-modal-header history-modal-header",
        div(
          div(class = "eyebrow", if (isTRUE(include_review)) "Plan review" else "Plan details"),
          div(
            class = "history-plan-title-row",
            h2(performance_plan_title(db, plan)),
            if (can_assign_reviewer && identical(plan$plan_status[[1]], "Approved")) {
              div(
                class = "history-title-actions approval-action-panel publishing-detail-actions",
                div(
                  class = "review-route-control",
                  selectInput(
                    "publishing_detail_route_status",
                    "Return to",
                    choices = publishing_route_choices(db, plan),
                    selected = "UnderReview",
                    selectize = FALSE,
                    width = "34rem"
                  )
                ),
                tags$button(type = "button", id = "return_publishing_plan", class = "civic-button secondary small", `data-plan-id` = plan_id, icon("route"), "Return"),
                tags$button(type = "button", id = "publish_plan", class = "civic-button primary small", `data-plan-id` = plan_id, icon("upload"), "Publish")
              )
            } else if (isTRUE(include_review) && can_assign_reviewer && !plan$plan_status[[1]] %in% c("Published", "Amended")) {
              div(
                class = "history-title-actions approval-action-panel review-approval-actions admin-review-route-actions",
                div(
                  class = "review-route-control",
                  selectInput(
                    "plan_review_next_status",
                    "Route to",
                    choices = admin_plan_review_route_choices(db, plan),
                    selected = plan_review_default_route(plan$plan_status[[1]]),
                    selectize = FALSE,
                    width = "34rem"
                  )
                ),
                tags$button(
                  type = "button",
                  id = "approve_plan_review",
                  class = "civic-button small primary",
                  `data-plan-review-id` = plan_id,
                  `data-approval-action` = "route",
                  icon("route"),
                  "Route to"
                )
              )
            } else if (isTRUE(include_review) && (can_route_review || can_assign_reviewer) && (
              plan$plan_status[[1]] %in% review_approvable_statuses() ||
                (plan_has_approval_stamp(db, plan_id, "Reviewer") && !isTRUE(can_assign_reviewer))
            )) {
              reviewer_has_stamp <- plan_has_approval_stamp(db, plan_id, "Reviewer")
              route_instead_of_rescind <- isTRUE(can_assign_reviewer)
              div(
                class = "history-title-actions approval-action-panel review-approval-actions",
                if ((can_route_review || route_instead_of_rescind) && plan$plan_status[[1]] %in% review_approvable_statuses()) div(
                  class = "review-route-control",
                  selectInput(
                    "plan_review_next_status",
                    "Route to",
                    choices = plan_review_route_choices(db, plan),
                    selected = plan_review_default_route(plan$plan_status[[1]]),
                    selectize = FALSE,
                    width = "34rem"
                  )
                ),
                tags$button(
                  type = "button",
                  id = "approve_plan_review",
                  class = paste("civic-button small", if (reviewer_has_stamp && !route_instead_of_rescind) "secondary danger-lite" else "primary"),
                  `data-plan-review-id` = plan_id,
                  `data-approval-action` = if (reviewer_has_stamp && !route_instead_of_rescind) "rescind" else "approve",
                  icon(if (reviewer_has_stamp && !route_instead_of_rescind) "rotate-left" else "circle-check"),
                  if (reviewer_has_stamp && !route_instead_of_rescind) "Reviewer Rescind" else "Route to"
                )
              )
            } else if (isTRUE(include_review) && isTRUE(can_approve_gate) && (
              plan$plan_status[[1]] %in% c("DeputyMayorReview", "CAReview") ||
                (plan_has_approval_stamp(db, plan_id, "DeputyMayor") && isTRUE(can_manage_deputy_stamp)) ||
                (plan_has_approval_stamp(db, plan_id, "CAOffice") && isTRUE(can_manage_ca_stamp))
            )) {
              gate_stage <- plan_gate_stage(plan$plan_status[[1]])
              if (
                is.na(gate_stage) ||
                  (identical(gate_stage, "DeputyMayor") && !isTRUE(can_manage_deputy_stamp)) ||
                  (identical(gate_stage, "CAOffice") && !isTRUE(can_manage_ca_stamp))
              ) {
                gate_stage <- if (plan_has_approval_stamp(db, plan_id, "CAOffice") && isTRUE(can_manage_ca_stamp)) "CAOffice" else "DeputyMayor"
              }
              gate_has_stamp <- plan_has_approval_stamp(db, plan_id, gate_stage)
              div(
                class = "history-title-actions approval-action-panel",
                div(
                  class = "approval-return-stack",
                  div(
                    class = "review-route-control approval-return-control",
                    selectInput(
                      "plan_gate_return_status",
                      "Return to",
                      choices = approval_return_route_choices(gate_stage, db, plan),
                      selected = if (identical(gate_stage, "CAOffice")) "DeputyMayorReview" else "UnderReview",
                      selectize = FALSE,
                      width = "100%"
                    )
                  ),
                  div(
                    class = "review-route-control approval-return-note",
                    textInput("plan_gate_return_note", "Return reason", value = "", placeholder = "Required note")
                  ),
                  tags$button(
                    type = "button",
                    id = "return_plan_gate",
                    class = "civic-button secondary small",
                    `data-plan-id` = plan_id,
                    `data-approval-stage` = gate_stage,
                    icon("reply"),
                    "Return"
                  )
                ),
                tags$button(
                  type = "button",
                  id = "approve_plan_gate",
                  class = paste("civic-button small", if (gate_has_stamp) "secondary danger-lite" else "primary"),
                  `data-plan-id` = plan_id,
                  `data-approval-stage` = gate_stage,
                  `data-approval-action` = if (gate_has_stamp) "rescind" else "approve",
                  icon(if (gate_has_stamp) "rotate-left" else "circle-check"),
                  if (gate_has_stamp) paste(approval_stage_label(gate_stage), "Rescind") else paste(approval_stage_label(gate_stage), "Approve")
                )
              )
            }
          ),
          div(class = "chip-row", status_chip(agency_plan_status(plan$plan_status[[1]]), status_tone(plan$plan_status[[1]])), status_chip(paste("Version", plan$version[[1]]), "primary")),
          div(
            class = "history-modal-contact-stack",
            p(class = "history-modal-contact", tags$strong("Performance Analyst: "), plan_reviewer_label(db, plan)),
            p(class = "history-modal-contact", tags$strong("Deputy Mayor: "), plan_deputy_mayor_label(db, plan)),
            p(class = "history-modal-contact", tags$strong("CA Office Approver: "), plan_ca_office_label(db, plan))
          )
        ),
        if (isTRUE(full_page)) actionButton("back_to_review_queue", label = tagList(icon("arrow-left"), "Back to queue"), class = "civic-button secondary small")
        else actionButton("close_history_plan_modal", "X", class = "icon-button history-modal-close", `aria-label` = "Close plan review")
      ),
      if (show_measure_validation_warning) div(
        class = "required-fields-note error-note plan-validation-warning",
        strong("Warning: submitted plan includes non-validated measures."),
        span(paste(
          "Not validated:",
          paste(head(invalid_selected_measures$title, 5), collapse = ", "),
          if (nrow(invalid_selected_measures) > 5) paste("and", nrow(invalid_selected_measures) - 5, "more") else ""
        ))
      ),
      if (isTRUE(include_review)) plan_workflow_history_panel(db, plan_id, can_add_admin_stamps = can_assign_reviewer),
      if (isTRUE(include_review)) div(
        class = "review-modal-summary",
        `data-expected-review-items` = expected_review_items,
        div(
          class = "review-summary-feedback",
          div(class = "eyebrow", "Assigned reviewer"),
          if (can_assign_reviewer) div(
            class = "reviewer-assignment-panel",
            div(
              class = "measure-field",
              selectInput(
                "plan_review_reviewer_id",
                "Assigned reviewer",
                choices = plan_reviewer_choices(db),
                selected = assigned_reviewer_id,
                selectize = TRUE
              )
            ),
            tags$button(type = "button", id = "save_plan_reviewer", class = "civic-button secondary small", `data-plan-review-id` = plan_id, icon("user-check"), "Save reviewer")
          ) else div(
            class = "assigned-reviewer-readonly",
            strong(plan_reviewer_label(db, plan))
          )
        ),
        div(
          class = "review-summary-card",
          span("Overall score"),
          # Frozen at whatever it was when this page/modal last rendered --
          # the autosave observer (plan_review_save_request) deliberately
          # skips a server re-render on every scoring tick (see its comment)
          # to avoid collapsing open goal/service drawers, so this card
          # doesn't update again during the same session on its own.
          # handlePlanReviewSaveResult() in app.js patches this element's
          # text directly from the same save result that updates the
          # autosave status line, so both stay in sync without a re-render.
          strong(id = "review_overall_score_value", if (!is.null(review_bits$review)) score_out_of_100(review_bits$review$overall_score[[1]]) else "Not scored")
        ),
        div(
          class = "review-summary-card",
          span("Rubric progress"),
          strong(class = "review-progress-value", paste0(scored_review_items, " of ", expected_review_items))
        ),
        div(
          class = "review-summary-card",
          span("Goals to score"),
          strong(length(saved_goal_ids))
        ),
        div(
          class = "review-summary-card",
          span("Services to score"),
          strong(scorable_service_count)
        ),
        div(
          class = "review-summary-card",
          span("Action Plan alignment"),
          strong(id = "review_alignment_value", if (action_plan_alignment_met) "Met" else "7 point penalty")
        )
      ),
      div(
        class = "history-modal-grid",
        div(
          class = "history-modal-section history-modal-section-wide",
          h3("Overview & Vision"),
          if (nrow(overview) || !is.null(overview_draft)) tagList(
            p(tags$strong("Overview: "), overview_text),
            p(tags$strong("Vision: "), vision_text),
            p(tags$strong("Web address: "), web_address),
            if (isTRUE(include_review)) review_score_block("Score overview and vision", review_bits$scores, plan_review_criteria("plan_overview"), "plan", NA_integer_, can_edit_review, open = TRUE)
          ) else tagList(
            p("No overview record is available for this plan."),
            if (isTRUE(include_review)) review_score_block("Score overview and vision", review_bits$scores, plan_review_criteria("plan_overview"), "plan", NA_integer_, can_edit_review, open = TRUE)
          )
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
              ,
              if (isTRUE(include_review)) tags$details(
                class = "review-score-block",
                tags$summary("Score this goal"),
                div(class = "review-score-grid", review_score_controls(review_bits$scores, plan_review_criteria("goal"), "goal", goal_targets$target_id[[i]], can_edit_review))
              )
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
            service_is_admin <- is_administration_service(service_rows[i, , drop = FALSE])
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
              if (service_is_admin) div(class = "required-fields-note", "Administration service: not scored and no service metrics required this cycle."),
              if (length(metric_ids)) tagList(
                div(class = "eyebrow", "Performance Metrics"),
                div(class = "history-measure-list", lapply(metric_ids, function(measure_id) measure_history_card(db, measure_id, current_fy)))
              ),
              if (isTRUE(include_review) && !service_is_admin) tags$details(
                class = "review-score-block",
                tags$summary("Score this service"),
                div(
                  class = "review-score-grid",
                  review_score_controls(
                    review_bits$scores,
                    plan_review_criteria("service"),
                    "service",
                    services$plan_service_id[match(service_id, services$service_id)],
                    can_edit_review
                  )
                )
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
          lapply(seq_len(nrow(risks)), function(i) {
            div(
              class = "history-modal-record",
              div(class = "chip-row", status_chip(risk_type_label(risks$risk_type[i]), "primary")),
              p(risks$description[i])
            )
          }),
          if (isTRUE(include_review)) review_score_block("Score risks and dependencies", review_bits$scores, plan_review_criteria("plan_risks"), "plan", NA_integer_, can_edit_review, open = TRUE)
        ) else tagList(
          p("No risks are available for this plan."),
          if (isTRUE(include_review)) review_score_block("Score risks and dependencies", review_bits$scores, plan_review_criteria("plan_risks"), "plan", NA_integer_, can_edit_review, open = TRUE)
        )
      ),
      if (isTRUE(include_review)) div(
        class = "history-modal-section review-rubric-section",
        h3("Plan-Level Review Scores"),
        p("Enter 1-4 scores for whole-plan criteria. Goal, service, overview, and risk criteria are scored beside their content above. Family of Measures applies to the whole plan."),
        div(
          class = "review-score-stack",
          review_score_block("Family of Measures", review_bits$scores, plan_review_criteria("plan_measures"), "plan", NA_integer_, can_edit_review, open = TRUE),
          review_score_block("Data & Reporting Readiness", review_bits$scores, plan_review_criteria("plan_data"), "plan", NA_integer_, can_edit_review, open = TRUE)
        ),
        textAreaInput("plan_review_internal_notes", "Internal reviewer notes", value = if (!is.null(review_bits$review) && !is.na(review_bits$review$internal_notes[[1]])) review_bits$review$internal_notes[[1]] else "", rows = 3)
      ),
      if (isTRUE(include_review) && can_edit_review) div(
        class = "review-save-bar",
        `data-expected-review-items` = expected_review_items,
        div(
          span(class = "review-save-status", "Review autosaves as you score."),
          strong(class = "review-progress-value", paste0(scored_review_items, " of ", expected_review_items, " scored"))
        ),
        tags$span(id = "save_plan_review_scores", `data-plan-review-id` = plan_id, class = "review-autosave-anchor", `aria-hidden` = "true")
      )
  )
  do.call(div, c(backdrop_attrs, list(panel)))
}

measure_label <- function(text, help, required = FALSE) {
  tags$span(
    class = "field-label-with-help",
    span(text),
    if (required) span(class = "required-marker", "Required"),
    tags$span(class = "field-help-icon", tabindex = "0", title = help, `aria-label` = paste(text, "guidance"), "?")
  )
}

# Recursively adds a disabled attribute to the actual <input>/<textarea>/
# <select> nested inside a Shiny widget's tag (Shiny's textInput() etc.
# don't take a disabled argument directly, and disabling the outer
# wrapper div wouldn't do anything). Used to lock definition fields on a
# validated measure without duplicating each field's whole render block
# into an editable/read-only branch.
disable_input_tag <- function(tag, disabled = TRUE) {
  if (!isTRUE(disabled)) return(tag)
  walk <- function(node) {
    if (inherits(node, "shiny.tag")) {
      if (node$name %in% c("input", "textarea", "select")) {
        node$attribs$disabled <- "disabled"
      }
      if (length(node$children)) node$children <- lapply(node$children, walk)
      return(node)
    }
    if (is.list(node)) return(lapply(node, walk))
    node
  }
  walk(tag)
}

measure_note_input <- function(input_id, label, value = "", locked = FALSE) {
  note_value <- if (is.null(value) || length(value) == 0 || is.na(value)) "" else as.character(value)
  textarea_attrs <- list(id = input_id, class = "form-control", rows = 2, maxlength = 340, note_value)
  if (locked) textarea_attrs$disabled <- "disabled"
  div(
    class = paste("form-group shiny-input-container", if (locked) "measure-note-locked"),
    tags$label(class = "control-label", `for` = input_id, label),
    do.call(tags$textarea, textarea_attrs)
  )
}

measure_value_input <- function(input_id, label, value = NA, format_type = "Count", locked = FALSE) {
  format_class <- paste0("format-", tolower(format_type))
  input_value <- if (is.null(value) || length(value) == 0 || is.na(value)) NULL else as.character(value)
  input_attrs <- list(
    id = input_id,
    class = "form-control measure-value-input",
    type = "number",
    value = input_value,
    step = "0.01",
    inputmode = "decimal",
    `data-value-role` = if (grepl("_target_", input_id, fixed = TRUE)) "target" else "actual"
  )
  if (identical(format_type, "Percent")) {
    input_attrs$min <- "0"
    input_attrs$max <- "100"
  }
  if (locked) input_attrs$disabled <- "disabled"
  div(
    class = paste("measure-number-field", format_class, if (locked) "measure-value-locked"),
    div(
      class = "form-group shiny-input-container",
      tags$label(class = "control-label", `for` = input_id, label),
      do.call(tags$input, input_attrs),
      # Rendered unconditionally (not gated on format_type == "Percent")
      # and hidden by default via the measure-fraction-warning-hidden
      # class, so it already exists in the DOM even when the format
      # dropdown gets switched to Percent client-side without a reload --
      # otherwise a brand-new measure, or an existing one whose format is
      # being changed for the first time this session, would have nothing
      # for checkMeasureFractionWarning() in app.js to toggle. Toggled on
      # every keystroke, not just blur -- deliberately louder than a
      # corner notification (per Melanie 2026-08-04: the toast for this
      # exact case wasn't noticeable enough for this audience).
      div(class = "measure-fraction-warning measure-fraction-warning-hidden", icon("triangle-exclamation"), tags$span())
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

measure_modal_ui <- function(db, agency_id, measure_id = NULL, can_edit_scope = FALSE, target_fy = 2027, can_edit_form = TRUE, can_delete_measure = FALSE, can_edit_locked_data = FALSE, default_is_city = FALSE, show_owning_entity_picker = FALSE) {
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
  # Once a measure is Validated, its definition locks to SystemAdmin only --
  # but unlocks again if it's later forced back to Draft (e.g. a required
  # field going missing), so the submitter can fix it. Historic fiscal-year
  # data is different: it locks once the measure has EVER been validated
  # and stays locked even through a later Draft downgrade, plus the current
  # fiscal year's actual (still being actively reported) and the following
  # fiscal year's target (still being actively planned) always stay open.
  # See measure_actual_is_locked()/measure_target_is_locked()/
  # measure_definition_is_locked() in R/database.R for the shared,
  # date-driven rule, enforced again server-side in
  # collect_measure_form()/collect_measure_years() and
  # save_measure_record() regardless of what this UI renders.
  is_measure_validated <- identical(status, "Validated")
  measure_ever_validated_flag <- is_measure_validated || measure_ever_validated(value("ever_validated_at", NA))
  missing_required_fields <- if (is_new) character(0) else measure_missing_required_fields(as.list(measure))
  # can_edit_form being FALSE (e.g. a shared-service measure not owned by
  # the current viewer -- see current_user_can_edit_measure()) used to only
  # set a data-can-edit="false" attribute for client-side JS to disable,
  # but that JS (initializeReadOnlyModals()) is wired to a MutationObserver
  # on #page, and this modal renders in a separate uiOutput("measure_modal")
  # outside #page -- so it never actually ran, and the form looked
  # editable even though persist_measure() correctly rejected the save
  # server-side. Folding it into definition_locked disables every field
  # directly in the server-rendered HTML instead, the same reliable
  # mechanism already used for the Validated-measure lock.
  form_locked <- !isTRUE(can_edit_form)
  definition_locked <- (measure_definition_is_locked(is_measure_validated) && !can_edit_locked_data) || form_locked
  effective_can_edit_scope <- can_edit_scope && !definition_locked
  status_meta <- if (is_new) list(label = "Draft", tone = "warning") else measure_library_status(measure)
  selected_format <- if (value("format_type", "Count") %in% c("Percent", "Count", "Currency", "N/A")) value("format_type", "Count") else "Count"
  format_choices <- if (identical(selected_format, "N/A")) c("N/A (legacy)" = "N/A", "Percent" = "Percent", "Count" = "Count", "Currency" = "Currency") else c("Percent", "Count", "Currency")
  selected_display_unit <- value("display_unit")
  measure_review_history <- if (is_new) data.frame() else measure_reviews_for(db, measure_id)
  selected_pillar_id <- value("pillar_id")
  selected_pillar <- db$reference_pillar[db$reference_pillar$pillar_id == selected_pillar_id, , drop = FALSE]
  selected_pillar_goal_id <- value("pillar_goal_id")
  selected_pillar_goal <- db$reference_pillar_goal[db$reference_pillar_goal$pillar_goal_id == selected_pillar_goal_id, , drop = FALSE]
  pillar_label <- if (nrow(selected_pillar)) selected_pillar$pillar_name[[1]] else "Not linked"
  pillar_goal_label <- if (nrow(selected_pillar_goal)) paste(selected_pillar_goal$goal_code[[1]], selected_pillar_goal$goal_title[[1]]) else "Not linked"
  scope_city <- isTRUE(value("is_city", default_is_city))
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
    `data-can-edit` = if (can_edit_form) "true" else "false",
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
        if (form_locked) {
          div(
            class = "measure-validated-lock-note measure-shared-lock-note",
            icon("lock"),
            "This measure belongs to a shared service and can only be edited by its own entity or a System Admin. You can view it, but Save and Submit are disabled."
          )
        },
        if (definition_locked && !form_locked) {
          div(
            class = "measure-validated-lock-note",
            icon("lock"),
            paste0(
              "This measure is validated and locked to system admins, except the ",
              fy_label(current_fiscal_year()), " actual and the ", fy_label(current_fiscal_year() + 1L), " target."
            )
          )
        },
        if (!is_new && identical(status, "Draft") && length(missing_required_fields)) {
          div(
            class = "measure-validated-lock-note measure-draft-incomplete-note",
            icon("triangle-exclamation"),
            paste0(
              "Draft: missing required fields -- ", paste(missing_required_fields, collapse = ", "), ". ",
              if (measure_ever_validated_flag) "Historic fiscal-year data from before this measure's last validation stays locked in the meantime." else "Complete these fields before submitting for approval."
            )
          )
        },
        {
          review_history_blocks <- measure_review_history_blocks(measure_review_history)
          if (!is.null(review_history_blocks)) {
            tags$section(
              class = "modal-section-block measure-review-feedback",
              h3("Reviewer Feedback"),
              # Every past round that left feedback, newest first -- not
              # just the latest, so a measure returned more than once shows
              # what earlier rounds asked for too (2026-08-04).
              review_history_blocks
            )
          }
        },
        tags$section(
          class = "modal-section-block measure-form-section",
          h3("Definition"),
          div(
            class = "measure-form-grid",
            if (is_new && show_owning_entity_picker) {
              owning_choices <- agency_selector_choices(db)
              div(
                class = "measure-field full-width",
                selectInput(
                  "measure_owning_entity",
                  measure_label("Owning agency", "Griffin files this measure under whichever agency or entity owns it. If there's no clear single owner, leave this set to Mayor's Office (Office of Performance and Innovation).", TRUE),
                  choices = owning_choices,
                  selected = default_owning_measure_choice(owning_choices),
                  selectize = FALSE
                )
              )
            },
            div(class = "measure-field full-width", disable_input_tag(textInput("measure_title", measure_label("Measure name", "Use a concise name that clearly identifies the outcome, output, efficiency, or effectiveness being tracked.", TRUE), value = value("title")), definition_locked)),
            div(class = "measure-field full-width", disable_input_tag(textAreaInput("measure_description", measure_label("Definition", "Define exactly what is being measured so a reviewer can understand the measure without additional context.", TRUE), rows = 3, value = value("description")), definition_locked)),
            div(class = "measure-field", disable_input_tag(selectInput("measure_type", measure_label("Measure type", "Classify the measure as output, efficiency, effectiveness, or outcome based on what it tells reviewers about performance.", TRUE), choices = c("Output", "Efficiency", "Effectiveness", "Outcome"), selected = value("measure_type", "Outcome"), selectize = FALSE), definition_locked)),
            div(class = "measure-field", disable_input_tag(selectInput("measure_direction", measure_label("Desired direction", "Select whether successful performance should increase, decrease, maintain, or not apply to this value.", TRUE), choices = c("Increase", "Decrease", "Maintain", "Not Applicable"), selected = value("desired_direction", "Increase"), selectize = FALSE), definition_locked)),
            div(class = "measure-field", disable_input_tag(selectInput("measure_format", measure_label("Format", "Select how this value should be displayed. New measures use Percent, Count, or Currency; N/A is preserved for legacy measures.", TRUE), choices = format_choices, selected = selected_format, selectize = FALSE), definition_locked)),
            div(class = "measure-field", disable_input_tag(selectInput("measure_unit", measure_label("Display unit", "Optional label for the unit shown with the value, such as residents, permits, or dollars."), choices = display_unit_choices(db, selected_display_unit), selected = selected_display_unit, selectize = FALSE), definition_locked)),
            div(class = "measure-field", disable_input_tag(numericInput("measure_baseline", measure_label("Baseline value", "Enter the starting value used to compare future progress."), value = value("baseline_value", NA)), definition_locked)),
            div(class = "measure-field", disable_input_tag(numericInput("measure_baseline_fy", measure_label("Baseline fiscal year", "Enter the fiscal year for the baseline value."), value = value("baseline_fy", 2026), min = 2000, max = 2100), definition_locked))
          )
        ),
        tags$section(
          class = "modal-section-block measure-form-section",
          h3("Data Source & Ownership"),
          div(
            class = "measure-form-grid",
            div(class = "measure-field full-width", disable_input_tag(textInput("measure_data_source", measure_label("Data source", "Name the system, report, dataset, or official source used to produce this measure.", TRUE), value = value("data_source")), definition_locked)),
            div(class = "measure-field", disable_input_tag(textInput("measure_data_owner", measure_label("Data owner", "Name the person or team responsible for the source data.", TRUE), value = value("data_owner")), definition_locked)),
            div(class = "measure-field", disable_input_tag(textInput("measure_data_owner_role", measure_label("Data owner role", "Identify the title or role accountable for maintaining and validating the data.", TRUE), value = value("data_owner_role")), definition_locked)),
            div(class = "measure-field", disable_input_tag(textInput("measure_frequency", measure_label("Update frequency", "State how often the measure can be updated, such as monthly, quarterly, annually, or daily.", TRUE), value = value("update_frequency")), definition_locked)),
            div(class = "measure-field", disable_input_tag(textInput("measure_data_location", measure_label("Data location", "Describe where the underlying data lives, such as a database, spreadsheet, system export, or public report.", TRUE), value = value("data_location")), definition_locked)),
            div(class = "measure-field full-width", disable_input_tag(textAreaInput("measure_formula", measure_label("Formula or calculation", "Document the calculation clearly enough that another reviewer could reproduce the result.", TRUE), rows = 2, value = value("formula")), definition_locked)),
            div(class = "measure-field full-width", disable_input_tag(textAreaInput("measure_collection_method", measure_label("Collection method", "Describe how the data is collected, compiled, refreshed, or quality checked.", TRUE), rows = 2, value = value("collection_method")), definition_locked))
          )
        ),
        tags$section(
          class = "modal-section-block measure-form-section",
          h3("Validation Criteria"),
          div(
            class = "measure-form-grid",
            div(class = "measure-field full-width", disable_input_tag(textAreaInput("measure_context", measure_label("Context required for interpretation", "Note caveats, comparison limits, seasonality, policy changes, or other context needed to interpret the value responsibly."), rows = 2, value = value("context_required")), definition_locked)),
            if (effective_can_edit_scope) {
              div(class = "measure-field checkbox-field", checkboxInput("measure_replicability", "Calculation is replicable", value = isTRUE(value("replicability", FALSE))), p(class = "field-inline-help", "Reviewer/admin field: a reviewer should be able to recreate the value from the formula and source data."))
            } else {
              div(class = "measure-scope-options scope-derived", div(class = "scope-derived-grid", span("Calculation is replicable"), strong(if (isTRUE(value("replicability", FALSE))) "Yes" else "Not yet validated")), p(class = "scope-admin-note", if (definition_locked) "This measure is validated -- only a system admin can change this now." else "This validation field is completed by OPI reviewers or system admins."))
            },
            div(class = "measure-field", disable_input_tag(textInput("measure_disaggregation", measure_label("Disaggregation", "List available breakdowns, such as geography, demographic group, program, facility, district, or service type."), value = value("disaggregation")), definition_locked)),
            div(class = "measure-field full-width", disable_input_tag(textAreaInput("measure_how_used", measure_label("How the data is used", "Explain how the agency uses this measure for management, budgeting, service improvement, or public accountability.", TRUE), rows = 2, value = value("how_data_used")), definition_locked)),
            div(class = "measure-field full-width", disable_input_tag(textAreaInput("measure_why_meaningful", measure_label("Why this measure is meaningful", "Explain why this measure is a useful signal of resident outcomes, service quality, efficiency, or operational performance."), rows = 2, value = value("why_meaningful")), definition_locked)),
            div(class = "measure-field full-width", disable_input_tag(textAreaInput("measure_proxy", measure_label("Proxy measure or limitations", "Describe whether this is a proxy for a harder-to-measure outcome and name important limitations."), rows = 2, value = value("proxy_measure")), definition_locked)),
            div(class = "measure-field full-width", disable_input_tag(textAreaInput("measure_improvement_notes", measure_label("Improvement notes", "Identify needed improvements to data quality, frequency, definition, validation, or reporting."), rows = 2, value = value("improvement_notes")), definition_locked)),
            if (effective_can_edit_scope) {
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
                p(class = "scope-admin-note", if (definition_locked) "This measure is validated -- only a system admin can change this now." else "Action Plan metric alignment is system-admin managed.")
              )
            },
            if (effective_can_edit_scope) {
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
          if (measure_ever_validated_flag && !can_edit_locked_data) {
            p(
              class = "field-inline-help",
              paste0(
                if (is_measure_validated) "This measure is validated: only the " else "This measure was previously validated, and its historic data stays locked even while it's back in Draft: only the ",
                fy_label(current_fiscal_year() - 1L), " and ", fy_label(current_fiscal_year()),
                " actuals and the ", fy_label(current_fiscal_year() + 1L), " target can still be edited. Everything else is locked to system admins."
              )
            )
          },
          div(
            class = "measure-year-list",
            lapply(measure_entry_years(), function(year) {
              actual_locked <- (measure_actual_is_locked(year, measure_ever_validated_flag) && !can_edit_locked_data) || form_locked
              target_locked <- (measure_target_is_locked(year, measure_ever_validated_flag) && !can_edit_locked_data) || form_locked
              actual_admin_override <- measure_actual_is_locked(year, measure_ever_validated_flag) && can_edit_locked_data
              target_admin_override <- measure_target_is_locked(year, measure_ever_validated_flag) && can_edit_locked_data
              is_recent_actual_year <- year == fiscal_measure_snapshot_years()$actual_fy
              is_next_target_year <- year == target_fy
              div(
                class = "measure-year-row",
                h4(fy_label(year)),
                div(
                  class = if (is_recent_actual_year) "measure-year-highlight",
                  measure_value_input(paste0("measure_actual_", year), measure_label("Actual", "Enter the reported annual value for this fiscal year."), annual_value(year, "annual_actual", NA), selected_format, locked = actual_locked),
                  if (is_recent_actual_year) p(class = "field-inline-help", "Required to publish the plan -- not required to save or submit this measure."),
                  if (actual_admin_override) p(class = "field-inline-help measure-locked-admin-note", "Locked field -- add a note if you change this value.")
                ),
                div(
                  class = if (is_recent_actual_year) "measure-year-highlight",
                  measure_note_input(paste0("measure_actual_notes_", year), measure_label("Actual notes", "Note on data quality, revisions, unusual events, or interpretation. Maximum 200 characters."), annual_value(year, "annual_actual_notes"), locked = actual_locked),
                  if (is_recent_actual_year) p(class = "field-inline-help", "Required to publish the plan -- not required to save or submit this measure.")
                ),
                div(
                  class = if (is_next_target_year) "measure-year-highlight",
                  measure_value_input(paste0("measure_target_", year), measure_label("Target", "Enter the target value for this fiscal year."), annual_value(year, "target_value", NA), selected_format, locked = target_locked),
                  if (is_next_target_year) p(class = "field-inline-help", "Required to publish the plan -- not required to save or submit this measure."),
                  if (target_admin_override) p(class = "field-inline-help measure-locked-admin-note", "Locked field -- add a note if you change this value.")
                ),
                div(
                  class = if (is_next_target_year) "measure-year-highlight",
                  measure_note_input(paste0("measure_target_notes_", year), measure_label("Target notes", "Note explaining target rationale, assumptions, or revisions. Maximum 200 characters."), annual_value(year, "target_value_notes"), locked = target_locked),
                  if (is_next_target_year) p(class = "field-inline-help", "Required to publish the plan -- not required to save or submit this measure.")
                )
              )
            })
          )
        )
      ),
      div(
        class = "measure-modal-actions",
        div(
          if (!is_new && isTRUE(can_delete_measure)) tags$button(id = "delete_measure", type = "button", class = "civic-button danger small", disabled = if (form_locked) "disabled", icon("trash-can"), "Delete measure"),
          if (!is_new && isTRUE(value("active", TRUE))) tags$button(id = "request_measure_deactivate", type = "button", class = "civic-button danger small", disabled = if (form_locked) "disabled", icon("ban"), "Make inactive"),
          if (!is_new && !isTRUE(value("active", TRUE))) {
            reactivate_button <- actionButton("reactivate_measure", "Reactivate", class = "civic-button secondary small")
            if (form_locked) reactivate_button$attribs$disabled <- "disabled"
            reactivate_button
          },
          if (!is_new && is_measure_validated && isTRUE(can_edit_locked_data)) tags$button(id = "request_measure_revert_to_draft", type = "button", class = "civic-button secondary small", disabled = if (form_locked) "disabled", icon("rotate-left"), "Revert to Draft")
        ),
        div(
          class = "measure-submit-group",
          if (form_locked) p(class = "approval-workflow-note", "This measure is locked -- Save and Submit are disabled."),
          div(
            if (!form_locked) tags$span(
              class = "field-help-icon",
              tabindex = "0",
              title = "Saving allows the measure to be added to a goal or service. Submit for approval marks this measure pending while a system admin reviews and validates your measure once you submit. All measures in Agency Performance Plans must be validated.",
              `aria-label` = "Save and submit guidance",
              "?"
            ),
            tags$button(id = "save_measure", type = "button", class = "civic-button secondary", disabled = if (form_locked) "disabled", "Save"),
            tags$button(id = "submit_measure", type = "button", class = "civic-button primary", disabled = if (form_locked) "disabled", "Submit for approval")
          )
        )
      ),
      tags$dialog(
        id = "deactivate_measure_dialog",
        class = "confirmation-dialog",
        div(class = "confirmation-dialog-panel", div(class = "confirmation-dialog-icon", icon("triangle-exclamation")), h2("Are you sure you want to make this measure inactive?"), p("It will no longer be available for new Goal KPI or Service Metric selections. Its history will be retained."), div(class = "confirmation-dialog-actions", tags$button(id = "cancel_measure_deactivate", type = "button", class = "civic-button secondary small", "Cancel"), actionButton("confirm_deactivate_measure", "Make inactive", class = "civic-button danger small")))
      ),
      tags$dialog(
        id = "revert_measure_to_draft_dialog",
        class = "confirmation-dialog",
        div(class = "confirmation-dialog-panel", div(class = "confirmation-dialog-icon", icon("triangle-exclamation")), h2("Are you sure you want to revert this measure to Draft?"), p("This measure is currently Validated. Reverting to Draft unlocks its definition fields for editing and removes its validated status until it's resubmitted and re-approved."), div(class = "confirmation-dialog-actions", tags$button(id = "cancel_measure_revert_to_draft", type = "button", class = "civic-button secondary small", "Cancel"), actionButton("confirm_measure_revert_to_draft", "Revert to Draft", class = "civic-button secondary small")))
      )
    )
  )
}

page_metrics <- function(db, agency_id, status_filter = "All except deprecated") {
  plan <- current_plan(db, agency_id)
  measures <- measure_library_rows(db, plan, include_ineligible = TRUE)
  status_labels <- if (nrow(measures)) {
    vapply(seq_len(nrow(measures)), function(i) measure_library_status(measures[i, , drop = FALSE])$label, character(1))
  } else {
    character(0)
  }
  status_choices <- unique(c(measure_status_filter_choices(), sort(unique(status_labels))))
  selected_status <- status_filter %||% "All except deprecated"
  if (!selected_status %in% status_choices) selected_status <- "All except deprecated"
  if (identical(selected_status, "All except deprecated")) {
    measures <- measures[status_labels != "Deprecated", , drop = FALSE]
    status_labels <- status_labels[status_labels != "Deprecated"]
  } else if (!identical(selected_status, "All statuses")) {
    measures <- measures[status_labels == selected_status, , drop = FALSE]
    status_labels <- status_labels[status_labels == selected_status]
  }
  snapshot_years <- fiscal_measure_snapshot_years()
  builder_page(
    performance_plan_title(db, plan, "Measures"),
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
        div(
          class = "measure-library-search",
          tags$label(`for` = "measure_library_search", "Search"),
          tags$input(id = "measure_library_search", class = "form-control", type = "search", placeholder = "Search measures")
        ),
        span(class = "measure-library-count", paste(nrow(measures), if (nrow(measures) == 1) "measure" else "measures"))
      ),
      div(
        class = "app-table measure-library-table",
        div(
          class = "table-row table-head metrics-row",
          span("Measure"),
          span(paste(fy_label(snapshot_years$actual_fy), "Actual /", fy_label(snapshot_years$target_fy), "Target")),
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
            `data-measure-search` = tolower(paste(measures$title[i], actual, target, status_meta$label, format(as.POSIXct(measures$last_updated[i]), "%b %d, %Y"))),
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

# Every measure marked Citywide (is_city = TRUE), across every agency --
# the admin view for the Action Plan Measures feature. Reuses the same
# measure editor modal as the regular Measures page (data-measure-id /
# data-new-measure, handled by the same client-side click handler and
# open_measure_id observer) rather than a separate editor. Visible to the
# whole Performance Reviewing group; the modal's own can_edit_scope check
# still restricts who can actually mark a measure Citywide or change its
# pillar to SystemAdmin/OPIReviewer.
page_action_plan_measures <- function(db, can_edit_owner = FALSE) {
  measures <- db$city_measures
  owner_choices <- if (can_edit_owner) agency_selector_choices(db) else character(0)
  snapshot_years <- fiscal_measure_snapshot_years()
  missing_pillar_count <- if (nrow(measures)) sum(is.na(measures$pillar_id)) else 0L
  awaiting_data_count <- if (nrow(measures)) sum(is.na(measures$current_value) & is.na(measures$target_value)) else 0L
  tagList(
    div(
      class = "briefing-header compact",
      div(
        div(class = "eyebrow", "Performance Reviewing"),
        h1("Action Plan Measures"),
        p("Every measure marked Citywide, across all agencies. Open a measure to update its data, targets, or Action Plan pillar alignment.")
      )
    ),
    div(
      class = "dashboard-grid reviewer-dashboard-grid",
      metric_tile("Citywide measures", nrow(measures), "Marked is_city across all agencies"),
      metric_tile("Missing a pillar", missing_pillar_count, "Won't appear on any pillar's Action Plan view until assigned", if (missing_pillar_count) "warning" else "success"),
      metric_tile("Awaiting data", awaiting_data_count, paste0(fy_label(snapshot_years$actual_fy), " actual and ", fy_label(snapshot_years$target_fy), " target both blank"), if (awaiting_data_count) "warning" else "success")
    ),
    surface(
      "Citywide Measures",
      "When you add a Citywide measure, you'll pick its owning agency or entity directly in the form. Leave Mayor's Office selected for measures with no single clear owner (Office of Performance and Innovation).",
      if (!nrow(measures)) {
        div(class = "empty-state", h3("No measures are marked Citywide yet"), p("Open any measure and check \"Citywide measure\" (SystemAdmin/OPIReviewer only) to have it appear here."))
      } else {
        div(
          class = "app-table measure-library-table action-plan-measures-table",
          div(
            class = "table-row table-head action-plan-measures-row",
            span("Measure"),
            span("Pillar"),
            span("Owning agency"),
            span(paste(fy_label(snapshot_years$actual_fy), "Actual /", fy_label(snapshot_years$target_fy), "Target")),
            span("Status")
          ),
          lapply(seq_len(nrow(measures)), function(i) {
            status_meta <- measure_library_status(measures[i, , drop = FALSE])
            actual <- format_measure_value(measures$current_value[i], measures$format_type[i], measures$display_unit[i], "Not reported")
            target <- format_measure_value(measures$target_value[i], measures$format_type[i], measures$display_unit[i], "Not set")
            pillar_label <- if (is.na(measures$pillar_name[i])) "Not linked" else measures$pillar_name[i]
            agency_label <- if (!is.na(measures$agency_public_name[i]) && nzchar(measures$agency_public_name[i])) measures$agency_public_name[i] else measures$agency_name[i]
            current_owner_value <- if (!is.na(measures$owning_entity_id[i])) paste0("entity:", measures$owning_entity_id[i]) else paste0("agency:", measures$agency_id[i])
            owner_cell <- if (can_edit_owner) {
              tags$select(
                class = "form-control action-plan-measure-owner-select",
                `data-measure-id` = measures$measure_id[i],
                lapply(seq_along(owner_choices), function(choice_index) {
                  value <- unname(owner_choices[[choice_index]])
                  tags$option(value = value, selected = if (identical(value, current_owner_value)) "selected", names(owner_choices)[[choice_index]])
                })
              )
            } else {
              span(agency_label)
            }
            div(
              class = "table-row action-plan-measures-row measure-library-row",
              role = "button",
              tabindex = "0",
              `data-measure-id` = measures$measure_id[i],
              span(measures$title[i]),
              span(class = if (is.na(measures$pillar_name[i])) "action-plan-measure-unlinked", pillar_label),
              owner_cell,
              span(paste(actual, "/", target)),
              status_chip(status_meta$label, status_meta$tone)
            )
          })
        )
      },
      actions = tags$button(type = "button", class = "civic-button primary", `data-new-measure` = "true", `data-page` = "action_plan_measures", `data-default-city` = "true", icon("plus"), "Add a Citywide measure")
    )
  )
}

page_overview <- function(db, agency_id, can_edit_plan = TRUE) {
  plan <- current_plan(db, agency_id)
  mv <- db$performance_overview_vision[db$performance_overview_vision$plan_id == plan$plan_id, , drop = FALSE]
  builder_page(
    performance_plan_title(db, plan, "Overview & Vision"),
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
          div(class = "website-field", textInput("agency_website", "Agency public web address", value = mv$web_address))
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
    locked = !plan_is_editable(plan) || !can_edit_plan
  )
}

page_goals <- function(db, agency_id, can_edit_plan = TRUE) {
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
  editor_count <- max(1L, goal_count)
  pillar_goal_codes <- db$reference_pillar_goal$goal_code
  pillar_goal_labels <- paste(db$reference_pillar_goal$goal_code, db$reference_pillar_goal$goal_title)
  alignment_choices <- c("Not aligned" = "", setNames(pillar_goal_codes, pillar_goal_labels))
  kpi_choices <- setNames(agency_measures$measure_id, agency_measures$title)
  preview_years <- measure_preview_years()
  preview_all_years <- c(preview_years$actual_years, preview_years$target_years)
  recent_actual_fy <- preview_years$actual_years[length(preview_years$actual_years)]
  upcoming_target_fy <- preview_years$target_years[length(preview_years$target_years)]

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
    performance_plan_title(db, plan, "Goals, Initiatives & KPIs"),
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
          lapply(seq_len(editor_count), function(i) {
            is_seed_goal <- i <= goal_count
            goal_id <- if (is_seed_goal) as.character(goals$agency_goal_id[i]) else "draft-1"
            goal_title <- if (is_seed_goal) as.character(goals$title[i]) else ""
            if (is.na(goal_title)) goal_title <- ""
            goal_alignment <- if (is_seed_goal) as.character(goals$alignment_code[i]) else ""
            if (is.na(goal_alignment)) goal_alignment <- ""
            initiative_link <- if (is_seed_goal) {
              db$performance_agency_goal_initiative_link[db$performance_agency_goal_initiative_link$agency_goal_id == goal_id, , drop = FALSE]
            } else {
              db$performance_agency_goal_initiative_link[0, , drop = FALSE]
            }
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
            measure_link <- if (is_seed_goal) {
              db$performance_pm_goal_link[db$performance_pm_goal_link$agency_goal_id == goal_id, , drop = FALSE]
            } else {
              db$performance_pm_goal_link[0, , drop = FALSE]
            }
            selected_measure <- if (nrow(measure_link) > 0) as.character(measure_link$measure_id) else character(0)
            initial_kpis <- if (length(selected_measure) > 0) selected_measure else ""
            goal_kpi_select <- function(kpi_index, selected_value) {
              selected_value <- as.character(selected_value %||% "")
              select_id <- paste0("goal_kpi_", goal_id, "_", kpi_index)
              tags$select(
                id = select_id,
                name = select_id,
                class = "form-control goal-kpi-select",
                tags$option(value = "", selected = if (!nzchar(selected_value)) "selected", "Select a performance measure"),
                lapply(seq_along(kpi_choices), function(choice_index) {
                  value <- as.character(kpi_choices[[choice_index]])
                  label <- names(kpi_choices)[[choice_index]]
                  tags$option(
                    value = value,
                    selected = if (identical(value, selected_value)) "selected",
                    label
                  )
                })
              )
            }
            kpi_selector_rows <- lapply(seq_along(initial_kpis), function(kpi_index) {
              div(
                class = "kpi-select-row",
                goal_kpi_select(kpi_index, initial_kpis[kpi_index]),
                if (kpi_index > 1) tags$button(type = "button", class = "kpi-remove-button", title = "Remove KPI", `aria-label` = "Remove KPI", icon("xmark"))
              )
            })

            kpi_previews <- lapply(seq_len(nrow(agency_measures)), function(measure_index) {
              measure <- agency_measures[measure_index, , drop = FALSE]
              history <- db$performance_measure_actuals[db$performance_measure_actuals$measure_id == measure$measure_id, , drop = FALSE]
              actual_values <- vapply(preview_all_years, function(year) {
                row <- history[history$fiscal_year == year, , drop = FALSE]
                value <- if (nrow(row)) row$annual_actual[[1]] else NA_real_
                format_measure_value(value, measure$format_type[1], measure$display_unit[1])
              }, character(1))
              target_values <- vapply(preview_all_years, function(year) {
                row <- history[history$fiscal_year == year, , drop = FALSE]
                value <- if (nrow(row)) row$target_value[[1]] else NA_real_
                format_measure_value(value, measure$format_type[1], measure$display_unit[1], "Not set")
              }, character(1))

              div(
                class = paste("kpi-measure-preview", if (as.character(measure$measure_id) %in% selected_measure) "active" else ""),
                `data-measure-id` = as.character(measure$measure_id),
                title = "Click to review or edit this measure",
                div(
                  class = "kpi-preview-header",
                  div(h4(measure$title)),
                  div(
                    class = "chip-row",
                    status_chip(measure$measure_type, "primary"),
                    status_chip(measure$desired_direction, "success"),
                    measure_validation_chip(measure)
                  )
                ),
                div(
                  class = "kpi-history-wrap",
                  tags$table(
                    class = "kpi-history-table",
                    tags$caption(class = "sr-only", paste(measure$title, "actuals and targets by fiscal year")),
                    tags$thead(tags$tr(
                      tags$th(scope = "col", "Series"),
                      lapply(preview_all_years, function(year) tags$th(scope = "col", fy_label(year)))
                    )),
                    tags$tbody(
                      tags$tr(tags$th(scope = "row", "Actual"), history_row_cells(actual_values, preview_all_years, recent_actual_fy)),
                      tags$tr(tags$th(scope = "row", "Target"), history_row_cells(target_values, preview_all_years, upcoming_target_fy))
                    )
                  ),
                  p(class = "kpi-history-click-hint", icon("arrow-up-right-from-square"), "Click to review or edit this measure")
                )
              )
            })

            tags$details(
              class = "goal-editor",
              `data-goal-id` = goal_id,
              tags$summary(
                div(
                  class = "goal-editor-summary",
                  div(span(paste("Goal", i), class = "goal-number"), strong(if (nzchar(goal_title)) goal_title else "Untitled goal")),
                  status_chip(if (nzchar(goal_alignment)) "Action Plan Aligned" else "Not Action Plan Aligned", if (nzchar(goal_alignment)) "success" else "primary")
                )
              ),
              div(
                class = "goal-editor-body",
                `aria-hidden` = "true",
                div(
                  class = "goal-form-field full-width goal-statement-field",
                  tags$label(class = "control-label", `for` = paste0("goal_statement_", goal_id), "Goal statement"),
                  p(class = "goal-field-instruction", "Describe what your agency intends to achieve this fiscal year, expressed as an outcome for Baltimore residents. Your goal should be specific, measurable, and time-bound - not a description of work your agency will do."),
                  textAreaInput(paste0("goal_statement_", goal_id), label = NULL, rows = 3, value = goal_title)
                ),
                div(
                  class = "goal-form-field full-width initiative-picker",
                  tags$label(class = "control-label", `for` = paste0("goal_initiative_", goal_id), "FY27 initiatives"),
                  p(class = "goal-field-instruction", "Identify one key action or project your agency will undertake this year to advance this goal. Be specific about what will be done and who is responsible - avoid restating the goal in different words."),
                  div(class = "initiative-inputs", `data-goal-id` = goal_id, initiative_input_rows),
                  tags$button(type = "button", class = "civic-button secondary small add-initiative-button", icon("plus"), "Add initiative")
                ),
                div(
                  class = "goal-form-field",
                  selectInput(paste0("goal_alignment_", goal_id), "Action Plan Pillar Goal (optional, one agency goal must align)", choices = alignment_choices, selected = goal_alignment, selectize = FALSE)
                ),
                div(
                  class = "goal-form-field full-width kpi-picker",
                  tags$label(class = "control-label", `for` = paste0("goal_kpi_", goal_id, "_1"), "Key performance indicators"),
                  p(class = "goal-field-instruction", "Choose from the agency's validated performance measures. Review the measure definition and five-year history before selecting it."),
                  p(class = "goal-field-instruction", "Select the measure that best captures whether this goal is being achieved. Choose outcome or leading indicators where possible - avoid selecting measures that only count activity or workload. A KPI can also serve as a service-level metric; you may see the same measure appear in both places."),
                  if (length(selected_measure) > 5) div(class = "required-fields-note error-note", "This goal has more than 5 KPIs selected. Remove KPIs until 5 or fewer remain before saving."),
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
                    strong("Don't see the right KPI?"),
                    p("If none of the available measures adequately captures progress toward this goal, you can build a new measure. You'll be taken to the measure builder to define it - once submitted, it will be added to your agency's measure library and available for selection here."),
                  tags$button(type = "button", class = "civic-button secondary small", `data-page` = "metrics", `data-new-measure` = "true", icon("plus"), "Build a new measure")
                  )
                ),
                div(
                  class = "goal-editor-actions",
                  # Rendered for every goal, including the first -- JS
                  # (updateGoalControls() in app.js) enables/disables it
                  # based on the plan's actual minimum (data-min-goals
                  # above), not by singling out the first goal's position.
                  tags$button(type = "button", class = "civic-button danger small remove-goal-button", icon("trash-can"), "Remove goal")
                )
              )
            )
          })
        ),
        actions = tags$button(id = "add_goal", type = "button", class = "civic-button primary", disabled = if (editor_count >= maximum_goals) "disabled" else NULL, icon("plus"), "Add goal")
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
            tags$summary(div(strong("FY27 initiatives"), span("2 criteria"))),
            goal_rubric_table(
              "FY27 initiatives scoring rubric",
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
    locked = !plan_is_editable(plan) || !can_edit_plan
  )
}

page_services <- function(db, agency_id, can_edit_plan = TRUE, can_edit_shared_service_description = FALSE) {
  plan <- current_plan(db, agency_id)
  service_rows <- plan_service_rows(db, plan)
  measures <- eligible_plan_measures(measure_library_rows(db, plan, include_ineligible = FALSE))
  metric_choices <- setNames(measures$measure_id, measures$title)
  services_draft <- if (plan_uses_draft_payload(plan)) section_draft_payload(db, plan$plan_id[[1]], "services") else NULL
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
    performance_plan_title(db, plan, "Services"),
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
          service_is_admin <- is_administration_service(service_rows[i, , drop = FALSE])
          selected_metric_ids <- if (!is.null(services_draft) && !is.null(services_draft$serviceMetrics[[service_id]])) {
            suppressWarnings(as.integer(unlist(services_draft$serviceMetrics[[service_id]])))
          } else if (service_is_admin) {
            integer(0)
          } else {
            service_metric_ids(db, plan, service_id, measures)
          }
          selected_metric_ids <- selected_metric_ids[!is.na(selected_metric_ids)]
          selected_metrics <- if (length(selected_metric_ids) > 0) as.character(selected_metric_ids) else ""
          tags$details(
            class = "goal-editor service-editor",
            `data-service-id` = service_id,
            `data-selected-metrics` = paste(selected_metrics[nzchar(selected_metrics)], collapse = ","),
            tags$summary(
              div(
                class = "goal-editor-summary",
                div(span(paste("Service", i), class = "goal-number"), strong(service_rows$service_name[i])),
                span(class = "status-chip tone-primary service-metric-count", if (service_is_admin) "Not scored" else paste(sum(nzchar(selected_metrics)), if (sum(nzchar(selected_metrics)) == 1) "Metric" else "Metrics"))
              )
            ),
            div(
              class = "goal-editor-body service-editor-body",
              `aria-hidden` = "true",
              service_editor_body_ui(
                db,
                plan,
                service_rows[i, , drop = FALSE],
                measures = measures,
                metric_choices = metric_choices,
                locked = !plan_is_editable(plan) || !can_edit_plan,
                can_edit_shared_description = can_edit_shared_service_description
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
    locked = !plan_is_editable(plan) || !can_edit_plan
  )
}

page_risks <- function(db, agency_id, can_edit_plan = TRUE) {
  plan <- current_plan(db, agency_id)
  risks <- db$performance_service_risk[db$performance_service_risk$plan_id == plan$plan_id, , drop = FALSE]
  risks_draft <- if (plan_uses_draft_payload(plan)) section_draft_payload(db, plan$plan_id[[1]], "risks") else NULL
  risks <- risks_with_draft_overlay(risks, plan$plan_id[[1]], risks_draft)
  risk_criteria <- plan_review_criteria("plan_risks")
  risk_rubric_row <- function(row) {
    tags$tr(
      tags$th(scope = "row", row$label),
      tags$td(class = "rubric-points", row$weight),
      tags$td(row$score1),
      tags$td(row$score2),
      tags$td(row$score3),
      tags$td(class = "rubric-strong", row$score4)
    )
  }
  builder_page(
    performance_plan_title(db, plan, "Risks"),
    "Capture delivery risks, mitigations, and unresolved dependencies.",
    tagList(
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
      surface(
        "Risks scoring rubric",
        "Use this scoring description to check whether risks are specific, operationally meaningful, and grounded in real delivery conditions.",
        div(
          class = "rubric-section-table-wrap",
          tags$table(
            class = "rubric-table goal-rubric-table",
            tags$caption(class = "sr-only", "Risks scoring rubric"),
            tags$thead(tags$tr(
              tags$th(scope = "col", "Criterion"),
              tags$th(scope = "col", "Max points", span(class = "rubric-header-note", "Weighted score")),
              tags$th(scope = "col", "Score 1", span(class = "rubric-header-note", "Incomplete")),
              tags$th(scope = "col", "Score 2", span(class = "rubric-header-note", "Developing")),
              tags$th(scope = "col", "Score 3", span(class = "rubric-header-note", "Strong")),
              tags$th(scope = "col", "Score 4", span(class = "rubric-header-note", "Exemplary"))
            )),
            tags$tbody(lapply(seq_len(nrow(risk_criteria)), function(i) risk_rubric_row(risk_criteria[i, , drop = FALSE])))
          )
        )
      )
    ),
    plan_id = plan$plan_id,
    section_key = "risks",
    locked = !plan_is_editable(plan) || !can_edit_plan
  )
}

risk_modal_ui <- function(db, agency_id, risk_id = NULL) {
  plan <- current_plan(db, agency_id)
  risks <- db$performance_service_risk[db$performance_service_risk$plan_id == plan$plan_id, , drop = FALSE]
  risks_draft <- if (plan_uses_draft_payload(plan)) section_draft_payload(db, plan$plan_id[[1]], "risks") else NULL
  risks <- risks_with_draft_overlay(risks, plan$plan_id[[1]], risks_draft)
  # risk_id may be a temp "new-<epoch>" id for a not-yet-promoted add --
  # risks_with_draft_overlay() makes risk_id character throughout, so this
  # must compare as character, not the numeric == this used before.
  risk <- if (is.null(risk_id)) data.frame() else risks[risks$risk_id == as.character(risk_id), , drop = FALSE]
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
        div(
          if (!is_new) tags$button(id = "delete_risk", type = "button", class = "civic-button danger", icon("trash-can"), "Delete risk")
        ),
        div(
          class = "measure-submit-group",
          div(tags$button(id = "save_risk", type = "button", class = "civic-button primary", "Save risk"))
        )
      )
    )
  )
}

cls_format_dollars <- function(value) {
  value <- suppressWarnings(as.numeric(value))
  if (length(value) != 1 || is.na(value)) return("—")
  paste0("$", formatC(value, format = "f", digits = 2, big.mark = ","))
}

# Whole dollars with thousands separators - "$1,284,500". Used where the exact
# figure matters but cents are noise, notably the Total requested card, which
# used to round to "$1.3M" (analyst feedback round 2).
#
# format = "f" with digits = 0, NOT format = "d". formatC(format = "d") coerces
# its argument to a 32-bit integer, so anything above 2,147,483,647 came back as
# "$NA" and logged "NAs introduced by coercion to integer range" on every render.
# That ceiling is well inside the range this app has to display: the city's total
# budget is billions, so the citywide "Total requested" card would have hit it as
# soon as real data landed. format = "f" stays in double precision.
cls_format_commas <- function(value) {
  value <- suppressWarnings(as.numeric(value))
  if (length(value) != 1 || is.na(value)) return("—")
  paste0("$", formatC(round(value), format = "f", digits = 0, big.mark = ","))
}

# "7/29/26 at 2:45 PM" — no leading zeros, portable across platforms.
cls_fmt_saved <- function(ts) {
  ts <- suppressWarnings(as.POSIXct(ts))
  if (length(ts) != 1 || is.na(ts)) return("recently")
  lt <- as.POSIXlt(ts)
  ampm <- if (lt$hour < 12) "AM" else "PM"
  h12 <- ((lt$hour + 11) %% 12) + 1
  sprintf("%d/%d/%02d at %d:%02d %s", lt$mon + 1, lt$mday, lt$year %% 100, h12, lt$min, ampm)
}

cls_truncate <- function(text, max = 90) {
  text <- as.character(text %||% "")
  text <- trimws(gsub("\\s+", " ", text))
  if (!nzchar(text)) return("")
  if (nchar(text) > max) paste0(substr(text, 1, max - 1), "…") else text
}

# CLS is organised by AGENCY, never by entity. A user can be routed into an
# entity's plan (Mayoralty alone has nine), but every request they create or see
# belongs to the parent agency, and all of that agency's entities show together.
# The agency's own name, used for the CLS heading and notice even when the user
# arrived through one of its entities.
cls_agency_display_name <- function(db, agency_id) {
  agency_id <- as.character(agency_id %||% "")
  if (!nzchar(agency_id) || is.na(agency_id)) return("Agency")
  a <- db$reference_agency
  if (!is.null(a) && nrow(a)) {
    row <- a[!is.na(a$agency_id) & a$agency_id == agency_id, , drop = FALSE]
    if (nrow(row)) return(as.character(row$agency_name[[1]]))
  }
  agency_id
}

cls_agency_id_for_submitter <- function(db, submitter_value) {
  submitter <- parse_submitter_value(submitter_value)
  if (identical(submitter$type, "agency")) return(as.character(submitter$id))
  pe <- db$reference_plan_entity
  if (is.null(pe) || !nrow(pe)) return(NA_character_)
  row <- pe[!is.na(pe$entity_id) & pe$entity_id == submitter$id, , drop = FALSE]
  if (!nrow(row)) return(NA_character_)
  as.character(row$parent_agency_id[[1]])
}

# Every FY2027 plan that rolls up to this agency: the agency's own plan plus the
# plans of any entity whose parent_agency_id matches.
cls_plan_ids_for_agency <- function(db, agency_id) {
  agency_id <- as.character(agency_id %||% "")
  if (!nzchar(agency_id) || is.na(agency_id)) return(integer(0))
  ap <- db$planning_agency_plan
  if (is.null(ap) || !nrow(ap)) return(integer(0))
  ap <- ap[!is.na(ap$fiscal_year) & ap$fiscal_year == 2027, , drop = FALSE]
  own <- ap$plan_id[!is.na(ap$agency_id) & ap$agency_id == agency_id]
  pe <- db$reference_plan_entity
  ent <- integer(0)
  if (!is.null(pe) && nrow(pe)) {
    kids <- pe$entity_id[!is.na(pe$parent_agency_id) & pe$parent_agency_id == agency_id]
    if (length(kids)) ent <- ap$plan_id[!is.na(ap$entity_id) & ap$entity_id %in% kids]
  }
  sort(unique(as.integer(c(own, ent))))
}

# Requests across every plan that rolls up to the agency.
cls_requests_for_agency <- function(db, agency_id) {
  requests <- db$budget_cls_request
  if (is.null(requests) || !nrow(requests)) return(if (is.null(requests)) data.frame() else requests[0, , drop = FALSE])
  ids <- cls_plan_ids_for_agency(db, agency_id)
  if (!length(ids)) return(requests[0, , drop = FALSE])
  requests[!is.na(requests$plan_id) & requests$plan_id %in% ids, , drop = FALSE]
}

# Services to choose from when creating a request: every service on every plan
# that rolls up to the agency, labelled with its entity when there is more than
# one plan so two identically-named services stay distinguishable.
cls_agency_service_choices <- function(db, agency_id) {
  ids <- cls_plan_ids_for_agency(db, agency_id)
  if (!length(ids)) return(character(0))
  ap <- db$planning_agency_plan
  out <- character(0)
  labels <- character(0)
  multi <- length(ids) > 1
  for (pid in ids) {
    plan <- ap[ap$plan_id == pid, , drop = FALSE]
    if (!nrow(plan)) next
    ch <- cls_plan_service_choices(db, plan)
    if (!length(ch)) next
    lab <- names(ch)
    if (multi && !is.na(plan$entity_id[[1]])) {
      lab <- paste0(lab, " — ", plan_display_name(db, plan))
    }
    out <- c(out, unname(ch))
    labels <- c(labels, lab)
  }
  if (!length(out)) return(character(0))
  ord <- order(labels)
  stats::setNames(out[ord], labels[ord])
}

cls_requests_for_plan <- function(db, plan) {
  requests <- db$budget_cls_request
  if (is.null(requests) || !nrow(requests)) return(if (is.null(requests)) data.frame() else requests[0, , drop = FALSE])
  if (is.null(plan) || !nrow(plan) || is.na(plan$plan_id[[1]])) return(requests[0, , drop = FALSE])
  requests[!is.na(requests$plan_id) & requests$plan_id == plan$plan_id[[1]], , drop = FALSE]
}

cls_plan_service_choices <- function(db, plan) {
  services <- plan_service_rows(db, plan)
  if (is.null(services) || !nrow(services)) return(character(0))
  services <- services[!is.na(services$plan_service_id), , drop = FALSE]
  if (!nrow(services)) return(character(0))
  labels <- paste(services$service_id, services$service_name)
  ord <- order(labels)
  stats::setNames(as.character(services$plan_service_id[ord]), labels[ord])
}

cls_service_name <- function(db, service_id) {
  service_id <- as.character(service_id)
  row <- db$reference_service[db$reference_service$service_id == service_id, , drop = FALSE]
  if (nrow(row)) row$service_name[[1]] else service_id
}

# Services are shown with their Service ID everywhere in the CLS pages, since
# budget staff work from the SRV codes as much as the names.
cls_service_label <- function(db, service_id) {
  service_id <- as.character(service_id)
  if (length(service_id) != 1 || is.na(service_id) || !nzchar(service_id)) return("—")
  name <- cls_service_name(db, service_id)
  if (identical(name, service_id)) service_id else paste(service_id, name)
}

# Timestamps and emails for the export columns. Both are vectorised: they feed a
# whole column at once, and a missing value has to come out as "" rather than NA
# so Excel shows an empty cell instead of the literal text "NA".
cls_export_stamp <- function(ts) {
  # A single "" recycles across the column, which is what a data load that
  # predates the column should produce.
  if (is.null(ts) || !length(ts)) return("")
  ts <- suppressWarnings(as.POSIXct(ts))
  out <- format(ts, "%Y-%m-%d %H:%M")
  out[is.na(ts)] <- ""
  out
}

cls_export_email <- function(value) {
  if (is.null(value) || !length(value)) return("")
  out <- trimws(as.character(value))
  out[is.na(out)] <- ""
  out
}

# Build the three CLS export tables as a named list of data frames — one per
# worksheet: "Request summary", "Line items", "Personnel". Amount/count columns
# stay numeric so Excel can total them.
cls_export_sheets <- function(db, plan) {
  reqs <- cls_requests_for_plan(db, plan)
  if (is.null(reqs)) reqs <- data.frame()
  numv <- function(x) suppressWarnings(as.numeric(x))
  yesno <- function(x) ifelse(as.logical(x) %in% TRUE, "Yes", "No")
  request_name_for <- function(cid) if (nrow(reqs)) as.character(reqs$request_name[match(cid, reqs$cls_id)]) else character(length(cid))

  if (nrow(reqs)) {
    summary_df <- data.frame(
      Request = as.character(reqs$request_name),
      Service = vapply(reqs$service_id, function(s) cls_service_label(db, s), character(1)),
      Type = as.character(reqs$request_type),
      Amount = numv(reqs$request_amount),
      `One-time` = yesno(reqs$one_time),
      Status = as.character(reqs$status),
      `Projected FY+2` = numv(reqs$amount_next_fy),
      `Projected FY+3` = numv(reqs$amount_2next_fy),
      Summary = as.character(reqs$overall_summary),
      # Audit trail, so a reviewer can see who opened a request and who touched
      # it last without opening it (analyst feedback round 2).
      `Created date` = cls_export_stamp(reqs$created_at),
      `Created by email` = cls_export_email(reqs$created_by_email),
      `Modified date` = cls_export_stamp(reqs$updated_at),
      `Modified by email` = cls_export_email(reqs$modified_by_email),
      check.names = FALSE, stringsAsFactors = FALSE
    )
  } else {
    summary_df <- data.frame(
      Request = character(0), Service = character(0), Type = character(0), Amount = numeric(0),
      `One-time` = character(0), Status = character(0),
      `Projected FY+2` = numeric(0), `Projected FY+3` = numeric(0), Summary = character(0),
      `Created date` = character(0), `Created by email` = character(0),
      `Modified date` = character(0), `Modified by email` = character(0),
      check.names = FALSE, stringsAsFactors = FALSE
    )
  }

  lines <- db$budget_cls_request_line
  line_rows <- if (!is.null(lines) && nrow(lines) && nrow(reqs)) lines[lines$cls_id %in% reqs$cls_id, , drop = FALSE] else NULL
  lines_df <- if (!is.null(line_rows) && nrow(line_rows)) {
    data.frame(
      Request = request_name_for(line_rows$cls_id),
      Object = as.character(line_rows$object_category),
      `Spend category` = as.character(line_rows$spend_category),
      Amount = numv(line_rows$amount),
      Justification = as.character(line_rows$justification),
      check.names = FALSE, stringsAsFactors = FALSE
    )
  } else {
    data.frame(Request = character(0), Object = character(0), `Spend category` = character(0), Amount = numeric(0), Justification = character(0), check.names = FALSE, stringsAsFactors = FALSE)
  }

  positions <- db$budget_cls_request_position
  pos_rows <- if (!is.null(positions) && nrow(positions) && nrow(reqs)) positions[positions$cls_id %in% reqs$cls_id, , drop = FALSE] else NULL
  pos_df <- if (!is.null(pos_rows) && nrow(pos_rows)) {
    data.frame(
      Request = request_name_for(pos_rows$cls_id),
      Classification = as.character(pos_rows$classification),
      Positions = suppressWarnings(as.integer(pos_rows$position_count)),
      `Estimated salary` = numv(pos_rows$estimated_salary),
      Justification = as.character(pos_rows$justification),
      Explanation = as.character(pos_rows$explanation),
      check.names = FALSE, stringsAsFactors = FALSE
    )
  } else {
    data.frame(Request = character(0), Classification = character(0), Positions = integer(0), `Estimated salary` = numeric(0), Justification = character(0), Explanation = character(0), check.names = FALSE, stringsAsFactors = FALSE)
  }

  list(`Request summary` = summary_df, `Line items` = lines_df, `Personnel` = pos_df)
}

# JSON payload describing every request (with its lines and positions) for the PDF export.
cls_export_payload <- function(db, plan) {
  reqs <- cls_requests_for_plan(db, plan)
  if (is.null(reqs)) reqs <- data.frame()
  num <- function(x) { x <- suppressWarnings(as.numeric(x)); if (length(x) != 1 || is.na(x)) NULL else round(x, 2) }
  requests <- list()
  if (nrow(reqs)) {
    for (i in seq_len(nrow(reqs))) {
      r <- reqs[i, , drop = FALSE]
      lines <- db$budget_cls_request_line
      lr <- if (!is.null(lines) && nrow(lines)) lines[lines$cls_id == r$cls_id, , drop = FALSE] else data.frame()
      positions <- db$budget_cls_request_position
      pr <- if (!is.null(positions) && nrow(positions)) positions[positions$cls_id == r$cls_id, , drop = FALSE] else data.frame()
      requests[[length(requests) + 1L]] <- list(
        name = as.character(r$request_name %||% ""),
        service = cls_service_label(db, r$service_id),
        type = as.character(r$request_type %||% ""),
        amount = num(r$request_amount),
        one_time = isTRUE(r$one_time),
        status = as.character(r$status %||% ""),
        amount_next_fy = num(r$amount_next_fy),
        amount_2next_fy = num(r$amount_2next_fy),
        summary = as.character(r$overall_summary %||% ""),
        lines = if (nrow(lr)) lapply(seq_len(nrow(lr)), function(j) list(
          object_category = as.character(lr$object_category[j] %||% ""),
          spend_category = as.character(lr$spend_category[j] %||% ""),
          amount = num(lr$amount[j]),
          justification = as.character(lr$justification[j] %||% "")
        )) else list(),
        positions = if (nrow(pr)) lapply(seq_len(nrow(pr)), function(j) list(
          classification = as.character(pr$classification[j] %||% ""),
          position_count = suppressWarnings(as.integer(pr$position_count[j])),
          estimated_salary = num(pr$estimated_salary[j]),
          justification = as.character(pr$justification[j] %||% ""),
          explanation = as.character(pr$explanation[j] %||% "")
        )) else list()
      )
    }
  }
  list(
    agency = plan_display_name(db, plan),
    generated = format(Sys.time(), "%B %d, %Y"),
    requests = requests
  )
}

build_cls_request_pdf <- function(db, plan, output_file) {
  payload_file <- tempfile(fileext = ".json")
  jsonlite::write_json(cls_export_payload(db, plan), payload_file, auto_unbox = TRUE, null = "null", pretty = TRUE)
  script_path <- normalizePath(file.path("scripts", "build_cls_pdf.py"), winslash = "/", mustWork = TRUE)
  status <- system2(plan_export_python(), shQuote(c(script_path, "--input", payload_file, "--output", output_file)), stdout = TRUE, stderr = TRUE)
  if (!file.exists(output_file) || file.info(output_file)$size == 0) {
    stop(paste("CLS PDF export failed:", paste(status, collapse = "\n")))
  }
  invisible(output_file)
}

# cls_format_km() was removed here: every CLS surface now shows separated whole
# dollars via cls_format_commas(). "$2.3M" hid the figure people were checking.

# A request is "complete" when the mandatory fields are filled in and the FY28
# amount is fully described by its objects plus positions. Used for the red
# indicator on the list page and the reminder on the request page.
cls_request_is_complete <- function(db, row) {
  filled <- function(x) { x <- as.character(x %||% ""); length(x) == 1 && !is.na(x) && nzchar(trimws(x)) }
  if (!filled(row$request_name)) return(FALSE)
  if (!filled(row$overall_summary)) return(FALSE)
  amount <- suppressWarnings(as.numeric(row$request_amount))
  if (length(amount) != 1 || is.na(amount) || amount <= 0) return(FALSE)
  lines <- db$budget_cls_request_line
  line_total <- if (!is.null(lines) && nrow(lines)) sum(suppressWarnings(as.numeric(lines$amount[lines$cls_id == row$cls_id[[1]]])), na.rm = TRUE) else 0
  positions <- db$budget_cls_request_position
  pos_total <- if (!is.null(positions) && nrow(positions)) sum(suppressWarnings(as.numeric(positions$estimated_salary[positions$cls_id == row$cls_id[[1]]])), na.rm = TRUE) else 0
  abs(amount - (line_total + pos_total)) < 0.005
}

# Which required pieces a request is still missing. Used for the list-page
# indicator and the banner wording.
cls_request_gaps <- function(db, request_row) {
  if (is.null(request_row) || !nrow(request_row)) return(character(0))
  r <- request_row[1, , drop = FALSE]
  gaps <- character(0)
  rname <- trimws(as.character(r$request_name %||% ""))
  if (!nzchar(rname) || identical(rname, CLS_DRAFT_NAME)) gaps <- c(gaps, "request name")
  if (!nzchar(trimws(as.character(r$request_type %||% "")))) gaps <- c(gaps, "request type")
  if (!nzchar(trimws(as.character(r$overall_summary %||% "")))) gaps <- c(gaps, "summary")
  # A recurring request continues into FY29 and FY30, so both out-years are
  # mandatory for it. A one-time request has neither (analyst feedback round 2).
  if (!isTRUE(r$one_time)) {
    positive <- function(x) { x <- suppressWarnings(as.numeric(x)); length(x) == 1 && !is.na(x) && x > 0 }
    if (!positive(r$amount_next_fy)) gaps <- c(gaps, "FY29 amount")
    if (!positive(r$amount_2next_fy)) gaps <- c(gaps, "FY30 amount")
  }
  amount <- suppressWarnings(as.numeric(r$request_amount))
  if (length(amount) != 1 || is.na(amount) || amount <= 0) {
    gaps <- c(gaps, "FY28 amount")
  } else {
    lines <- db$budget_cls_request_line
    line_total <- if (!is.null(lines) && nrow(lines)) sum(suppressWarnings(as.numeric(lines$amount[lines$cls_id == r$cls_id[[1]]])), na.rm = TRUE) else 0
    positions <- db$budget_cls_request_position
    pos_total <- if (!is.null(positions) && nrow(positions)) sum(suppressWarnings(as.numeric(positions$estimated_salary[positions$cls_id == r$cls_id[[1]]])), na.rm = TRUE) else 0
    if (abs(amount - (line_total + pos_total)) >= 0.005) gaps <- c(gaps, "a complete breakdown by object or positions")
  }
  gaps
}

cls_status_label <- function(row) {
  status <- as.character(row$status %||% "")
  if (length(status) != 1 || is.na(status) || !nzchar(status)) "In Progress" else status
}

# The six workflow statuses each get their own colour. This replaced a mapping
# onto the generic tone- classes, which only offer five and had to reuse amber
# for both "Agency Review" and "Partially Approved", making two very different
# states look identical (analyst feedback round 2).
cls_status_slug <- function(status) {
  gsub("[^a-z0-9]+", "-", tolower(as.character(status %||% "")))
}

cls_status_chip <- function(status) {
  label <- as.character(status %||% "")
  if (!nzchar(label)) label <- "In Progress"
  span(
    class = paste("status-chip cls-status-chip", paste0("cls-status-", cls_status_slug(label))),
    label
  )
}

# The placeholder list plus anything agencies have created through the
# "Create a spend category" field, so a new one is reusable straight away.
# Sentinel option in the spend-category dropdown: the agency needs a category
# that isn't on the list yet, and describes it in the justification.
CLS_NEW_SPEND_CATEGORY <- "Create Spend Category"

# Placeholder name a request is created under before the user names it. Treated
# as "unnamed" by the form and by the completeness check.
CLS_DRAFT_NAME <- "Untitled CLS request"

# A money or count field: thousands separators as you type, and decimals are
# refused outright. A native number input cannot render a comma, so these are
# text inputs wired to Shiny by a custom input binding in app.js that strips the
# separators before the value reaches the server (analyst feedback round 2).
cls_money_input <- function(input_id, label = NULL, value = NA, placeholder = NULL,
                            class = NULL) {
  v <- suppressWarnings(as.numeric(value))
  shown <- if (length(v) == 1 && !is.na(v)) formatC(round(v), format = "d", big.mark = ",") else ""
  div(
    class = trimws(paste("form-group shiny-input-container cls-money-group", class %||% "")),
    if (!is.null(label)) tags$label(class = "control-label", `for` = input_id, label),
    tags$input(
      id = input_id, type = "text", class = "form-control cls-money-input",
      inputmode = "numeric", autocomplete = "off",
      value = shown, placeholder = placeholder
    )
  )
}

# A dropdown whose panel holds checkboxes, rather than a selectize tag-input.
# The input id and value shape match selectInput(multiple = TRUE), so the
# server-side observers are unchanged (analyst feedback round 1).
cls_check_dropdown <- function(input_id, label, choices, selected = NULL) {
  n_sel <- length(selected)
  n_all <- length(choices)
  summary_text <- if (!n_all) "None available"
    else if (n_sel == 0) paste("No", tolower(label), "selected")
    else if (n_sel == n_all) paste("All", tolower(label))
    else paste(n_sel, "of", n_all, "selected")
  div(
    class = "cls-check-dropdown",
    tags$label(class = "control-label", `for` = paste0(input_id, "_toggle"), label),
    tags$button(
      id = paste0(input_id, "_toggle"), type = "button", class = "cls-cd-toggle",
      `data-cls-cd-toggle` = input_id, `aria-expanded` = "false",
      tags$span(class = "cls-cd-summary", summary_text),
      tags$span(class = "cls-cd-caret", icon("chevron-down"))
    ),
    div(
      class = "cls-cd-panel", `data-cls-cd-panel` = input_id, style = "display:none;",
      div(class = "cls-cd-actions",
        tags$button(type = "button", class = "cls-cd-mini", `data-cls-cd-all` = input_id, "Select all"),
        tags$button(type = "button", class = "cls-cd-mini", `data-cls-cd-none` = input_id, "Clear"),
        # Ticks are held until this is pressed (or the panel is closed), so a
        # whole set of choices reaches the table at once (analyst feedback round 2).
        tags$button(type = "button", class = "cls-cd-mini cls-cd-apply",
                    `data-cls-cd-apply` = input_id, "Apply")),
      checkboxGroupInput(input_id, label = NULL, choices = choices, selected = selected)
    )
  )
}

# A chart surface the user can fold away - the cards above it are often all
# someone needs, and the chart is tall (analyst feedback round 1).
cls_collapsible_chart <- function(key, title, description, body) {
  panel_id <- paste0("cls_chart_body_", key)
  tags$section(
    class = "section-surface cls-chart-surface",
    div(
      class = "surface-header",
      div(h2(title), p(description)),
      div(class = "surface-actions",
        tags$button(
          type = "button", class = "civic-button secondary small cls-chart-toggle",
          `data-cls-chart-toggle` = panel_id, `aria-expanded` = "true", `aria-controls` = panel_id,
          icon("chevron-up"), tags$span(class = "cls-chart-toggle-label", "Hide chart")
        ))
    ),
    div(id = panel_id, class = "cls-chart-body", body)
  )
}

# The definition + example for a request type, reused as a tooltip on CLS Review
# so a reviewer does not have to open the request to recall what a type means.
cls_request_type_tooltip <- function(request_type) {
  rt <- as.character(request_type %||% "")
  if (!nzchar(rt)) return(NULL)
  for (entry in cls_adjustment_type_guidance) {
    if (identical(entry[[1]], rt)) {
      return(paste0(rt, ". ", entry[[2]], " Example: ", entry[[3]]))
    }
  }
  rt
}

# The dropdown list: chart-of-accounts codes from reference.spend_category, plus
# anything existing requests already reference so a stored value is never silently
# dropped from its own row. Codes keep their chart order (sort_order); sorting the
# whole thing alphabetically would scatter the numeric blocks.
cls_spend_category_options <- function(db) {
  catalogue <- spend_category_labels(db)
  used <- character(0)
  lines <- db$budget_cls_request_line
  if (!is.null(lines) && nrow(lines)) {
    used <- trimws(as.character(lines$spend_category))
    used <- used[!is.na(used) & nzchar(used)]
  }
  c(catalogue, sort(unique(setdiff(used, catalogue))))
}

# Every Agency Submitter for this agency, named in the submission notice. Plural
# because an agency can have more than one person with final sign-off.
cls_submitter_names <- function(db, plan) {
  if (is.null(plan) || !nrow(plan)) return("Your Agency Submitter")
  cls_submitter_names_for_agency(db, plan$agency_id[[1]])
}

cls_submitter_names_for_agency <- function(db, agency_id) {
  ids <- cls_submitter_user_ids_for_agency(db, agency_id)
  if (!length(ids)) return("Your Agency Submitter")
  names <- db$access_user$full_name[match(ids, db$access_user$user_id)]
  names <- unique(trimws(as.character(names)))
  names <- names[!is.na(names) & nzchar(names)]
  names <- sort(names)
  if (!length(names)) return("Your Agency Submitter")
  if (length(names) == 1) return(names[[1]])
  if (length(names) == 2) return(paste(names, collapse = " and "))
  paste0(paste(names[-length(names)], collapse = ", "), ", and ", names[[length(names)]])
}

# Everyone holding the AgencySubmitter role for an agency. Most role rows carry
# no agency_id - the role is granted against an entity, and the agency is only
# reachable through access.user_entity_access - so a role-table-only lookup
# named almost nobody. Entity grants roll up to the parent agency, matching the
# way CLS groups everything else (analyst feedback round 2).
cls_submitter_user_ids_for_agency <- function(db, agency_id) {
  agency_id <- as.character(agency_id %||% "")
  if (!nzchar(agency_id) || is.na(agency_id)) return(integer(0))
  ur <- db$access_user_role
  if (is.null(ur) || !nrow(ur)) return(integer(0))
  submitters <- ur[!is.na(ur$app_role) & ur$app_role == "AgencySubmitter", , drop = FALSE]
  if (!nrow(submitters)) return(integer(0))

  # 1. Roles scoped straight to the agency.
  direct <- submitters$user_id[!is.na(submitters$agency_id) & submitters$agency_id == agency_id]

  # 2. Roles with no agency of their own, resolved through the user's entity
  #    access: either the access row names the agency, or it names an entity
  #    whose parent_agency_id does.
  via_entity <- integer(0)
  uea <- db$access_user_entity_access
  if (!is.null(uea) && nrow(uea)) {
    unscoped <- submitters$user_id[is.na(submitters$agency_id) | !nzchar(as.character(submitters$agency_id))]
    if (length(unscoped)) {
      mine <- uea[uea$user_id %in% unscoped, , drop = FALSE]
      hit <- !is.na(mine$agency_id) & mine$agency_id == agency_id
      pe <- db$reference_plan_entity
      if (!is.null(pe) && nrow(pe)) {
        kids <- pe$entity_id[!is.na(pe$parent_agency_id) & pe$parent_agency_id == agency_id]
        if (length(kids)) hit <- hit | (!is.na(mine$entity_id) & mine$entity_id %in% kids)
      }
      via_entity <- mine$user_id[hit]
    }
  }
  unique(as.integer(c(direct, via_entity)))
}

cls_submitter_name <- function(db, plan) {
  if (is.null(plan) || !nrow(plan) || is.na(plan$agency_id[[1]])) return("your Agency Submitter")
  ur <- db$access_user_role
  if (is.null(ur) || !nrow(ur)) return("your Agency Submitter")
  rows <- ur[!is.na(ur$app_role) & ur$app_role == "AgencySubmitter" & !is.na(ur$agency_id) & ur$agency_id == plan$agency_id[[1]], , drop = FALSE]
  if (!nrow(rows)) return("your Agency Submitter")
  users <- db$access_user[db$access_user$user_id == rows$user_id[[1]], , drop = FALSE]
  if (nrow(users) && nzchar(as.character(users$full_name[[1]] %||% ""))) users$full_name[[1]] else "your Agency Submitter"
}

page_cls_requests <- function(db, agency_id, app_roles = character(0)) {
  # Whichever entity the user was routed into, CLS works at the agency level.
  cls_agency <- cls_agency_id_for_submitter(db, agency_id)
  plan_ids <- cls_plan_ids_for_agency(db, cls_agency)
  plan <- current_plan(db, agency_id)
  can_edit <- can_edit_cls_requests(app_roles)
  has_plan <- length(plan_ids) > 0
  requests <- cls_requests_for_agency(db, cls_agency)
  request_count <- if (is.null(requests)) 0L else nrow(requests)

  create_action <- if (can_edit && has_plan) {
    actionButton("cls_create_open", label = tagList(icon("plus"), "Add CLS Request"), class = "civic-button primary small")
  } else {
    NULL
  }
  # Analyst feedback: the create button sits in its own bar under the subtext so
  # it never rides up beside the heading on a narrow screen.
  create_bar <- if (!is.null(create_action)) div(class = "cls-create-bar", create_action) else NULL
  header_actions <- NULL

  export_bar <- if (has_plan && request_count) {
    div(
      class = "cls-export-bar",
      span(class = "cls-export-label", "Export request(s):"),
      downloadButton("cls_export_xlsx", label = tagList(icon("file-excel"), "Excel"), class = "civic-button secondary small"),
      downloadButton("cls_export_pdf", label = tagList(icon("file-pdf"), "PDF"), class = "civic-button secondary small")
    )
  } else {
    NULL
  }

  table_body <- if (!has_plan) {
    div(class = "cls-empty-state", p(class = "empty-state-copy", "No active plan is available for this agency, so CLS requests cannot be created yet."))
  } else if (!request_count) {
    div(class = "cls-empty-state", p(class = "empty-state-copy", if (can_edit) "No CLS requests yet. Use “Add CLS Request” to add the first one." else "No CLS requests have been created for this agency yet."))
  } else {
    div(
      class = "app-table cls-request-table",
      div(
        class = "table-row table-head cls-request-row",
        tags$button(type = "button", class = "cls-sort-btn", `data-cls-sort` = "name", "Request name", tags$span(class = "cls-sort-icon", icon("sort"))),
        tags$button(type = "button", class = "cls-sort-btn", `data-cls-sort` = "service", "Service", tags$span(class = "cls-sort-icon", icon("sort"))),
        tags$button(type = "button", class = "cls-sort-btn", `data-cls-sort` = "amount", "Amount", tags$span(class = "cls-sort-icon", icon("sort"))),
        tags$button(type = "button", class = "cls-sort-btn", `data-cls-sort` = "status", "Status", tags$span(class = "cls-sort-icon", icon("sort"))),
        span(class = "cls-request-actions-head", "")
      ),
      lapply(seq_len(request_count), function(i) {
        r <- requests[i, , drop = FALSE]
        amount_key <- suppressWarnings(as.numeric(r$request_amount))
        status <- cls_status_label(r)
        gaps <- cls_request_gaps(db, r)
        missing_tip <- if (length(gaps)) {
          paste0("This request is not properly detailed. Still needed: ", paste(gaps, collapse = ", "), ".")
        } else NULL
        div(
          class = paste("table-row cls-request-row", if (length(gaps)) "cls-request-row-missing" else ""),
          `data-sort-name` = tolower(as.character(r$request_name %||% "")),
          `data-sort-service` = tolower(cls_service_label(db, r$service_id)),
          `data-sort-amount` = if (is.na(amount_key)) "" else as.character(amount_key),
          `data-sort-status` = tolower(status),
          span(
            class = "cls-request-name",
            # Clamped to two lines in CSS, so the full name is on the tooltip.
            span(title = as.character(r$request_name %||% ""), r$request_name),
            if (length(gaps)) tags$span(
              class = "cls-missing-flag",
              title = missing_tip,
              `aria-label` = missing_tip,
              tabindex = "0",
              icon("circle-exclamation"), "Not detailed"
            )
          ),
          span(cls_service_label(db, r$service_id)),
          span(class = "cls-request-amount", cls_format_commas(r$request_amount)),
          span(cls_status_chip(status)),
          div(
            class = "cls-request-actions",
            # Per-request hand-off: writers submit a draft to their submitter;
            # submitters send an individual request on to BBMR.
            if (can_approve_cls(app_roles) && status %in% c("In Progress", "Agency Review")) {
              tags$button(type = "button", class = "civic-button submit-agency small",
                `data-cls-send-bbmr` = r$cls_id, `data-cls-name` = r$request_name,
                `aria-label` = paste("Send", r$request_name, "for BBMR review"),
                icon("paper-plane"), "Send to BBMR")
            } else if (has_any_role(app_roles, c("AgencyWriter", "AgencySubmitter")) && identical(status, "In Progress")) {
              tags$button(type = "button", class = "civic-button submit-agency small",
                `data-cls-submit` = r$cls_id, `data-cls-name` = r$request_name,
                `aria-label` = paste("Submit", r$request_name, "for approval"),
                icon("paper-plane"), "Submit")
            },
            # A request that has reached BBMR is a submitted record; it can no
            # longer be deleted by anyone.
            if (can_edit && !cls_status_is_complete(status)) {
              tags$button(type = "button", class = "civic-button danger small",
                `data-cls-delete` = r$cls_id, `data-cls-name` = r$request_name, icon("trash-can"), "Delete")
            } else if (can_edit) {
              tags$span(class = "cls-delete-locked", title = "Sent for BBMR review - this request can no longer be deleted",
                icon("lock"))
            },
            # Once a request has gone to BBMR it is read-only, so the action says
            # View rather than Modify - it was promising an edit it could not
            # deliver (analyst feedback 2026-08-04).
            if (cls_status_is_complete(status)) {
              tags$button(type = "button", class = "civic-button secondary small cls-enter-arrow",
                `data-cls-open` = r$cls_id,
                `aria-label` = paste("View request", r$request_name),
                "View", icon("eye"))
            } else {
              tags$button(type = "button", class = "civic-button primary small cls-enter-arrow",
                `data-cls-open` = r$cls_id,
                `aria-label` = paste("Modify request", r$request_name),
                "Modify", icon("arrow-right"))
            }
          )
        )
      })
    )
  }

  # Analyst feedback: agencies get the same cards and chart BBMR has, scoped to
  # their own requests, with the bar chart broken out by service rather than agency.
  agency_summary <- if (has_plan && request_count) {
    all_rows <- cls_review_rows(db)
    mine <- if (nrow(all_rows)) all_rows[all_rows$cls_id %in% requests$cls_id, , drop = FALSE] else all_rows
    sent <- if (nrow(mine)) mine[mine$completed, , drop = FALSE] else mine
    div(
      class = "cls-agency-summary",
      div(
        class = "dashboard-grid cls-review-grid",
        metric_tile("Requests in progress", if (nrow(mine)) sum(!mine$completed) else 0L),
        metric_tile("Sent for BBMR review", nrow(sent), tone = "success"),
        metric_tile("Total requested", cls_format_commas(if (nrow(mine)) sum(mine$request_amount, na.rm = TRUE) else 0)),
        metric_tile("Total positions", if (nrow(mine)) sum(mine$position_count, na.rm = TRUE) else 0L)
      ),
      cls_collapsible_chart(
        "agency",
        "Requests by Service",
        "How this agency's requested dollars are distributed across its services.",
        cls_review_chart(mine, group_col = "service", group_noun = "service")
      )
    )
  } else NULL

  agency_label <- cls_agency_display_name(db, cls_agency)
  submitter_names <- cls_submitter_names_for_agency(db, cls_agency)
  analyst_name <- { a <- agency_budget_analyst(db, cls_agency); if (is.na(a)) "Unassigned" else a }
  # "needs" when one person holds final sign-off, "need" when several do.
  needs_verb <- if (identical(submitter_names, "Your Agency Submitter") ||
                    grepl(" and ", submitter_names, fixed = TRUE)) "need" else "needs"
  # Rewritten as numbered instructions (2026-08-04). The prose version carried the
  # same facts but read as background; agencies were missing the steps and, in
  # particular, that they should be working with their budget analyst rather than
  # submitting cold.
  subtext <- tagList(
    span(class = "cls-subtext-line",
      "Build one request per initiative or project, then break its total out by expenditure ",
      "object and any new positions."),
    tags$ol(class = "cls-subtext-steps",
      tags$li("Select ", tags$strong("Add CLS Request"), " and give it a name, service and type."),
      tags$li("Enter the FY28 amount. If the request recurs, enter FY29 and FY30 as well."),
      tags$li("Break that total out until the banner confirms it is fully described. Objects and ",
              "positions both count toward it."),
      tags$li(tags$strong(paste0("Work with your budget analyst, ", analyst_name, ",")),
              " as you build each request — they can tell you whether a cost belongs in CLS ",
              "and how to categorise it."),
      tags$li(paste0("Submit the request to ", submitter_names, ", who ", needs_verb,
                     " to give it a final review before it goes to BBMR."))),
    span(class = "cls-subtext-line",
      "Anyone at ", tags$strong(agency_label), " can enter and edit requests, so work on them ",
      "together. Only a submitter can send one on. The deadline is ",
      tags$strong("September 15th COB (4:30pm)"), ", after which the system locks — leave time ",
      "for that final review."),
    # Who signs off and who at BBMR to ask, named on the page rather than looked
    # up elsewhere (analyst feedback round 2).
    span(class = "cls-subtext-line cls-subtext-people",
      span(class = "cls-people-line",
        span(class = "cls-people-label", "Submitter:"), " ", submitter_names),
      span(class = "cls-people-line",
        span(class = "cls-people-label", "Budget Analyst:"), " ", analyst_name))
  )

  surface(
    paste(agency_label, "Requests"),
    subtext,
    agency_summary,
    create_bar,
    table_body,
    export_bar,
    actions = header_actions
  )
}

# All CLS requests across every agency, with agency label, line/position rollups,
# and any BBMR review fields joined on. Used by the BBMR CLS Review page.
cls_review_rows <- function(db) {
  reqs <- db$budget_cls_request
  if (is.null(reqs) || !nrow(reqs)) return(data.frame())
  lines <- db$budget_cls_request_line
  positions <- db$budget_cls_request_position
  reviews <- db$budget_cls_review

  agency_for <- function(plan_id) {
    plan <- db$planning_agency_plan[db$planning_agency_plan$plan_id == plan_id, , drop = FALSE]
    if (!nrow(plan)) return("Unassigned")
    plan_display_name(db, plan)
  }

  out <- data.frame(
    cls_id = reqs$cls_id,
    agency = vapply(reqs$plan_id, agency_for, character(1)),
    request_name = as.character(reqs$request_name),
    service = vapply(reqs$service_id, function(s) cls_service_label(db, s), character(1)),
    request_type = ifelse(is.na(reqs$request_type), "", as.character(reqs$request_type)),
    request_amount = suppressWarnings(as.numeric(reqs$request_amount)),
    amount_next_fy = suppressWarnings(as.numeric(reqs$amount_next_fy)),
    amount_2next_fy = suppressWarnings(as.numeric(reqs$amount_2next_fy)),
    one_time = as.logical(reqs$one_time),
    status = if ("status" %in% names(reqs)) ifelse(is.na(reqs$status) | !nzchar(as.character(reqs$status)), NA_character_, as.character(reqs$status)) else NA_character_,
    overall_summary = ifelse(is.na(reqs$overall_summary), "", as.character(reqs$overall_summary)),
    created_at = cls_export_stamp(reqs$created_at),
    created_by_email = cls_export_email(reqs$created_by_email),
    updated_at = cls_export_stamp(reqs$updated_at),
    modified_by_email = cls_export_email(reqs$modified_by_email),
    stringsAsFactors = FALSE
  )
  out$status[is.na(out$status)] <- "In Progress"
  # "Complete" is derived from status now that the completed column is gone.
  out$completed <- cls_status_is_complete(out$status)

  out$line_count <- vapply(out$cls_id, function(id) {
    if (is.null(lines) || !nrow(lines)) 0L else sum(lines$cls_id == id)
  }, integer(1))
  out$line_total <- vapply(out$cls_id, function(id) {
    if (is.null(lines) || !nrow(lines)) 0 else sum(suppressWarnings(as.numeric(lines$amount[lines$cls_id == id])), na.rm = TRUE)
  }, numeric(1))
  out$position_count <- vapply(out$cls_id, function(id) {
    if (is.null(positions) || !nrow(positions)) 0L else as.integer(sum(suppressWarnings(as.integer(positions$position_count[positions$cls_id == id])), na.rm = TRUE))
  }, integer(1))
  out$position_salary <- vapply(out$cls_id, function(id) {
    if (is.null(positions) || !nrow(positions)) 0 else sum(suppressWarnings(as.numeric(positions$estimated_salary[positions$cls_id == id])), na.rm = TRUE)
  }, numeric(1))

  pick <- function(id, field, default = "") {
    if (is.null(reviews) || !nrow(reviews)) return(default)
    row <- reviews[reviews$cls_id == id, , drop = FALSE]
    if (!nrow(row)) return(default)
    v <- row[[field]][[1]]
    if (is.na(v)) default else v
  }
  out$analyst_notes <- vapply(out$cls_id, function(id) as.character(pick(id, "analyst_notes", "")), character(1))
  out$analyst_approval <- vapply(out$cls_id, function(id) as.character(pick(id, "analyst_approval", "")), character(1))
  out$bbmr_approval <- vapply(out$cls_id, function(id) as.character(pick(id, "bbmr_approval", "")), character(1))
  out$approved_amount <- vapply(out$cls_id, function(id) suppressWarnings(as.numeric(pick(id, "approved_amount", NA_real_))), numeric(1))
  out$approved_positions <- vapply(out$cls_id, function(id) suppressWarnings(as.integer(pick(id, "approved_positions", NA_integer_))), integer(1))

  out[order(-as.integer(out$completed), tolower(out$agency), tolower(out$request_name)), , drop = FALSE]
}

# Dependency-free stacked bar chart: requested dollars per group, split by how
# far each request has got through approval. Tooltips are native SVG <title>.
# group_col is "agency" for BBMR's citywide view and "service" for an agency's
# own view of its requests (analyst feedback round 1).
cls_review_chart <- function(rows, group_col = "agency", group_noun = "agency") {
  if (is.null(rows) || !nrow(rows)) {
    return(div(class = "cls-empty-state", p(class = "empty-state-copy", "No CLS request data to chart yet.")))
  }
  amounts <- ifelse(is.na(rows$request_amount), 0, rows$request_amount)

  # Decision buckets, in the order they stack left to right.
  segments <- list(
    list(key = "approved",   label = "Approved",           class = "seg-approved"),
    list(key = "partial",    label = "Partially approved", class = "seg-partial"),
    list(key = "unapproved", label = "Not approved",       class = "seg-unapproved"),
    list(key = "denied",     label = "Denied",             class = "seg-denied"),
    list(key = "pending",    label = "Awaiting decision",  class = "seg-pending")
  )
  # A partial approval is split: only the dollars BBMR actually approved are
  # yellow, and the shortfall shows separately as "Not approved". Anything else
  # contributes its whole requested amount to one bucket (analyst feedback round 2).
  seg_values <- matrix(0, nrow = length(amounts), ncol = length(segments),
                       dimnames = list(NULL, vapply(segments, function(s) s$key, character(1))))
  approved_amt <- suppressWarnings(as.numeric(rows$approved_amount %||% rep(NA_real_, length(amounts))))
  for (i in seq_along(amounts)) {
    status <- as.character(rows$status[[i]])
    total <- amounts[[i]]
    if (identical(status, "Approved")) {
      seg_values[i, "approved"] <- total
    } else if (identical(status, "Partially Approved")) {
      appr <- approved_amt[[i]]
      if (is.na(appr) || appr < 0) appr <- 0
      appr <- min(appr, total)
      seg_values[i, "partial"] <- appr
      seg_values[i, "unapproved"] <- total - appr
    } else if (identical(status, "Denied")) {
      seg_values[i, "denied"] <- total
    } else {
      seg_values[i, "pending"] <- total
    }
  }

  group_values <- as.character(rows[[group_col]])
  agencies <- unique(group_values)
  totals <- vapply(agencies, function(a) sum(amounts[group_values == a]), numeric(1))
  ord <- order(-totals)
  agencies <- agencies[ord]; totals <- totals[ord]
  if (length(agencies) > 10) { agencies <- agencies[seq_len(10)]; totals <- totals[seq_len(10)] }
  max_total <- max(totals, na.rm = TRUE)
  if (!is.finite(max_total) || max_total <= 0) max_total <- 1

  # Narrow bars and small type: the chart is a shape-at-a-glance, and a tall one
  # pushed the table below the fold (analyst feedback round 2).
  # The right gutter has to hold a full separated figure ("$2,308,000"), not the
  # old "$2.3M", so it is wider than the abbreviated version needed.
  bar_h <- 13; gap <- 7; label_w <- 170; chart_w <- 680
  plot_w <- chart_w - label_w - 112
  height <- length(agencies) * (bar_h + gap) + 8

  bars <- lapply(seq_along(agencies), function(i) {
    a <- agencies[[i]]
    y <- (i - 1) * (bar_h + gap) + 4
    x <- label_w
    pieces <- list()
    for (seg in segments) {
      keep <- group_values == a
      value <- sum(seg_values[keep, seg$key])
      if (value <= 0) next
      w <- max(1, value / max_total * plot_w)
      n <- sum(keep & seg_values[, seg$key] > 0)
      pieces[[length(pieces) + 1L]] <- tags$g(
        tags$title(sprintf("%s — %s %s across %d %s", a, seg$label, cls_format_commas(value), n, if (n == 1) "request" else "requests")),
        tags$rect(x = x, y = y, width = w, height = bar_h, rx = 2, class = paste("cls-chart-bar", seg$class))
      )
      x <- x + w
    }
    tags$g(
      tags$text(x = label_w - 6, y = y + bar_h / 2 + 3, `text-anchor` = "end", class = "cls-chart-label", substr(a, 1, 30)),
      pieces,
      tags$text(x = min(x + 5, chart_w - 4), y = y + bar_h / 2 + 3, class = "cls-chart-value", cls_format_commas(totals[[i]]))
    )
  })

  legend_items <- lapply(segments, function(seg) {
    total <- sum(seg_values[, seg$key])
    if (total <= 0) return(NULL)
    span(class = "cls-chart-legend-item",
      span(class = paste("cls-chart-swatch", seg$class)),
      paste0(seg$label, " ", cls_format_commas(total)))
  })

  div(
    class = "cls-chart-wrap",
    tags$svg(
      class = "cls-chart", viewBox = paste("0 0", chart_w, height),
      role = "img", `aria-label` = paste("Requested dollars by", group_noun, "split by approval decision"),
      preserveAspectRatio = "xMinYMin meet",
      bars
    ),
    div(class = "cls-chart-legend", legend_items),
    p(class = "cls-chart-caption", sprintf(
      "Requested dollars by %s (top 10), split by approval decision. Hover a segment for its amount and request count.",
      group_noun))
  )
}

# BBMR export: every agency and service, with the review/approval fields added.
cls_review_export_sheets <- function(db) {
  rows <- cls_review_rows(db)
  numv <- function(x) suppressWarnings(as.numeric(x))
  if (is.null(rows) || !nrow(rows)) {
    empty <- data.frame(Agency = character(0), Request = character(0), stringsAsFactors = FALSE)
    return(list(`Requests and decisions` = empty, `Line items` = empty, `Personnel` = empty))
  }

  requests_df <- data.frame(
    Agency = rows$agency,
    Request = rows$request_name,
    Service = rows$service,
    Type = rows$request_type,
    Status = rows$status,
    `FY28 amount` = numv(rows$request_amount),
    `FY29 amount` = numv(rows$amount_next_fy),
    `FY30 amount` = numv(rows$amount_2next_fy),
    Duration = ifelse(rows$one_time %in% TRUE, "One-time", "Recurring"),
    `Objects` = rows$line_count,
    `Object total` = numv(rows$line_total),
    `Positions` = rows$position_count,
    `Position cost` = numv(rows$position_salary),
    `Analyst approval` = rows$analyst_approval,
    `BBMR approval` = rows$bbmr_approval,
    `Analyst notes` = rows$analyst_notes,
    Summary = rows$overall_summary,
    `Created date` = rows$created_at,
    `Created by email` = rows$created_by_email,
    `Modified date` = rows$updated_at,
    `Modified by email` = rows$modified_by_email,
    check.names = FALSE, stringsAsFactors = FALSE
  )

  lines <- db$budget_cls_request_line
  lines_df <- if (!is.null(lines) && nrow(lines)) {
    keep <- lines[lines$cls_id %in% rows$cls_id, , drop = FALSE]
    idx <- match(keep$cls_id, rows$cls_id)
    data.frame(
      Agency = rows$agency[idx],
      Request = rows$request_name[idx],
      Status = rows$status[idx],
      `BBMR approval` = rows$bbmr_approval[idx],
      Object = as.character(keep$object_category),
      `Spend category` = as.character(keep$spend_category),
      Amount = numv(keep$amount),
      Justification = as.character(keep$justification),
      check.names = FALSE, stringsAsFactors = FALSE
    )
  } else {
    data.frame(Agency = character(0), Request = character(0), Status = character(0), `BBMR approval` = character(0),
               Object = character(0), `Spend category` = character(0), Amount = numeric(0), Justification = character(0),
               check.names = FALSE, stringsAsFactors = FALSE)
  }

  positions <- db$budget_cls_request_position
  pos_df <- if (!is.null(positions) && nrow(positions)) {
    keep <- positions[positions$cls_id %in% rows$cls_id, , drop = FALSE]
    idx <- match(keep$cls_id, rows$cls_id)
    data.frame(
      Agency = rows$agency[idx],
      Request = rows$request_name[idx],
      Status = rows$status[idx],
      `BBMR approval` = rows$bbmr_approval[idx],
      Classification = as.character(keep$classification),
      Positions = suppressWarnings(as.integer(keep$position_count)),
      `Estimated cost` = numv(keep$estimated_salary),
      Justification = as.character(keep$justification),
      Explanation = as.character(keep$explanation),
      check.names = FALSE, stringsAsFactors = FALSE
    )
  } else {
    data.frame(Agency = character(0), Request = character(0), Status = character(0), `BBMR approval` = character(0),
               Classification = character(0), Positions = integer(0), `Estimated cost` = numeric(0),
               Justification = character(0), Explanation = character(0), check.names = FALSE, stringsAsFactors = FALSE)
  }

  list(`Requests and decisions` = requests_df, `Line items` = lines_df, `Personnel` = pos_df)
}

# Bulk approve grid: one row per request in the current filter, replacing the
# collapsible table rather than sitting on top of it. Kept to a single line per
# request and inside the page width (analyst feedback round 1).
cls_bulk_grid <- function(rows, approval_choices) {
  if (is.null(rows) || !nrow(rows)) {
    return(div(class = "cls-empty-state", p(class = "empty-state-copy", "No requests match the current filters.")))
  }
  # FY29/FY30 came off and Request type went on: the out-years are not what a
  # bulk decision turns on, the type is (analyst feedback round 2).
  head_row <- div(
    class = "cls-bulk-row cls-bulk-head",
    span("Agency"), span("Service"), span("Request"), span("Type"),
    span(class = "num", "FY28"),
    span("Duration"), span(class = "num", "Pos."),
    span("Analyst rec."),
    span("BBMR approval"), span(class = "num", "Appr. FY28"), span(class = "num", "Appr. pos."),
    span(class = "cls-bulk-back-head", "Return")
  )
  body <- lapply(seq_len(nrow(rows)), function(i) {
    r <- rows[i, , drop = FALSE]
    id <- r$cls_id
    cell <- function(v) span(title = v, v)
    div(
      class = "cls-bulk-row",
      cell(r$agency),
      cell(r$service),
      cell(r$request_name),
      # Full definition of the type on hover, as on the collapsed review row.
      span(title = cls_request_type_tooltip(r$request_type),
           if (nzchar(as.character(r$request_type %||% ""))) r$request_type else "—"),
      # Whole dollars here rather than cents: amounts are integers now, so the
      # cents were always ".00" and the width is better spent on the Return column.
      span(class = "num", cls_format_commas(r$request_amount)),
      cell(if (isTRUE(r$one_time)) "One-time" else "Recurring"),
      span(class = "num", r$position_count),
      # The analyst recommendation is context for the decision, not part of it, so
      # it is read-only here: a bulk approver can see the advice without being able
      # to overwrite it. It stays editable in the per-request analyst panel.
      span(class = "cls-bulk-analyst",
           title = if (nzchar(as.character(r$analyst_approval %||% ""))) {
             paste("Analyst recommendation:", r$analyst_approval)
           } else "No analyst recommendation recorded",
           if (nzchar(as.character(r$analyst_approval %||% ""))) r$analyst_approval else "—"),
      selectInput(paste0("cls_bulk_bbmr_", id), NULL, choices = approval_choices,
                  selected = r$bbmr_approval, selectize = FALSE, width = "100%"),
      cls_money_input(paste0("cls_bulk_amount_", id), NULL,
                      value = if (!is.na(r$approved_amount)) r$approved_amount else NA),
      cls_money_input(paste0("cls_bulk_positions_", id), NULL,
                      value = if (!is.na(r$approved_positions)) r$approved_positions else NA),
      # Send back: hands the request to the agency to rework, which means
      # unlocking it. Only offered for a request that is currently locked -
      # anything still In Progress or in Agency Review is already theirs.
      if (cls_status_is_complete(r$status)) {
        tags$button(
          type = "button", class = "civic-button secondary small cls-icon-only cls-bulk-back",
          `data-cls-send-back` = id, `data-cls-name` = r$request_name,
          title = paste0("Send “", r$request_name, "” back to the agency to rework. This unlocks it for editing."),
          `aria-label` = paste("Send", r$request_name, "back to the agency"),
          icon("rotate-left")
        )
      } else {
        span(class = "cls-bulk-back-na", title = "Already with the agency", "—")
      }
    )
  })
  tagList(
    div(class = "cls-bulk-scroll", div(class = "cls-bulk-grid", head_row, body)),
    p(class = "cls-bulk-hint",
      "Leave a row's approval blank to skip it. Approved FY28 and Approved pos. are what the agency will see.",
      tags$br(),
      "Return sends a request back to the agency and unlocks it for editing, clearing any decision already recorded.")
  )
}

# The Budget Planning section on CLS Review: the two pages the section contains,
# named and nothing more. It started out with descriptions, Open buttons and a
# test-agency panel; all three were removed on request (2026-08-04) - reviewers
# reach both pages from the left nav, so this is orientation, not navigation.
cls_budget_planning_section <- function(db, app_roles = character(0)) {
  tags$section(
    class = "section-surface cls-bp-section",
    div(class = "surface-header", div(h2("Budget Planning"))),
    tags$ul(
      class = "cls-bp-list",
      tags$li("CLS Requests"),
      tags$li("CLS Review")
    )
  )
}

page_cls_review <- function(db, app_roles = character(0), status_filter = character(0), agency_filter = character(0),
                            service_filter = character(0), bulk_mode = FALSE) {
  rows <- cls_review_rows(db)
  total_pending <- if (nrow(rows)) nrow(rows) else 0L
  complete_rows <- if (nrow(rows)) rows[rows$completed, , drop = FALSE] else rows
  total_for_review <- if (nrow(complete_rows)) nrow(complete_rows) else 0L
  # Total requested and Total positions count EVERY request, not just the ones
  # already sent to BBMR. Counting only the sent ones made the card disagree with
  # the sum of the table below it, which read as broken (analyst feedback).
  total_dollars <- if (nrow(rows)) sum(rows$request_amount, na.rm = TRUE) else 0
  total_positions <- if (nrow(rows)) sum(rows$position_count, na.rm = TRUE) else 0

  agency_choices <- if (nrow(rows)) sort(unique(rows$agency)) else character(0)
  service_choices_rv <- if (nrow(rows)) sort(unique(rows$service)) else character(0)
  status_choices <- cls_status_choices
  sel_status <- if (length(status_filter)) status_filter else status_choices
  sel_agency <- if (length(agency_filter)) agency_filter else agency_choices
  sel_service <- if (length(service_filter)) service_filter else service_choices_rv

  view_rows <- rows
  if (nrow(view_rows) && length(sel_status)) {
    view_rows <- view_rows[view_rows$status %in% sel_status, , drop = FALSE]
  }
  if (nrow(view_rows) && length(sel_agency)) {
    view_rows <- view_rows[view_rows$agency %in% sel_agency, , drop = FALSE]
  }
  if (nrow(view_rows) && length(sel_service)) {
    view_rows <- view_rows[view_rows$service %in% sel_service, , drop = FALSE]
  }

  # Two separate vocabularies on purpose: the analyst recommends, BBMR approves.
  # Sharing one list made the advisory field look as binding as the decision.
  approval_choices <- c(stats::setNames("", "(not set)"),
                        stats::setNames(cls_bbmr_approval_choices, cls_bbmr_approval_choices))
  analyst_choices <- c(stats::setNames("", "(not set)"),
                       stats::setNames(cls_analyst_recommendation_choices, cls_analyst_recommendation_choices))
  review_rows_ui <- lapply(seq_len(nrow(view_rows)), function(i) {
    r <- view_rows[i, , drop = FALSE]
    id <- r$cls_id
    div(
      class = "cls-rv-row",
      # Collapsed summary line — the whole row toggles the detail panel.
      tags$button(
        type = "button", class = "cls-rv-head", `data-cls-rv-toggle` = id, `aria-expanded` = "false",
        span(class = "cls-rv-caret", icon("chevron-right")),
        span(class = "cls-rv-name", r$request_name),
        span(class = "cls-rv-agency", r$agency),
        span(class = "cls-rv-service", r$service),
        span(class = "cls-rv-positions", r$position_count),
        # Unrounded at the rolled-up level: BBMR needs to trace the exact figure.
        span(class = "cls-rv-amount", cls_format_dollars(r$request_amount)),
        span(class = "cls-rv-status", cls_status_chip(r$status))
      ),
      div(
        id = paste0("cls_rv_body_", id), class = "cls-rv-body", style = "display:none;",
        # Agency, Service, FY28, Positions and Status are already on the collapsed
        # row, so the panel adds only what isn't there: summary, type with its
        # definition, duration, and the out-years.
        if (nzchar(r$overall_summary)) div(class = "cls-rv-summary", tags$strong("Summary. "), r$overall_summary),
        div(
          class = "cls-rv-meta",
          div(class = "cls-rv-meta-line",
            span(class = "cls-detail-label", "Type:"),
            span(class = "cls-rv-type", title = cls_request_type_tooltip(r$request_type),
              if (nzchar(r$request_type)) r$request_type else "—",
              tags$span(class = "cls-rv-type-hint", icon("circle-info")))),
          div(class = "cls-rv-meta-line",
            span(class = "cls-detail-label", "Duration:"),
            span(if (isTRUE(r$one_time)) "One-time" else "Recurring")),
          div(class = "cls-rv-submitted",
            cls_detail_field("FY28", cls_format_dollars(r$request_amount)),
            cls_detail_field("FY29", cls_format_dollars(r$amount_next_fy)),
            cls_detail_field("FY30", cls_format_dollars(r$amount_2next_fy)))
        ),
        # Objects and positions, laid out like the request page so reviewers see
        # the same breakdown the agency entered.
        {
          lr <- db$budget_cls_request_line
          lr <- if (!is.null(lr) && nrow(lr)) lr[lr$cls_id == id, , drop = FALSE] else NULL
          div(
            class = "cls-rv-block",
            div(class = "cls-rv-block-title", "Request details"),
            if (is.null(lr) || !nrow(lr)) {
              p(class = "empty-state-copy", "No objects were entered.")
            } else {
              div(class = "app-table cls-line-table",
                div(class = "table-row table-head cls-line-row", span("Object"), span("Spend category"), span("Amount"), span("Justification"), span("")),
                lapply(seq_len(nrow(lr)), function(j) {
                  li <- lr[j, , drop = FALSE]
                  div(class = "table-row cls-line-row",
                    span(if (nzchar(as.character(li$object_category %||% ""))) li$object_category else "—"),
                    span(if (nzchar(as.character(li$spend_category %||% ""))) li$spend_category else "—"),
                    span(class = "cls-request-amount", cls_format_dollars(li$amount)),
                    span(if (nzchar(as.character(li$justification %||% ""))) li$justification else "—"),
                    span(""))
                }))
            }
          )
        },
        {
          pr <- db$budget_cls_request_position
          pr <- if (!is.null(pr) && nrow(pr)) pr[pr$cls_id == id, , drop = FALSE] else NULL
          div(
            class = "cls-rv-block",
            div(class = "cls-rv-block-title", "Position requests"),
            if (is.null(pr) || !nrow(pr)) {
              p(class = "empty-state-copy", "No positions were requested.")
            } else {
              div(class = "app-table cls-position-table",
                div(class = "table-row table-head cls-position-row", span("Classification"), span("Positions"), span("Est. cost"), span("Justification"), span("")),
                lapply(seq_len(nrow(pr)), function(j) {
                  po <- pr[j, , drop = FALSE]
                  div(class = "table-row cls-position-row",
                    span(po$classification),
                    span(as.character(po$position_count %||% 0)),
                    span(class = "cls-request-amount", cls_format_dollars(po$estimated_salary)),
                    span(if (nzchar(as.character(po$justification %||% ""))) po$justification else "—"),
                    span(""))
                }))
            },
            if (!is.null(pr) && nrow(pr) && any(nzchar(as.character(pr$explanation %||% "")))) {
              div(class = "cls-rv-explanations",
                lapply(seq_len(nrow(pr)), function(j) {
                  ex <- as.character(pr$explanation[j] %||% "")
                  if (!nzchar(ex)) return(NULL)
                  p(class = "cls-rv-explanation", tags$strong(paste0(pr$classification[j], ". ")), ex)
                }))
            }
          )
        },
        div(
          class = "cls-review-fields cls-analyst-panel",
          div(class = "cls-analyst-panel-title", "Analyst review"),
          div(class = "cls-review-field-grid",
            # Advisory only - deliberately not wired to the request status.
            selectInput(paste0("cls_rv_analyst_", id), "Analyst recommendation", choices = analyst_choices, selected = r$analyst_approval, selectize = FALSE),
            # This one does set the status, which is why it is called out in red.
            div(class = "cls-bbmr-approval-field",
              selectInput(paste0("cls_rv_bbmr_", id), "BBMR approval", choices = approval_choices, selected = r$bbmr_approval, selectize = FALSE),
              div(class = "cls-status-warning", "THIS STATUS IS SENT TO AGENCIES"))
          ),
          # Approved prefills from the request; Partial starts blank so the
          # reviewer types what was actually approved.
          div(
            class = "cls-approved-fields",
            `data-cls-approved-for` = id,
            style = if (r$bbmr_approval %in% c("Approved", "Partial")) NULL else "display:none;",
            div(class = "cls-review-field-grid",
              # A stored decision always wins; otherwise Approved prefills from
              # the request and Partial starts blank for the reviewer to fill.
              cls_money_input(paste0("cls_rv_appr_amount_", id), "Approved FY28",
                value = if (!is.na(r$approved_amount)) r$approved_amount
                        else if (identical(r$bbmr_approval, "Approved")) suppressWarnings(as.numeric(r$request_amount))
                        else NA),
              cls_money_input(paste0("cls_rv_appr_positions_", id), "Approved positions",
                value = if (!is.na(r$approved_positions)) r$approved_positions
                        else if (identical(r$bbmr_approval, "Approved")) suppressWarnings(as.integer(r$position_count))
                        else NA))
          ),
          div(class = "cls-field-full", textAreaInput(paste0("cls_rv_notes_", id), "Analyst notes", value = r$analyst_notes, width = "100%", rows = 2, resize = "vertical")),
          div(class = "cls-rv-actions",
            tags$button(type = "button", class = "civic-button secondary small", `data-cls-open` = id,
              `aria-label` = paste("Open request", r$request_name), icon("up-right-from-square"), "Open request"),
            tags$button(type = "button", class = "civic-button primary small", `data-cls-review-save` = id, icon("check"), "Save review"))
        )
      )
    )
  })

  tagList(
    div(
      class = "briefing-header compact",
      div(
        div(class = "eyebrow", "BBMR"),
        h1("CLS Review"),
        p("Review Current Level of Service requests submitted by agencies and record approval decisions.")
      ),
      status_chip(paste(total_for_review, "ready"), "success")
    ),
    # Budget Planning at a glance: both pages in the section, named and linked, so
    # every reviewer can find them rather than having to know the nav (2026-08-03).
    cls_budget_planning_section(db, app_roles),
    div(
      class = "cls-review-overview",
      div(
        class = "dashboard-grid cls-review-grid",
        metric_tile("Pending Requests", total_pending),
        metric_tile("Requests for Review", total_for_review, tone = "success"),
        metric_tile("Total requested", cls_format_commas(total_dollars)),
        metric_tile("Total positions", total_positions)
      ),
      cls_collapsible_chart("review", "Request volume",
        "How requested dollars are distributed across agencies.", cls_review_chart(rows))
    ),
    div(
      class = "cls-review-divider",
      span(class = "cls-review-divider-label", "Review")
    ),
    surface(
      if (isTRUE(bulk_mode)) "Bulk approve" else "Review requests",
      if (isTRUE(bulk_mode)) {
        "Set a decision on every request in the current filter, then Save and close."
      } else {
        "Filter by status, agency or service, then expand a request to record its approval."
      },
      actions = if (isTRUE(bulk_mode)) {
        tagList(
          actionButton("cls_bulk_save", label = tagList(icon("check"), "Save and close"), class = "civic-button primary small"),
          tags$button(type = "button", class = "civic-button secondary small",
            `data-cls-bulk-approve` = "close", icon("xmark"), "Cancel")
        )
      } else {
        tags$button(type = "button", class = "civic-button primary small",
          `data-cls-bulk-approve` = "open", icon("table-list"), "Bulk Approve")
      },
      # Analyst feedback: the filters had an Apply step that made them look
      # broken. They now filter the table as soon as a selection changes.
      div(
        class = "cls-review-filters",
        div(class = "measure-field", cls_check_dropdown("cls_review_status_filter", "Status", status_choices, sel_status)),
        div(class = "measure-field", cls_check_dropdown("cls_review_agency_filter", "Agency", agency_choices, sel_agency)),
        div(class = "measure-field", cls_check_dropdown("cls_review_service_filter", "Service", service_choices_rv, sel_service)),
        div(
          class = "cls-review-filter-actions",
          actionButton("cls_review_reset_filters", "Reset filters", class = "civic-button secondary small")
        )
      ),
      div(
        class = "cls-rv-toolbar",
        div(class = "cls-rv-count", paste(nrow(view_rows), if (nrow(view_rows) == 1) "request" else "requests")),
        div(class = "cls-export-bar cls-export-bar-inline",
          span(class = "cls-export-label", "Export all agencies:"),
          downloadButton("cls_review_export_xlsx", label = tagList(icon("file-excel"), "Excel"), class = "civic-button secondary small"))
      ),
      if (isTRUE(bulk_mode)) {
        cls_bulk_grid(view_rows, approval_choices)
      } else if (!length(review_rows_ui)) {
        div(class = "cls-empty-state", p(class = "empty-state-copy", "No requests match the current filters."))
      } else {
        div(
          class = "cls-rv-table",
          div(class = "cls-rv-head cls-rv-header-row",
            span(class = "cls-rv-caret"),
            span(class = "cls-rv-name", "Request"),
            span(class = "cls-rv-agency", "Agency"),
            span(class = "cls-rv-service", "Service"),
            span(class = "cls-rv-positions", "Positions"),
            span(class = "cls-rv-amount", "FY28"),
            span(class = "cls-rv-status", "Status")
          ),
          review_rows_ui
        )
      }
    )
  )
}

cls_detail_field <- function(label, value) {
  # Values are kept to one line, so carry the full text as a tooltip for the few
  # (long service names, long request types) that end up truncated.
  tip <- if (is.character(value) && length(value) == 1 && !is.na(value) && nzchar(value)) value else NULL
  div(
    class = "cls-detail-field",
    span(class = "cls-detail-label", label),
    span(class = "cls-detail-value", title = tip, value)
  )
}

page_cls_request_detail <- function(db, cls_id, app_roles = character(0), agency_id = NULL, origin_page = NULL,
                                    editing_line_id = NA_integer_, editing_position_id = NA_integer_) {
  can_edit <- can_edit_cls_requests(app_roles)
  editing_line_id <- suppressWarnings(as.integer(editing_line_id))
  editing_position_id <- suppressWarnings(as.integer(editing_position_id))
  cls_id_int <- suppressWarnings(as.integer(cls_id))
  is_new <- is.na(cls_id_int)
  num_value <- function(x) {
    x <- suppressWarnings(as.numeric(x))
    if (length(x) != 1 || is.na(x)) NA else x
  }
  type_choices <- c("(select a type)" = "", cls_request_type_choices)
  # BBMR reviewers arrive from the CLS Review workspace, so send them back there
  # (they can still edit; only the return destination differs). Anyone who opened
  # the request from CLS Review returns to CLS Review even if they also hold an
  # agency role, and a reviewer with no agency list access never gets offered it.
  came_from_review <- identical(as.character(origin_page %||% ""), "cls_review")
  # Deliberately keyed on BBMRReviewer, not can_review_cls(): that predicate also
  # covers SystemAdmin, and since Budget Planning is currently SystemAdmin-only a
  # broader test would make every request read-only for the one role that can
  # reach the page at all.
  is_bbmr_reviewer <- has_any_role(app_roles, "BBMRReviewer")
  # Two separate questions. Where does Back go? Whoever opened this from CLS
  # Review returns there - BBMR reviewers and SystemAdmins alike.
  back_to_review <- came_from_review ||
    (can_review_cls(app_roles) && !can_view_cls_requests(app_roles))
  # Whether the page is read-only is decided below, once the owning agency is
  # known - a reviewer may edit a TEST agency. (A `reviewer_view` variable used to
  # sit here; it has had no readers since that logic moved to read_only_reason.)
  back_link <- if (back_to_review) {
    tags$button(type = "button", class = "cls-back-link", `data-page` = "cls_review", icon("arrow-left"), "Back to CLS Review")
  } else {
    tags$button(type = "button", class = "cls-back-link", `data-page` = "cls_requests", icon("arrow-left"), "Back to CLS requests")
  }

  request <- NULL
  if (!is_new) {
    requests <- db$budget_cls_request
    request <- if (!is.null(requests) && nrow(requests)) requests[requests$cls_id == cls_id_int, , drop = FALSE] else NULL
    if (is.null(request) || !nrow(request)) {
      return(div(
        class = "cls-detail-shell",
        div(class = "cls-detail-topbar", back_link),
        tags$section(class = "section-surface", h2("Request not found"), p("This request could not be found. It may have been deleted."))
      ))
    }
    request <- request[1, , drop = FALSE]
  }

  # Which agency owns this request has to be known before deciding whether the
  # page is read-only, because a BBMR reviewer may edit a TEST agency's requests.
  plan <- if (is_new) current_plan(db, agency_id) else db$planning_agency_plan[db$planning_agency_plan$plan_id == request$plan_id[[1]], , drop = FALSE]
  # Services come from every plan rolling up to the agency, so a request can be
  # filed against any of its entities' services.
  cls_agency <- if (is_new) cls_agency_id_for_submitter(db, agency_id) else {
    if (nrow(plan) && !is.na(plan$agency_id[[1]])) as.character(plan$agency_id[[1]])
    else cls_agency_id_for_submitter(db, paste0("entity:", plan$entity_id[[1]]))
  }
  # Analyst feedback, round 1: once a request has gone to BBMR the agency can no
  # longer change it, and BBMR reviewers see it read-only too - their decision is
  # recorded on the CLS Review page, not by editing the agency's submission.
  #
  # A test-agency exception was added 2026-08-03 and removed again 2026-08-04:
  # reviewers now see every agency, and read-only applies uniformly.
  locked_status <- !is_new && cls_status_is_complete(cls_status_label(request))
  read_only_reason <- if (is_bbmr_reviewer) {
    "BBMR reviewers open requests read-only. Record your decision on the CLS Review page."
  } else if (locked_status) {
    "This request has been sent for BBMR review, so it can no longer be changed."
  } else NULL
  if (!is.null(read_only_reason)) can_edit <- FALSE
  service_choices <- cls_agency_service_choices(db, cls_agency)
  if (!length(service_choices)) service_choices <- cls_plan_service_choices(db, plan)
  cur_ps <- if (is_new) NULL else as.character(request$plan_service_id[[1]])
  if (!is_new && !is.null(cur_ps) && !cur_ps %in% unname(service_choices)) {
    service_choices <- c(stats::setNames(cur_ps, cls_service_label(db, request$service_id)), service_choices)
  }
  submitter <- cls_submitter_name(db, plan)
  # All Agency Submitters on the agency, for the notice at the top of the page.
  submitter_names <- cls_submitter_names_for_agency(db, cls_agency)
  submitter_unnamed <- identical(submitter_names, "Your Agency Submitter")
  submitter_is_plural <- grepl(" and ", submitter_names, fixed = TRUE)
  page_title <- if (is_new) "New CLS request" else {
    nm <- as.character(request$request_name %||% "CLS request")
    # A freshly created draft has not been named yet.
    if (identical(nm, CLS_DRAFT_NAME) || !nzchar(trimws(nm))) "New CLS request" else nm
  }

  # Field label with an info icon to its right; the panel opens below the input.
  cls_labelled_info <- function(label, panel, id) {
    tagList(
      div(
        class = "cls-label-row",
        tags$span(class = "control-label", label),
        tags$button(
          type = "button", class = "cls-info-toggle", `data-cls-info` = id,
          `aria-label` = paste("About", label), `aria-expanded` = "false",
          icon("circle-info")
        )
      ),
      div(id = paste0("cls_info_", id), class = "cls-info-panel", style = "display:none;", panel)
    )
  }

  type_info_panel <- div(
    class = "cls-type-info-body",
    tags$table(
      class = "cls-type-table",
      tags$thead(tags$tr(tags$th("Adjustment type"), tags$th("Description"), tags$th("Example"))),
      tags$tbody(lapply(cls_adjustment_type_guidance, function(row) {
        tags$tr(tags$td(tags$strong(row[[1]])), tags$td(row[[2]]), tags$td(row[[3]]))
      }))
    )
  )

  onetime_info_panel <- p(
    class = "cls-info-copy",
    "Subscriptions and Professional Services purchased for multi-year contracts are recurring if the agency plans to use their services indefinitely. Especially in these cases, the FY29 and FY30 year amounts will assume any year-over-year increase to the contract. Contact your budget analyst if you have any questions about how this should be input."
  )

  # ---- Summary section (merged header + request details) ----
  if (!can_edit && is_new) {
    summary_body <- div(class = "cls-empty-state", p(class = "empty-state-copy", "You do not have permission to create CLS requests."))
  } else if (!can_edit) {
    r <- request
    rtype <- as.character(r$request_type %||% ""); if (is.na(rtype)) rtype <- ""
    summary_body <- tagList(
      div(class = "cls-form-service", span(class = "cls-detail-label", "Service"), tags$strong(cls_service_label(db, r$service_id))),
      if (nzchar(rtype)) div(class = "chip-row cls-detail-chips", status_chip(rtype, "primary"), status_chip(if (isTRUE(r$one_time)) "One-time" else "Ongoing", if (isTRUE(r$one_time)) "warning" else "success")),
      div(
        class = "cls-detail-grid",
        cls_detail_field("Request amount", cls_format_dollars(r$request_amount)),
        if (!isTRUE(r$one_time)) cls_detail_field("FY29 amount", cls_format_dollars(r$amount_next_fy)),
        if (!isTRUE(r$one_time)) cls_detail_field("FY30 amount", cls_format_dollars(r$amount_2next_fy))
      ),
      if (nzchar(as.character(r$overall_summary %||% ""))) div(class = "cls-detail-summary", tags$strong("Summary"), p(r$overall_summary))
    )
  } else if (is_new && !length(service_choices)) {
    summary_body <- div(class = "cls-empty-state", p(class = "empty-state-copy", "This plan has no services available to attach a request to."))
  } else {
    v_name <- if (is_new) "" else {
      nm <- as.character(request$request_name %||% "")
      # Drafts are created under a placeholder name; show it blank so the user
      # types their own rather than editing around ours.
      if (identical(nm, CLS_DRAFT_NAME)) "" else nm
    }
    v_type <- if (is_new) "" else { t <- as.character(request$request_type %||% ""); if (is.na(t)) "" else t }
    v_amount <- if (is_new) NA else num_value(request$request_amount)
    v_next <- if (is_new) NA else num_value(request$amount_next_fy)
    v_2next <- if (is_new) NA else num_value(request$amount_2next_fy)
    v_onetime <- if (is_new) FALSE else isTRUE(request$one_time)
    v_summary <- if (is_new) "" else as.character(request$overall_summary %||% "")
    summary_body <- tagList(
      p(class = "cls-request-intro",
        "Describe the ", tags$strong(class = "cls-intro-name", if (nzchar(v_name)) v_name else "request"),
        " by line item and any positions below. Each request should encompass an initiative and all of the accompanying costs."),
      div(class = "cls-field-full", `data-cls-required` = "true",
        textInput("cls_form_name", "Request name", value = v_name, width = "100%", placeholder = "A short, descriptive name for this request")),
      div(class = "cls-field-full", `data-cls-required` = "true",
        selectInput("cls_form_service", "Service", choices = service_choices, selected = cur_ps, selectize = FALSE, width = "100%")),
      div(class = "cls-field-full cls-type-field",
        cls_labelled_info("Request type", type_info_panel, "type"),
        selectInput("cls_form_type", label = NULL, choices = type_choices, selected = v_type, selectize = FALSE, width = "100%")),
      div(class = "cls-field-full cls-onetime-field",
        cls_labelled_info("Request duration", onetime_info_panel, "onetime"),
        div(class = "cls-toggle-row",
          tags$label(
            class = "cls-switch",
            tags$input(id = "cls_form_one_time", type = "checkbox", class = "cls-switch-input",
              checked = if (isTRUE(v_onetime)) "checked" else NULL),
            tags$span(class = "cls-switch-track", tags$span(class = "cls-switch-thumb"))
          ),
          tags$span(id = "cls_onetime_label", class = "cls-switch-label",
            if (isTRUE(v_onetime)) "One-Time Request" else "Recurring Request")
        )
      ),
      # The two out-years are required for a recurring request and hidden for a
      # one-time one; the JS skips hidden required fields.
      div(class = "cls-amount-row",
        div(class = "cls-amount-cell", `data-cls-required` = "true", cls_money_input("cls_form_amount", "FY28 Amount", value = v_amount)),
        div(class = "cls-amount-cell cls-outyear-field", `data-cls-required` = "true", cls_money_input("cls_form_amount_next", "FY29 Amount", value = v_next)),
        div(class = "cls-amount-cell cls-outyear-field", `data-cls-required` = "true", cls_money_input("cls_form_amount_2next", "FY30 Amount", value = v_2next))
      ),
      div(class = "cls-field-full", `data-cls-required` = "true",
        textAreaInput("cls_form_summary", "Summarize the request", value = v_summary, width = "100%", rows = 4, resize = "vertical",
          placeholder = "Provide a short explanation of the request for review."),
        div(id = "cls_summary_wordcount", class = "cls-wordcount")),
      # No create button: filling in the name and service is enough for autosave
      # to create the request, after which details and positions unlock below.
      if (is_new) div(class = "cls-new-hint",
        span(class = "cls-reminder-icon", icon("circle-info")),
        span("Fill in the request name and service and this request saves itself — then break it out by object and positions below."))
    )
  }

  summary_section <- tags$section(
    class = "section-surface cls-summary-surface",
    div(class = "cls-summary-head cls-summary-head-stacked",
      div(class = "eyebrow", "Budget proposal • CLS request"),
      h2(class = "cls-detail-title", page_title)
    ),
    summary_body
  )

  details_subtext <- paste(
    "In this section you will provide the budget breakdown for the request by expenditure object.",
    "In the Object amount field, list the requested amount for that object — there should be one line per object.",
    "In the Justification field, explain the proposed amount.",
    "Use the Add Details button to keep adding objects until the full request is broken out by object."
  )

  if (is_new) {
    details_section <- tags$section(class = "section-surface",
      h2("Request details"),
      p(details_subtext),
      div(class = "cls-empty-state", p(class = "empty-state-copy", "Create the request above first — then break it out by expenditure object here.")))
    positions_section <- tags$section(class = "section-surface",
      h2("Position requests"),
      div(class = "cls-empty-state", p(class = "empty-state-copy", "Create the request above first — then add any position requests here.")))
  } else {
    lines <- db$budget_cls_request_line
    lines <- if (!is.null(lines) && nrow(lines)) lines[lines$cls_id == cls_id_int, , drop = FALSE] else NULL
    line_count <- if (is.null(lines)) 0L else nrow(lines)
    line_total <- if (line_count) sum(suppressWarnings(as.numeric(lines$amount)), na.rm = TRUE) else 0
    req_amount <- num_value(request$request_amount); if (is.na(req_amount)) req_amount <- 0
    remaining <- req_amount - line_total

    line_table <- if (!line_count) {
      div(class = "cls-empty-state", p(class = "empty-state-copy", "No objects yet."))
    } else {
      div(class = "app-table cls-line-table",
        div(class = "table-row table-head cls-line-row", span("Object"), span("Spend category"), span("Amount"), span("Justification"), span("")),
        lapply(seq_len(line_count), function(i) {
          li <- lines[i, , drop = FALSE]
          amt <- suppressWarnings(as.numeric(li$amount))
          spend <- as.character(li$spend_category %||% "")
          if (can_edit && !is.na(editing_line_id) && identical(as.integer(li$line_id[[1]]), editing_line_id)) {
            # Edit in place: the same four fields, pre-filled, with Save/Cancel.
            div(class = "table-row cls-line-row cls-row-editing",
              selectInput("cls_line_edit_category", NULL, choices = c("(select an object)" = "", cls_object_choices),
                selected = as.character(li$object_category %||% ""), selectize = FALSE, width = "100%"),
              selectInput("cls_line_edit_spend_category", NULL, choices = c("(select a spend category)" = "", cls_spend_category_options(db), CLS_NEW_SPEND_CATEGORY),
                selected = spend, selectize = FALSE, width = "100%"),
              cls_money_input("cls_line_edit_amount", NULL, value = if (is.na(amt)) NA else amt),
              textInput("cls_line_edit_justification", NULL, value = as.character(li$justification %||% ""), width = "100%"),
              div(class = "cls-request-actions cls-edit-actions",
                actionButton("cls_line_edit_save", label = icon("check"), class = "civic-button primary small cls-icon-only",
                  title = "Save this object"),
                tags$button(type = "button", class = "civic-button ghost small cls-icon-only",
                  `data-cls-cancel-edit` = "line", title = "Cancel", `aria-label` = "Cancel", icon("xmark"))))
          } else {
            div(class = "table-row cls-line-row", `data-cls-line-amount` = if (is.na(amt)) "" else as.character(amt),
              span(if (nzchar(as.character(li$object_category %||% ""))) li$object_category else "—"),
              span(if (nzchar(spend)) spend else "—"),
              span(class = "cls-request-amount", cls_format_dollars(li$amount)),
              span(if (nzchar(as.character(li$justification %||% ""))) li$justification else "—"),
              div(class = "cls-request-actions",
                if (can_edit) tags$button(type = "button", class = "civic-button ghost small cls-row-edit",
                  `data-cls-edit-line` = li$line_id, `aria-label` = "Edit this object", title = "Edit this object", icon("pen")),
                if (can_edit) tags$button(type = "button", class = "civic-button danger small", `data-cls-delete-line` = li$line_id, icon("trash-can"), "Remove")))
          }
        }))
    }
    line_add <- if (can_edit) div(class = "cls-add-form",
      div(class = "cls-add-form-title", "Add an object to this request"),
      div(class = "cls-form-grid",
        selectInput("cls_line_category", "Object", choices = c("(select an object)" = "", cls_object_choices), selectize = FALSE),
        selectInput("cls_line_spend_category", "Spend category",
          choices = c("(select a spend category)" = "", cls_spend_category_options(db), CLS_NEW_SPEND_CATEGORY), selectize = FALSE),
        cls_money_input("cls_line_amount", "Amount", value = NA)),
      div(class = "cls-field-full",
        tags$label(`for` = "cls_line_justification", class = "control-label", "Justification",
          # Shown only while "Create Spend Category" is picked - the justification
          # is where the new category gets described.
          tags$span(id = "cls_new_category_note", class = "cls-field-note", style = "display:none;",
            "Please describe the new spend category.")),
        textInput("cls_line_justification", label = NULL, width = "100%", placeholder = "Explain the proposed amount.")),
      div(class = "cls-form-actions", actionButton("cls_submit_line", label = tagList(icon("plus"), "Add Details"), class = "civic-button secondary small"))
    ) else NULL

    positions <- db$budget_cls_request_position
    positions <- if (!is.null(positions) && nrow(positions)) positions[positions$cls_id == cls_id_int, , drop = FALSE] else NULL
    position_count <- if (is.null(positions)) 0L else nrow(positions)
    position_total <- if (position_count) sum(suppressWarnings(as.numeric(positions$estimated_salary)), na.rm = TRUE) else 0
    # The request amount must be explained by objects *and* positions combined.
    accounted <- line_total + position_total
    remaining <- req_amount - accounted

    balanced <- req_amount > 0 && abs(remaining) < 0.005
    remaining_note <- div(
      class = paste("cls-remaining-note", if (balanced) "cls-remaining-ok" else if (req_amount > 0) "cls-remaining-over" else ""),
      `data-cls-request-amount` = as.character(req_amount),
      span(class = "cls-remaining-text",
        if (req_amount <= 0) {
          "Enter the FY28 Amount above, then describe it by object or positions."
        } else if (balanced) {
          sprintf("The total request of %s is fully described by object and positions.", cls_format_dollars(req_amount))
        } else if (remaining > 0) {
          sprintf("The total request needs to explain %s. Describe the request amount by object or positions.", cls_format_dollars(remaining))
        } else {
          sprintf("The total request exceeds %s. Reduce the request amount by object or positions.", cls_format_dollars(abs(remaining)))
        }))

    details_section <- tags$section(class = "section-surface cls-details-surface",
      remaining_note,
      h2("Request details"),
      p(details_subtext),
      line_add,
      div(class = "cls-table-divider",
        span(class = "cls-table-divider-label", if (line_count == 1) "1 object added" else paste(line_count, "objects added"))),
      line_table)

    position_table <- if (!position_count) {
      div(class = "cls-empty-state", p(class = "empty-state-copy", "No position requests yet."))
    } else {
      div(class = "app-table cls-position-table",
        div(class = "table-row table-head cls-position-row", span("Classification"), span("Positions"), span("Est. cost"), span("Justification"), span("")),
        lapply(seq_len(position_count), function(i) {
          po <- positions[i, , drop = FALSE]
          amt <- suppressWarnings(as.numeric(po$estimated_salary))
          if (can_edit && !is.na(editing_position_id) && identical(as.integer(po$pos_id[[1]]), editing_position_id)) {
            div(class = "table-row cls-position-row cls-row-editing",
              textInput("cls_position_edit_classification", NULL, value = as.character(po$classification %||% ""), width = "100%"),
              cls_money_input("cls_position_edit_count", NULL, value = suppressWarnings(as.integer(po$position_count %||% 0))),
              cls_money_input("cls_position_edit_salary", NULL, value = if (is.na(amt)) NA else amt),
              textInput("cls_position_edit_justification", NULL, value = as.character(po$justification %||% ""), width = "100%"),
              div(class = "cls-request-actions cls-edit-actions",
                actionButton("cls_position_edit_save", label = icon("check"), class = "civic-button primary small cls-icon-only",
                  title = "Save this position"),
                tags$button(type = "button", class = "civic-button ghost small cls-icon-only",
                  `data-cls-cancel-edit` = "position", title = "Cancel", `aria-label` = "Cancel", icon("xmark"))))
          } else {
            div(class = "table-row cls-position-row", `data-cls-position-amount` = if (is.na(amt)) "" else as.character(amt),
              span(po$classification),
              span(as.character(po$position_count %||% 0)),
              span(class = "cls-request-amount", cls_format_dollars(po$estimated_salary)),
              span(if (nzchar(as.character(po$justification %||% ""))) po$justification else "—"),
              div(class = "cls-request-actions",
                if (can_edit) tags$button(type = "button", class = "civic-button ghost small cls-row-edit",
                  `data-cls-edit-position` = po$pos_id, `aria-label` = "Edit this position", title = "Edit this position", icon("pen")),
                if (can_edit) tags$button(type = "button", class = "civic-button danger small", `data-cls-delete-position` = po$pos_id, icon("trash-can"), "Remove")))
          }
        }))
    }
    position_add <- if (can_edit) div(class = "cls-add-form",
      div(class = "cls-form-grid",
        textInput("cls_position_classification", "Job classification", placeholder = "Classification title"),
        # Starts empty: a pre-filled 1 was being submitted unread (analyst
        # feedback round 2).
        cls_money_input("cls_position_count", "Position Count", value = NA),
        # TODO: link "Estimated Cost" to the salary/benefit cost reference once available.
        div(class = "cls-cost-field",
          tags$label(`for` = "cls_position_salary", class = "control-label",
            tags$a(href = "#", class = "cls-cost-link", `data-cls-cost-help` = "true", "Estimated Cost")),
          cls_money_input("cls_position_salary", label = NULL, value = NA))),
      div(class = "cls-field-full", textAreaInput("cls_position_justification", "Justify the need for creating additional positions", width = "100%", rows = 2, resize = "vertical")),
      div(class = "cls-field-full", textAreaInput("cls_position_explanation", "Explain how the additional positions are needed to maintain the current level of service", width = "100%", rows = 2, resize = "vertical")),
      div(class = "cls-form-actions", actionButton("cls_submit_position", label = tagList(icon("plus"), "Add position"), class = "civic-button secondary small"))
    ) else NULL

    show_positions <- position_count > 0
    positions_body <- div(id = "cls_positions_body", class = "cls-positions-body",
      style = if (show_positions) NULL else "display:none;",
      position_add, position_table)
    positions_section <- tags$section(class = "section-surface",
      h2("Position requests"),
      if (can_edit) div(class = "cls-positions-toggle", checkboxInput("cls_add_positions_toggle", "Add positions to this request", value = show_positions)),
      if (!can_edit && !show_positions) div(class = "cls-empty-state", p(class = "empty-state-copy", "No position requests were included.")) else positions_body)
  }

  reminder <- if (!is.null(read_only_reason)) div(class = "cls-reminder cls-reminder-locked",
    span(class = "cls-reminder-icon", icon("lock")),
    span(read_only_reason)
  ) else if (can_edit) div(class = "cls-reminder",
    span(class = "cls-reminder-icon", icon("circle-info")),
    # Every Agency Submitter on the agency is named, not just the first one
    # found: sign-off can sit with more than one person (analyst feedback round 2).
    if (submitter_unnamed) {
      span("This request must be sent to your Agency Submitter and submitted before your agency's CLS deadline.")
    } else {
      span("This request must be sent to ", tags$strong(submitter_names),
        if (submitter_is_plural) ", your Agency Submitters, " else ", your Agency Submitter, ",
        "and submitted before your agency's CLS deadline.")
    }
  ) else NULL

  div(
    class = "cls-detail-shell",
    div(
      class = "cls-detail-topbar",
      back_link,
      if (can_edit && !is_new) div(class = "cls-save-status", span(class = "cls-save-icon", icon("cloud-arrow-up")), uiOutput("cls_save_status", inline = TRUE))
    ),
    reminder,
    summary_section,
    details_section,
    positions_section
  )
}

page_ui <- function(page, db, agency_id, measure_status_filter = "All except deprecated", can_manage_team = FALSE, can_submit_plan = FALSE, app_roles = c("AgencyViewer"), agency_roles = character(0), selected_user_id = "", selected_review_plan_id = NA_integer_, selected_review_include_review = TRUE, feedback_filters = list(), selected_cls_id = NA_integer_, cls_review_filters = list(), cls_detail_origin = NULL, editing_line_id = NA_integer_, editing_position_id = NA_integer_, active_sessions = NA_integer_, active_users = NA_integer_) {
  if (identical(page, "services") && submitter_is_mayoral_service(db, agency_id)) {
    page <- "metrics"
  }
  if (identical(page, "cls_requests") && !can_view_cls_requests(app_roles)) {
    # BBMR reviewers land back in their own workspace rather than the agency list.
    page <- if (can_review_cls(app_roles)) "cls_review" else "landing"
  }
  if (identical(page, "cls_request_detail") && !can_open_cls_request(app_roles)) {
    page <- "landing"
  }
  if (identical(page, "cls_review") && !can_review_cls(app_roles)) {
    page <- "landing"
  }
  review_admin_mode <- uses_review_administration_mode(app_roles)
  if (review_admin_mode && page %in% c("strategic_plan", "plan_history", "overview", "goals", "services", "metrics", "risks")) {
    page <- "reviewer_dashboard"
  }
  if (identical(page, "publishing_queue") && !can_finalize_plans(app_roles)) {
    page <- "reviewer_dashboard"
  }
  if (identical(page, "approval_queue") && !can_view_plan_approval_queue_context(db, app_roles, selected_user_id)) {
    page <- "reviewer_dashboard"
  }
  if (identical(page, "measure_review") && !can_review_measures(app_roles)) {
    page <- if (can_view_plan_approval_queue(app_roles)) "approval_queue" else "reviewer_dashboard"
  }
  can_edit_plan <- can_edit_plan_sections(app_roles)
  team_scope_choices <- if (review_admin_mode) agency_choices_only(db) else NULL
  switch(
    page,
    login = page_login(),
    landing = page_landing(db, agency_id, app_roles, agency_roles),
    reviewer_dashboard = page_reviewer_dashboard(db, can_finalize_plans(app_roles), app_roles, selected_user_id),
    plan_review_detail = {
      selected_plan <- db$planning_agency_plan[db$planning_agency_plan$plan_id == suppressWarnings(as.integer(selected_review_plan_id)), , drop = FALSE]
      page_plan_review_detail(
        db,
        selected_review_plan_id,
        can_review_plans(app_roles),
        can_finalize_plans(app_roles),
        selected_review_include_review,
        can_route_plan_reviews(app_roles),
        can_approve_plan_gate_context(db, selected_plan, app_roles, selected_user_id),
        can_manage_plan_stamp_context(db, selected_plan, "DeputyMayor", app_roles, selected_user_id),
        can_manage_plan_stamp_context(db, selected_plan, "CAOffice", app_roles, selected_user_id)
      )
    },
    approval_queue = page_plan_approval_queue(db, app_roles, selected_user_id),
    publishing_queue = page_publishing_queue(db),
    measure_review = page_measure_review(db),
    action_plan_measures = if (can_view_performance_reviewing(app_roles)) page_action_plan_measures(db, can_review_measures(app_roles)) else page_landing(db, agency_id, app_roles, agency_roles),
    bug_fix = if (can_view_application_admin(app_roles)) {
      page_bug_fix(
        db,
        search = if (is.null(feedback_filters$search) || length(feedback_filters$search) == 0) "" else feedback_filters$search[[1]],
        category_filter = if (is.null(feedback_filters$category) || length(feedback_filters$category) == 0) character(0) else feedback_filters$category,
        priority_filter = if (is.null(feedback_filters$priority) || length(feedback_filters$priority) == 0) character(0) else feedback_filters$priority,
        status_filter = if (is.null(feedback_filters$status) || length(feedback_filters$status) == 0) character(0) else feedback_filters$status,
        active_sessions = active_sessions,
        active_users = active_users
      )
    } else page_landing(db, agency_id, app_roles, agency_roles),
    role_preview = if (can_view_application_admin(app_roles)) page_role_preview(db, app_roles, agency_roles, selected_user_id, agency_id) else page_landing(db, agency_id, app_roles, agency_roles),
    strategic_plan = page_strategic_plan(db, agency_id),
    team = page_team(db, agency_id, can_manage_team, team_scope_choices),
    plan_history = page_plan_history(db, agency_id, can_submit_plan),
    metrics = page_metrics(db, agency_id, measure_status_filter),
    overview = page_overview(db, agency_id, can_edit_plan),
    goals = page_goals(db, agency_id, can_edit_plan),
    services = page_services(db, agency_id, can_edit_plan, can_edit_shared_service_description(app_roles)),
    risks = page_risks(db, agency_id, can_edit_plan),
    cls_requests = if (can_access_budget_planning(app_roles)) page_cls_requests(db, agency_id, app_roles) else page_landing(db, agency_id, app_roles, agency_roles),
    cls_request_detail = if (can_access_budget_planning(app_roles)) page_cls_request_detail(db, selected_cls_id, app_roles, agency_id, cls_detail_origin, editing_line_id, editing_position_id) else page_landing(db, agency_id, app_roles, agency_roles),
    cls_review = if (can_access_budget_planning(app_roles)) page_cls_review(db, app_roles, cls_review_filters$status %||% character(0), cls_review_filters$agency %||% character(0), cls_review_filters$service %||% character(0), isTRUE(cls_review_filters$bulk)) else page_landing(db, agency_id, app_roles, agency_roles),
    page_landing(db, agency_id, app_roles, agency_roles)
  )
}

ui <- tagList(
  tags$head(
    tags$title("Beacon Baltimore City Performance & Budgeting"),
    tags$meta(name = "viewport", content = "width=device-width, initial-scale=1"),
    tags$link(rel = "stylesheet", href = "styles.css?v=20260804-1"),
    tags$script(src = "app.js?v=20260804-1", defer = "defer")
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
            div(class = "brand-subtitle", "Baltimore City Performance & Budgeting")
          )
        ),
        uiOutput("header_context_selector")
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
          nav_item("login", "Sign in", icon("right-to-bracket")),
          tags$button(
            type = "button",
            class = "nav-item auth-signout-action",
            `data-auth-action` = "sign-out",
            `aria-label` = "Sign out",
            span(class = "nav-icon", `aria-hidden` = "true", icon("right-from-bracket")),
            span(class = "nav-label", "Sign out")
          ),
          nav_item("strategic_plan", "Action plan", icon("clipboard-list"), item_class = "performance-planning-nav-item"),
          nav_item("landing", "Timeline", icon("calendar-days")),
          nav_item("team", "Team and roles", icon("users")),
          div(class = "nav-group-label performance-reviewing-nav-item", "Performance Reviewing"),
          uiOutput("performance_reviewing_nav"),
          div(class = "nav-group-label application-nav-item", "Application"),
          nav_item("role_preview", "Role preview", icon("user-shield"), item_class = "application-nav-item"),
          nav_item("bug_fix", "Bug/Fix", icon("bug"), item_class = "application-nav-item"),
          div(class = "nav-group-label performance-planning-nav-item", "Performance Planning"),
          nav_item("plan_history", "View plan", icon("file-circle-check"), item_class = "performance-planning-nav-item nav-review-plan-highlight"),
          nav_item("overview", "Overview & vision", icon("eye"), item_class = "performance-planning-nav-item"),
          nav_item("goals", "Goals", icon("flag"), item_class = "performance-planning-nav-item"),
          nav_item("services", "Services", icon("briefcase"), item_class = "nav-services-item performance-planning-nav-item"),
          nav_item("metrics", "Measures", icon("chart-line"), item_class = "performance-planning-nav-item"),
          nav_item("risks", "Risks", icon("triangle-exclamation"), item_class = "performance-planning-nav-item"),
          div(class = "nav-group-label cls-requests-nav-item", "Budget Planning"),
          nav_item("cls_requests", "CLS Requests", icon("file-invoice-dollar"), item_class = "cls-requests-nav-item"),
          nav_item("cls_review", "CLS Review", icon("magnifying-glass-dollar"), item_class = "cls-review-nav-item")
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
      nav_item("login", "Sign in", icon("right-to-bracket")),
      tags$button(
        type = "button",
        class = "nav-item auth-signout-action",
        `data-auth-action` = "sign-out",
        `aria-label` = "Sign out",
        span(class = "nav-icon", `aria-hidden` = "true", icon("right-from-bracket")),
        span(class = "nav-label", "Sign out")
      ),
      nav_item("strategic_plan", "Action plan", icon("clipboard-list"), item_class = "performance-planning-nav-item"),
      nav_item("landing", "Timeline", icon("calendar-days")),
      nav_item("team", "Team and roles", icon("users")),
      div(class = "nav-group-label performance-reviewing-nav-item", "Performance Reviewing"),
      uiOutput("mobile_performance_reviewing_nav"),
      div(class = "nav-group-label application-nav-item", "Application"),
      nav_item("role_preview", "Role preview", icon("user-shield"), item_class = "application-nav-item"),
      nav_item("bug_fix", "Bug/Fix", icon("bug"), item_class = "application-nav-item"),
      div(class = "nav-group-label performance-planning-nav-item", "Performance Planning"),
      nav_item("plan_history", "View plan", icon("file-circle-check"), item_class = "performance-planning-nav-item nav-review-plan-highlight"),
      nav_item("overview", "Overview & vision", icon("eye"), item_class = "performance-planning-nav-item"),
      nav_item("goals", "Goals", icon("flag"), item_class = "performance-planning-nav-item"),
      nav_item("services", "Services", icon("briefcase"), item_class = "nav-services-item performance-planning-nav-item"),
      nav_item("metrics", "Measures", icon("chart-line"), item_class = "performance-planning-nav-item"),
      nav_item("risks", "Risks", icon("triangle-exclamation"), item_class = "performance-planning-nav-item"),
      div(class = "nav-group-label cls-requests-nav-item", "Budget Planning"),
      nav_item("cls_requests", "CLS Requests", icon("file-invoice-dollar"), item_class = "cls-requests-nav-item"),
      nav_item("cls_review", "CLS Review", icon("magnifying-glass-dollar"), item_class = "cls-review-nav-item")
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
              div(tags$strong("Beacon"), span("Baltimore City Performance & Budgeting"))
            ),
            tags$a(class = "footer-city-link", href = "https://www.baltimorecity.gov/", target = "_blank", rel = "noopener", "BaltimoreCity.gov", icon("arrow-up-right-from-square"))
          ),
          div(
            class = "footer-column",
            tags$h2("Navigation"),
            tags$button(type = "button", class = "footer-link", `data-page` = "strategic_plan", "Action Plan"),
            tags$button(type = "button", class = "footer-link", `data-page` = "landing", "Timeline"),
            tags$button(type = "button", class = "footer-link", `data-page` = "plan_history", "View Plan"),
            tags$button(type = "button", class = "footer-link", `data-page` = "metrics", "Measures")
          ),
          div(
            class = "footer-column",
            tags$h2("Resources"),
            tags$a(class = "footer-link", href = "https://www.baltimorecity.gov/", target = "_blank", rel = "noopener", "BaltimoreCity.gov", icon("arrow-up-right-from-square")),
            tags$a(class = "footer-link", href = "https://s3.amazonaws.com/baltimorecity.gov.if-us-east-1/s3fs-public/2026-05/2026%20Mayor%27s%20Action%20Plan_0.pdf", target = "_blank", rel = "noopener", "Mayor's Action Plan", icon("arrow-up-right-from-square"))
          ),
          div(
            class = "footer-column footer-cta",
            tags$h2("Support"),
            p("Questions about performance planning, review routing, or Beacon?"),
            tags$a(class = "footer-contact-button", href = "mailto:melanie.lada@baltimorecity.gov", "Contact Support")
          )
        ),
        div(
          class = "footer-bottom",
          span("Copyright 2026 Baltimore City Government. All rights reserved."),
          div(
            class = "footer-policy-links",
            tags$a(href = "https://www.baltimorecity.gov/privacy", target = "_blank", rel = "noopener", "Privacy Policy"),
            tags$a(href = "https://www.baltimorecity.gov/accessibility", target = "_blank", rel = "noopener", "Accessibility")
          )
        )
      )
    ),
    uiOutput("pillar_modal"),
    uiOutput("history_plan_modal"),
    uiOutput("measure_modal"),
    uiOutput("risk_modal"),
    uiOutput("team_role_modal"),
    actionButton("open_feedback_modal", tagList(icon("comment-dots"), span("Feedback")), class = "floating-feedback-button"),
    uiOutput("feedback_modal"),
    div(
      class = "download-sink",
      downloadButton("download_plan_pdf", "Download PDF"),
      downloadButton("download_plan_pptx", "Download PowerPoint")
    )
  )
)

server <- function(input, output, session) {
  database <- connect_app_database()
  if (!isTRUE(getOption("beacon.review_schema_checked", FALSE))) {
    ensure_review_schema(database)
    options(beacon.review_schema_checked = TRUE)
  }
  # A plain (non-reactive) holder for the id of a freshly created CLS draft.
  # onSessionEnded runs outside the reactive graph, so it cannot read a
  # reactiveVal - it needs the id parked somewhere ordinary.
  cls_draft_watch <- new.env(parent = emptyenv())
  cls_draft_watch$cls_id <- NA_integer_
  # Discard an untouched draft when the user abandons it. Safe to call with
  # anything: discard_empty_cls_draft() only deletes a row that is genuinely
  # empty, so a named or detailed request is never at risk.
  cls_discard_draft <- function(cls_id = cls_draft_watch$cls_id) {
    cls_id <- suppressWarnings(as.integer(cls_id))
    if (length(cls_id) != 1 || is.na(cls_id)) return(invisible(FALSE))
    dropped <- tryCatch(
      isTRUE(discard_empty_cls_draft(database, cls_id, CLS_DRAFT_NAME)),
      error = function(error) FALSE
    )
    if (identical(cls_draft_watch$cls_id, cls_id)) cls_draft_watch$cls_id <- NA_integer_
    invisible(dropped)
  }
  session$onSessionEnded(function() {
    # Closing the browser must not leave a blank request behind on the agency's
    # list. Runs before the disconnect so the delete has a live connection.
    tryCatch(cls_discard_draft(), error = function(error) NULL)
    DBI::dbDisconnect(database)
  })
  app_data <- reactiveVal(NULL)
  current_user <- reactiveVal(NULL)
  auth_state <- reactiveVal(list(view = "login"))
  current_page <- reactiveVal("login")
  current_pillar_modal <- reactiveVal(NULL)
  current_measure_id <- reactiveVal(NULL)
  # Reported 2026-08-05 (DHR): saving a new measure created several
  # duplicate copies. persist_measure() kicks off save_measure_record()
  # synchronously, but the entity-link + app_data() refresh that follows
  # runs via an async future_promise -- current_measure_id() stays "new"
  # for the entire gap until that promise resolves and closes the modal.
  # With no visual feedback that a save is already in flight, a repeat
  # click on Save during that window re-entered persist_measure() while
  # existing_measure_id was still "new", inserting another fresh row
  # instead of recognizing the measure that had just been created.
  measure_save_in_progress <- reactiveVal(FALSE)
  pending_new_measure_default_city <- reactiveVal(FALSE)
  # Same reentrancy hazard as measure_save_in_progress above -- a brand-new
  # risk/team member has no real id yet until refresh_app_data()'s async
  # gap closes, so a repeat click on Save while that's in flight would
  # otherwise mint a second one instead of recognizing the first.
  risk_save_in_progress <- reactiveVal(FALSE)
  team_role_save_in_progress <- reactiveVal(FALSE)
  # 2026-08-07: app_data() is per-session, so every sign-in (fresh login OR
  # an auto-restored session on page load) starts from NULL and needs its
  # own full load. That load used to run inline on complete_sign_in()'s
  # calling thread -- since this is a single-threaded R process, one
  # person's login blocked every other connected session's requests (even
  # unrelated ones) for as long as it took, confirmed via load testing to
  # reach 8-12s at 50 concurrent logins. Guards a second submit while the
  # background load from the first is still in flight (same reentrancy
  # class as measure_save_in_progress above).
  sign_in_in_progress <- reactiveVal(FALSE)
  current_risk_id <- reactiveVal(NULL)
  current_history_plan_id <- reactiveVal(NULL)
  current_history_include_review <- reactiveVal(TRUE)
  current_review_return_page <- reactiveVal("reviewer_dashboard")
  current_export_plan_id <- reactiveVal(NULL)
  current_export_include_review <- reactiveVal(TRUE)
  current_export_draft <- reactiveVal(NULL)
  current_workspace <- reactiveVal("admin")
  current_user_type <- reactiveVal("admin")
  current_team_access_id <- reactiveVal(NULL)
  current_role_preview_user_id <- reactiveVal(NULL)
  current_role_preview_app_role <- reactiveVal("SystemAdmin")
  current_role_preview_agency_role <- reactiveVal(c("Admin"))
  feedback_modal_open <- reactiveVal(FALSE)
  current_cls_id <- reactiveVal(NA_integer_)
  # Which page the open request was reached from, so Back returns there.
  cls_detail_origin <- reactiveVal(NULL)
  # Which object / position row is open in the inline editor (analyst feedback).
  cls_editing_line <- reactiveVal(NA_integer_)
  cls_editing_position <- reactiveVal(NA_integer_)
  cls_last_save <- reactiveVal(NULL)
  cls_applied_status <- reactiveVal(NULL)
  cls_applied_agency <- reactiveVal(NULL)
  cls_applied_service <- reactiveVal(NULL)
  # Mirror the Bug/Fix and Measures page filter/search widgets in their own
  # reactiveVals rather than reading input$feedback_search etc. directly.
  # update*Input() only works on a widget that's currently mounted in the
  # DOM -- if a user signs out and a different user signs in without ever
  # visiting the page that widget lives on, the reset call silently no-ops
  # and the next time that page renders, it rebuilds its `value =`/
  # `selected =` from the still-stale input$..., leaking the previous
  # user's filter into the new user's session. These reactiveVals are
  # reset unconditionally in complete_sign_in(), independent of whatever
  # page happens to be showing at that moment.
  feedback_search_value <- reactiveVal("")
  feedback_category_filter_value <- reactiveVal(character(0))
  feedback_priority_filter_value <- reactiveVal(character(0))
  # Initialized to the intended default (not character(0)) so the reactive
  # value always matches what page_feedback() actually renders as
  # `selected =` -- see the reload-loop comment there for why that mismatch
  # matters.
  feedback_status_filter_value <- reactiveVal(default_feedback_status_filter)
  measure_status_filter_value <- reactiveVal("All except deprecated")
  service_open_flags <- new.env(parent = emptyenv())
  service_body_outputs_registered <- new.env(parent = emptyenv())
  section_draft_cache <- new.env(parent = emptyenv())
  review_snapshot_cache <- new.env(parent = emptyenv())

  register_service_body_outputs <- function(data) {
    if (is.null(data) || !"reference_service" %in% names(data) || !nrow(data$reference_service)) {
      return(invisible(FALSE))
    }
    service_ids <- data$reference_service$service_id
    for (service_id in service_ids) {
      service_id_key <- as.character(service_id)
      if (!exists(service_id_key, envir = service_open_flags, inherits = FALSE)) {
        service_open_flags[[service_id_key]] <- reactiveVal(FALSE)
      }
      if (exists(service_id_key, envir = service_body_outputs_registered, inherits = FALSE)) {
        next
      }
      service_body_outputs_registered[[service_id_key]] <- TRUE
      local({
        service_id_local <- service_id
        service_open_flag <- service_open_flags[[as.character(service_id_local)]]
        output[[service_body_output_id(service_id_local)]] <- renderUI({
          if (!identical(current_page(), "services") || !isTRUE(service_open_flag())) {
            return(div(class = "service-lazy-placeholder", "Loading..."))
          }
          data <- ensure_app_data()
          plan <- current_plan(data, current_submitter_value())
          data <- data_with_cached_section_draft(data, plan$plan_id[[1]], "services")
          service_rows <- plan_service_rows(data, plan)
          service_row <- service_rows[service_rows$service_id == service_id_local, , drop = FALSE]
          if (!nrow(service_row)) return(NULL)
          measures <- eligible_plan_measures(measure_library_rows(data, plan, include_ineligible = FALSE))
          metric_choices <- setNames(measures$measure_id, measures$title)
          service_editor_body_ui(
            data,
            plan,
            service_row[1, , drop = FALSE],
            measures = measures,
            metric_choices = metric_choices,
            locked = !plan_is_editable(plan) || !current_user_can_edit_plan(),
            can_edit_shared_description = can_edit_shared_service_description(current_user_app_roles())
          )
        })
      })
    }
    invisible(TRUE)
  }

  ensure_app_data <- function() {
    data <- app_data()
    if (is.null(data)) {
      data <- load_app_data(database)
      app_data(data)
      register_service_body_outputs(data)
    }
    data
  }

  # Reloads app data in a background worker instead of blocking the shared
  # single-threaded Shiny process. `after` runs once the fresh data has
  # landed in app_data() -- put cleanup/notification code there instead of
  # directly after the call, since this returns immediately.
  #
  # domains: NULL (default) reloads the ENTIRE database (~31 queries) --
  # the safe, always-correct choice for anything not migrated below. Pass
  # a character vector naming entries in refresh_domain_loaders (e.g.
  # domains = "cls") to reload only that domain's own queries instead,
  # merging just those keys into the CURRENT app_data() (re-read fresh at
  # merge time, not the stale snapshot from before this call started, so
  # a concurrent unrelated refresh can't get clobbered).
  #
  # *** Adding a new save flow (CLS or otherwise)? Read this. ***
  # Every refresh_app_data() call defaults to reloading all ~31 queries,
  # which is the app's #1 capacity problem (see backlog) -- concurrent
  # saves anywhere in the app compete for the same background workers and
  # CPU. Before wiring up refresh_app_data() for a new save, check: does
  # this save write ONLY to tables no other page reads or joins against?
  # If yes, add a `load_<name>_domain_data(connection)` function in
  # R/database.R (load_cls_domain_data() above load_app_data() is the
  # reference example -- load_app_data() itself calls it too, so both
  # paths always run identical SQL), register it below, and pass
  # `domains = "<name>"` at every call site for that save instead of
  # leaving domains unset. If the save touches anything shared (a column
  # another page's query joins against), leave domains unset -- reloading
  # too much is merely wasteful, reloading too little means some OTHER
  # page silently shows stale data, which is the worse failure mode.
  refresh_domain_loaders <- list(
    cls = load_cls_domain_data,
    measures = load_measures_domain_data
  )

  refresh_app_data <- function(after = NULL, on_error = NULL, domains = NULL) {
    promises::future_promise({
      connection <- connect_app_database()
      on.exit(DBI::dbDisconnect(connection), add = TRUE)
      loaded <- if (is.null(domains)) {
        load_app_data(connection)
      } else {
        loaders <- refresh_domain_loaders[domains]
        unknown <- domains[vapply(loaders, is.null, logical(1))]
        if (length(unknown)) stop(paste("Unknown refresh domain(s):", paste(unknown, collapse = ", ")))
        do.call(c, unname(lapply(loaders, function(loader) loader(connection))))
      }
      # Diagnostic trace for the 2026-08-07 OOM crash loop -- logs this
      # worker's own RSS right after the load it just did, tagged with
      # which domain(s) triggered it, so a recurrence shows exactly which
      # call shape (full reload vs. a specific domain) the growth tracks
      # with instead of only the after-the-fact OOM kill message.
      rss_kb <- process_rss_kb()
      if (!is.na(rss_kb)) {
        cat(sprintf(
          "MEMLOG scope=worker pid=%s domains=%s rss_kb=%s at=%s\n",
          Sys.getpid(), if (is.null(domains)) "full" else paste(domains, collapse = ","),
          rss_kb, format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC")
        ))
      }
      loaded
    }, seed = TRUE) %...>% (function(loaded) {
      if (is.null(domains)) {
        app_data(loaded)
      } else {
        current <- app_data()
        current[names(loaded)] <- loaded
        app_data(current)
      }
      register_service_body_outputs(app_data())
      if (!is.null(after)) after()
    }) %...!% (function(error) {
      showNotification(paste("Couldn't refresh plan data:", conditionMessage(error)), type = "error", duration = 8)
      if (!is.null(on_error)) on_error(error)
    })
    invisible(NULL)
  }

  notify_unknown_login_email <- function(email, context = "sign in", requested_entity = "", requested_agency_role = "") {
    sent <- auth_send_unknown_email_alert(email, context, requested_entity, requested_agency_role)
    notice <- if (isTRUE(sent)) {
      "No Beacon account is associated with that email address. Melanie Lada has been notified."
    } else {
      "No Beacon account is associated with that email address. Beacon could not send the access notification, so please contact melanie.lada@baltimorecity.gov."
    }
    list(notice = notice, sent = isTRUE(sent))
  }

  finish_sign_in <- function(user, data, issue_session) {
    email <- tolower(trimws(user$email[[1]] %||% ""))
    user_rows <- data$access_user[tolower(data$access_user$email) == email, , drop = FALSE]
    if (!nrow(user_rows)) {
      showNotification("That email address is not in the current user list. Contact melanie.lada@baltimorecity.gov for access.", type = "error", duration = 10)
      return(FALSE)
    }
    user_id <- as.character(user_rows$user_id[[1]])
    current_role_preview_user_id(user_id)
    defaults <- matched_user_role_defaults(data, user_id)
    current_role_preview_app_role(defaults$app_role)
    current_role_preview_agency_role(defaults$agency_roles)
    updateSelectInput(session, "role_preview_user_id", selected = user_id)
    updateSelectInput(session, "role_preview_app_role", selected = defaults$app_role)
    updateSelectInput(session, "role_preview_agency_role", selected = if (length(defaults$agency_roles)) defaults$agency_roles else "None")
    # Shiny persists input values for the life of the browser session/tab,
    # not per signed-in user -- signing out and a different user signing
    # back in on the same tab (no page reload) would otherwise leave the
    # previous user's page filters/search terms in place, silently
    # filtering the new user's own view. Reset the authoritative
    # reactiveVals (read by output$page regardless of which page is
    # currently mounted -- see the declarations above) on every completed
    # sign-in, including a restored session, so a new user always starts
    # from a clean slate. Also nudge the widgets directly via
    # update*Input() in case the relevant page happens to already be
    # mounted; that call alone is NOT sufficient, since update*Input() is a
    # no-op against a widget that isn't currently in the DOM, which is
    # exactly the case that let this bug slip through the first time.
    feedback_search_value("")
    feedback_category_filter_value(character(0))
    feedback_priority_filter_value(character(0))
    feedback_status_filter_value(default_feedback_status_filter)
    measure_status_filter_value("All except deprecated")
    # Same reasoning for the CLS workspace: the applied CLS Review filters, the
    # request that happened to be open, and its "last saved by" note are all
    # per-user state held in session-level reactiveVals.
    cls_applied_status(NULL)
    cls_applied_agency(NULL)
    current_cls_id(NA_integer_)
    cls_detail_origin(NULL)
    cls_last_save(NULL)
    updateTextInput(session, "feedback_search", value = "")
    updateSelectInput(session, "feedback_category_filter", selected = character(0))
    updateSelectInput(session, "feedback_priority_filter", selected = character(0))
    updateSelectInput(session, "feedback_status_filter", selected = default_feedback_status_filter)
    updateSelectInput(session, "measure_status_filter", selected = "All except deprecated")
    submitter_value <- matched_user_submitter_value(data, user_id)
    if (!is.null(submitter_value)) {
      update_submitter_selectors(data, submitter_value)
    }
    admin_mode <- can_view_performance_reviewing(c(defaults$app_role))
    current_workspace(if (admin_mode) "admin" else "agency")
    current_user_type(if (admin_mode) "admin" else if ("Agency Director" %in% defaults$agency_roles) "agency_director" else "agency")
    next_page <- if (admin_mode) "reviewer_dashboard" else "landing"
    current_page(next_page)
    if (isTRUE(issue_session)) {
      token <- auth_issue_login_session(database, user$user_id[[1]])
      session$sendCustomMessage("auth-session-issued", list(token = token, email = user$email[[1]], expiresDays = AUTH_SESSION_DAYS))
    }
    session$sendCustomMessage("set-auth-state", list(signedIn = TRUE, email = user$email[[1]]))
    session$sendCustomMessage("set-page", next_page)
    TRUE
  }

  # Entry point for both a fresh login (handle_login_attempt()) and an
  # auto-restored session on page load (input$auth_restore_session below).
  # app_data() is per-session and starts NULL every time, so this always
  # needs a load on first sign-in in a given browser session -- doing that
  # in the background (same future_promise() pattern refresh_app_data()
  # already uses for saves) keeps one person's login from blocking every
  # other connected session while it runs. finish_sign_in() -- the actual
  # sign-in completion logic -- only needs `data` once it's actually
  # available, whether that's immediately (a second sign-in in the same
  # tab, data already cached) or once the background load resolves.
  complete_sign_in <- function(user, issue_session = TRUE) {
    current_user(user)
    auth_state(list(view = "login"))
    existing <- app_data()
    if (!is.null(existing)) {
      finish_sign_in(user, existing, issue_session)
      return(invisible(TRUE))
    }
    if (isTRUE(sign_in_in_progress())) return(invisible(FALSE))
    sign_in_in_progress(TRUE)
    auth_state(list(view = "login", notice = "Signing in…"))
    refresh_app_data(
      after = function() {
        sign_in_in_progress(FALSE)
        finish_sign_in(user, app_data(), issue_session)
      },
      on_error = function(error) {
        sign_in_in_progress(FALSE)
        current_user(NULL)
        auth_state(list(view = "login", notice = "Something went wrong loading your account. Try signing in again."))
      }
    )
    invisible(TRUE)
  }

  handle_login_attempt <- function(email, password) {
    email <- tolower(trimws(email %||% ""))
    password <- as.character(password %||% "")
    if (!nzchar(email) || !grepl("@", email, fixed = TRUE)) {
      auth_state(list(view = "login", notice = "Enter a valid email address to continue."))
      return(invisible(FALSE))
    }
    if (auth_attempt_blocked(email)) {
      auth_state(list(view = "login", notice = paste("Too many failed attempts. Try again in", AUTH_LOCKOUT_MINUTES, "minutes.")))
      return(invisible(FALSE))
    }
    user <- auth_find_user(database, email)
    if (is.null(user)) {
      auth_note_failure(email)
      auth_state(list(
        view = "access_request",
        email = email,
        context = "sign in",
        notice = "That email is not connected to an active Beacon account. Add the requested entity and role/title below."
      ))
      return(invisible(FALSE))
    }
    verified <- auth_verify_login(database, email, password)
    if (is.null(verified)) {
      auth_note_failure(email)
      auth_state(list(view = "login", notice = "Sign-in failed. Check your email and password, or use “First time here” if you have not set a password yet."))
      return(invisible(FALSE))
    }
    auth_clear_failures(email)
    complete_sign_in(verified, issue_session = TRUE)
    invisible(TRUE)
  }

  update_cached_section_draft <- function(plan_id, section_key, payload_json, row = NULL) {
    key <- paste(as.integer(plan_id), as.character(section_key), sep = "::")
    draft_id <- if (!is.null(row) && "draft_id" %in% names(row)) row$draft_id[[1]] else NA_integer_
    revision <- if (!is.null(row) && "revision" %in% names(row)) row$revision[[1]] else NA_integer_
    updated_at <- if (!is.null(row) && "updated_at" %in% names(row)) row$updated_at[[1]] else Sys.time()
    section_draft_cache[[key]] <- data.frame(
      draft_id = draft_id,
      plan_id = as.integer(plan_id),
      section_key = as.character(section_key),
      payload = as.character(payload_json),
      revision = revision,
      updated_by = NA_integer_,
      updated_at = updated_at,
      stringsAsFactors = FALSE
    )
    invisible(TRUE)
  }
  data_with_cached_section_draft <- function(data, plan_id, section_key) {
    key <- paste(as.integer(plan_id), as.character(section_key), sep = "::")
    if (!exists(key, envir = section_draft_cache, inherits = FALSE)) return(data)
    cached_row <- get(key, envir = section_draft_cache, inherits = FALSE)
    if (!"planning_plan_section_draft" %in% names(data)) return(data)
    drafts <- data$planning_plan_section_draft
    if (!nrow(drafts)) {
      data$planning_plan_section_draft <- cached_row
    } else {
      match_index <- which(drafts$plan_id == as.integer(plan_id) & drafts$section_key == as.character(section_key))
      if (length(match_index)) {
        common_names <- intersect(names(drafts), names(cached_row))
        drafts[match_index[[1]], common_names] <- cached_row[1, common_names, drop = FALSE]
      } else {
        drafts <- rbind(drafts, cached_row[, names(drafts), drop = FALSE])
      }
      data$planning_plan_section_draft <- drafts
    }
    data
  }
  # Same non-reactive-cache pattern as section_draft_cache/
  # data_with_cached_section_draft() above, applied to plan review
  # scoring: the autosave observer (plan_review_save_request) writes here
  # instead of into app_data(), and output$page reads the cache back in at
  # render time. Writing to app_data() on every debounced scoring keystroke
  # would force a full page_plan_review_detail() re-render, which collapses
  # every goal/service scoring drawer back to closed -- the same problem
  # already solved for Goals/Services drafts.
  update_cached_review_snapshot <- function(plan_id, snapshot) {
    review_snapshot_cache[[as.character(as.integer(plan_id))]] <- snapshot
    invisible(TRUE)
  }
  # See merge_cached_review_snapshots() for what this does and why -- kept
  # as a thin wrapper here so callers in server() don't need to pass
  # review_snapshot_cache explicitly.
  data_with_cached_review_snapshot <- function(data) {
    merge_cached_review_snapshots(data, review_snapshot_cache)
  }
  current_submitter_value <- function() {
    selected <- input$selected_agency %||% input$selected_agency_nav %||% input$selected_agency_mobile
    data <- ensure_app_data()
    # Same choice list the visible selector is built from, so the resolved value
    # can never be something the dropdown does not offer.
    choices <- current_user_submitter_choices(data)
    if (!length(choices)) return("")
    valid_values <- unname(choices)
    if (is.null(selected) || !selected %in% valid_values) valid_values[[1]] else selected
  }
  current_agency_id <- function() {
    data <- ensure_app_data()
    plan <- current_plan(data, current_submitter_value())
    agency_id <- plan_accounting_agency_id(data, plan)
    if (is.na(agency_id) || !agency_id %in% data$reference_agency$agency_id) "AGC2600" else agency_id
  }
  current_user_is_system_admin <- function() {
    identical(current_workspace(), "admin")
  }
  current_user_app_roles <- function() {
    selected_role <- current_role_preview_app_role() %||% input$role_preview_app_role
    if (!is.null(selected_role) && selected_role %in% performance_role_choices) {
      return(c(selected_role))
    }
    switch(
      current_user_type(),
      agency = c("AgencySubmitter"),
      agency_director = c("AgencyWriter"),
      admin = c("SystemAdmin"),
      c("AgencyViewer")
    )
  }
  current_user_agency_roles <- function() {
    selected_role <- current_role_preview_agency_role()
    if (is.null(selected_role) || !length(selected_role)) {
      selected_role <- input$role_preview_agency_role
    }
    selected_role <- unique(as.character(selected_role %||% character(0)))
    selected_role <- selected_role[!is.na(selected_role) & selected_role != "None"]
    selected_role <- selected_role[selected_role %in% agency_role_choices]
    if (length(selected_role)) {
      return(selected_role)
    }
    switch(
      current_user_type(),
      agency = character(0),
      agency_director = c("Agency Director"),
      admin = c("Admin"),
      character(0)
    )
  }
  current_user_submitter_choices <- function(data = NULL) {
    if (is.null(data)) data <- ensure_app_data()
    app_roles <- current_user_app_roles()
    user_id <- current_role_preview_user_id() %||% input$role_preview_user_id %||% ""
    # BBMR reviewers work across every agency, so they get the full list rather
    # than the grant-derived one - their role carries no agency or entity grant,
    # which would otherwise leave the switcher empty.
    if (has_any_role(app_roles, c("SystemAdmin", "OPIReviewer", "BBMRReviewer"))) {
      agency_selector_choices(data)
    } else {
      user_submitter_choices(data, user_id)
    }
  }
  update_role_preview_agency_selector <- function(data = NULL, selected = NULL) {
    if (is.null(data)) data <- ensure_app_data()
    choices <- current_user_submitter_choices(data)
    if (!length(choices)) return(invisible(FALSE))
    if (is.null(selected) || !selected %in% unname(choices)) selected <- unname(choices)[[1]]
    updateSelectInput(session, "role_preview_selected_agency", choices = choices, selected = selected)
    update_submitter_selectors(data, selected)
    invisible(TRUE)
  }
  update_submitter_selectors <- function(data = NULL, selected = NULL) {
    if (is.null(data)) data <- ensure_app_data()
    choices <- current_user_submitter_choices(data)
    if (!length(choices)) return(invisible(FALSE))
    if (is.null(selected) || !selected %in% unname(choices)) selected <- unname(choices)[[1]]
    updateSelectInput(session, "selected_agency", choices = choices, selected = selected)
    updateSelectInput(session, "selected_agency_nav", choices = choices, selected = selected)
    updateSelectInput(session, "selected_agency_mobile", choices = choices, selected = selected)
    invisible(TRUE)
  }

  sync_role_preview_user <- function(user_id) {
    user_id <- user_id %||% ""
    if (!nzchar(user_id)) return(invisible(FALSE))
    current_role_preview_user_id(user_id)
    data <- ensure_app_data()
    defaults <- matched_user_role_defaults(data, user_id)
    current_role_preview_app_role(defaults$app_role)
    current_role_preview_agency_role(defaults$agency_roles)
    for (input_id in c("role_preview_user_id")) {
      updateSelectInput(session, input_id, selected = user_id)
    }
    for (input_id in c("role_preview_app_role")) {
      updateSelectInput(session, input_id, selected = defaults$app_role)
    }
    for (input_id in c("role_preview_agency_role")) {
      updateSelectInput(session, input_id, selected = if (length(defaults$agency_roles)) defaults$agency_roles else "None")
    }
    submitter_value <- matched_user_submitter_value(data, user_id)
    if (!is.null(submitter_value)) {
      update_role_preview_agency_selector(data, submitter_value)
    }
    invisible(TRUE)
  }

  observeEvent(input$role_preview_user_id, {
    sync_role_preview_user(input$role_preview_user_id)
  }, ignoreInit = FALSE)

  observeEvent(input$role_preview_app_role, {
    selected_role <- input$role_preview_app_role
    if (!is.null(selected_role) && selected_role %in% performance_role_choices) {
      current_role_preview_app_role(selected_role)
      update_role_preview_agency_selector(app_data())
    }
  }, ignoreInit = FALSE)

  observeEvent(input$role_preview_agency_role, {
    selected_role <- input$role_preview_agency_role
    if (is.null(selected_role)) return()
    selected_role <- unique(as.character(selected_role))
    selected_role <- selected_role[!is.na(selected_role)]
    if ("None" %in% selected_role && length(selected_role) > 1) {
      selected_role <- setdiff(selected_role, "None")
      updateSelectInput(session, "role_preview_agency_role", selected = selected_role)
    }
    if (all(selected_role %in% c("None", agency_role_choices))) current_role_preview_agency_role(setdiff(selected_role, "None"))
  }, ignoreInit = FALSE)

  observeEvent(input$role_preview_selected_agency, {
    selected <- input$role_preview_selected_agency
    if (!is.null(selected) && nzchar(selected)) {
      sync_selected_agency_inputs(selected)
    }
  }, ignoreInit = TRUE)

  current_user_can_manage_team <- function() {
    can_edit_roles(current_user_app_roles(), current_user_agency_roles())
  }
  current_user_can_assign_submitter <- function() {
    can_assign_submitter(current_user_app_roles(), current_user_agency_roles())
  }
  current_user_can_submit_plan <- function() {
    can_submit_plans(current_user_app_roles())
  }
  current_user_can_edit_plan <- function() {
    can_edit_plan_sections(current_user_app_roles())
  }
  current_user_can_review_measures <- function() {
    can_review_measures(current_user_app_roles())
  }
  current_user_can_review_plans <- function() {
    can_review_plans(current_user_app_roles())
  }
  current_user_can_route_plan_reviews <- function() {
    can_route_plan_reviews(current_user_app_roles())
  }
  current_user_can_assign_plan_reviewer <- function() {
    can_finalize_plans(current_user_app_roles())
  }
  current_user_can_view_application_admin <- function() {
    can_view_application_admin(current_user_app_roles())
  }
  current_user_can_submit_measure <- function() {
    can_submit_measures(current_user_app_roles(), current_user_agency_roles())
  }
  current_user_can_manage_measure_admin_fields <- function() {
    can_review_measures(current_user_app_roles())
  }
  # A shared service's measures are only editable by SystemAdmin/BBMR, OR
  # by the specific entity that measure_entity_link attributes it to --
  # not by every grantee under the shared parent agency. Non-shared
  # measures are unaffected (existing role check governs those alone).
  current_user_can_edit_measure <- function(data, measure_id, plan) {
    if (current_user_can_manage_measure_admin_fields()) return(TRUE)
    if (!measure_belongs_to_shared_service(data, measure_id)) return(TRUE)
    if (is.null(plan) || !nrow(plan) || is.na(plan$entity_id[[1]])) return(FALSE)
    links <- data$performance_measure_entity_link
    measure_id <- as.integer(measure_id)
    any(!is.na(links$entity_id) & links$entity_id == plan$entity_id[[1]] & links$measure_id == measure_id)
  }
  current_user_can_edit_locked_measure_data <- function() {
    can_edit_locked_measure_data(current_user_app_roles())
  }
  current_user_email <- function() {
    data <- app_data()
    user_id <- suppressWarnings(as.integer(current_role_preview_user_id() %||% input$role_preview_user_id %||% NA_integer_))
    if (!is.na(user_id) && "access_user" %in% names(data) && nrow(data$access_user)) {
      user <- data$access_user[data$access_user$user_id == user_id, , drop = FALSE]
      if (nrow(user) && !is.na(user$email[[1]])) return(user$email[[1]])
    }
    ""
  }

  reset_service_open_flags <- function() {
    for (name in ls(service_open_flags, all.names = TRUE)) {
      service_open_flags[[name]](FALSE)
    }
  }

  observeEvent(input$service_lazy_open, {
    service_id <- input$service_lazy_open$serviceId %||% ""
    if (!nzchar(service_id)) return()
    key <- as.character(service_id)
    if (exists(key, envir = service_open_flags, inherits = FALSE)) {
      service_open_flags[[key]](TRUE)
    }
  }, ignoreInit = TRUE)

  observeEvent(input$current_page, {
    if (!identical(input$current_page, "services")) {
      reset_service_open_flags()
    }
  }, ignoreInit = TRUE)

  sync_selected_agency_inputs <- function(selected) {
    if (is.null(selected) || !nzchar(selected)) return(invisible(FALSE))
    for (input_id in c("selected_agency", "selected_agency_nav", "selected_agency_mobile")) {
      updateSelectInput(session, input_id, selected = selected)
    }
    invisible(TRUE)
  }

  observeEvent(input$selected_agency, {
    reset_service_open_flags()
    if (!is.null(input$selected_agency) && nzchar(input$selected_agency)) {
      sync_selected_agency_inputs(input$selected_agency)
    }
  }, ignoreInit = TRUE)

  observeEvent(input$selected_agency_nav, {
    reset_service_open_flags()
    if (!is.null(input$selected_agency_nav) && nzchar(input$selected_agency_nav)) {
      sync_selected_agency_inputs(input$selected_agency_nav)
    }
  }, ignoreInit = TRUE)

  observeEvent(input$selected_agency_mobile, {
    reset_service_open_flags()
    if (!is.null(input$selected_agency_mobile) && nzchar(input$selected_agency_mobile)) {
      sync_selected_agency_inputs(input$selected_agency_mobile)
    }
  }, ignoreInit = TRUE)

  observe({
    if (is.null(current_user())) {
      session$sendCustomMessage("set-auth-state", list(signedIn = FALSE))
      return()
    }
    data <- app_data()
    submitter_value <- current_submitter_value()
    hide_services <- submitter_is_mayoral_service(data, submitter_value)
    review_admin_mode <- uses_review_administration_mode(current_user_app_roles())
    can_view_approval_context <- can_view_plan_approval_queue_context(data, current_user_app_roles(), current_role_preview_user_id() %||% input$role_preview_user_id %||% NA_integer_)
    can_view_reviewing_context <- can_view_performance_reviewing(current_user_app_roles()) || can_view_approval_context
    budget_planning_access <- can_access_budget_planning(current_user_app_roles())
    session$sendCustomMessage("set-navigation-scope", list(
      hideServices = hide_services,
      showPerformanceReviewing = can_view_reviewing_context,
      showMeasureReview = current_user_can_review_measures(),
      showApprovalQueue = can_view_approval_context,
      showPublishingQueue = can_finalize_plans(current_user_app_roles()),
      hidePerformancePlanning = review_admin_mode,
      showApplicationAdmin = current_user_can_view_application_admin(),
      showClsRequests = budget_planning_access && can_view_cls_requests(current_user_app_roles()),
      showClsReview = budget_planning_access && can_review_cls(current_user_app_roles())
    ))
    if (!(budget_planning_access && can_view_cls_requests(current_user_app_roles())) && identical(current_page(), "cls_requests")) {
      next_page <- if (budget_planning_access && can_review_cls(current_user_app_roles())) "cls_review" else "landing"
      current_page(next_page)
      session$sendCustomMessage("set-page", next_page)
    }
    if (!(budget_planning_access && can_open_cls_request(current_user_app_roles())) && identical(current_page(), "cls_request_detail")) {
      current_page("landing")
      session$sendCustomMessage("set-page", "landing")
    }
    if (!(budget_planning_access && can_review_cls(current_user_app_roles())) && identical(current_page(), "cls_review")) {
      current_page("landing")
      session$sendCustomMessage("set-page", "landing")
    }
    if (hide_services && identical(current_page(), "services")) {
      current_page("metrics")
      session$sendCustomMessage("set-page", "metrics")
    }
    if (review_admin_mode && current_page() %in% c("strategic_plan", "plan_history", "overview", "goals", "services", "metrics", "risks")) {
      current_page("reviewer_dashboard")
      session$sendCustomMessage("set-page", "reviewer_dashboard")
    }
    plan_detail_from_history <- identical(current_page(), "plan_review_detail") && identical(current_review_return_page(), "plan_history")
    if (!can_view_reviewing_context && !plan_detail_from_history && current_page() %in% c("reviewer_dashboard", "plan_review_detail", "approval_queue", "publishing_queue", "measure_review")) {
      current_page("landing")
      session$sendCustomMessage("set-page", "landing")
    }
    if (!current_user_can_review_measures() && identical(current_page(), "measure_review")) {
      next_page <- if (can_view_plan_approval_queue(current_user_app_roles())) "approval_queue" else "reviewer_dashboard"
      current_page(next_page)
      session$sendCustomMessage("set-page", next_page)
    }
    if (!can_view_approval_context && identical(current_page(), "approval_queue")) {
      current_page("reviewer_dashboard")
      session$sendCustomMessage("set-page", "reviewer_dashboard")
    }
    if (!can_finalize_plans(current_user_app_roles()) && identical(current_page(), "publishing_queue")) {
      current_page("reviewer_dashboard")
      session$sendCustomMessage("set-page", "reviewer_dashboard")
    }
    if (!current_user_can_view_application_admin() && identical(current_page(), "bug_fix")) {
      current_page("landing")
      session$sendCustomMessage("set-page", "landing")
    }
  })

  output$header_context_selector <- renderUI({
    if (is.null(current_user()) || identical(current_page(), "login")) {
      return(NULL)
    }
    app_roles <- current_user_app_roles()
    if (uses_review_administration_mode(app_roles) && !has_any_role(app_roles, c("SystemAdmin", "OPIReviewer"))) {
      return(NULL)
    }
    data <- ensure_app_data()
    user_id <- current_role_preview_user_id() %||% input$role_preview_user_id %||% ""
    choices <- if (has_any_role(app_roles, c("SystemAdmin", "OPIReviewer"))) {
      agency_selector_choices(data)
    } else {
      user_submitter_choices(data, user_id)
    }
    if (length(choices) <= 1) {
      return(NULL)
    }
    div(
      class = "header-agency-selector",
      selectInput(
        "selected_agency",
        label = NULL,
        choices = choices,
        selected = current_submitter_value(),
        selectize = TRUE,
        width = "100%"
      )
    )
  })

  review_nav_ui <- function() {
    if (is.null(current_user())) return(NULL)
    data <- ensure_app_data()
    user_id <- current_role_preview_user_id() %||% input$role_preview_user_id %||% NA_integer_
    app_roles <- current_user_app_roles()
    approval_first <- has_any_role(app_roles, c("DeputyMayor", "CAOffice")) || user_is_portfolio_approver(data, user_id)
    performance_reviewing_nav_items(approval_first)
  }

  output$performance_reviewing_nav <- renderUI({
    review_nav_ui()
  })

  output$mobile_performance_reviewing_nav <- renderUI({
    review_nav_ui()
  })

  observeEvent(input$team_scope_agency, {
    selected <- input$team_scope_agency
    if (is.null(selected) || !nzchar(selected)) return()
    sync_selected_agency_inputs(selected)
  }, ignoreInit = TRUE)
  nullable_number <- function(value, integer = FALSE) {
    if (is.null(value) || length(value) == 0 || is.na(value) || identical(value, "")) return(if (integer) NA_integer_ else NA_real_)
    if (integer) as.integer(value) else as.numeric(value)
  }
  plan_scalar_integer <- function(plan, field) {
    if (is.null(plan) || !nrow(plan) || !field %in% names(plan) || !length(plan[[field]])) {
      return(NA_integer_)
    }
    suppressWarnings(as.integer(plan[[field]][[1]]))
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
  values_differ <- function(a, b) {
    if (is.na(a) && is.na(b)) return(FALSE)
    if (is.na(a) || is.na(b)) return(TRUE)
    !isTRUE(all.equal(as.numeric(a), as.numeric(b)))
  }
  # Reassigning a measure's owner from the Action Plan Measures list
  # (action_plan_measure_owner_select) moves the measure to the new
  # owner's accounting agency and replaces its entity link -- consistent
  # with how a brand-new Citywide measure's owning-entity picker already
  # works (resolve_owning_agency_id()/ensure_measure_current_entity_link()).
  # A measure only ever has one owning agency, so this is a full
  # reassignment, not just a display relabel.
  reassign_measure_owner <- function(measure_id, submitter_value) {
    measure_id <- as.integer(measure_id)
    data <- app_data()
    new_agency_id <- resolve_owning_agency_id(data, submitter_value)
    if (is.na(new_agency_id) || !nzchar(new_agency_id)) return(invisible(FALSE))
    DBI::dbExecute(database, "UPDATE performance.performance_measure SET agency_id = $2 WHERE measure_id = $1", params = list(measure_id, new_agency_id))
    DBI::dbExecute(database, "DELETE FROM performance.measure_entity_link WHERE measure_id = $1", params = list(measure_id))
    # Create the link synchronously, before refresh_app_data() below, using
    # `data` patched with the just-updated agency_id -- see the identical
    # fix (and its full explanation) in persist_measure() above. Creating
    # it inside refresh_app_data()'s `after` instead would set app_data()
    # from a snapshot taken before this new link exists, hiding it from the
    # current session until some later, unrelated refresh happened.
    if ("performance_performance_measure" %in% names(data)) {
      data$performance_performance_measure$agency_id[data$performance_performance_measure$measure_id == measure_id] <- new_agency_id
    }
    ensure_measure_current_entity_link(database, measure_id, data, current_plan(data, submitter_value))
    refresh_app_data(after = function() {
      showNotification("Measure owner updated.", type = "message")
    }, domains = "measures")
    invisible(TRUE)
  }
  collect_measure_form <- function() {
    data <- app_data()
    agency_id <- current_agency_id()
    plan <- current_plan(data, current_submitter_value())
    initial_cycle <- plan_scalar_integer(plan, "cycle_id")
    existing_id <- current_measure_id()
    if (is.null(existing_id) || identical(existing_id, "new")) {
      picker_value <- input$measure_owning_entity
      if (!is.null(picker_value) && length(picker_value) == 1 && nzchar(picker_value)) {
        resolved_owner <- resolve_owning_agency_id(data, picker_value)
        if (!is.na(resolved_owner) && nzchar(resolved_owner)) agency_id <- resolved_owner
      }
    }
    existing <- if (is.null(existing_id) || identical(existing_id, "new")) data.frame() else data$performance_performance_measure[data$performance_performance_measure$measure_id == as.integer(existing_id), , drop = FALSE]
    is_validated <- nrow(existing) > 0 && identical(existing$approval_status[[1]], "Validated")
    is_admin <- current_user_can_edit_locked_measure_data()
    # Once validated, every definition field reverts to its existing
    # value for anyone but a SystemAdmin -- a tampered client request
    # can't slip a change past the disabled UI control. save_measure_record()
    # enforces the identical rule again server-side as a second guard.
    definition_locked <- measure_definition_is_locked(is_validated) && !is_admin
    existing_value <- function(field, fallback = NA) if (nrow(existing)) existing[[field]][[1]] else fallback
    locked_or <- function(field, submitted) if (definition_locked) existing_value(field) else submitted
    scope_editable <- current_user_can_manage_measure_admin_fields() && !definition_locked
    values <- list(
      measure_id = if (nrow(existing)) existing$measure_id[[1]] else NULL,
      agency_id = agency_id,
      initial_cycle = initial_cycle,
      title = locked_or("title", input$measure_title),
      measure_type = locked_or("measure_type", input$measure_type),
      description = locked_or("description", input$measure_description),
      data_source = locked_or("data_source", input$measure_data_source),
      data_owner = locked_or("data_owner", input$measure_data_owner),
      data_owner_role = locked_or("data_owner_role", input$measure_data_owner_role),
      update_frequency = locked_or("update_frequency", input$measure_frequency),
      formula = locked_or("formula", input$measure_formula),
      desired_direction = locked_or("desired_direction", input$measure_direction),
      baseline_value = locked_or("baseline_value", nullable_number(input$measure_baseline)),
      baseline_fy = locked_or("baseline_fy", nullable_number(input$measure_baseline_fy, TRUE)),
      format_type = locked_or("format_type", input$measure_format),
      display_unit = locked_or("display_unit", if (nzchar(trimws(input$measure_unit))) input$measure_unit else NA_character_),
      context_required = locked_or("context_required", input$measure_context),
      replicability = if (scope_editable) isTRUE(input$measure_replicability) else isTRUE(existing_value("replicability", FALSE)),
      disaggregation = locked_or("disaggregation", input$measure_disaggregation),
      data_location = locked_or("data_location", input$measure_data_location),
      collection_method = locked_or("collection_method", input$measure_collection_method),
      how_data_used = locked_or("how_data_used", input$measure_how_used),
      why_meaningful = locked_or("why_meaningful", input$measure_why_meaningful),
      proxy_measure = locked_or("proxy_measure", input$measure_proxy),
      improvement_notes = locked_or("improvement_notes", input$measure_improvement_notes),
      change_mapping = measure_change_mapping_for_date(
        if (nrow(existing)) existing$change_mapping[[1]] else NA_character_,
        if (nrow(existing)) existing$created_date[[1]] else Sys.Date()
      ),
      pillar_id = if (scope_editable) nullable_number(input$measure_pillar, TRUE) else existing_value("pillar_id", NA_integer_),
      pillar_goal_id = if (scope_editable) nullable_number(input$measure_pillar_goal, TRUE) else existing_value("pillar_goal_id", NA_integer_),
      is_city = if (scope_editable) input_bool(input$measure_is_city) else isTRUE(existing_value("is_city", FALSE)),
      is_agency = if (scope_editable) input_bool(input$measure_is_agency) else isTRUE(existing_value("is_agency", FALSE)),
      is_service = if (scope_editable) input_bool(input$measure_is_service) else isTRUE(existing_value("is_service", FALSE)),
      approval_status = if (nrow(existing)) existing$approval_status[[1]] else "Draft",
      submitted_for_approval_at = if (nrow(existing)) existing$submitted_for_approval_at[[1]] else as.POSIXct(NA)
    )
    if (!current_user_can_manage_measure_admin_fields()) {
      values <- derive_measure_scope(data, values)
    }
    values
  }
  collect_measure_years <- function() {
    data <- app_data()
    existing_id <- current_measure_id()
    existing_measure <- if (is.null(existing_id) || identical(existing_id, "new")) {
      data.frame()
    } else {
      data$performance_performance_measure[data$performance_performance_measure$measure_id == as.integer(existing_id), , drop = FALSE]
    }
    ever_validated <- nrow(existing_measure) > 0 && (
      identical(existing_measure$approval_status[[1]], "Validated") ||
        measure_ever_validated(existing_measure$ever_validated_at[[1]])
    )
    existing_actuals <- if (is.null(existing_id) || identical(existing_id, "new")) {
      data.frame()
    } else {
      data$performance_measure_actuals[data$performance_measure_actuals$measure_id == as.integer(existing_id), , drop = FALSE]
    }
    is_admin <- current_user_can_edit_locked_measure_data()
    lapply(measure_entry_years(), function(year) {
      existing_row <- existing_actuals[existing_actuals$fiscal_year == year, , drop = FALSE]
      existing_actual <- if (nrow(existing_row)) existing_row$annual_actual[[1]] else NA_real_
      existing_actual_notes <- if (nrow(existing_row)) existing_row$annual_actual_notes[[1]] else NA_character_
      existing_target <- if (nrow(existing_row)) existing_row$target_value[[1]] else NA_real_
      existing_target_notes <- if (nrow(existing_row)) existing_row$target_value_notes[[1]] else NA_character_

      submitted_actual <- nullable_number(input[[paste0("measure_actual_", year)]])
      submitted_actual_notes <- limit_note(input[[paste0("measure_actual_notes_", year)]])
      submitted_target <- nullable_number(input[[paste0("measure_target_", year)]])
      submitted_target_notes <- limit_note(input[[paste0("measure_target_notes_", year)]])

      actual_locked <- measure_actual_is_locked(year, ever_validated)
      target_locked <- measure_target_is_locked(year, ever_validated)

      # Disabling the input already stops a non-admin from changing a locked
      # field in the UI, but a locked field's stored value is what's kept
      # here regardless of what a submitted request contains -- so a
      # tampered client request can't slip an edit past the disabled control.
      final_actual <- if (actual_locked && !is_admin) existing_actual else submitted_actual
      final_actual_notes <- if (actual_locked && !is_admin) (existing_actual_notes %||% "") else submitted_actual_notes
      final_target <- if (target_locked && !is_admin) existing_target else submitted_target
      final_target_notes <- if (target_locked && !is_admin) (existing_target_notes %||% "") else submitted_target_notes

      list(
        fiscal_year = year,
        annual_actual = final_actual,
        annual_actual_notes = final_actual_notes,
        target_value = final_target,
        target_value_notes = final_target_notes,
        actual_locked_change_needs_note = actual_locked && is_admin && values_differ(final_actual, existing_actual) && !nzchar(trimws(final_actual_notes %||% "")),
        target_locked_change_needs_note = target_locked && is_admin && values_differ(final_target, existing_target) && !nzchar(trimws(final_target_notes %||% ""))
      )
    })
  }
  persist_measure <- function(submit = FALSE) {
    # Reentrancy guard: a repeat Save click while the previous save's async
    # refresh is still in flight must be ignored outright, not re-run --
    # see the comment on measure_save_in_progress's declaration above.
    if (isTRUE(measure_save_in_progress())) return()
    measure_save_in_progress(TRUE)
    async_save_kicked_off <- FALSE
    # Tells the client to re-enable the Save/Submit buttons it disabled on
    # click. Fires here for every SYNCHRONOUS exit (a validation error
    # returning before the async refresh ever starts); the async success/
    # error paths below send their own once refresh_app_data() actually
    # finishes, since on.exit() runs immediately, well before that.
    on.exit({
      if (!async_save_kicked_off) {
        measure_save_in_progress(FALSE)
        session$sendCustomMessage("measure-save-result", list(ok = FALSE))
      }
    }, add = TRUE)
    if (!submit && !current_user_can_submit_measure() && !current_user_can_review_measures()) {
      showNotification("You do not have permission to edit measures.", type = "error", duration = 8)
      return()
    }
    if (submit && !current_user_can_submit_measure()) {
      showNotification("You do not have permission to submit measures for approval.", type = "error", duration = 8)
      return()
    }
    existing_measure_id <- current_measure_id()
    if (!identical(existing_measure_id, "new")) {
      data <- app_data()
      plan <- current_plan(data, current_submitter_value())
      if (!current_user_can_edit_measure(data, existing_measure_id, plan)) {
        showNotification("This measure belongs to a shared service and can only be edited by its own entity or a System Admin.", type = "error", duration = 8)
        return()
      }
    }
    values <- collect_measure_form()
    # Computed against what the user actually entered, before the
    # placeholder-text fallback below papers over blank required fields for
    # storage purposes -- otherwise a brand new measure would never show as
    # "missing fields" since every required field would already read
    # "Draft ... pending." by the time this ran.
    missing_fields <- measure_missing_required_fields(values)
    yearly_values <- collect_measure_years()
    locked_changes_missing_note <- Filter(
      function(row) isTRUE(row$actual_locked_change_needs_note) || isTRUE(row$target_locked_change_needs_note),
      yearly_values
    )
    if (length(locked_changes_missing_note)) {
      years_needing_notes <- vapply(locked_changes_missing_note, function(row) fy_label(row$fiscal_year), character(1))
      showNotification(
        paste("Add a note explaining the change before saving edits to locked historical data:", paste(years_needing_notes, collapse = ", ")),
        type = "error", duration = 10
      )
      return()
    }
    if (length(values$initial_cycle) != 1 || is.na(values$initial_cycle)) {
      showNotification("No active planning cycle was found for this agency or entity. Please select a valid agency/entity before saving the measure.", type = "error", duration = 8)
      return()
    }
    if (submit) {
      data <- app_data()
      plan <- current_plan(data, current_submitter_value())
      plan_fiscal_year <- plan_scalar_integer(plan, "fiscal_year")
      if (is.na(plan_fiscal_year)) {
        showNotification("No active planning cycle was found for this agency or entity. Please select a valid agency/entity before submitting the measure.", type = "error", duration = 8)
        return()
      }
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
    suspicious_fractions <- measure_values_with_suspicious_fraction(values$format_type, yearly_values)
    if (length(suspicious_fractions)) {
      showNotification(
        paste0(
          "Heads up: ", paste(suspicious_fractions, collapse = ", "),
          " ", if (length(suspicious_fractions) > 1) "are" else "is",
          " below 1 for a percent measure -- if you meant e.g. 97%, enter 97, not 0.97. Saved as entered."
        ),
        type = "warning", duration = 10
      )
    }
    data <- app_data()
    user_rows <- data$access_user_agency_access[data$access_user_agency_access$agency_id == values$agency_id, , drop = FALSE]
    if (!nrow(user_rows) && !nrow(data$access_user_agency_access)) {
      showNotification("No user is available to report measure actuals. Please add a user access row before saving measure data.", type = "error", duration = 8)
      return()
    }
    reported_by <- if (nrow(user_rows)) user_rows$user_id[[1]] else data$access_user_agency_access$user_id[[1]]
    result <- tryCatch(
      save_measure_record(
        database, values, yearly_values, reported_by, submit,
        is_admin = current_user_can_edit_locked_measure_data(),
        required_fields_complete = !length(missing_fields)
      ),
      error = function(error) error
    )
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    link_submitter_value <- resolve_link_submitter_value(existing_measure_id, input$measure_owning_entity, current_submitter_value())
    # Reported 2026-08-05: even after fixing ensure_measure_current_entity_link()
    # itself, a new measure only showed up in its entity's library after a
    # full page reload, not in the current session. Cause: the link was
    # created inside refresh_app_data()'s `after` callback, which runs
    # AFTER app_data() has already been set from a snapshot taken before
    # the link existed -- so the link a user just created stayed invisible
    # in their own live session until some LATER, unrelated refresh
    # happened to run. Only a fresh page load (a brand new session,
    # app_data() starting over from NULL) picked it up. Fixed by creating
    # the link synchronously, BEFORE refresh_app_data() runs, using a
    # single freshly-fetched row for just the new measure_id (not a full
    # app_data reload) patched into `data` so
    # ensure_measure_current_entity_link()'s own measure_row lookup
    # succeeds -- see the identical fix in reassign_measure_owner() above.
    new_measure_row <- DBI::dbGetQuery(database, "SELECT measure_id, agency_id FROM performance.performance_measure WHERE measure_id = $1", params = list(as.integer(result)))
    data_with_new_measure <- data
    if (nrow(new_measure_row) && "performance_performance_measure" %in% names(data)) {
      existing_rows <- data$performance_performance_measure[data$performance_performance_measure$measure_id != as.integer(result), , drop = FALSE]
      synthetic_row <- existing_rows[0, , drop = FALSE]
      synthetic_row[1, "measure_id"] <- new_measure_row$measure_id[[1]]
      synthetic_row[1, "agency_id"] <- new_measure_row$agency_id[[1]]
      data_with_new_measure$performance_performance_measure <- rbind(existing_rows, synthetic_row)
    }
    link_result <- tryCatch(
      ensure_measure_current_entity_link(database, result, data_with_new_measure, current_plan(data_with_new_measure, link_submitter_value)),
      error = function(error) error
    )
    if (inherits(link_result, "error")) {
      showNotification(paste("Measure saved, but entity link could not be updated:", conditionMessage(link_result)), type = "warning", duration = 10)
    }
    async_save_kicked_off <- TRUE
    refresh_app_data(
      after = function() {
        measure_save_in_progress(FALSE)
        current_measure_id(NULL)
        showNotification(if (submit) "Measure submitted for approval." else "Measure saved.", type = "message")
        session$sendCustomMessage("measure-save-result", list(ok = TRUE))
      },
      on_error = function(error) {
        measure_save_in_progress(FALSE)
        session$sendCustomMessage("measure-save-result", list(ok = FALSE))
      },
      domains = "measures"
    )
  }

  observeEvent(input$open_measure_id, {
    raw_measure_id <- as.character(input$open_measure_id)
    if (identical(raw_measure_id, "new:city")) {
      pending_new_measure_default_city(TRUE)
      current_measure_id("new")
    } else {
      pending_new_measure_default_city(FALSE)
      current_measure_id(raw_measure_id)
    }
  }, ignoreInit = TRUE)

  observeEvent(input$close_measure_modal, current_measure_id(NULL), ignoreInit = TRUE)
  observeEvent(input$measure_save_request, persist_measure(FALSE), ignoreInit = TRUE)
  observeEvent(input$measure_submit_request, persist_measure(TRUE), ignoreInit = TRUE)
  observeEvent(input$measure_delete_confirmed_request, {
    if (!can_delete_measures(current_user_app_roles())) {
      showNotification("Only System Admins can delete measures.", type = "error", duration = 8)
      return()
    }
    measure_id <- current_measure_id()
    if (is.null(measure_id) || identical(measure_id, "new")) return()
    result <- tryCatch(delete_measure_record(database, measure_id), error = function(error) error)
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data(after = function() {
      current_measure_id(NULL)
      showNotification("Measure deleted.", type = "message", duration = 6)
    }, domains = "measures")
  }, ignoreInit = TRUE)
  observeEvent(input$action_plan_measure_owner_request, {
    if (!current_user_can_manage_measure_admin_fields()) {
      showNotification("Only System Admins and OPI reviewers can reassign a measure's owner.", type = "error", duration = 8)
      return()
    }
    request <- input$action_plan_measure_owner_request
    measure_id <- suppressWarnings(as.integer(request$measureId))
    submitter_value <- request$value
    if (is.na(measure_id) || is.null(submitter_value) || !nzchar(submitter_value)) return()
    result <- tryCatch(reassign_measure_owner(measure_id, submitter_value), error = function(error) error)
    if (inherits(result, "error")) {
      showNotification(paste("Couldn't reassign the measure's owner:", conditionMessage(result)), type = "error", duration = 8)
    }
  }, ignoreInit = TRUE)
  observeEvent(input$guidance_download_started, {
    showNotification("Performance planning guidance download started.", type = "message")
  }, ignoreInit = TRUE)
  observeEvent(input$open_feedback_modal, {
    feedback_modal_open(TRUE)
  }, ignoreInit = TRUE)
  observeEvent(input$open_feedback_modal_request, {
    feedback_modal_open(TRUE)
  }, ignoreInit = TRUE)
  observeEvent(input$close_feedback_modal, {
    feedback_modal_open(FALSE)
  }, ignoreInit = TRUE)

  # ---- CLS requests -------------------------------------------------------
  cls_guard_edit <- function() {
    if (!can_edit_cls_requests(current_user_app_roles())) {
      showNotification("You do not have permission to change CLS requests.", type = "error", duration = 6)
      return(FALSE)
    }
    TRUE
  }
  cls_user_label <- function() {
    u <- current_user()
    if (is.null(u)) return("")
    nm <- as.character(u$full_name %||% "")
    if (nzchar(trimws(nm))) return(nm)
    as.character(u$email %||% "")
  }
  # modified_by / reviewed_by store the user id; the name shown in the UI is
  # resolved from access.user.full_name when the data is loaded.
  cls_user_id <- function() {
    u <- current_user()
    if (is.null(u)) return(NA_integer_)
    suppressWarnings(as.integer(u$user_id %||% NA_integer_))
  }
  output$cls_save_status <- renderUI({
    saved_label <- function(ts, by) {
      by <- as.character(by %||% "")
      span(
        title = if (nzchar(by)) paste("Saved by", by) else "Autosave enabled",
        paste0("Last Saved ", cls_fmt_saved(ts))
      )
    }
    ls <- cls_last_save()
    if (!is.null(ls)) {
      return(saved_label(ls$at, ls$by))
    }
    cls_id <- suppressWarnings(as.integer(current_cls_id()))
    data <- app_data()
    if (!is.na(cls_id) && !is.null(data) && !is.null(data$budget_cls_request) && nrow(data$budget_cls_request)) {
      r <- data$budget_cls_request[data$budget_cls_request$cls_id == cls_id, , drop = FALSE]
      if (nrow(r)) {
        # modified_by is a user id; modified_by_name is the joined full_name.
        return(saved_label(r$updated_at[[1]], r$modified_by_name[[1]] %||% ""))
      }
    }
    span(title = "Autosave enabled", "Autosave on")
  })
  observeEvent(input$cls_autosave, {
    if (!can_edit_cls_requests(current_user_app_roles())) return()
    cls_id <- suppressWarnings(as.integer(current_cls_id()))
    if (!nzchar(trimws(as.character(input$cls_form_name %||% "")))) {
      session$sendCustomMessage("cls-save-status", "Add a request name to save")
      return()
    }
    # The "Create request" button is gone (analyst feedback): a brand-new request
    # is created by its first autosave, once it has a name and a service, and
    # from then on autosaves as an update like any other.
    if (is.na(cls_id)) {
      service_id <- suppressWarnings(as.integer(input$cls_form_service))
      if (is.na(service_id)) {
        session$sendCustomMessage("cls-save-status", "Choose a service to save")
        return()
      }
      created <- tryCatch(
        create_cls_request(
          database,
          plan_service_id = service_id,
          request_name = input$cls_form_name,
          request_type = input$cls_form_type,
          request_amount = input$cls_form_amount,
          one_time = isTRUE(input$cls_form_one_time),
          overall_summary = input$cls_form_summary,
          amount_next_fy = input$cls_form_amount_next,
          amount_2next_fy = input$cls_form_amount_2next,
          modified_by = cls_user_id()
        ),
        error = function(error) error
      )
      if (inherits(created, "error")) {
        session$sendCustomMessage("cls-save-status", "Could not autosave")
        return()
      }
      current_cls_id(as.integer(created))
      cls_last_save(list(at = Sys.time(), by = cls_user_label()))
      # Re-render once so the details and positions sections unlock.
      refresh_app_data(domains = "cls")
      return()
    }
    result <- tryCatch(
      update_cls_request(
        database, cls_id,
        request_name = input$cls_form_name,
        request_type = input$cls_form_type,
        request_amount = input$cls_form_amount,
        one_time = isTRUE(input$cls_form_one_time),
        overall_summary = input$cls_form_summary,
        amount_next_fy = input$cls_form_amount_next,
        amount_2next_fy = input$cls_form_amount_2next,
        plan_service_id = input$cls_form_service,
        modified_by = cls_user_id()
      ),
      error = function(error) error
    )
    if (inherits(result, "error")) {
      session$sendCustomMessage("cls-save-status", "Could not autosave")
      return()
    }
    # Deliberately not refreshing app_data here so the form is not re-rendered
    # mid-edit; the list refreshes when the user leaves the request page.
    cls_last_save(list(at = Sys.time(), by = cls_user_label()))
  }, ignoreInit = TRUE)
  observeEvent(input$cls_create_open, {
    if (!cls_guard_edit()) return()
    # Analyst feedback: every field must be editable the moment the user enters
    # the request, including objects and positions. Those need a cls_id to hang
    # off, so the draft row is created here rather than on first autosave. It
    # shows on the list as a not-detailed request until it is filled in.
    data <- ensure_app_data()
    agency <- cls_agency_id_for_submitter(data, current_submitter_value())
    choices <- cls_agency_service_choices(data, agency)
    if (!length(choices)) {
      showNotification("This agency has no services on its current plan, so a CLS request cannot be created yet.",
                       type = "error", duration = 8)
      return()
    }
    created <- tryCatch(
      create_cls_request(
        database,
        plan_service_id = as.integer(choices[[1]]),
        request_name = CLS_DRAFT_NAME,
        modified_by = cls_user_id()
      ),
      error = function(error) error
    )
    if (inherits(created, "error")) {
      showNotification(conditionMessage(created), type = "error", duration = 8)
      return()
    }
    refresh_app_data(domains = "cls")
    current_cls_id(as.integer(created))
    # Remember it outside the reactive graph too, so the session-ended handler
    # can clean it up if the user simply closes the browser.
    cls_draft_watch$cls_id <- as.integer(created)
    cls_detail_origin("cls_requests")
    cls_last_save(NULL)
    current_page("cls_request_detail")
    session$sendCustomMessage("set-page", "cls_request_detail")
  }, ignoreInit = TRUE)
  # The agency goes in the file name so a folder of downloads is sortable and a
  # forwarded workbook identifies itself (analyst feedback round 2).
  cls_export_agency_slug <- function() {
    data <- ensure_app_data()
    agency <- cls_agency_display_name(data, cls_agency_id_for_submitter(data, current_submitter_value()))
    slug <- tolower(gsub("[^A-Za-z0-9]+", "-", as.character(agency %||% "")))
    slug <- gsub("(^-|-$)", "", slug)
    if (!nzchar(slug)) "agency" else slug
  }
  output$cls_export_xlsx <- downloadHandler(
    filename = function() paste0("cls-requests-", cls_export_agency_slug(), "-", format(Sys.time(), "%Y%m%d"), ".xlsx"),
    content = function(file) {
      data <- ensure_app_data()
      plan <- current_plan(data, current_submitter_value())
      sheets <- cls_export_sheets(data, plan)
      if (requireNamespace("writexl", quietly = TRUE)) {
        writexl::write_xlsx(sheets, path = file)
      } else {
        utils::write.csv(sheets[["Request summary"]], file, row.names = FALSE)
      }
    }
  )
  output$cls_export_pdf <- downloadHandler(
    filename = function() paste0("cls-requests-", cls_export_agency_slug(), "-", format(Sys.time(), "%Y%m%d"), ".pdf"),
    content = function(file) {
      data <- ensure_app_data()
      plan <- current_plan(data, current_submitter_value())
      build_cls_request_pdf(data, plan, file)
    }
  )
  # ---- Per-request hand-off (one request at a time) -----------------------
  cls_pending_submit <- reactiveVal(NULL)
  cls_request_name_for <- function(data, cls_id) {
    reqs <- data$budget_cls_request
    if (is.null(reqs) || !nrow(reqs)) return("this request")
    row <- reqs[reqs$cls_id == cls_id, , drop = FALSE]
    if (!nrow(row)) return("this request")
    as.character(row$request_name[[1]] %||% "this request")
  }
  # A request cannot move to the next pair of hands until it is fully described.
  cls_block_if_incomplete <- function(data, cls_id) {
    reqs <- data$budget_cls_request
    row <- if (is.null(reqs) || !nrow(reqs)) NULL else reqs[reqs$cls_id == cls_id, , drop = FALSE]
    if (is.null(row) || !nrow(row)) return(TRUE)
    gaps <- cls_request_gaps(data, row)
    if (!length(gaps)) return(FALSE)
    showModal(modalDialog(
      title = "This request is not ready to send",
      div(class = "cls-submit-dialog",
        p(paste0("“", cls_request_name_for(data, cls_id), "” still needs:")),
        tags$ul(lapply(gaps, tags$li)),
        p("Open the request and complete it, then send it on.")),
      footer = modalButton("Close"),
      easyClose = TRUE
    ))
    TRUE
  }
  observeEvent(input$cls_submit_one, {
    if (!cls_guard_edit()) return()
    cls_id <- suppressWarnings(as.integer(input$cls_submit_one$clsId))
    if (is.na(cls_id)) return()
    data <- ensure_app_data()
    if (cls_block_if_incomplete(data, cls_id)) return()
    plan <- current_plan(data, current_submitter_value())
    cls_pending_submit(list(cls_id = cls_id, mode = "approval"))
    showModal(modalDialog(
      title = "Submit for approval",
      div(class = "cls-submit-dialog",
        p(paste0("Submit “", cls_request_name_for(data, cls_id), "” to ", cls_submitter_name(data, plan), " for approval?"))),
      footer = tagList(modalButton("Cancel"), actionButton("cls_submit_confirm", "Submit", class = "civic-button submit-agency")),
      easyClose = TRUE
    ))
  }, ignoreInit = TRUE)
  observeEvent(input$cls_submit_confirm, {
    removeModal()
    pending <- cls_pending_submit()
    if (is.null(pending) || !identical(pending$mode, "approval")) return()
    if (!cls_guard_edit()) return()
    data <- ensure_app_data()
    plan <- current_plan(data, current_submitter_value())
    result <- tryCatch(set_cls_status(database, pending$cls_id, "Agency Review", cls_user_id()), error = function(error) error)
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    cls_pending_submit(NULL)
    refresh_app_data(domains = "cls")
    # Email notification to the Agency Submitter is intentionally disabled for now.
    # When enabled, send here via the app's mail helper (see R/auth.R send_mail usage).
    notify_agency_submitter_of_cls <- FALSE
    if (isTRUE(notify_agency_submitter_of_cls)) {
      # send_cls_submission_email(data, plan, pending$cls_id)  # future email hook
    }
    showNotification(
      paste0("Request submitted to ", cls_submitter_name(data, plan), " for approval. (Email notification is disabled for now.)"),
      type = "message", duration = 7
    )
  }, ignoreInit = TRUE)
  output$cls_review_export_xlsx <- downloadHandler(
    # Names the agency when the filter is narrowed to exactly one, so a workbook
    # sent to that agency says so on the tin.
    filename = function() {
      picked <- cls_applied_agency()
      label <- if (length(picked) == 1) {
        slug <- tolower(gsub("[^A-Za-z0-9]+", "-", picked[[1]]))
        gsub("(^-|-$)", "", slug)
      } else "all-agencies"
      if (!nzchar(label)) label <- "all-agencies"
      paste0("cls-review-", label, "-", format(Sys.time(), "%Y%m%d"), ".xlsx")
    },
    content = function(file) {
      if (!can_review_cls(current_user_app_roles())) stop("Only BBMR Reviewers can export the review workbook.")
      sheets <- cls_review_export_sheets(ensure_app_data())
      if (requireNamespace("writexl", quietly = TRUE)) {
        writexl::write_xlsx(sheets, path = file)
      } else {
        utils::write.csv(sheets[["Requests and decisions"]], file, row.names = FALSE)
      }
    }
  )
  # Filters apply as soon as they change - no Apply step (analyst feedback).
  observeEvent(input$cls_review_status_filter, {
    cls_applied_status(as.character(input$cls_review_status_filter %||% character(0)))
  }, ignoreInit = TRUE, ignoreNULL = FALSE)
  observeEvent(input$cls_review_agency_filter, {
    cls_applied_agency(as.character(input$cls_review_agency_filter %||% character(0)))
  }, ignoreInit = TRUE, ignoreNULL = FALSE)
  observeEvent(input$cls_review_service_filter, {
    cls_applied_service(as.character(input$cls_review_service_filter %||% character(0)))
  }, ignoreInit = TRUE, ignoreNULL = FALSE)
  observeEvent(input$cls_review_reset_filters, {
    cls_applied_status(NULL)
    cls_applied_agency(NULL)
    cls_applied_service(NULL)
    data <- ensure_app_data()
    rows <- cls_review_rows(data)
    agencies <- if (nrow(rows)) sort(unique(rows$agency)) else character(0)
    services <- if (nrow(rows)) sort(unique(rows$service)) else character(0)
    updateCheckboxGroupInput(session, "cls_review_status_filter", choices = cls_status_choices, selected = cls_status_choices)
    updateCheckboxGroupInput(session, "cls_review_agency_filter", choices = agencies, selected = agencies)
    updateCheckboxGroupInput(session, "cls_review_service_filter", choices = services, selected = services)
  }, ignoreInit = TRUE)

  # --- Bulk approve: an inline mode on CLS Review, not a modal ---
  cls_bulk_mode <- reactiveVal(FALSE)
  observeEvent(input$cls_bulk_approve, {
    if (!can_review_cls(current_user_app_roles())) return()
    cls_bulk_mode(identical(as.character(input$cls_bulk_approve$what %||% ""), "open"))
  }, ignoreInit = TRUE)
  # Send back: returns a submitted request to the agency and unlocks it. Because
  # "locked" is derived from status, moving it back to In Progress is what makes
  # it editable again; any decision already recorded is cleared so the agency is
  # not looking at a stale approval while they rework it.
  observeEvent(input$cls_send_back, {
    if (!can_review_cls(current_user_app_roles())) {
      showNotification("Only BBMR Reviewers can send a request back to an agency.", type = "error", duration = 6)
      return()
    }
    cls_id <- suppressWarnings(as.integer(input$cls_send_back$clsId))
    if (is.na(cls_id)) return()
    data <- ensure_app_data()
    name <- cls_request_name_for(data, cls_id)
    result <- tryCatch({
      clear_cls_review_decision(database, cls_id, reviewed_by = cls_user_id())
      set_cls_status(database, cls_id, "In Progress", cls_user_id())
    }, error = function(error) error)
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data(domains = "cls")
    showNotification(
      paste0("“", name, "” was sent back to the agency and is unlocked for editing."),
      type = "message", duration = 7
    )
  }, ignoreInit = TRUE)
  observeEvent(input$cls_bulk_save, {
    if (!can_review_cls(current_user_app_roles())) return()
    data <- ensure_app_data()
    rows <- cls_review_rows(data)
    if (length(cls_applied_status())) rows <- rows[rows$status %in% cls_applied_status(), , drop = FALSE]
    if (length(cls_applied_agency())) rows <- rows[rows$agency %in% cls_applied_agency(), , drop = FALSE]
    if (length(cls_applied_service())) rows <- rows[rows$service %in% cls_applied_service(), , drop = FALSE]
    saved <- 0L
    failed <- character(0)
    for (i in seq_len(nrow(rows))) {
      id <- rows$cls_id[[i]]
      decision <- as.character(input[[paste0("cls_bulk_bbmr_", id)]] %||% "")
      if (!nzchar(decision)) next
      result <- tryCatch(
        save_cls_review(
          database, id,
          analyst_notes = rows$analyst_notes[[i]],
          analyst_approval = rows$analyst_approval[[i]],
          bbmr_approval = decision,
          reviewed_by = cls_user_id(),
          approved_amount = input[[paste0("cls_bulk_amount_", id)]],
          approved_positions = input[[paste0("cls_bulk_positions_", id)]]
        ),
        error = function(error) error
      )
      if (inherits(result, "error")) failed <- c(failed, rows$request_name[[i]]) else saved <- saved + 1L
    }
    cls_bulk_mode(FALSE)
    refresh_app_data(domains = "cls")
    if (length(failed)) {
      showNotification(paste0("Saved ", saved, ". Could not save: ", paste(failed, collapse = ", "), "."),
                       type = "error", duration = 10)
    } else {
      showNotification(paste0("Recorded decisions on ", saved, if (saved == 1) " request." else " requests."),
                       type = "message", duration = 7)
    }
  }, ignoreInit = TRUE)
  observeEvent(input$cls_review_save, {
    if (!can_review_cls(current_user_app_roles())) {
      showNotification("Only BBMR Reviewers can record CLS review decisions.", type = "error", duration = 6)
      return()
    }
    cls_id <- suppressWarnings(as.integer(input$cls_review_save$clsId))
    if (is.na(cls_id)) return()
    result <- tryCatch(
      save_cls_review(
        database, cls_id,
        analyst_notes = input[[paste0("cls_rv_notes_", cls_id)]],
        analyst_approval = input[[paste0("cls_rv_analyst_", cls_id)]],
        bbmr_approval = input[[paste0("cls_rv_bbmr_", cls_id)]],
        reviewed_by = cls_user_id(),
        approved_amount = input[[paste0("cls_rv_appr_amount_", cls_id)]],
        approved_positions = input[[paste0("cls_rv_appr_positions_", cls_id)]]
      ),
      error = function(error) error
    )
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data(domains = "cls")
    showNotification("Review saved.", type = "message", duration = 5)
  }, ignoreInit = TRUE)
  observeEvent(input$cls_send_bbmr_one, {
    if (!can_approve_cls(current_user_app_roles())) return()
    cls_id <- suppressWarnings(as.integer(input$cls_send_bbmr_one$clsId))
    if (is.na(cls_id)) return()
    data <- ensure_app_data()
    if (cls_block_if_incomplete(data, cls_id)) return()
    cls_pending_submit(list(cls_id = cls_id, mode = "bbmr"))
    showModal(modalDialog(
      title = "Send for BBMR Review",
      div(class = "cls-submit-dialog",
        # Named attestation: the submitter is putting their name to this.
        p(class = "cls-attestation",
          "I, ", tags$strong(cls_user_label()),
          ", have reviewed this request and submit for review."),
        p(class = "cls-attestation-detail",
          paste0("Request: “", cls_request_name_for(data, cls_id), "”. This marks the request complete and sends it to BBMR."))),
      footer = tagList(modalButton("Cancel"), actionButton("cls_send_bbmr_confirm", "Submit for review", class = "civic-button submit-agency")),
      easyClose = TRUE
    ))
  }, ignoreInit = TRUE)
  observeEvent(input$cls_send_bbmr_confirm, {
    removeModal()
    pending <- cls_pending_submit()
    if (is.null(pending) || !identical(pending$mode, "bbmr")) return()
    if (!can_approve_cls(current_user_app_roles())) return()
    result <- tryCatch(set_cls_status(database, pending$cls_id, "BBMR Review", cls_user_id()), error = function(error) error)
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    cls_pending_submit(NULL)
    refresh_app_data(domains = "cls")
    showNotification("Request marked complete and sent for BBMR review.", type = "message", duration = 7)
  }, ignoreInit = TRUE)
  observeEvent(input$cls_open_detail, {
    if (!can_open_cls_request(current_user_app_roles())) return()
    cls_id <- suppressWarnings(as.integer(input$cls_open_detail$clsId))
    if (is.na(cls_id)) return()
    current_cls_id(cls_id)
    cls_detail_origin(current_page())
    cls_last_save(NULL)
    current_page("cls_request_detail")
    session$sendCustomMessage("set-page", "cls_request_detail")
  }, ignoreInit = TRUE)
  observeEvent(input$cls_submit_update, {
    if (!cls_guard_edit()) return()
    cls_id <- suppressWarnings(as.integer(current_cls_id()))
    if (is.na(cls_id)) return()
    result <- tryCatch(
      update_cls_request(
        database, cls_id,
        request_name = input$cls_form_name,
        request_type = input$cls_form_type,
        request_amount = input$cls_form_amount,
        one_time = isTRUE(input$cls_form_one_time),
        overall_summary = input$cls_form_summary,
        amount_next_fy = input$cls_form_amount_next,
        amount_2next_fy = input$cls_form_amount_2next,
        plan_service_id = input$cls_form_service
      ),
      error = function(error) error
    )
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data(domains = "cls")
    showNotification("CLS request saved.", type = "message", duration = 5)
  }, ignoreInit = TRUE)
  # Analyst feedback: nothing lands in the table until every field is filled.
  cls_missing_fields <- function(fields) {
    missing <- character(0)
    for (label in names(fields)) {
      v <- fields[[label]]
      ok <- if (is.numeric(v)) length(v) == 1 && !is.na(v) && v > 0 else nzchar(trimws(as.character(v %||% "")))
      if (!isTRUE(ok)) missing <- c(missing, label)
    }
    missing
  }
  cls_warn_missing <- function(missing, what) {
    showNotification(
      paste0("Add ", what, " needs: ", paste(missing, collapse = ", "), "."),
      type = "error", duration = 7
    )
  }
  observeEvent(input$cls_submit_line, {
    if (!cls_guard_edit()) return()
    cls_id <- suppressWarnings(as.integer(current_cls_id()))
    if (is.na(cls_id)) return()
    missing <- cls_missing_fields(list(
      Object = input$cls_line_category,
      `Spend category` = input$cls_line_spend_category,
      Amount = suppressWarnings(as.numeric(input$cls_line_amount)),
      Justification = input$cls_line_justification
    ))
    if (length(missing)) { cls_warn_missing(missing, "an object"); return() }
    result <- tryCatch(
      add_cls_request_line(database, cls_id, input$cls_line_category, input$cls_line_amount,
                           input$cls_line_justification,
                           spend_category = input$cls_line_spend_category),
      error = function(error) error
    )
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data(domains = "cls")
    showNotification("Line item added.", type = "message", duration = 5)
  }, ignoreInit = TRUE)
  observeEvent(input$cls_submit_position, {
    if (!cls_guard_edit()) return()
    cls_id <- suppressWarnings(as.integer(current_cls_id()))
    if (is.na(cls_id)) return()
    missing <- cls_missing_fields(list(
      `Job classification` = input$cls_position_classification,
      `Number of positions` = suppressWarnings(as.numeric(input$cls_position_count)),
      `Estimated Cost` = suppressWarnings(as.numeric(input$cls_position_salary)),
      Justification = input$cls_position_justification,
      Explanation = input$cls_position_explanation
    ))
    if (length(missing)) { cls_warn_missing(missing, "a position"); return() }
    result <- tryCatch(
      add_cls_request_position(
        database, cls_id,
        classification = input$cls_position_classification,
        position_count = input$cls_position_count,
        estimated_salary = input$cls_position_salary,
        justification = input$cls_position_justification,
        explanation = input$cls_position_explanation
      ),
      error = function(error) error
    )
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data(domains = "cls")
    showNotification("Position request added.", type = "message", duration = 5)
  }, ignoreInit = TRUE)
  observeEvent(input$cls_edit_line, {
    if (!cls_guard_edit()) return()
    cls_editing_position(NA_integer_)
    cls_editing_line(suppressWarnings(as.integer(input$cls_edit_line$lineId)))
  }, ignoreInit = TRUE)
  observeEvent(input$cls_edit_position, {
    if (!cls_guard_edit()) return()
    cls_editing_line(NA_integer_)
    cls_editing_position(suppressWarnings(as.integer(input$cls_edit_position$posId)))
  }, ignoreInit = TRUE)
  observeEvent(input$cls_cancel_edit, {
    cls_editing_line(NA_integer_)
    cls_editing_position(NA_integer_)
  }, ignoreInit = TRUE)
  observeEvent(input$cls_line_edit_save, {
    if (!cls_guard_edit()) return()
    line_id <- suppressWarnings(as.integer(cls_editing_line()))
    if (is.na(line_id)) return()
    missing <- cls_missing_fields(list(
      Object = input$cls_line_edit_category,
      `Spend category` = input$cls_line_edit_spend_category,
      Amount = suppressWarnings(as.numeric(input$cls_line_edit_amount)),
      Justification = input$cls_line_edit_justification
    ))
    if (length(missing)) { cls_warn_missing(missing, "an object"); return() }
    result <- tryCatch(
      update_cls_request_line(
        database, line_id,
        object_category = input$cls_line_edit_category,
        amount = input$cls_line_edit_amount,
        justification = input$cls_line_edit_justification,
        spend_category = input$cls_line_edit_spend_category,
        modified_by = cls_user_id()
      ),
      error = function(error) error
    )
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    cls_editing_line(NA_integer_)
    refresh_app_data(domains = "cls")
    showNotification("Object updated.", type = "message", duration = 5)
  }, ignoreInit = TRUE)
  observeEvent(input$cls_position_edit_save, {
    if (!cls_guard_edit()) return()
    pos_id <- suppressWarnings(as.integer(cls_editing_position()))
    if (is.na(pos_id)) return()
    missing <- cls_missing_fields(list(
      `Job classification` = input$cls_position_edit_classification,
      `Number of positions` = suppressWarnings(as.numeric(input$cls_position_edit_count)),
      `Estimated Cost` = suppressWarnings(as.numeric(input$cls_position_edit_salary)),
      Justification = input$cls_position_edit_justification
    ))
    if (length(missing)) { cls_warn_missing(missing, "a position"); return() }
    result <- tryCatch(
      update_cls_request_position(
        database, pos_id,
        classification = input$cls_position_edit_classification,
        position_count = input$cls_position_edit_count,
        estimated_salary = input$cls_position_edit_salary,
        justification = input$cls_position_edit_justification,
        modified_by = cls_user_id()
      ),
      error = function(error) error
    )
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    cls_editing_position(NA_integer_)
    refresh_app_data(domains = "cls")
    showNotification("Position updated.", type = "message", duration = 5)
  }, ignoreInit = TRUE)
  observeEvent(input$cls_delete, {
    if (!cls_guard_edit()) return()
    cls_id <- suppressWarnings(as.integer(input$cls_delete$clsId))
    if (is.na(cls_id)) return()
    result <- tryCatch(delete_cls_request(database, cls_id), error = function(error) error)
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    if (!is.na(current_cls_id()) && current_cls_id() == cls_id && identical(current_page(), "cls_request_detail")) {
      current_cls_id(NA_integer_)
      current_page("cls_requests")
      session$sendCustomMessage("set-page", "cls_requests")
    }
    refresh_app_data(domains = "cls")
    showNotification("CLS request deleted.", type = "message", duration = 5)
  }, ignoreInit = TRUE)
  observeEvent(input$cls_delete_line, {
    if (!cls_guard_edit()) return()
    line_id <- suppressWarnings(as.integer(input$cls_delete_line$lineId))
    if (is.na(line_id)) return()
    result <- tryCatch(delete_cls_request_line(database, line_id), error = function(error) error)
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data(domains = "cls")
    showNotification("Line item removed.", type = "message", duration = 5)
  }, ignoreInit = TRUE)
  observeEvent(input$cls_delete_position, {
    if (!cls_guard_edit()) return()
    pos_id <- suppressWarnings(as.integer(input$cls_delete_position$posId))
    if (is.na(pos_id)) return()
    result <- tryCatch(delete_cls_request_position(database, pos_id), error = function(error) error)
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data(domains = "cls")
    showNotification("Position request removed.", type = "message", duration = 5)
  }, ignoreInit = TRUE)
  observeEvent(input$submit_feedback_request, {
    request <- input$submit_feedback_request
    page_key <- as.character(request$page %||% current_page())
    page_url <- as.character(request$pageUrl %||% "")
    screenshot_data <- as.character(request$screenshotData %||% input$feedback_screenshot_data %||% "")
    result <- tryCatch(
      save_feedback_request(database, input$feedback_email, input$feedback_comment, screenshot_data, page_key, page_url),
      error = function(error) error
    )
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data(after = function() {
      feedback_modal_open(FALSE)
      showNotification("Feedback submitted. Thank you.", type = "message", duration = 6)
    })
  }, ignoreInit = TRUE)
  observeEvent(input$feedback_admin_update, {
    if (!current_user_can_view_application_admin()) {
      showNotification("Only System Admins can update feedback requests.", type = "error", duration = 8)
      return()
    }
    request <- input$feedback_admin_update
    result <- tryCatch(
      update_feedback_request(
        database,
        request$feedbackId,
        request$category,
        request$priority,
        request$status,
        request$assignedAdminId,
        current_user_email()
      ),
      error = function(error) error
    )
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data(after = function() {
      showNotification("Feedback request updated.", type = "message", duration = 5)
    })
  }, ignoreInit = TRUE)
  observeEvent(input$feedback_admin_delete, {
    if (!current_user_can_view_application_admin()) {
      showNotification("Only System Admins can delete feedback requests.", type = "error", duration = 8)
      return()
    }
    result <- tryCatch(delete_feedback_request(database, input$feedback_admin_delete$feedbackId), error = function(error) error)
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data(after = function() {
      showNotification("Feedback request deleted.", type = "message", duration = 5)
    })
  }, ignoreInit = TRUE)
  observeEvent(input$measure_review_decision, {
    if (!current_user_can_review_measures()) {
      showNotification("Only System Admins and OPI Reviewers can approve, validate, return, or provide feedback on measures.", type = "error", duration = 8)
      return()
    }
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
    refresh_app_data(after = function() {
      showNotification(if (identical(action, "approve")) "Measure approved." else "Measure returned to agency with feedback.", type = "message")
    }, domains = "measures")
  }, ignoreInit = TRUE)
  observeEvent(input$measure_cap_error, {
    message <- input$measure_cap_error$message %||% "No more than 5 measures are allowed."
    showNotification(message, type = "error", duration = 8)
  }, ignoreInit = TRUE)
  observeEvent(input$confirm_deactivate_measure, {
    measure_id <- current_measure_id()
    if (is.null(measure_id) || identical(measure_id, "new")) return()
    result <- tryCatch(set_measure_active(database, measure_id, current_agency_id(), FALSE), error = function(error) error)
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error")
      return()
    }
    refresh_app_data(after = function() {
      showNotification("Measure made inactive.", type = "message")
    }, domains = "measures")
  }, ignoreInit = TRUE)
  observeEvent(input$reactivate_measure, {
    set_measure_active(database, current_measure_id(), current_agency_id(), TRUE)
    refresh_app_data(after = function() {
      showNotification("Measure reactivated.", type = "message")
    }, domains = "measures")
  }, ignoreInit = TRUE)
  observeEvent(input$confirm_measure_revert_to_draft, {
    if (!current_user_can_edit_locked_measure_data()) {
      showNotification("Only System Admins can revert a measure's status.", type = "error", duration = 8)
      return()
    }
    measure_id <- current_measure_id()
    if (is.null(measure_id) || identical(measure_id, "new")) return()
    result <- tryCatch(revert_measure_to_draft(database, measure_id), error = function(error) error)
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data(after = function() {
      showNotification("Measure reverted to Draft.", type = "message")
    }, domains = "measures")
  }, ignoreInit = TRUE)

  observeEvent(input$open_risk_id, {
    current_risk_id(as.character(input$open_risk_id))
  }, ignoreInit = TRUE)

  observeEvent(input$close_risk_modal, current_risk_id(NULL), ignoreInit = TRUE)
  observeEvent(input$open_team_access_id, {
    request <- input$open_team_access_id
    access_id <- as.character(request$accessId)
    if (!identical(access_id, "new") && !is_entity_access_id(access_id) && is.na(suppressWarnings(as.integer(access_id)))) return()
    current_team_access_id(access_id)
  }, ignoreInit = TRUE)
  observeEvent(input$close_team_role_modal, current_team_access_id(NULL), ignoreInit = TRUE)
  observeEvent(input$close_team_role_modal_footer, current_team_access_id(NULL), ignoreInit = TRUE)
  observeEvent(input$team_role_save_request, {
    if (isTRUE(team_role_save_in_progress())) return()
    team_role_save_in_progress(TRUE)
    async_save_kicked_off <- FALSE
    on.exit({
      if (!async_save_kicked_off) {
        team_role_save_in_progress(FALSE)
        session$sendCustomMessage("team-role-save-result", list(ok = FALSE))
      }
    }, add = TRUE)
    if (!current_user_can_manage_team()) {
      showNotification("You do not have permission to change team roles.", type = "error", duration = 8)
      return()
    }
    access_id <- current_team_access_id()
    if (is.null(access_id)) return()
    data <- app_data()
    plan <- current_plan(data, current_submitter_value())
    accounting_agency_id <- plan_accounting_agency_id(data, plan)
    team_entity_id <- plan_team_entity_context_id(data, plan)
    is_entity_context <- !is.na(team_entity_id)
    service_id <- if (is_entity_context) plan_team_primary_access_service_id(data, plan) else plan_team_primary_service_id(data, plan)
    target_performance_role <- input$team_performance_role
    performance_role_unchanged <- FALSE
    if (!identical(access_id, "new")) {
      access_row <- if (is_entity_access_id(access_id) && "access_user_entity_access" %in% names(data)) {
        data$access_user_entity_access[
          data$access_user_entity_access$entity_access_id == entity_access_numeric_id(access_id),
          ,
          drop = FALSE
        ]
      } else {
        data$access_user_agency_access[
          data$access_user_agency_access$access_id == suppressWarnings(as.integer(access_id)),
          ,
          drop = FALSE
        ]
      }
      if (nrow(access_row)) {
        current_role_rows <- data$access_user_role[
          data$access_user_role$user_id == access_row$user_id[[1]] &
            (is.na(data$access_user_role$agency_id) | data$access_user_role$agency_id == accounting_agency_id),
          ,
          drop = FALSE
        ]
        if (nrow(current_role_rows)) {
          performance_role_unchanged <- identical(as.character(target_performance_role), as.character(current_role_rows$app_role[[1]]))
        }
      }
    }
    if (!performance_role_unchanged && !can_grant_performance_role(current_user_app_roles(), current_user_agency_roles(), target_performance_role)) {
      showNotification("You do not have permission to assign that performance role.", type = "error", duration = 8)
      return()
    }
    result <- tryCatch({
      if (is_entity_context) {
        save_entity_team_role_assignment(
          database,
          if (is_entity_access_id(access_id)) entity_access_numeric_id(access_id) else "new",
          team_entity_id,
          accounting_agency_id,
          input$team_full_name,
          input$team_email,
          input$team_agency_role,
          target_performance_role,
          isTRUE(input$team_budget_access),
          isTRUE(input$team_adaptive_planning),
          isTRUE(input$team_performance_plan_access),
          service_id
        )
      } else {
        save_team_role_assignment(
          database,
          access_id,
          accounting_agency_id,
          input$team_full_name,
          input$team_email,
          input$team_agency_role,
          target_performance_role,
          isTRUE(input$team_budget_access),
          isTRUE(input$team_adaptive_planning),
          isTRUE(input$team_performance_plan_access),
          service_id
        )
      }
    }, error = function(error) error)
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    async_save_kicked_off <- TRUE
    refresh_app_data(
      after = function() {
        team_role_save_in_progress(FALSE)
        current_team_access_id(NULL)
        showNotification("Team role updated.", type = "message")
        session$sendCustomMessage("team-role-save-result", list(ok = TRUE))
      },
      on_error = function(error) {
        team_role_save_in_progress(FALSE)
        session$sendCustomMessage("team-role-save-result", list(ok = FALSE))
      }
    )
  }, ignoreInit = FALSE)
  observeEvent(input$team_role_delete_confirmed_request, {
    if (!current_user_can_manage_team()) {
      showNotification("You do not have permission to delete team access.", type = "error", duration = 8)
      return()
    }
    access_id <- current_team_access_id()
    if (is.null(access_id) || identical(access_id, "new")) return()
    result <- tryCatch({
      if (is_entity_access_id(access_id)) {
        delete_entity_team_role_assignment(
          database,
          entity_access_numeric_id(access_id),
          current_role_preview_user_id() %||% input$role_preview_user_id %||% NA_integer_
        )
      } else {
        delete_team_role_assignment(
          database,
          access_id,
          current_role_preview_user_id() %||% input$role_preview_user_id %||% NA_integer_
        )
      }
    }, error = function(error) error)
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data(after = function() {
      current_team_access_id(NULL)
      showNotification("Team access deleted.", type = "message")
    })
  }, ignoreInit = TRUE)
  observeEvent(input$risk_save_request, {
    if (isTRUE(risk_save_in_progress())) return()
    risk_save_in_progress(TRUE)
    async_save_kicked_off <- FALSE
    on.exit({
      if (!async_save_kicked_off) {
        risk_save_in_progress(FALSE)
        session$sendCustomMessage("risk-save-result", list(ok = FALSE))
      }
    }, add = TRUE)
    if (!current_user_can_edit_plan()) {
      showNotification("You do not have permission to edit this plan.", type = "error", duration = 8)
      return()
    }
    data <- app_data()
    plan <- current_plan(data, current_submitter_value())
    if (!plan_is_editable(plan)) {
      showNotification("This plan is locked and cannot be edited.", type = "error", duration = 8)
      return()
    }
    risk_id <- current_risk_id()
    # NULL only for the literal "new" sentinel (a brand-new risk, no draft
    # entry yet). A "new-<epoch>" temp id (re-editing an unsaved add before
    # it's ever promoted) must pass through as-is so
    # save_risks_draft_upsert() reuses that same draft entry instead of
    # minting a second one.
    risk_id <- if (is.null(risk_id) || identical(risk_id, "new")) NULL else risk_id
    result <- tryCatch(
      save_risks_draft_upsert(
        database, plan$plan_id[[1]], risk_id, input$risk_type, input$risk_description,
        updated_by = suppressWarnings(as.integer(current_role_preview_user_id() %||% input$role_preview_user_id %||% NA_integer_))
      ),
      error = function(error) error
    )
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    async_save_kicked_off <- TRUE
    refresh_app_data(
      after = function() {
        risk_save_in_progress(FALSE)
        current_risk_id(NULL)
        showNotification("Risk saved.", type = "message")
        session$sendCustomMessage("risk-save-result", list(ok = TRUE))
      },
      on_error = function(error) {
        risk_save_in_progress(FALSE)
        session$sendCustomMessage("risk-save-result", list(ok = FALSE))
      }
    )
  }, ignoreInit = TRUE)

  observeEvent(input$risk_delete_confirmed_request, {
    if (!current_user_can_edit_plan()) {
      showNotification("You do not have permission to edit this plan.", type = "error", duration = 8)
      return()
    }
    data <- app_data()
    plan <- current_plan(data, current_submitter_value())
    if (!plan_is_editable(plan)) {
      showNotification("This plan is locked and cannot be edited.", type = "error", duration = 8)
      return()
    }
    risk_id <- current_risk_id()
    risk_id <- if (is.null(risk_id) || identical(risk_id, "new")) NULL else risk_id
    result <- tryCatch(
      save_risks_draft_delete(
        database, plan$plan_id[[1]], risk_id,
        updated_by = suppressWarnings(as.integer(current_role_preview_user_id() %||% input$role_preview_user_id %||% NA_integer_))
      ),
      error = function(error) error
    )
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data(after = function() {
      current_risk_id(NULL)
      showNotification("Risk deleted.", type = "message")
    })
  }, ignoreInit = TRUE)

  observeEvent(input$duplicate_plan_from, {
    if (!current_user_can_edit_plan()) {
      showNotification("You do not have permission to update this plan draft.", type = "error", duration = 8)
      return()
    }
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
    refresh_app_data(after = function() {
      showNotification(paste(fy_label(source_plan$fiscal_year[[1]]), "plan copied into the current shared draft."), type = "message", duration = 8)
    })
  }, ignoreInit = TRUE)

  observeEvent(input$review_plan_request, {
    request <- input$review_plan_request
    plan_id <- suppressWarnings(as.integer(request$planId))
    if (is.na(plan_id)) return()
    current_history_plan_id(plan_id)
    current_history_include_review(isTRUE(request$includeReview))
    return_page <- as.character(request$returnPage %||% "reviewer_dashboard")
    if (!return_page %in% c("reviewer_dashboard", "approval_queue", "publishing_queue", "plan_history")) {
      return_page <- "reviewer_dashboard"
    }
    current_review_return_page(return_page)
    current_page("plan_review_detail")
    session$sendCustomMessage("set-page", "plan_review_detail")
  }, ignoreInit = TRUE)

  observeEvent(input$close_history_plan_modal, {
    current_history_plan_id(NULL)
    current_history_include_review(TRUE)
  }, ignoreInit = TRUE)

  observeEvent(input$back_to_review_queue, {
    current_history_plan_id(NULL)
    current_history_include_review(TRUE)
    return_page <- current_review_return_page() %||% "reviewer_dashboard"
    current_page(return_page)
    session$sendCustomMessage("set-page", return_page)
  }, ignoreInit = TRUE)

  collect_plan_review_scores <- function(plan_id) {
    data <- app_data()
    plan <- data$planning_agency_plan[data$planning_agency_plan$plan_id == plan_id, , drop = FALSE]
    if (!nrow(plan)) return(list())
    goals <- data$performance_agency_goal[data$performance_agency_goal$plan_id == plan_id, , drop = FALSE]
    goals <- goals[order(goals$sort_order), , drop = FALSE]
    goal_targets <- plan_review_goal_target_ids(data, plan, goals)
    services <- plan_review_scorable_services(data, plan)
    rows <- list()
    append_rows <- function(criteria, target_type = "plan", target_id = NA_integer_) {
      for (i in seq_len(nrow(criteria))) {
        criterion <- criteria[i, , drop = FALSE]
        score_id <- review_input_id("review_score", criterion$section_code[[1]], criterion$criterion_code[[1]], target_type, target_id)
        notes_id <- review_input_id("review_notes", criterion$section_code[[1]], criterion$criterion_code[[1]], target_type, target_id)
        rows[[length(rows) + 1]] <<- list(
          section_code = criterion$section_code[[1]],
          criterion_code = criterion$criterion_code[[1]],
          target_type = target_type,
          target_id = if (is.na(target_id) || is.null(target_id)) NA_integer_ else as.integer(target_id),
          score = input[[score_id]],
          weight = criterion$weight[[1]],
          justification = input[[notes_id]] %||% ""
        )
      }
    }
    append_rows(plan_review_criteria("plan_overview"))
    append_rows(plan_review_criteria("plan_measures"))
    append_rows(plan_review_criteria("plan_risks"))
    append_rows(plan_review_criteria("plan_data"))
    if (nrow(goal_targets)) {
      for (i in seq_len(nrow(goal_targets))) {
        append_rows(plan_review_criteria("goal"), "goal", goal_targets$target_id[[i]])
      }
    }
    if (nrow(services)) {
      for (i in seq_len(nrow(services))) {
        append_rows(plan_review_criteria("service"), "service", services$plan_service_id[[i]])
      }
    }
    rows
  }

  observeEvent(input$plan_review_save_request, {
    if (!current_user_can_review_plans()) {
      showNotification("You do not have permission to score plans.", type = "error", duration = 8)
      return()
    }
    request <- input$plan_review_save_request
    plan_id <- suppressWarnings(as.integer(request$planId))
    source <- as.character(request$source %||% "manual")
    if (is.na(plan_id)) return()
    data <- app_data()
    plan <- data$planning_agency_plan[data$planning_agency_plan$plan_id == plan_id, , drop = FALSE]
    selected_reviewer_id <- suppressWarnings(as.integer(input$plan_review_reviewer_id %||% NA_integer_))
    current_preview_user_id <- suppressWarnings(as.integer(current_role_preview_user_id() %||% input$role_preview_user_id %||% NA_integer_))
    reviewer_rows <- data$access_user_role[data$access_user_role$app_role %in% access_policy$plan_review_app_roles, , drop = FALSE]
    reviewer_id <- if (!is.na(selected_reviewer_id)) {
      selected_reviewer_id
    } else if (!is.na(current_preview_user_id) && current_preview_user_id %in% reviewer_rows$user_id) {
      current_preview_user_id
    } else if (nrow(reviewer_rows)) {
      reviewer_rows$user_id[[1]]
    } else {
      NA_integer_
    }
    result <- tryCatch(
      save_plan_review_scores(database, plan_id, reviewer_id, collect_plan_review_scores(plan_id), input$plan_review_internal_notes %||% ""),
      error = function(error) error
    )
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    # No refresh_app_data() here on purpose: this observer fires on every
    # scoring-input change (auto-saved, debounced), not just a single manual
    # save, and refresh_app_data() reloads the ENTIRE database before
    # output$page fully re-renders -- visibly collapsing/scrolling the page
    # after every criterion score. The updated total score is already sent to
    # the client below, so no server re-render is needed for that feedback.
    # Terminal workflow actions on this plan (approve/route/publish) already
    # call refresh_app_data() on their own, so app_data() is guaranteed fresh
    # by the time it actually gates a workflow decision.
    #
    # But leaving app_data() fully stale in the meantime has its own bug:
    # if anything else causes output$page to re-render before the next full
    # refresh (a different input changing, a periodic session tick), it
    # reads back the pre-save review_plan_review/review_section_score rows
    # -- making content the reviewer just cleared appear to reappear.
    #
    # Patching app_data() itself (an earlier version of this fix) traded
    # that bug for a worse one: writing to app_data() re-invalidates
    # output$page on every autosave tick, which re-renders
    # page_plan_review_detail() from scratch and collapses every open
    # goal/service scoring drawer back to closed -- the exact problem
    # already solved for Goals/Services autosave via section_draft_cache/
    # data_with_cached_section_draft(). Mirror that pattern here: write to
    # the non-reactive review_snapshot_cache instead, and
    # data_with_cached_review_snapshot() reads it back in at render time
    # (see output$page) without ever touching app_data().
    snapshot <- tryCatch(plan_review_snapshot_for_plan(database, plan_id), error = function(error) NULL)
    if (!is.null(snapshot)) update_cached_review_snapshot(plan_id, snapshot)
    # Reported 2026-08-06: the "Action Plan alignment" summary chip kept
    # showing a stale "7 point penalty" even after scoring the Pillar Goal
    # Alignment criterion, confirmed 4/4 on every goal in the database --
    # a reload fixed it. Root cause: this chip is baked into the page at
    # the last full render, same as every other static part of
    # history_plan_modal(), but unlike the overall score number just
    # above, nothing ever re-sent it after an autosave (which
    # deliberately skips a full re-render -- see the comment above this
    # observer). Send it here the same way, computed from the same fresh
    # snapshot the overall score itself came from.
    alignment_met <- !is.null(snapshot) && nrow(snapshot$scores) > 0 &&
      any(snapshot$scores$criterion_code == "PILLAR" & !is.na(snapshot$scores$score), na.rm = TRUE)
    session$sendCustomMessage("plan-review-save-result", list(
      ok = TRUE,
      source = source,
      score = round(result),
      alignmentMet = isTRUE(alignment_met),
      savedAt = format(Sys.time(), "%H:%M:%S")
    ))
    if (!identical(source, "auto")) {
      showNotification(paste0("Plan review scores saved. Current score: ", round(result), "/100."), type = "message", duration = 8)
    }
  }, ignoreInit = TRUE)

  observeEvent(input$plan_reviewer_save_request, {
    if (!current_user_can_assign_plan_reviewer()) {
      showNotification("Only System Admins can assign plan reviewers.", type = "error", duration = 8)
      return()
    }
    request <- input$plan_reviewer_save_request
    plan_id <- suppressWarnings(as.integer(request$planId))
    reviewer_id <- suppressWarnings(as.integer(input$plan_review_reviewer_id))
    modified_by <- suppressWarnings(as.integer(current_role_preview_user_id() %||% NA_integer_))
    if (is.na(plan_id) || is.na(reviewer_id)) {
      showNotification("Choose a reviewer before saving.", type = "error", duration = 8)
      return()
    }
    result <- tryCatch(
      assign_plan_reviewer(database, plan_id, reviewer_id, modified_by),
      error = function(error) error
    )
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data(after = function() {
      showNotification("Plan reviewer assignment saved.", type = "message", duration = 6)
    })
  }, ignoreInit = TRUE)

  observeEvent(input$plan_review_approve_request, {
    if (!current_user_can_review_plans()) {
      showNotification("You do not have permission to approve plan reviews.", type = "error", duration = 8)
      return()
    }
    request <- input$plan_review_approve_request
    plan_id <- suppressWarnings(as.integer(request$planId))
    if (is.na(plan_id)) return()
    data <- app_data()
    plan <- data$planning_agency_plan[data$planning_agency_plan$plan_id == plan_id, , drop = FALSE]
    if (!nrow(plan)) {
      showNotification("Plan not found.", type = "error", duration = 8)
      return()
    }
    selected_reviewer_id <- suppressWarnings(as.integer(input$plan_review_reviewer_id %||% NA_integer_))
    current_preview_user_id <- suppressWarnings(as.integer(current_role_preview_user_id() %||% input$role_preview_user_id %||% NA_integer_))
    reviewer_rows <- data$access_user_role[data$access_user_role$app_role %in% c("SystemAdmin", "OPIReviewer"), , drop = FALSE]
    actor_id <- if (!is.na(current_preview_user_id)) {
      current_preview_user_id
    } else if (nrow(reviewer_rows)) {
      reviewer_rows$user_id[[1]]
    } else {
      NA_integer_
    }
    reviewer_id <- if (!is.na(plan$assigned_reviewer[[1]])) {
      plan$assigned_reviewer[[1]]
    } else if (!is.na(selected_reviewer_id)) {
      selected_reviewer_id
    } else if (!is.na(current_preview_user_id) && current_preview_user_id %in% reviewer_rows$user_id) {
      current_preview_user_id
    } else if (nrow(reviewer_rows)) {
      reviewer_rows$user_id[[1]]
    } else {
      NA_integer_
    }
    next_status <- as.character(request$nextStatus %||% input$plan_review_next_status %||% "DeputyMayorReview")
    admin_route <- current_user_can_assign_plan_reviewer()
    route_choices <- if (isTRUE(admin_route)) admin_plan_review_route_choices(data, plan) else plan_review_route_choices(data, plan)
    if (!current_user_can_route_plan_reviews()) {
      next_status <- "DeputyMayorReview"
    }
    if (!next_status %in% unname(route_choices)) {
      showNotification("Choose a valid routing destination before approving.", type = "error", duration = 8)
      return()
    }
    result <- tryCatch(
      if (isTRUE(admin_route)) {
        route_plan_from_review_admin(database, plan_id, routed_by = actor_id, next_status = next_status)
      } else {
        approve_plan_review(database, plan_id, reviewer_id, next_status, routed_by = actor_id)
      },
      error = function(error) error
    )
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data(after = function() {
      current_history_plan_id(plan_id)
      current_history_include_review(TRUE)
      route_label <- names(route_choices)[match(next_status, unname(route_choices))] %||% "the next approval step"
      review_action_label <- if (isTRUE(admin_route)) {
        "Plan routed"
      } else if (identical(next_status, "Returned")) {
        "Plan returned"
      } else {
        "Reviewer approval saved"
      }
      showNotification(paste(review_action_label, "and routed to", route_label, "."), type = "message", duration = 8)
    })
  }, ignoreInit = TRUE)

  observeEvent(input$plan_gate_approve_request, {
    request <- input$plan_gate_approve_request
    plan_id <- suppressWarnings(as.integer(request$planId))
    if (is.na(plan_id)) return()
    data <- app_data()
    plan <- data$planning_agency_plan[data$planning_agency_plan$plan_id == plan_id, , drop = FALSE]
    current_preview_user_id <- suppressWarnings(as.integer(current_role_preview_user_id() %||% input$role_preview_user_id %||% NA_integer_))
    if (!can_approve_plan_gate_context(data, plan, current_user_app_roles(), current_preview_user_id)) {
      showNotification("You do not have permission to approve this plan step.", type = "error", duration = 8)
      return()
    }
    result <- tryCatch(
      approve_plan_gate(database, plan_id, current_preview_user_id),
      error = function(error) error
    )
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data(after = function() {
      current_history_plan_id(plan_id)
      current_history_include_review(TRUE)
      next_status <- plan_gate_next_status(plan$plan_status[[1]])
      showNotification(paste("Approval stamp added. Plan routed to", agency_plan_status(next_status), "."), type = "message", duration = 8)
    })
  }, ignoreInit = TRUE)

  observeEvent(input$plan_gate_return_request, {
    request <- input$plan_gate_return_request
    plan_id <- suppressWarnings(as.integer(request$planId))
    next_status <- as.character(request$nextStatus %||% "")
    return_note <- trimws(as.character(request$note %||% ""))
    if (is.na(plan_id)) return()
    if (!next_status %in% c("Returned", "UnderReview", "DeputyMayorReview")) {
      showNotification("Choose a valid return destination.", type = "error", duration = 8)
      return()
    }
    if (!nzchar(return_note)) {
      showNotification("Add a return reason before returning this plan.", type = "error", duration = 8)
      return()
    }
    data <- app_data()
    plan <- data$planning_agency_plan[data$planning_agency_plan$plan_id == plan_id, , drop = FALSE]
    current_preview_user_id <- suppressWarnings(as.integer(current_role_preview_user_id() %||% input$role_preview_user_id %||% NA_integer_))
    status <- if (nrow(plan)) as.character(plan$plan_status[[1]]) else ""
    can_return <- has_any_role(current_user_app_roles(), "SystemAdmin") ||
      (identical(status, "DeputyMayorReview") && can_manage_plan_stamp_context(data, plan, "DeputyMayor", current_user_app_roles(), current_preview_user_id) && !identical(next_status, "DeputyMayorReview")) ||
      (identical(status, "CAReview") && can_manage_plan_stamp_context(data, plan, "CAOffice", current_user_app_roles(), current_preview_user_id))
    if (!can_return) {
      showNotification("You do not have permission to return this plan from the current approval step.", type = "error", duration = 8)
      return()
    }
    result <- tryCatch(
      return_plan_from_approval_gate(database, plan_id, current_preview_user_id, next_status, return_note),
      error = function(error) error
    )
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data(after = function() {
      current_history_plan_id(plan_id)
      current_history_include_review(TRUE)
      showNotification(paste("Plan returned to", agency_plan_status(next_status), "."), type = "message", duration = 8)
    })
  }, ignoreInit = TRUE)

  observeEvent(input$publishing_route_request, {
    if (!can_finalize_plans(current_user_app_roles())) {
      showNotification("Only System Admins can route plans from the publishing queue.", type = "error", duration = 8)
      return()
    }
    request <- input$publishing_route_request
    plan_id <- suppressWarnings(as.integer(request$planId))
    next_status <- as.character(request$nextStatus %||% "")
    data <- app_data()
    plan <- data$planning_agency_plan[data$planning_agency_plan$plan_id == plan_id, , drop = FALSE]
    route_choices <- publishing_route_choices(data, plan)
    if (is.na(plan_id) || !next_status %in% unname(route_choices)) {
      showNotification("Choose a valid route for this plan.", type = "error", duration = 8)
      return()
    }
    current_preview_user_id <- suppressWarnings(as.integer(current_role_preview_user_id() %||% NA_integer_))
    result <- tryCatch(
      route_plan_from_publishing_queue(database, plan_id, current_preview_user_id, next_status),
      error = function(error) error
    )
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data(after = function() {
      route_label <- names(route_choices)[match(next_status, unname(route_choices))] %||% "the selected queue"
      showNotification(paste("Plan routed back to", route_label, "."), type = "message", duration = 8)
    })
  }, ignoreInit = TRUE)

  observeEvent(input$publish_plan_request, {
    if (!can_finalize_plans(current_user_app_roles())) {
      showNotification("Only System Admins can publish plans.", type = "error", duration = 8)
      return()
    }
    request <- input$publish_plan_request
    plan_id <- suppressWarnings(as.integer(request$planId))
    if (is.na(plan_id)) return()
    data <- ensure_app_data()
    plan <- data$planning_agency_plan[data$planning_agency_plan$plan_id == plan_id, , drop = FALSE]
    goals <- data$performance_agency_goal[data$performance_agency_goal$plan_id == plan_id, , drop = FALSE]
    services <- plan_service_rows(data, plan)
    selected_measure_ids <- plan_selected_measure_ids(data, plan, goals, services)
    missing_fiscal_data <- plan_measures_missing_required_fiscal_data(data, plan, goals, services)
    if (nrow(missing_fiscal_data)) {
      recent_actual_fy <- fiscal_measure_snapshot_years()$actual_fy
      next_target_fy <- current_fiscal_year() + 1L
      showNotification(
        paste0(
          "Cannot publish: missing ", fy_label(recent_actual_fy), " actual or ", fy_label(next_target_fy), " target for ",
          paste(head(missing_fiscal_data$title, 5), collapse = ", "),
          if (nrow(missing_fiscal_data) > 5) paste0(" and ", nrow(missing_fiscal_data) - 5, " more") else ""
        ),
        type = "error", duration = 10
      )
      return()
    }
    current_preview_user_id <- suppressWarnings(as.integer(current_role_preview_user_id() %||% NA_integer_))
    result <- tryCatch(
      publish_agency_plan(
        database, plan_id, current_preview_user_id,
        required_measure_ids = selected_measure_ids,
        actual_fy = fiscal_measure_snapshot_years()$actual_fy,
        next_target_fy = current_fiscal_year() + 1L
      ),
      error = function(error) error
    )
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data(after = function() {
      current_history_plan_id(plan_id)
      current_history_include_review(TRUE)
      showNotification("Plan published. Approved payload has been promoted to database records.", type = "message", duration = 8)
    })
  }, ignoreInit = TRUE)

  observeEvent(input$plan_approval_stamp_request, {
    request <- input$plan_approval_stamp_request
    plan_id <- suppressWarnings(as.integer(request$planId))
    stage <- as.character(request$stage %||% "")
    action <- as.character(request$action %||% "add")
    if (is.na(plan_id) || !stage %in% c("Reviewer", "OPIApproval", "DeputyMayor", "CAOffice")) {
      showNotification("Choose a valid approval stamp.", type = "error", duration = 8)
      return()
    }
    if (!action %in% c("add", "remove")) action <- "add"
    data <- app_data()
    plan <- data$planning_agency_plan[data$planning_agency_plan$plan_id == plan_id, , drop = FALSE]
    current_preview_user_id <- suppressWarnings(as.integer(current_role_preview_user_id() %||% NA_integer_))
    if (!can_manage_plan_stamp_context(data, plan, stage, current_user_app_roles(), current_preview_user_id)) {
      showNotification("You do not have permission to update this approval stamp.", type = "error", duration = 8)
      return()
    }
    result <- tryCatch(
      if (identical(action, "remove")) {
        remove_plan_approval_stamp(database, plan_id, stage, removed_by = current_preview_user_id, notes = paste(approval_stage_label(stage), "approval stamp removed."))
      } else {
        add_plan_approval_stamp(database, plan_id, stage, added_by = current_preview_user_id, approved_by = current_preview_user_id, notes = "Approval stamp added.")
      },
      error = function(error) error
    )
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data(after = function() {
      current_history_plan_id(plan_id)
      current_history_include_review(TRUE)
      showNotification(paste(approval_stage_label(stage), "approval stamp", if (identical(action, "remove")) "removed." else "added."), type = "message", duration = 6)
    })
  }, ignoreInit = TRUE)

  observeEvent(input$export_plan_request, {
    request <- input$export_plan_request
    plan_id <- suppressWarnings(as.integer(request$planId))
    export_type <- tolower(as.character(request$exportType))
    include_review <- isTRUE(request$includeReview)
    if (is.na(plan_id) || !export_type %in% c("pdf", "pptx")) return()
    current_export_draft(NULL)
    draft_section_key <- as.character(request$draftSectionKey %||% "")
    draft_payload_json <- as.character(request$draftPayloadJson %||% "")
    trigger_download <- function() {
      current_export_plan_id(plan_id)
      current_export_include_review(include_review)
      session$sendCustomMessage("trigger-plan-download", list(type = export_type))
    }
    if (
      nzchar(draft_section_key) &&
        nzchar(draft_payload_json) &&
        draft_section_key %in% c("overview", "goals", "services", "risks")
    ) {
      update_cached_section_draft(plan_id, draft_section_key, draft_payload_json)
      current_export_draft(list(plan_id = plan_id, section_key = draft_section_key))
      result <- tryCatch({
        data <- app_data()
        plan <- data$planning_agency_plan[data$planning_agency_plan$plan_id == plan_id, , drop = FALSE]
        if (nrow(plan) && plan_is_editable(plan) && current_user_can_edit_plan()) {
          saved <- overwrite_section_draft(database, plan_id, draft_section_key, draft_payload_json)
          update_cached_section_draft(plan_id, draft_section_key, draft_payload_json, saved[1, , drop = FALSE])
          TRUE
        } else {
          FALSE
        }
      }, error = function(error) error)
      if (inherits(result, "error")) {
        showNotification(paste("Export will use the last saved draft:", conditionMessage(result)), type = "warning", duration = 8)
        trigger_download()
        return()
      }
      if (isTRUE(result)) {
        # Unlike the other refresh_app_data() call sites, this one can't let
        # the download trigger race ahead of the reload -- the export needs
        # to reflect the just-saved draft. Waiting here only delays this
        # user's own download trigger; the reload itself still runs in the
        # background worker, so it doesn't block anyone else's session.
        refresh_app_data(after = trigger_download, on_error = trigger_download)
        return()
      }
    }
    trigger_download()
  }, ignoreInit = TRUE)

  observeEvent(input$submit_plan_request, {
    if (!current_user_can_submit_plan()) {
      showNotification("Only AgencySubmitter and SystemAdmin users can submit the plan.", type = "error", duration = 8)
      return()
    }
    request <- input$submit_plan_request
    plan_id <- suppressWarnings(as.integer(request$planId))
    if (is.na(plan_id)) return()
    result <- tryCatch(submit_agency_plan(database, plan_id), error = function(error) error)
    if (inherits(result, "error")) {
      showNotification(conditionMessage(result), type = "error", duration = 8)
      return()
    }
    refresh_app_data(after = function() {
      showNotification("Plan submitted. Builder fields are locked while the plan is in review.", type = "message", duration = 8)
    })
  }, ignoreInit = TRUE)

  output$download_measure_validation_csv <- downloadHandler(
    filename = function() paste0("measure-validation-", format(Sys.Date(), "%Y-%m-%d"), ".csv"),
    content = function(file) {
      utils::write.csv(measure_validation_export_rows(app_data()), file, row.names = FALSE, na = "")
    }
  )

  output$download_measure_data_csv <- downloadHandler(
    filename = function() paste0("measure-data-", format(Sys.Date(), "%Y-%m-%d"), ".csv"),
    content = function(file) {
      utils::write.csv(measure_data_export_rows(app_data()), file, row.names = FALSE, na = "")
    }
  )

  output$download_plan_pdf <- downloadHandler(
    filename = function() {
      data <- app_data()
      plan <- data$planning_agency_plan[data$planning_agency_plan$plan_id == current_export_plan_id(), , drop = FALSE]
      plan_export_filename(data, plan, "pdf", current_export_include_review())
    },
    content = function(file) {
      plan_id <- current_export_plan_id()
      if (is.null(plan_id)) stop("No plan selected for export")
      data <- app_data()
      # Reported 2026-08-05: a plan reviewed/returned more than once could
      # export with an earlier round's review text at the top. The
      # on-screen review page patches in review_snapshot_cache (see
      # output$page's data_with_cached_review_snapshot() call) because
      # review-score/note autosaves deliberately skip refresh_app_data()
      # (would collapse the open scoring UI mid-edit) -- export read
      # app_data() directly and missed that same patch.
      data <- data_with_cached_review_snapshot(data)
      export_draft <- current_export_draft()
      if (!is.null(export_draft) && identical(as.integer(export_draft$plan_id), as.integer(plan_id))) {
        data <- data_with_cached_section_draft(data, plan_id, export_draft$section_key)
      }
      build_plan_export_file(data, plan_id, file, "pdf", current_export_include_review())
      showNotification("PDF downloaded successfully.", type = "message")
    }
  )

  output$download_plan_pptx <- downloadHandler(
    filename = function() {
      data <- app_data()
      plan <- data$planning_agency_plan[data$planning_agency_plan$plan_id == current_export_plan_id(), , drop = FALSE]
      plan_export_filename(data, plan, "pptx", current_export_include_review())
    },
    content = function(file) {
      plan_id <- current_export_plan_id()
      if (is.null(plan_id)) stop("No plan selected for export")
      data <- app_data()
      data <- data_with_cached_review_snapshot(data)
      export_draft <- current_export_draft()
      if (!is.null(export_draft) && identical(as.integer(export_draft$plan_id), as.integer(plan_id))) {
        data <- data_with_cached_section_draft(data, plan_id, export_draft$section_key)
      }
      build_plan_export_file(data, plan_id, file, "pptx", current_export_include_review())
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
    send_draft_error <- function(message, conflict = FALSE, extra = list()) {
      session$sendCustomMessage("shared-draft-result", list(
        ok = FALSE,
        conflict = conflict,
        planId = plan_id,
        sectionKey = section_key,
        message = message
      ) |> modifyList(extra))
    }
    if (is.na(plan_id) || is.na(revision) || !grepl("^[a-z][a-z0-9_-]{0,59}$", section_key)) {
      send_draft_error("The draft save request was incomplete. Your browser recovery copy is still available.")
      return()
    }
    tryCatch({
      if (!current_user_can_edit_plan()) {
        send_draft_error("You do not have permission to edit this plan.")
        return()
      }
      limit_error <- validate_measure_selection_limit(payload_json, section_key, 5L)
      if (!is.null(limit_error)) {
        send_draft_error(limit_error)
        return()
      }
      data <- app_data()
      plan <- data$planning_agency_plan[data$planning_agency_plan$plan_id == plan_id, , drop = FALSE]
      if (!nrow(plan) || !plan_is_editable(plan)) {
        send_draft_error("This plan is locked and cannot be edited.")
        return()
      }

      result <- save_section_draft(database, plan_id, section_key, payload_json, revision)
      if (isTRUE(result$ok)) {
        # Update the non-reactive draft cache only -- output$page already reads
        # fresh draft content via data_with_cached_section_draft() on every
        # render. Writing to app_data() here would force a full-page
        # re-render on every autosave tick (matching the goals_draft_quiet_save
        # / service_metrics_draft_save pattern, which never write to app_data()).
        update_cached_section_draft(plan_id, section_key, payload_json, result$row)
        session$sendCustomMessage("shared-draft-result", list(
          ok = TRUE,
          planId = plan_id,
          sectionKey = section_key,
          revision = result$row$revision[[1]],
          updatedAt = format(result$row$updated_at[[1]], "%Y-%m-%dT%H:%M:%S")
        ))
      } else if (!is.null(result$conflict)) {
        send_draft_error(
          "A newer shared draft was saved by someone else. Your browser recovery copy is still available; reload before saving again.",
          conflict = TRUE,
          extra = list(
            revision = result$conflict$revision[[1]],
            updatedAt = format(result$conflict$updated_at[[1]], "%Y-%m-%dT%H:%M:%S")
          )
        )
      } else {
        send_draft_error("The shared draft could not be saved. Your browser recovery copy is still available.")
      }
    }, error = function(error) {
      send_draft_error(conditionMessage(error))
    })
  }, ignoreInit = TRUE)

  # NOTE: service_description_draft_save / service_metrics_draft_save
  # observers were removed 2026-07-24 -- confirmed dead (app.js's
  # flushServiceDescriptionAutosave()/flushServiceMetricsAutosave() are
  # defined but never called; the live Services autosave path is
  # services_draft_quiet_save below, via scheduleServicesQuietAutosave()).

  observeEvent(input$goals_draft_quiet_save, {
    request <- input$goals_draft_quiet_save
    plan_id <- suppressWarnings(as.integer(request$planId))
    section_key <- as.character(request$sectionKey %||% "goals")
    payload_json <- as.character(request$payloadJson %||% "")
    if (is.na(plan_id) || !identical(section_key, "goals") || !nzchar(payload_json)) {
      session$sendCustomMessage("goals-draft-result", list(ok = FALSE, planId = plan_id, sectionKey = "goals", message = "The goals save request was incomplete."))
      return()
    }
    tryCatch({
      if (!current_user_can_edit_plan()) {
        session$sendCustomMessage("goals-draft-result", list(ok = FALSE, planId = plan_id, sectionKey = "goals", message = "You do not have permission to edit this plan."))
        return()
      }
      data <- app_data()
      plan <- data$planning_agency_plan[data$planning_agency_plan$plan_id == plan_id, , drop = FALSE]
      if (!nrow(plan) || !plan_is_editable(plan)) {
        session$sendCustomMessage("goals-draft-result", list(ok = FALSE, planId = plan_id, sectionKey = "goals", message = "This plan is locked and cannot be edited."))
        return()
      }
      payload <- tryCatch(jsonlite::fromJSON(payload_json, simplifyVector = FALSE), error = function(error) NULL)
      if (is.null(payload) || !is.list(payload)) {
        session$sendCustomMessage("goals-draft-result", list(ok = FALSE, planId = plan_id, sectionKey = "goals", message = "The goals draft could not be read."))
        return()
      }
      saved <- save_goals_draft_merged(database, plan_id, payload_json)
      row <- saved[1, , drop = FALSE]
      merged_payload_json <- get_section_draft(database, plan_id, "goals")$payload[[1]]
      update_cached_section_draft(plan_id, "goals", merged_payload_json, row)
      session$sendCustomMessage("goals-draft-result", list(
        ok = TRUE,
        planId = plan_id,
        sectionKey = "goals",
        revision = row$revision[[1]],
        updatedAt = format(row$updated_at[[1]], "%Y-%m-%dT%H:%M:%S")
      ))
    }, error = function(error) {
      session$sendCustomMessage("goals-draft-result", list(ok = FALSE, planId = plan_id, sectionKey = "goals", message = conditionMessage(error)))
    })
  }, ignoreInit = TRUE)

  observeEvent(input$services_draft_quiet_save, {
    request <- input$services_draft_quiet_save
    plan_id <- suppressWarnings(as.integer(request$planId))
    section_key <- as.character(request$sectionKey %||% "services")
    payload_json <- as.character(request$payloadJson %||% "")
    if (is.na(plan_id) || !identical(section_key, "services") || !nzchar(payload_json)) {
      session$sendCustomMessage("services-draft-result", list(ok = FALSE, planId = plan_id, sectionKey = "services", message = "The services save request was incomplete."))
      return()
    }
    tryCatch({
      if (!current_user_can_edit_plan()) {
        session$sendCustomMessage("services-draft-result", list(ok = FALSE, planId = plan_id, sectionKey = "services", message = "You do not have permission to edit this plan."))
        return()
      }
      data <- app_data()
      plan <- data$planning_agency_plan[data$planning_agency_plan$plan_id == plan_id, , drop = FALSE]
      if (!nrow(plan) || !plan_is_editable(plan)) {
        session$sendCustomMessage("services-draft-result", list(ok = FALSE, planId = plan_id, sectionKey = "services", message = "This plan is locked and cannot be edited."))
        return()
      }
      payload <- tryCatch(jsonlite::fromJSON(payload_json, simplifyVector = FALSE), error = function(error) NULL)
      if (is.null(payload) || !is.list(payload)) {
        session$sendCustomMessage("services-draft-result", list(ok = FALSE, planId = plan_id, sectionKey = "services", message = "The services draft could not be read."))
        return()
      }
      if (!is.null(payload$values) && is.list(payload$values)) {
        payload$values <- payload$values[!grepl("^service_metric_", names(payload$values))]
        payload_json <- jsonlite::toJSON(payload, auto_unbox = TRUE, null = "null")
      }
      saved <- save_services_draft_quiet_merged(database, plan_id, payload_json)
      row <- saved[1, , drop = FALSE]
      merged_payload_json <- get_section_draft(database, plan_id, "services")$payload[[1]]
      update_cached_section_draft(plan_id, "services", merged_payload_json, row)
      session$sendCustomMessage("services-draft-result", list(
        ok = TRUE,
        planId = plan_id,
        sectionKey = "services",
        revision = row$revision[[1]],
        updatedAt = format(row$updated_at[[1]], "%Y-%m-%dT%H:%M:%S")
      ))
    }, error = function(error) {
      session$sendCustomMessage("services-draft-result", list(ok = FALSE, planId = plan_id, sectionKey = "services", message = conditionMessage(error)))
    })
  }, ignoreInit = TRUE)

  observeEvent(input$current_page, {
    if (is.null(current_user()) && !identical(input$current_page, "login")) {
      current_page("login")
      session$sendCustomMessage("set-page", "login")
      return()
    }
    if (identical(current_page(), "plan_review_detail") && !identical(input$current_page, "plan_review_detail")) {
      current_history_plan_id(NULL)
      current_history_include_review(TRUE)
    }
    # Leaving the CLS request page: drop the request if it was never filled in,
    # then pick up autosaved changes for the list view.
    if (identical(current_page(), "cls_request_detail") && !identical(input$current_page, "cls_request_detail")) {
      cls_discard_draft(current_cls_id())
      refresh_app_data(domains = "cls")
    }
    current_page(input$current_page)
  }, ignoreInit = TRUE)

  # A ?reset=<token> link lands on the choose-a-new-password view.
  observeEvent(session$clientData$url_search, {
    query <- parseQueryString(session$clientData$url_search)
    if (is.null(query$reset) || !is.null(current_user())) return()
    if (is.null(auth_lookup_reset_token(database, query$reset))) {
      auth_state(list(view = "login", notice = "That password link is invalid or has expired. Request a new one."))
    } else {
      auth_state(list(view = "reset", token = query$reset))
    }
  })

  observeEvent(input$goto_first_time, auth_state(list(view = "request", first_time = TRUE)))
  observeEvent(input$goto_forgot, auth_state(list(view = "request", first_time = FALSE)))
  observeEvent(input$goto_login, auth_state(list(view = "login")))

  observeEvent(input$request_submit, {
    state <- auth_state()
    email <- trimws(input$request_email %||% "")
    dev_link <- NULL
    delivery_failed <- FALSE
    unknown_email <- FALSE
    if (nzchar(email)) {
      user <- auth_find_user(database, email)
      if (!is.null(user)) {
        token <- auth_issue_reset_token(database, user$user_id[[1]])
        link <- auth_reset_link(session, token)
        if (auth_dev_links_enabled()) {
          # Dev mode shows the link and never emails - local demos must not
          # send real mail to seeded (real) employee addresses.
          dev_link <- link
        } else {
          delivery_failed <- !auth_send_reset_email(user$email[[1]], link, isTRUE(state$first_time))
        }
      } else {
        unknown_email <- TRUE
      }
    }
    if (unknown_email) {
      auth_state(list(
        view = "access_request",
        email = email,
        context = if (isTRUE(state$first_time)) "first-time password setup" else "password reset",
        first_time = isTRUE(state$first_time),
        notice = "That email is not connected to an active Beacon account. Add the requested entity and role/title below."
      ))
      return()
    }
    if (delivery_failed) {
      auth_state(list(
        view = "request",
        first_time = isTRUE(state$first_time),
        notice = "The account exists, but Beacon could not send the email. Ask a system admin to verify SendGrid settings."
      ))
      showNotification("Email could not be sent. Check SendGrid settings.", type = "error", duration = 10)
      return()
    }
    auth_state(list(view = "sent", first_time = isTRUE(state$first_time), dev_link = dev_link))
  })

  observeEvent(input$access_request_submit, {
    state <- auth_state()
    email <- trimws(input$access_request_email %||% state$email %||% "")
    if (!nzchar(email) || !grepl("@", email, fixed = TRUE)) {
      auth_state(modifyList(state, list(notice = "Enter a valid email address to request access.")))
      return()
    }
    requested_entity <- trimws(input$access_request_entity %||% "")
    requested_agency_role <- trimws(input$access_request_agency_role %||% "")
    context <- trimws(state$context %||% "sign in")
    alert <- notify_unknown_login_email(email, context, requested_entity, requested_agency_role)
    auth_state(list(
      view = "access_request",
      email = email,
      context = context,
      requested_entity = requested_entity,
      requested_agency_role = requested_agency_role,
      notice = alert$notice,
      notice_tone = if (isTRUE(alert$sent)) "success" else "error"
    ))
  }, ignoreInit = TRUE)

  observeEvent(input$reset_submit, {
    state <- auth_state()
    problem <- auth_password_problem(input$reset_password, input$reset_confirm)
    if (!is.null(problem)) {
      auth_state(modifyList(state, list(notice = problem)))
      return()
    }
    if (auth_complete_reset(database, state$token, input$reset_password)) {
      auth_state(list(view = "reset_done"))
    } else {
      auth_state(list(view = "login", notice = "That password link is invalid or has expired. Request a new one."))
    }
  })

  observeEvent(input$auth_restore_session, {
    if (!is.null(current_user())) return()
    token <- as.character(input$auth_restore_session$token %||% "")
    if (!nzchar(token)) return()
    restored_user <- auth_lookup_login_session(database, token)
    if (is.null(restored_user)) {
      session$sendCustomMessage("auth-session-expired", list())
      return()
    }
    complete_sign_in(restored_user, issue_session = FALSE)
  }, ignoreInit = FALSE)

  observeEvent(input$auth_session_activity, {
    if (is.null(current_user())) return()
    token <- as.character(input$auth_session_activity$token %||% "")
    if (!nzchar(token)) return()
    if (!auth_touch_login_session(database, token)) {
      current_user(NULL)
      current_page("login")
      auth_state(list(view = "login", notice = "You were signed out after 60 minutes of inactivity."))
      session$sendCustomMessage("auth-session-expired", list())
      session$sendCustomMessage("set-auth-state", list(signedIn = FALSE))
      session$sendCustomMessage("set-page", "login")
    }
  }, ignoreInit = TRUE)

  observeEvent(input$auth_sign_out, {
    token <- as.character(input$auth_sign_out$token %||% "")
    reason <- as.character(input$auth_sign_out$reason %||% "manual")
    if (nzchar(token)) {
      tryCatch(auth_revoke_login_session(database, token), error = function(error) NULL)
    }
    current_user(NULL)
    current_page("login")
    notice <- if (identical(reason, "idle")) "You were signed out after 60 minutes of inactivity." else "You have been signed out."
    auth_state(list(view = "login", notice = notice))
    current_history_plan_id(NULL)
    current_history_include_review(TRUE)
    session$sendCustomMessage("auth-session-expired", list())
    session$sendCustomMessage("set-auth-state", list(signedIn = FALSE))
    session$sendCustomMessage("set-page", "login")
  }, ignoreInit = TRUE)

  observeEvent(input$login_submit_request, {
    request <- input$login_submit_request
    handle_login_attempt(request$email, request$password)
  }, ignoreInit = TRUE)

  observeEvent(input$login_email_continue, {
    handle_login_attempt(input$login_email, input$login_password)
  }, ignoreInit = TRUE)

  observeEvent(input$open_pillar_request, {
    pillar_id <- as.character(input$open_pillar_request$pillarId %||% "")
    if (nzchar(pillar_id)) current_pillar_modal(pillar_id)
  }, ignoreInit = TRUE)

  observeEvent(input$close_pillar_modal, {
    current_pillar_modal(NULL)
  }, ignoreInit = TRUE)

  # Keep the filter reactiveVals (declared above, see the comment there) in
  # sync with the actual widgets whenever the signed-in user changes them.
  # ignoreNULL = FALSE is required: clearing a multi-select filter down to
  # zero selections reports input$... as NULL, and the default
  # ignoreNULL = TRUE would silently skip that update, leaving the
  # reactiveVal (and therefore server-side filtering) stuck on the
  # previous, non-empty selection even within the same user's session.
  observeEvent(input$feedback_search, feedback_search_value(input$feedback_search %||% ""), ignoreInit = TRUE, ignoreNULL = FALSE)
  observeEvent(input$feedback_category_filter, feedback_category_filter_value(input$feedback_category_filter %||% character(0)), ignoreInit = TRUE, ignoreNULL = FALSE)
  observeEvent(input$feedback_priority_filter, feedback_priority_filter_value(input$feedback_priority_filter %||% character(0)), ignoreInit = TRUE, ignoreNULL = FALSE)
  observeEvent(input$feedback_status_filter, feedback_status_filter_value(input$feedback_status_filter %||% character(0)), ignoreInit = TRUE, ignoreNULL = FALSE)
  observeEvent(input$measure_status_filter, measure_status_filter_value(input$measure_status_filter %||% "All except deprecated"), ignoreInit = TRUE, ignoreNULL = FALSE)

  # Rendered separately from output$page on purpose. page_bug_fix()'s filter
  # selectInputs used to be recreated from scratch every time any of these
  # reactiveVals changed, since output$page's one giant renderUI depended on
  # them too. A freshly (re)initialized selectize widget echoes its own
  # "selected" back to the server as if the person had just changed it --
  # normally a harmless no-op, since reactiveVal ignores an identical value.
  # But recreating the widget while a removal is still in flight could echo
  # back the *previous* (pre-removal) selection, flipping the reactiveVal
  # back, re-rendering again, echoing the *new* one, flipping back again --
  # reported 2026-08-04 as the Bug/Fix status filter getting "caught in a
  # loop" when removing a single status (confirmed via server-side logging:
  # the value oscillated between the pre- and post-removal selection).
  # Keeping the filter controls out of output$page's dependency graph (see
  # isolate() around feedback_filters below) means changing a filter no
  # longer touches their DOM at all -- only this list output re-renders.
  output$feedback_admin_list <- renderUI({
    req(identical(current_page(), "bug_fix"))
    feedback_list_ui(
      ensure_app_data(),
      feedback_search_value(),
      feedback_category_filter_value(),
      feedback_priority_filter_value(),
      feedback_status_filter_value()
    )
  })

  output$page <- renderUI({
    if (is.null(current_user()) || identical(current_page(), "login")) {
      state <- auth_state()
      login_data <- if (identical(state$view %||% "login", "access_request")) ensure_app_data() else NULL
      return(page_login(state, login_data))
    }
    page_data <- ensure_app_data()
    if (current_page() %in% c("overview", "goals", "services")) {
      plan <- current_plan(page_data, current_submitter_value())
      if (!is.null(plan) && nrow(plan)) {
        page_data <- data_with_cached_section_draft(page_data, plan$plan_id[[1]], current_page())
      }
    }
    page_data <- data_with_cached_review_snapshot(page_data)
    # Only queried when actually viewing Bug/Fix -- switch() in page_ui()
    # means this branch, and this query, is skipped for every other page.
    active_sessions <- NA_integer_
    active_users <- NA_integer_
    if (identical(current_page(), "bug_fix") && current_user_can_view_application_admin()) {
      session_counts <- auth_active_session_count(database)
      active_sessions <- session_counts$sessions
      active_users <- session_counts$users
    }
    page_ui(
      current_page(),
      page_data,
      current_submitter_value(),
      measure_status_filter_value(),
      current_user_can_manage_team(),
      current_user_can_submit_plan(),
      current_user_app_roles(),
      current_user_agency_roles(),
      current_role_preview_user_id() %||% input$role_preview_user_id %||% "",
      current_history_plan_id() %||% NA_integer_,
      current_history_include_review(),
      # isolate()'d so this only supplies the filter controls' initial
      # `selected =`/`value =` whenever output$page redraws for some OTHER
      # reason (e.g. navigating to the page). Reading these reactively here
      # would recreate the controls on every filter change -- see the
      # comment on output$feedback_admin_list above for why that's the bug.
      # The controls stay live via observeEvent(input$feedback_status_filter,
      # ...) above and feed the actual filtering through that separate
      # output instead.
      feedback_filters = isolate(list(
        search = feedback_search_value(),
        category = feedback_category_filter_value(),
        priority = feedback_priority_filter_value(),
        status = feedback_status_filter_value()
      )),
      selected_cls_id = current_cls_id(),
      cls_detail_origin = cls_detail_origin(),
      editing_line_id = cls_editing_line(),
      editing_position_id = cls_editing_position(),
      # Filters apply only when Apply is pressed (NULL = show everything).
      cls_review_filters = list(
        status = cls_applied_status() %||% character(0),
        agency = cls_applied_agency() %||% character(0),
        service = cls_applied_service() %||% character(0),
        bulk = cls_bulk_mode()
      ),
      active_sessions = active_sessions,
      active_users = active_users
    )
  })

  output$pillar_modal <- renderUI({
    pillar_id <- current_pillar_modal()
    if (is.null(pillar_id)) {
      return(NULL)
    }
    pillar_modal(pillar_id, ensure_app_data())
  })

  output$measure_modal <- renderUI({
    measure_id <- current_measure_id()
    if (is.null(measure_id)) return(NULL)
    data <- ensure_app_data()
    plan <- current_plan(data, current_submitter_value())
    target_fy <- if (is.null(plan) || !nrow(plan)) 2028 else as.integer(plan$fiscal_year[[1]]) + 1L
    measure_modal_ui(
      data,
      current_agency_id(),
      if (identical(measure_id, "new")) NULL else as.integer(measure_id),
      current_user_can_manage_measure_admin_fields(),
      target_fy,
      (current_user_can_submit_measure() || current_user_can_review_measures()) &&
        (identical(measure_id, "new") || current_user_can_edit_measure(data, measure_id, plan)),
      can_delete_measures(current_user_app_roles()),
      current_user_can_edit_locked_measure_data(),
      identical(measure_id, "new") && isTRUE(pending_new_measure_default_city()),
      identical(measure_id, "new") && isTRUE(pending_new_measure_default_city())
    )
  })

  output$history_plan_modal <- renderUI({
    if (identical(current_page(), "plan_review_detail")) return(NULL)
    if (!identical(current_page(), "plan_history")) return(NULL)
    plan_id <- current_history_plan_id()
    if (is.null(plan_id)) return(NULL)
    data <- ensure_app_data()
    plan <- data$planning_agency_plan[data$planning_agency_plan$plan_id == as.integer(plan_id), , drop = FALSE]
    history_plan_modal(
      data,
      as.integer(plan_id),
      can_review_plans(current_user_app_roles()),
      current_user_can_assign_plan_reviewer(),
      current_history_include_review(),
      can_route_review = current_user_can_route_plan_reviews(),
      can_approve_gate = can_approve_plan_gate_context(data, plan, current_user_app_roles(), current_role_preview_user_id() %||% input$role_preview_user_id %||% NA_integer_),
      can_manage_deputy_stamp = can_manage_plan_stamp_context(data, plan, "DeputyMayor", current_user_app_roles(), current_role_preview_user_id() %||% input$role_preview_user_id %||% NA_integer_),
      can_manage_ca_stamp = can_manage_plan_stamp_context(data, plan, "CAOffice", current_user_app_roles(), current_role_preview_user_id() %||% input$role_preview_user_id %||% NA_integer_)
    )
  })

  output$risk_modal <- renderUI({
    risk_id <- current_risk_id()
    if (is.null(risk_id)) return(NULL)
    # Passed through as character, not coerced to integer -- a "new-<epoch>"
    # temp id (reopening an unsaved add) must reach risk_modal_ui() intact
    # so it can prefill from the draft overlay instead of showing blank.
    risk_modal_ui(ensure_app_data(), current_submitter_value(), if (identical(risk_id, "new")) NULL else risk_id)
  })
  output$team_role_modal <- renderUI({
    access_id <- current_team_access_id()
    if (is.null(access_id)) return(NULL)
    team_role_modal_ui(
      ensure_app_data(),
      current_submitter_value(),
      access_id,
      current_user_can_manage_team(),
      grantable_performance_roles(current_user_app_roles(), current_user_agency_roles())
    )
  })
  output$feedback_modal <- renderUI({
    if (!isTRUE(feedback_modal_open())) return(NULL)
    feedback_modal_ui(current_user_email(), pages[[current_page()]] %||% current_page())
  })
}

shinyApp(ui, server)
