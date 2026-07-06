library(DBI)

source("R/database.R")

description_path <- file.path("database", "seed", "service_descriptions_update.csv")
if (!file.exists(description_path)) {
  stop("Missing service description CSV: ", description_path)
}

descriptions <- read.csv(description_path, stringsAsFactors = FALSE, check.names = FALSE)
required <- c("service_id", "service_description")
missing <- setdiff(required, names(descriptions))
if (length(missing)) {
  stop("Missing required columns: ", paste(missing, collapse = ", "))
}

descriptions$service_id <- trimws(descriptions$service_id)
descriptions$service_description <- trimws(descriptions$service_description)
descriptions <- descriptions[nzchar(descriptions$service_id) & nzchar(descriptions$service_description), , drop = FALSE]

if (anyDuplicated(descriptions$service_id)) {
  dupes <- unique(descriptions$service_id[duplicated(descriptions$service_id)])
  stop("Duplicate service IDs remain in update CSV: ", paste(dupes, collapse = ", "))
}

con <- connect_app_database()
on.exit(dbDisconnect(con), add = TRUE)

existing <- dbGetQuery(con, "SELECT service_id FROM reference.service")
matched <- descriptions[descriptions$service_id %in% existing$service_id, , drop = FALSE]
unmatched <- descriptions[!descriptions$service_id %in% existing$service_id, , drop = FALSE]

DBI::dbWithTransaction(con, {
  for (i in seq_len(nrow(matched))) {
    dbExecute(
      con,
      "UPDATE reference.service
       SET service_description = $2,
           updated_at = now()
       WHERE service_id = $1",
      params = list(matched$service_id[[i]], matched$service_description[[i]])
    )
  }
})

cat("Service descriptions in source:", nrow(descriptions), "\n")
cat("Updated reference.service rows:", nrow(matched), "\n")
cat("Unmatched service IDs:", nrow(unmatched), "\n")
if (nrow(unmatched)) {
  print(unmatched[, intersect(c("agency_id", "agency", "service_id", "service"), names(unmatched)), drop = FALSE])
}
