# Imports historical measure_actuals data from an external spreadsheet export
# (perf_data.xlsx) into performance.measure_actuals, matching rows to existing
# performance.performance_measure records by agency_id + normalized title
# (the spreadsheet's own Measure ID column uses several incompatible legacy
# schemes -- e.g. "AM01", "1851", "4321-446-A-1" -- none of which line up with
# our database's serial measure_id, so title-based matching is the only
# reliable join).
#
# Usage:
#   Rscript scripts/import_perf_data_actuals.R database/seed/perf_data_export.xlsx --dry-run
#   Rscript scripts/import_perf_data_actuals.R database/seed/perf_data_export.xlsx --write
#
# --dry-run (default) only prints a summary and writes review CSVs to
# outputs/perf_data_import/. --write actually inserts/updates
# performance.measure_actuals for matched rows.

source("R/database.R", local = TRUE)

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop("Usage: Rscript scripts/import_perf_data_actuals.R <path-to-xlsx> [--write]")
xlsx_path <- args[[1]]
do_write <- "--write" %in% args

if (!requireNamespace("readxl", quietly = TRUE)) {
  install.packages("readxl", repos = "https://cloud.r-project.org")
}
library(readxl)

out_dir <- file.path("outputs", "perf_data_import")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

norm_title <- function(x) {
  x <- tolower(x)
  x <- iconv(x, from = "UTF-8", to = "ASCII//TRANSLIT")
  gsub("[^a-z0-9]", "", x)
}

clean_numeric <- function(x) {
  # \\s alone does not match U+00A0 (non-breaking space), which appears a lot
  # in this spreadsheet's numeric cells -- strip it explicitly too.
  x <- gsub("[\u00a0\\s]+", "", x, perl = TRUE)
  x <- gsub(",", "", x)
  x <- gsub("^\\$", "", x)
  x <- gsub("%$", "", x)
  na_markers <- c("", "n/a", "na", "nodata", "new", "tbd", "-", "--")
  bad <- tolower(x) %in% na_markers | grepl("[a-zA-Z]", x)
  x[bad] <- NA
  suppressWarnings(as.numeric(x))
}

# ---- 1. Read and de-duplicate ----
raw <- readxl::read_excel(xlsx_path, sheet = 1, col_types = "text")
raw$measure_id_clean <- trimws(raw[["Measure ID"]])
raw$agency_id_clean <- trimws(sub("^([A-Z]{2,4}[0-9]{3,4}).*$", "\\1", raw[["Agency ID"]]))
raw$title_norm <- norm_title(raw[["Performance Measure"]])
raw$modified_parsed <- suppressWarnings(as.numeric(raw$Modified))

fy_actual_cols <- c("FY 21 Actual", "FY 22 Actual", "FY 23 Actual", "FY 24 Actual", "FY 25 Actual", "FY 26 Actual")
fy_target_cols <- c("FY 24 Target", "FY 25 Target", "FY 26 Target", "FY 27 Target")
completeness <- rowSums(!is.na(raw[, c(fy_actual_cols, fy_target_cols)]))

dedup_key <- ifelse(
  is.na(raw$measure_id_clean) | raw$measure_id_clean == "",
  paste0("__blank_", seq_len(nrow(raw))),
  raw$measure_id_clean
)
ord <- order(dedup_key, -completeness, -ifelse(is.na(raw$modified_parsed), -Inf, raw$modified_parsed))
raw_ord <- raw[ord, ]
deduped <- raw_ord[!duplicated(dedup_key[ord]), ]

cat("raw rows:", nrow(raw), "| after de-dup:", nrow(deduped), "\n")

# ---- 2. Match against existing measures (agency_id + normalized title) ----
con <- connect_app_database()
on.exit(DBI::dbDisconnect(con), add = TRUE)

db_measures <- DBI::dbGetQuery(con, "SELECT measure_id, agency_id, title, format_type FROM performance.performance_measure")
db_measures$title_norm <- norm_title(db_measures$title)
db_measures$match_key <- paste(db_measures$agency_id, db_measures$title_norm, sep = "||")

deduped$match_key <- paste(deduped$agency_id_clean, deduped$title_norm, sep = "||")
deduped$matched_measure_id <- db_measures$measure_id[match(deduped$match_key, db_measures$match_key)]
deduped$matched_format_type <- db_measures$format_type[match(deduped$match_key, db_measures$match_key)]

matched <- deduped[!is.na(deduped$matched_measure_id), ]
unmatched <- deduped[is.na(deduped$matched_measure_id), ]
cat("matched to existing measures:", nrow(matched), "| unmatched (not imported):", nrow(unmatched), "\n")

write.csv(
  unmatched[, c("Performance Measure", "Agency", "agency_id_clean", "Measure ID", "Status")],
  file.path(out_dir, "unmatched_rows.csv"),
  row.names = FALSE
)

# ---- 3. Reshape wide FY columns into long measure_actuals candidate rows ----
fy_map <- list(
  `2021` = list(actual = "FY 21 Actual", target = NA, q1 = NA, q2 = NA, q3 = NA, q4 = NA),
  `2022` = list(actual = "FY 22 Actual", target = NA, q1 = NA, q2 = NA, q3 = NA, q4 = NA),
  `2023` = list(actual = "FY 23 Actual", target = NA, q1 = NA, q2 = NA, q3 = NA, q4 = NA),
  `2024` = list(actual = "FY 24 Actual", target = "FY 24 Target", q1 = NA, q2 = NA, q3 = NA, q4 = NA),
  `2025` = list(actual = "FY 25 Actual", target = "FY 25 Target", q1 = "FY 25 Q1", q2 = "FY 25 Q2", q3 = "FY 25 Q3", q4 = "FY 25 Q4"),
  `2026` = list(actual = "FY 26 Actual", target = "FY 26 Target", q1 = "FY 26 Q1", q2 = "FY 26 Q2", q3 = "FY 26 Q3", q4 = "FY 26 Q4"),
  `2027` = list(actual = NA, target = "FY 27 Target", q1 = NA, q2 = NA, q3 = NA, q4 = NA)
)
get_col <- function(row, colname) {
  if (is.na(colname)) return(NA_character_)
  val <- row[[colname]]
  if (is.null(val) || is.na(val) || trimws(val) == "") return(NA_character_)
  trimws(val)
}

long_rows <- vector("list", nrow(matched) * length(fy_map))
idx <- 1
for (i in seq_len(nrow(matched))) {
  row <- matched[i, ]
  for (fy in names(fy_map)) {
    m <- fy_map[[fy]]
    vals <- list(
      actual = get_col(row, m$actual), target = get_col(row, m$target),
      q1 = get_col(row, m$q1), q2 = get_col(row, m$q2), q3 = get_col(row, m$q3), q4 = get_col(row, m$q4)
    )
    if (all(vapply(vals, is.na, logical(1)))) next
    long_rows[[idx]] <- data.frame(
      measure_id = row$matched_measure_id, format_type = row$matched_format_type,
      fiscal_year = as.integer(fy),
      annual_actual = vals$actual, target_value = vals$target,
      q1_value = vals$q1, q2_value = vals$q2, q3_value = vals$q3, q4_value = vals$q4,
      title = row[["Performance Measure"]], stringsAsFactors = FALSE
    )
    idx <- idx + 1
  }
}
long_df <- do.call(rbind, long_rows[seq_len(idx - 1)])
cat("candidate measure_actuals rows:", nrow(long_df), "for", length(unique(long_df$measure_id)), "measures\n")

# ---- 4. Clean numeric values; normalize whole-percent values to fractions ----
value_cols <- c("annual_actual", "target_value", "q1_value", "q2_value", "q3_value", "q4_value")
for (col in value_cols) {
  long_df[[paste0(col, "_num")]] <- clean_numeric(long_df[[col]])
}

parse_fail <- data.frame()
for (col in value_cols) {
  raw_col <- long_df[[col]]
  num_col <- long_df[[paste0(col, "_num")]]
  bad_idx <- which(!is.na(raw_col) & trimws(raw_col) != "" & is.na(num_col))
  if (length(bad_idx)) {
    parse_fail <- rbind(parse_fail, data.frame(
      measure_id = long_df$measure_id[bad_idx], fiscal_year = long_df$fiscal_year[bad_idx],
      column = col, raw_value = raw_col[bad_idx], title = long_df$title[bad_idx]
    ))
  }
}
write.csv(parse_fail, file.path(out_dir, "unparseable_values.csv"), row.names = FALSE)
cat("values that could not be parsed as numeric (left NULL, written for review):", nrow(parse_fail), "\n")

pct_normalized <- data.frame()
for (col in value_cols) {
  numcol <- paste0(col, "_num")
  idx <- which(long_df$format_type == "Percent" & !is.na(long_df[[numcol]]) & long_df[[numcol]] > 1.5)
  if (length(idx)) {
    pct_normalized <- rbind(pct_normalized, data.frame(
      measure_id = long_df$measure_id[idx], fiscal_year = long_df$fiscal_year[idx],
      column = col, original_value = long_df[[numcol]][idx], title = long_df$title[idx]
    ))
    long_df[[numcol]][idx] <- long_df[[numcol]][idx] / 100
  }
}
write.csv(pct_normalized, file.path(out_dir, "percent_values_normalized.csv"), row.names = FALSE)
cat("Percent-type values detected as whole percentages and divided by 100:", nrow(pct_normalized), "\n")

# Remaining sanity check after normalization
still_odd <- long_df[
  long_df$format_type == "Percent" &
    (!is.na(long_df$annual_actual_num) & (long_df$annual_actual_num > 1.5 | long_df$annual_actual_num < -0.5)),
]
write.csv(still_odd[, c("measure_id", "fiscal_year", "annual_actual_num", "title")], file.path(out_dir, "still_out_of_range.csv"), row.names = FALSE)
cat("still out of sane range after normalization (needs manual review):", nrow(still_odd), "\n")

saveRDS(long_df, file.path(out_dir, "final_long_actuals.rds"))

# ---- 5. Write (only if --write passed) ----
if (do_write) {
  cat("\n--write passed: writing to performance.measure_actuals...\n")
  written <- 0
  DBI::dbWithTransaction(con, {
    for (i in seq_len(nrow(long_df))) {
      r <- long_df[i, ]
      DBI::dbExecute(
        con,
        paste(
          "INSERT INTO performance.measure_actuals",
          "(measure_id, fiscal_year, annual_actual, target_value, q1_value, q2_value, q3_value, q4_value, reported_by)",
          "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 2)",
          "ON CONFLICT (measure_id, fiscal_year) DO UPDATE SET",
          "annual_actual = COALESCE(EXCLUDED.annual_actual, performance.measure_actuals.annual_actual),",
          "target_value = COALESCE(EXCLUDED.target_value, performance.measure_actuals.target_value),",
          "q1_value = COALESCE(EXCLUDED.q1_value, performance.measure_actuals.q1_value),",
          "q2_value = COALESCE(EXCLUDED.q2_value, performance.measure_actuals.q2_value),",
          "q3_value = COALESCE(EXCLUDED.q3_value, performance.measure_actuals.q3_value),",
          "q4_value = COALESCE(EXCLUDED.q4_value, performance.measure_actuals.q4_value),",
          "updated_at = now()"
        ),
        params = list(
          r$measure_id, r$fiscal_year, r$annual_actual_num, r$target_value_num,
          r$q1_value_num, r$q2_value_num, r$q3_value_num, r$q4_value_num
        )
      )
      written <- written + 1
    }
  })
  cat("wrote/updated", written, "measure_actuals rows\n")
} else {
  cat("\nDry run only (pass --write to actually insert). Review outputs in", out_dir, "\n")
}
