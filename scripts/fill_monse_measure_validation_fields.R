# Fills in blank validation fields on the 15 canonical FY2027 MONSE measures
# using the matching rows from Melanie's Metric Validation Spreadsheet
# (2026-07-24), matched by service context + semantic content to the budget
# book measures confirmed earlier the same day. Per Melanie's direction:
#   - Only fill fields that are genuinely blank; never overwrite a field
#     that's already populated with real content (several of these measures
#     already have detailed, specific validation text that's clearly not
#     from this spreadsheet and shouldn't be replaced with less-specific
#     text).
#   - Exception: `description` gets replaced even though non-blank, because
#     ten of these measures currently just have the *service-level* blurb
#     copy-pasted in (wrong/generic), not a measure-specific description.
#   - Exception: measures 725 and 726 had each other's formula swapped
#     (confirmed a real bug, not a blank) -- fixed here per Melanie's
#     explicit approval.
#   - Measure 729 ("# of interventions conducted across School-Based
#     Violence Intervention Program Sites") wasn't in the original 60-row
#     dump with a confident match; Melanie separately tracked down the
#     correct row (marked "No Match" in the sheet's own Goal column, but an
#     exact title match) and confirmed fixing its formula too, which was
#     also wrong (described a different measure entirely, not blank).
#   - Fiscal-year actuals/targets are NOT touched at all here -- those came
#     from the budget book screenshots directly (see
#     scripts/populate_monse_canonical_measure_data.R) and are out of scope
#     for this script entirely.
#   - `disaggregation` is skipped for every measure: the spreadsheet only
#     answers a Yes/No question ("can it be broken down by groups?"), but
#     the app's field expects actual breakdown category names, so writing
#     "Yes" there would look wrong rather than helpful.

source("R/database.R", local = TRUE)

connection <- connect_app_database()
on.exit(DBI::dbDisconnect(connection), add = TRUE)

# One entry per matched measure. Only fields present here are ever written,
# and only into a currently-blank column (fill_field()) or, for
# descriptions, only when the column still holds the exact generic
# placeholder text for that measure's service.
entries <- list(
  `680` = list(
    context_required = "Only resolved mediations are included",
    replicability = TRUE
  ),
  `684` = list(replicability = TRUE),
  `690` = list(replicability = TRUE),
  `691` = list(replicability = TRUE),
  `720` = list(
    description = "The average number of days between a qualifying incident and its associated response",
    context_required = "N/A",
    data_location = "Microsoft Dataverse Table",
    collection_method = "Data entered by Stabilization Manager on an ongoing basis into Microsoft case management system",
    replicability = TRUE,
    how_data_used = "Efficiency and effectiveness of neighborhood stabilization program",
    why_meaningful = "Shows efficiency of stabilization lane"
  ),
  `721` = list(
    description = "The percentage of contacts who are receiving services within a month of being engaged by MONSE's street outreach team",
    context_required = "N/A",
    data_location = "Microsoft Dataverse Table",
    collection_method = "Data entered by Stabilization Manager on an ongoing basis into Microsoft case management system",
    replicability = TRUE,
    how_data_used = "Efficiency and effectiveness of neighborhood stabilization program",
    why_meaningful = "Shows efficiency of stabilization lane in serving the needs of the population"
  ),
  `722` = list(
    description = "The average number of days between the date of referral and the time of intake for re-entry participants",
    context_required = "N/A",
    data_location = "Microsoft Dataverse Table",
    collection_method = "Data entered by Re-Entry coordinator on an ongoing basis into Microsoft case management system",
    replicability = TRUE,
    how_data_used = "Efficiency of re-entry program",
    why_meaningful = "Shows how efficient we are in servicing citizens re entering society"
  ),
  `723` = list(
    description = "The number of safe return plans developed for participants in the re-entry lane.",
    context_required = "N/A",
    data_location = "Microsoft Dataverse Table",
    collection_method = "Data entered by Re-Entry coordinator on an ongoing basis into Microsoft case management system",
    replicability = TRUE,
    how_data_used = "Impact of re-entry lane on participant re-entry readiness",
    why_meaningful = "Shows how effective we are in servicing citizens returning to society."
  ),
  `724` = list(
    description = "The average number of supervised visitations conducted per week",
    context_required = "N/A",
    data_location = "Apricot Social Solutions case management system tables",
    collection_method = "Apricot entries made by Visitation Center staff at MONSE on an ongoing basis",
    replicability = TRUE,
    how_data_used = "Productivity of Visitation Center staff",
    why_meaningful = "Shows general productivity of Visitation Center"
  ),
  `725` = list(
    description = "The number of people who attended human trafficking related trainings conducted by MONSE staff or partners.",
    context_required = "N/A",
    data_location = "Apricot Social Solutions case management system tables",
    collection_method = "Apricot entries made by Victim Services Human Trafficking Staff on a daily basis",
    replicability = TRUE,
    how_data_used = "Productivity of Human Trafficking program",
    why_meaningful = "Shows general productivity of trainings for Human Trafficking",
    formula_fix = "Sum of people attending human trafficking trainings"
  ),
  `726` = list(
    description = "The percent of people who self-reported feelings of safety compared to all survey participants within the Baltimore City Visitation Center",
    context_required = "N/A",
    data_location = "Apricot Social Solutions case management system tables",
    collection_method = "Apricot entries made by Visitation Center staff at MONSE on an ongoing basis",
    replicability = TRUE,
    how_data_used = "Impact of Visitation Center program",
    why_meaningful = "Shows how effective the Visitation Center is at serving its population",
    improvement_notes = "Finding a better way of collecting public perception through surveying - including connected individuals to pre-post responses",
    formula_fix = "Surveys with feelings of safety divided by all surveys"
  ),
  `727` = list(
    description = "The total number of direct communications conducted through GVRS.",
    context_required = "N/A",
    data_location = "Apricot Social Solutions case management system tables",
    collection_method = "Apricot entries made by GVRS Staff on a daily basis",
    replicability = TRUE,
    how_data_used = "GVRS productivity",
    why_meaningful = "It shows general productivity of GVRS program and lane"
  ),
  `728` = list(
    description = "The number of days between the date of the direct communication and enrollment with a service provider.",
    context_required = "Only for Full Custom Notifications (excludes law enforcement notifications)",
    data_location = "Apricot Social Solutions case management system tables",
    collection_method = "Apricot entries made by GVRS Staff on a daily basis",
    replicability = TRUE,
    how_data_used = "Enhanced performance of GVRS model",
    why_meaningful = "It shows general efficeincy of GVRS program and lane"
  ),
  `729` = list(
    # Melanie found this row after the initial spreadsheet pull didn't
    # surface a confident match ("No Match" in the sheet's own Goal column,
    # but the measure title is an exact match). formula_fix because the
    # existing formula ("Average of the days between incidents at SBVIP
    # partnering schools") describes a completely different measure, not a
    # blank -- same kind of mismatch as the 725/726 swap.
    description = "The number of School-Based mediations conducted and logged into Apricot 360 during the school year",
    context_required = "N/A",
    data_location = "Apricot Social Solutions case management system tables",
    collection_method = "Apricot entries made by School-Based Violence Intervention Program staff on a daily basis",
    replicability = TRUE,
    how_data_used = "Impact of School-Based Violence Intervention Program",
    why_meaningful = "Allows us to see trend in interventions",
    formula_fix = "Count of rows included in a fiscal year from report https://apricot.socialsolutions.com/report/run/report_id/70 mediation section"
  ),
  `730` = list(
    description = "The percentage change in incidents that take place within School-Based Violence Intervention Program partnered schools year over year",
    context_required = "N/A",
    data_location = "Apricot Social Solutions case management system tables",
    collection_method = "Apricot entries made by School-Based Violence Intervention Program staff on a daily basis",
    replicability = TRUE,
    how_data_used = "Impact of School-Based Violence Intervention Program",
    why_meaningful = "Shows impact of School-Based Violence Intervention Program when looked at over time",
    proxy_measure = "Can show intermediary results (YTD)"
  )
)

# Generic service-level blurbs currently sitting in `description` for
# several of these measures (a copy-paste artifact, not measure-specific) --
# only replace description when it still matches one of these exactly.
generic_descriptions <- c(
  "This service contains MONSE's community engagement and youth programming and the staff that support it. The goal of this service is to facilitate meaningful engagement with residents to co-produce public safety, rebuild government trust, and address community concerns through collaborative strategies. Activities performed by this service include youth diversion, Coordinated Neighborhood Stabilization Responses (CNSR), Peace Mobile operations, and Summer Youth Engagement.",
  "This service contains MONSE’s Re-Entry programming and support staff. The goal of this service is to provide meaningful supports and programming for returning citizens. Activities performed by this service include safe return planning, re-entry services, and the Re-Entry Action Council.",
  "This service contains MONSE's Victim Services Programming and support staff. MONSE’s Victim Services team fills gaps and supports survivors of gun violence, intimate partner violence (IPV), and other trauma. This includes primary, secondary, and tertiary victims. Activities performed by this service include the management of the Baltimore City Visitation Center, intensive case management, other direct victim supports, anti-human trafficking work, and IPV prevention.",
  "This service contains MONSE’s violence prevention programming and the staff that support it. The Community Violence Intervention (CVI) ecosystem together with focused deterrence through the Group Violence Reduction Strategy (GVRS) constitute Baltimore’s dual approaches to gun violence prevention. Activities supported by this service include GVRS, Safe Streets, Hospital-Based Intervention Programming (HBIP), and School-Based Violence Prevention programming."
)

# NOT %||% -- R 4.4+ ships its own base::%||% (NULL-coalescing only, no NA
# handling), which silently shadows this codebase's NA-aware %||% defined
# in R/database.R (guarded by `if (!exists("%||%", ...))`, which is already
# TRUE once base provides one). A DB column read back as SQL NULL comes
# through as NA, not NULL, so every blank-check in this script using %||%
# was silently never catching it. Sidestepping entirely with an explicit
# helper rather than relying on that operator at all.
field_is_blank <- function(x) {
  is.null(x) || length(x) == 0 || is.na(x) || !nzchar(trimws(as.character(x)))
}

# Normalizes curly vs. straight apostrophes/quotes before comparing against
# generic_descriptions, so this isn't fragile against which quote style
# happens to be stored.
normalize_quotes <- function(x) {
  x <- gsub("[‘’]", "'", x)
  gsub("[“”]", "\"", x)
}

DBI::dbWithTransaction(connection, {
  fields_updated <- 0L
  for (measure_id in names(entries)) {
    entry <- entries[[measure_id]]
    current <- DBI::dbGetQuery(
      connection,
      "SELECT description, context_required, data_location, collection_method, how_data_used, why_meaningful, proxy_measure, improvement_notes, replicability, formula FROM performance.performance_measure WHERE measure_id = $1",
      params = list(as.integer(measure_id))
    )
    if (!nrow(current)) stop("measure_id not found: ", measure_id)

    updates <- list()
    if (!is.null(entry$description) && !field_is_blank(current$description[[1]]) && normalize_quotes(trimws(current$description[[1]])) %in% normalize_quotes(generic_descriptions)) {
      updates$description <- entry$description
    }
    for (field in c("context_required", "data_location", "collection_method", "how_data_used", "why_meaningful", "proxy_measure", "improvement_notes")) {
      if (!is.null(entry[[field]]) && field_is_blank(current[[field]][[1]])) {
        updates[[field]] <- entry[[field]]
      }
    }
    if (isTRUE(entry$replicability) && !isTRUE(current$replicability[[1]])) {
      updates$replicability <- TRUE
    }
    if (!is.null(entry$formula_fix)) {
      updates$formula <- entry$formula_fix
    }

    if (!length(updates)) next
    set_clauses <- paste(sprintf("%s = $%d", names(updates), seq_along(updates) + 1), collapse = ", ")
    DBI::dbExecute(
      connection,
      sprintf("UPDATE performance.performance_measure SET %s WHERE measure_id = $1", set_clauses),
      params = c(list(as.integer(measure_id)), unname(updates))
    )
    cat("measure_id", measure_id, "- updated fields:", paste(names(updates), collapse = ", "), "\n")
    fields_updated <- fields_updated + length(updates)
  }
  cat("\ntotal fields written:", fields_updated, "\n")
})
