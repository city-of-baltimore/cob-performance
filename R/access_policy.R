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

access_policy <- list(
  role_edit_app_roles = c("SystemAdmin", "OPIReviewer", "BBMRReviewer", "CAOffice", "DeputyMayor", "AgencySubmitter"),
  role_edit_agency_roles = c("Agency Head", "Agency Director", "Chief of Staff"),
  plan_edit_app_roles = c("AgencySubmitter", "AgencyWriter", "AgencyApprover", "SystemAdmin", "OPIReviewer"),
  submitter_assignment_app_roles = c("SystemAdmin", "CAOffice", "DeputyMayor"),
  submitter_assignment_agency_roles = c("Agency Head", "Agency Director", "Chief of Staff", "Admin"),
  measure_review_app_roles = c("SystemAdmin", "OPIReviewer"),
  measure_submit_app_roles = c("AgencySubmitter", "AgencyWriter", "AgencyApprover", "SystemAdmin", "OPIReviewer"),
  measure_submit_agency_roles = c("Performance Lead", "Chief of Staff", "Agency Director", "Agency Head", "Admin"),
  plan_review_app_roles = c("SystemAdmin", "OPIReviewer", "BBMRReviewer", "CAOffice", "DeputyMayor"),
  final_plan_approval_app_roles = c("SystemAdmin")
)

has_any_role <- function(values, allowed) {
  any(values %in% allowed)
}

can_edit_roles <- function(app_roles, agency_roles) {
  has_any_role(app_roles, access_policy$role_edit_app_roles) ||
    has_any_role(agency_roles, access_policy$role_edit_agency_roles)
}

can_assign_submitter <- function(app_roles, agency_roles) {
  has_any_role(app_roles, access_policy$submitter_assignment_app_roles) ||
    has_any_role(agency_roles, access_policy$submitter_assignment_agency_roles)
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

can_view_performance_reviewing <- function(app_roles) {
  has_any_role(app_roles, c("SystemAdmin", "OPIReviewer", "BBMRReviewer", "CAOffice", "DeputyMayor"))
}

uses_review_administration_mode <- function(app_roles) {
  has_any_role(app_roles, c("CAOffice", "DeputyMayor"))
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
  if (has_any_role(app_roles, "SystemAdmin")) return(TRUE)
  stage <- as.character(stage)
  if (identical(stage, "Reviewer")) return(has_any_role(app_roles, c("OPIReviewer", "BBMRReviewer")))
  if (identical(stage, "DeputyMayor")) {
    return((has_any_role(app_roles, "DeputyMayor") || has_any_role(app_roles, "CAOffice")) && user_name_matches_text(db, user_id, plan_deputy_mayor_label(db, plan)))
  }
  if (identical(stage, "CAOffice")) return(has_any_role(app_roles, "CAOffice") && user_name_matches_text(db, user_id, plan_ca_office_label(db, plan)))
  FALSE
}
