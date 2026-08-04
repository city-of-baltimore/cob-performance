#!/usr/bin/env Rscript
# Load chart-of-accounts spend categories into reference.spend_category.
#
# The codes are city budget data and this repository is PUBLIC, so they are not
# committed. This script is the loader only; the data comes from a CSV kept
# outside version control (database/seed/spend_category_seed.csv is gitignored).
#
#   Rscript scripts/load_spend_categories.R [--file <path>] [--dry-run] [--prune]
#
#   --file     CSV with columns code,label[,sort_order]. Defaults to
#              database/seed/spend_category_seed.csv.
#   --dry-run  Report what would change and write nothing.
#   --prune    Deactivate codes in the table that are absent from the file.
#              Off by default, so a partial file cannot quietly retire codes.
#
# Idempotent: re-running with the same file is a no-op. Existing codes are
# updated in place rather than deleted and reinserted, so any request line
# already pointing at a code keeps working.

suppressWarnings(suppressMessages({
  source(file.path("R", "database.R"))
}))

args <- commandArgs(trailingOnly = TRUE)
arg_value <- function(flag, default = NULL) {
  hit <- which(args == flag)
  if (!length(hit) || hit[[1]] == length(args)) return(default)
  args[[hit[[1]] + 1L]]
}
path <- arg_value("--file", file.path("database", "seed", "spend_category_seed.csv"))
dry_run <- "--dry-run" %in% args
prune <- "--prune" %in% args

if (!file.exists(path)) {
  stop("No spend-category file at '", path, "'. Pass --file <path>. ",
       "The list is not in version control, so it will not be present on a fresh clone.")
}

seed <- utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE, colClasses = "character")
if (!all(c("code", "label") %in% names(seed))) {
  stop("File must have at least 'code' and 'label' columns; found: ", paste(names(seed), collapse = ", "))
}
seed$code <- trimws(seed$code)
seed$label <- trimws(seed$label)
seed <- seed[nzchar(seed$code) & nzchar(seed$label), , drop = FALSE]
if (!nrow(seed)) stop("No usable rows in ", path)

dupes <- unique(seed$code[duplicated(seed$code)])
if (length(dupes)) {
  stop("Duplicate codes in the file: ", paste(dupes, collapse = ", "),
       ". Each code must appear once - resolve them in the source list first.")
}

seed$sort_order <- if ("sort_order" %in% names(seed)) {
  suppressWarnings(as.integer(seed$sort_order))
} else {
  seq_len(nrow(seed))
}
seed$sort_order[is.na(seed$sort_order)] <- seq_len(nrow(seed))[is.na(seed$sort_order)]

connection <- connect_app_database()
on.exit(try(DBI::dbDisconnect(connection), silent = TRUE), add = TRUE)
ensure_review_schema(connection)

existing <- DBI::dbGetQuery(connection, "SELECT code, label, sort_order, active FROM reference.spend_category")
to_add <- setdiff(seed$code, existing$code)
to_retire <- setdiff(existing$code[existing$active %in% TRUE], seed$code)
changed <- character(0)
if (nrow(existing)) {
  idx <- match(existing$code, seed$code)
  same <- !is.na(idx) &
    existing$label == seed$label[idx] &
    existing$sort_order == seed$sort_order[idx] &
    existing$active %in% TRUE
  changed <- existing$code[!is.na(idx) & !same]
}

cat(sprintf("file            : %s (%d codes)\n", path, nrow(seed)))
cat(sprintf("already in table: %d\n", nrow(existing)))
cat(sprintf("to insert       : %d\n", length(to_add)))
cat(sprintf("to update       : %d\n", length(changed)))
cat(sprintf("absent from file: %d%s\n", length(to_retire),
            if (length(to_retire)) if (prune) " (will be deactivated)" else " (left active; pass --prune to deactivate)" else ""))

if (dry_run) {
  cat("\n--dry-run: nothing written.\n")
  quit(save = "no", status = 0)
}

DBI::dbWithTransaction(connection, {
  for (i in seq_len(nrow(seed))) {
    DBI::dbExecute(
      connection,
      paste(
        "INSERT INTO reference.spend_category (code, label, sort_order, active, updated_at)",
        "VALUES ($1::varchar, $2::varchar, $3::integer, true, now())",
        "ON CONFLICT (code) DO UPDATE SET label = EXCLUDED.label,",
        "sort_order = EXCLUDED.sort_order, active = true, updated_at = now()"
      ),
      params = list(seed$code[[i]], seed$label[[i]], seed$sort_order[[i]])
    )
  }
  if (prune && length(to_retire)) {
    # Deactivated, never deleted: a request line may already point at the code.
    for (code in to_retire) {
      DBI::dbExecute(
        connection,
        "UPDATE reference.spend_category SET active = false, updated_at = now() WHERE code = $1",
        params = list(code)
      )
    }
  }
})

after <- DBI::dbGetQuery(connection, "SELECT count(*) FILTER (WHERE active) AS active, count(*) AS total FROM reference.spend_category")
cat(sprintf("\ndone: %s active of %s total in reference.spend_category\n",
            as.integer(after$active[[1]]), as.integer(after$total[[1]])))
