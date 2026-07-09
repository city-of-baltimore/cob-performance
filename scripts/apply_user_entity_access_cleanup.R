source("R/database.R", local = TRUE)

seed_path <- file.path("database", "seed", "user_entity_access_seed.csv")
if (!file.exists(seed_path)) {
  stop("Missing seed file: ", seed_path)
}

seed <- utils::read.csv(seed_path, stringsAsFactors = FALSE, check.names = FALSE)
required <- c("email", "public_name")
missing_columns <- setdiff(required, names(seed))
if (length(missing_columns)) {
  stop("Seed is missing required columns: ", paste(missing_columns, collapse = ", "))
}

seed_keys <- unique(data.frame(
  email = tolower(trimws(as.character(seed$email))),
  public_name = trimws(as.character(seed$public_name)),
  stringsAsFactors = FALSE
))
seed_keys <- seed_keys[nzchar(seed_keys$email) & nzchar(seed_keys$public_name), , drop = FALSE]
if (!nrow(seed_keys)) stop("Seed contains no usable user/entity rows.")

connection <- connect_app_database()
on.exit(DBI::dbDisconnect(connection), add = TRUE)

apply_user_entity_access_seed(connection, seed_path)

DBI::dbWithTransaction(connection, {
  DBI::dbWriteTable(
    connection,
    "tmp_user_entity_access_seed",
    seed_keys,
    overwrite = TRUE,
    temporary = TRUE
  )

  removed_access <- DBI::dbExecute(
    connection,
    paste(
      "DELETE FROM access.user_entity_access uea",
      "USING access.\"user\" u, reference.plan_entity pe",
      "WHERE u.user_id = uea.user_id",
      "  AND pe.entity_id = uea.entity_id",
      "  AND COALESCE(pe.active, true)",
      "  AND COALESCE(pe.has_own_plan, true)",
      "  AND NOT EXISTS (",
      "    SELECT 1",
      "    FROM tmp_user_entity_access_seed seed",
      "    WHERE seed.email = lower(u.email)",
      "      AND seed.public_name = pe.public_name",
      "  )"
    )
  )

  removed_duplicate_access <- DBI::dbExecute(
    connection,
    paste(
      "WITH ranked AS (",
      "  SELECT",
      "    uea.entity_access_id,",
      "    row_number() OVER (",
      "      PARTITION BY lower(u.email), pe.public_name",
      "      ORDER BY (u.email = lower(u.email)) DESC, uea.updated_at DESC NULLS LAST, uea.entity_access_id DESC",
      "    ) AS row_rank",
      "  FROM access.user_entity_access uea",
      "  JOIN access.\"user\" u ON u.user_id = uea.user_id",
      "  JOIN reference.plan_entity pe ON pe.entity_id = uea.entity_id",
      "  WHERE COALESCE(u.active, true)",
      "    AND COALESCE(pe.active, true)",
      "    AND COALESCE(pe.has_own_plan, true)",
      ")",
      "DELETE FROM access.user_entity_access uea",
      "USING ranked",
      "WHERE uea.entity_access_id = ranked.entity_access_id",
      "  AND ranked.row_rank > 1"
    )
  )

  consolidated <- consolidate_user_performance_roles(connection)

  duplicate_roles <- DBI::dbGetQuery(
    connection,
    "SELECT COUNT(*) AS n FROM (SELECT user_id FROM access.user_role GROUP BY user_id HAVING COUNT(*) > 1) x"
  )$n[[1]]

  missing_roles <- DBI::dbGetQuery(
    connection,
    paste(
      "SELECT COUNT(*) AS n",
      "FROM access.user_entity_access uea",
      "JOIN access.\"user\" u ON u.user_id = uea.user_id",
      "JOIN reference.plan_entity pe ON pe.entity_id = uea.entity_id",
      "LEFT JOIN access.user_role ur ON ur.user_id = uea.user_id AND (ur.agency_id IS NULL OR ur.agency_id = uea.agency_id)",
      "WHERE COALESCE(u.active, true)",
      "  AND COALESCE(pe.active, true)",
      "  AND COALESCE(pe.has_own_plan, true)",
      "GROUP BY uea.entity_access_id",
      "HAVING COUNT(ur.user_role_id) = 0"
    )
  )
  missing_roles <- nrow(missing_roles)

  cat("seed_rows=", nrow(seed_keys), "\n", sep = "")
  cat("removed_entity_access_rows=", removed_access, "\n", sep = "")
  cat("removed_duplicate_entity_access_rows=", removed_duplicate_access, "\n", sep = "")
  cat("consolidated_role_groups=", consolidated, "\n", sep = "")
  cat("remaining_duplicate_role_groups=", duplicate_roles, "\n", sep = "")
  cat("remaining_entity_rows_without_roles=", missing_roles, "\n", sep = "")
})
