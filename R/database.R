if (!exists("%||%", mode = "function")) {
  `%||%` <- function(x, y) if (is.null(x) || length(x) == 0 || (length(x) == 1 && is.na(x))) y else x
}

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

logical_seed_value <- function(value) {
  value <- tolower(trimws(as.character(value %||% "")))
  value %in% c("true", "t", "1", "yes", "y")
}

performance_role_rank <- function(role) {
  ranks <- c(
    AgencyViewer = 10L,
    AgencyWriter = 20L,
    # Retired role, kept only so any legacy row still ranks. Not assignable.
    AgencyApprover = 30L,
    AgencySubmitter = 40L,
    BBMRReviewer = 50L,
    OPIReviewer = 60L,
    DeputyMayor = 70L,
    CAOffice = 80L,
    SystemAdmin = 90L
  )
  role <- trimws(as.character(role %||% ""))
  value <- unname(ranks[role])
  ifelse(is.na(value), 0L, as.integer(value))
}

highest_performance_role <- function(roles) {
  roles <- unique(trimws(as.character(roles %||% character(0))))
  roles <- roles[nzchar(roles)]
  if (!length(roles)) return("AgencyViewer")
  roles[which.max(performance_role_rank(roles))]
}

consolidate_user_performance_roles <- function(connection) {
  duplicate_groups <- DBI::dbGetQuery(
    connection,
    "SELECT user_id FROM access.user_role GROUP BY user_id HAVING COUNT(*) > 1"
  )
  if (!nrow(duplicate_groups)) return(invisible(0L))

  consolidated <- 0L
  for (i in seq_len(nrow(duplicate_groups))) {
    user_id <- duplicate_groups$user_id[[i]]
    role_rows <- DBI::dbGetQuery(
      connection,
      paste(
        "SELECT user_role_id, app_role, budget_access, adaptive_planning, performance_plan_access",
        "FROM access.user_role",
        "WHERE user_id = $1",
        "ORDER BY user_role_id"
      ),
      params = list(user_id)
    )
    if (nrow(role_rows) <= 1) next

    selected_role <- highest_performance_role(role_rows$app_role)
    selected_rows <- role_rows[role_rows$app_role == selected_role, , drop = FALSE]
    keep_role_id <- if (nrow(selected_rows)) selected_rows$user_role_id[[1]] else role_rows$user_role_id[[1]]
    budget_access <- any(role_rows$budget_access %in% TRUE, na.rm = TRUE)
    adaptive_planning <- any(role_rows$adaptive_planning %in% TRUE, na.rm = TRUE)
    performance_plan_access <- any(role_rows$performance_plan_access %in% TRUE, na.rm = TRUE)

    DBI::dbExecute(
      connection,
      paste(
        "UPDATE access.user_role",
        "SET app_role = $2::varchar(30), agency_id = NULL, budget_access = $3, adaptive_planning = $4, performance_plan_access = $5, updated_at = now()",
        "WHERE user_role_id = $1"
      ),
      params = list(keep_role_id, selected_role, budget_access, adaptive_planning, performance_plan_access)
    )
    DBI::dbExecute(
      connection,
      "DELETE FROM access.user_role WHERE user_id = $1 AND user_role_id <> $2",
      params = list(user_id, keep_role_id)
    )
    consolidated <- consolidated + 1L
  }
  invisible(consolidated)
}

apply_agency_budget_analyst_seed <- function(connection, path = file.path("database", "seed", "agency_budget_analyst_seed.csv")) {
  if (!file.exists(path)) return(invisible(FALSE))
  seed <- utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
  if (!all(c("agency_id", "analyst_name") %in% names(seed))) {
    warning("Skipping agency budget analyst seed; missing agency_id/analyst_name columns")
    return(invisible(FALSE))
  }
  for (i in seq_len(nrow(seed))) {
    agency_id <- trimws(as.character(seed$agency_id[[i]] %||% ""))
    analyst_name <- trimws(as.character(seed$analyst_name[[i]] %||% ""))
    if (!nzchar(agency_id) || !nzchar(analyst_name)) next
    DBI::dbExecute(
      connection,
      "UPDATE reference.agency SET budget_analyst = $2 WHERE agency_id = $1",
      params = list(agency_id, analyst_name)
    )
  }
  invisible(TRUE)
}

apply_agency_budget_analyst_seed_once <- function(connection, path = file.path("database", "seed", "agency_budget_analyst_seed.csv")) {
  seed_name <- "agency_budget_analyst_seed"
  if (seed_already_applied(connection, seed_name)) return(invisible(FALSE))
  # Renamed 2026-07-30 from "agency_fiscal_analyst_seed" (the column was
  # reference.agency.fiscal_analyst, now .budget_analyst). If the old seed
  # already ran, carry that forward as already-applied under the new name
  # rather than re-running it -- re-running would blindly overwrite the
  # column with the CSV's values again, silently reverting any manual edit
  # an admin has made through the app since the original seed ran.
  if (seed_already_applied(connection, "agency_fiscal_analyst_seed")) {
    mark_seed_applied(connection, seed_name)
    return(invisible(FALSE))
  }
  apply_agency_budget_analyst_seed(connection, path)
  mark_seed_applied(connection, seed_name)
  invisible(TRUE)
}

# application.seed_applied tracks one-time data operations so they run
# exactly once per database rather than re-applying (and silently reverting
# admin edits/deletions) on every app restart.
seed_already_applied <- function(connection, seed_name) {
  isTRUE(DBI::dbGetQuery(
    connection,
    "SELECT EXISTS (SELECT 1 FROM application.seed_applied WHERE seed_name = $1)",
    params = list(seed_name)
  )[[1]])
}

mark_seed_applied <- function(connection, seed_name) {
  DBI::dbExecute(
    connection,
    "INSERT INTO application.seed_applied (seed_name) VALUES ($1) ON CONFLICT (seed_name) DO NOTHING",
    params = list(seed_name)
  )
}

# application.log_row_change() (see ensure_review_schema()) reads this
# transaction-local setting to attribute an audit_log row to whoever made
# the change, for tables that don't already carry an editor column of
# their own. Must be called inside the same DBI::dbWithTransaction() block
# as the write it's meant to attribute -- set_config(..., true) is
# transaction-local (like SET LOCAL), so it has no effect on a write that
# runs in a separate implicit transaction.
set_audit_actor <- function(connection, user_id) {
  user_id <- suppressWarnings(as.integer(user_id))
  DBI::dbExecute(
    connection,
    "SELECT set_config('app.current_user_id', $1, true)",
    params = list(if (is.na(user_id)) NA_character_ else as.character(user_id))
  )
}

apply_user_entity_access_seed_once <- function(connection, path = file.path("database", "seed", "user_entity_access_seed.csv")) {
  seed_name <- "user_entity_access_seed"
  if (seed_already_applied(connection, seed_name)) return(invisible(FALSE))
  # This CSV is a one-time bulk import from early in the project, not a
  # perpetual sync source -- team membership is managed live through the
  # Team & Roles UI from here on. Re-running it on every restart was
  # silently re-inserting deleted access rows and overwriting role changes
  # admins had made since. A database that already has real access rows is
  # treated as already seeded (skip re-applying, just record the marker); a
  # genuinely empty database still gets the one-time initial population.
  already_has_data <- isTRUE(DBI::dbGetQuery(connection, "SELECT EXISTS (SELECT 1 FROM access.user_entity_access LIMIT 1)")[[1]])
  if (!already_has_data) {
    apply_user_entity_access_seed(connection, path)
  }
  mark_seed_applied(connection, seed_name)
  invisible(TRUE)
}

apply_user_entity_access_seed <- function(connection, path = file.path("database", "seed", "user_entity_access_seed.csv")) {
  if (!file.exists(path)) return(invisible(FALSE))
  seed <- utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
  required <- c("email", "full_name", "agency_id", "agency_role", "agency_roles", "access_level", "app_role")
  missing_columns <- setdiff(required, names(seed))
  if (length(missing_columns)) {
    warning("Skipping user entity access seed; missing columns: ", paste(missing_columns, collapse = ", "))
    return(invisible(FALSE))
  }
  has_public_name <- "public_name" %in% names(seed)
  has_entity_id <- "entity_id" %in% names(seed)
  if (!has_public_name && !has_entity_id) {
    warning("Skipping user entity access seed; missing public_name or entity_id")
    return(invisible(FALSE))
  }
  seed <- seed[!is.na(seed$email) & nzchar(trimws(seed$email)), , drop = FALSE]
  if (!nrow(seed)) return(invisible(TRUE))

  DBI::dbWithTransaction(connection, {
    DBI::dbExecute(connection, "SELECT setval(pg_get_serial_sequence('access.\"user\"', 'user_id'), COALESCE((SELECT MAX(user_id) FROM access.\"user\"), 1), (SELECT COUNT(*) > 0 FROM access.\"user\"))")
    DBI::dbExecute(connection, "SELECT setval(pg_get_serial_sequence('access.user_entity_access', 'entity_access_id'), COALESCE((SELECT MAX(entity_access_id) FROM access.user_entity_access), 1), (SELECT COUNT(*) > 0 FROM access.user_entity_access))")
    DBI::dbExecute(connection, "SELECT setval(pg_get_serial_sequence('access.user_role', 'user_role_id'), COALESCE((SELECT MAX(user_role_id) FROM access.user_role), 1), (SELECT COUNT(*) > 0 FROM access.user_role))")
    for (i in seq_len(nrow(seed))) {
      row <- seed[i, , drop = FALSE]
      email <- tolower(trimws(as.character(row$email[[1]] %||% "")))
      full_name <- trimws(as.character(row$full_name[[1]] %||% ""))
      public_name <- if (has_public_name) trimws(as.character(row$public_name[[1]] %||% "")) else ""
      entity_id <- if (has_entity_id) suppressWarnings(as.integer(row$entity_id[[1]] %||% NA_integer_)) else NA_integer_
      agency_id <- trimws(as.character(row$agency_id[[1]] %||% ""))
      service_id <- trimws(as.character(row$service_id[[1]] %||% ""))
      if (!nzchar(service_id)) service_id <- NA_character_
      agency_role <- trimws(as.character(row$agency_role[[1]] %||% "Agency Staff"))
      agency_roles <- trimws(as.character(row$agency_roles[[1]] %||% agency_role))
      access_level <- trimws(as.character(row$access_level[[1]] %||% "Edit"))
      app_role <- trimws(as.character(row$app_role[[1]] %||% "AgencyViewer"))
      if (identical(access_level, "Submit")) app_role <- "AgencySubmitter"
      budget_access <- logical_seed_value(row$budget_access[[1]])
      adaptive_planning <- logical_seed_value(row$adaptive_planning[[1]])
      performance_plan_access <- logical_seed_value(row$performance_plan_access[[1]])
      if (!nzchar(email) || !nzchar(agency_id) || !nzchar(app_role)) next
      entity_exists <- if (nzchar(public_name)) {
        DBI::dbGetQuery(
          connection,
          "SELECT entity_id FROM reference.plan_entity WHERE public_name = $1 AND active = true AND has_own_plan = true ORDER BY entity_id LIMIT 1",
          params = list(public_name)
        )
      } else if (!is.na(entity_id)) {
        DBI::dbGetQuery(
          connection,
          "SELECT entity_id FROM reference.plan_entity WHERE entity_id = $1 AND active = true AND has_own_plan = true",
          params = list(entity_id)
        )
      } else {
        data.frame()
      }
      if (!nrow(entity_exists)) next
      entity_id <- entity_exists$entity_id[[1]]
      user <- DBI::dbGetQuery(
        connection,
        paste(
          'INSERT INTO access."user" (email, full_name, auth_type, active)',
          "VALUES ($1, $2, 'MicrosoftAD', true)",
          'ON CONFLICT (email) DO UPDATE SET full_name = COALESCE(NULLIF(EXCLUDED.full_name, \'\'), access."user".full_name), active = true, updated_at = now()',
          "RETURNING user_id"
        ),
        params = list(email, full_name)
      )
      user_id <- user$user_id[[1]]
      DBI::dbExecute(
        connection,
        paste(
          "INSERT INTO access.user_entity_access",
          "(user_id, entity_id, agency_id, service_id, agency_role, agency_roles, access_level, budget_access, adaptive_planning, performance_plan_access)",
          "VALUES ($1, $2, $3::varchar(20), $4::varchar(20), $5::varchar(30), $6, $7::varchar(20), $8, $9, $10)",
          "ON CONFLICT (user_id, entity_id) DO UPDATE SET",
          "agency_id = EXCLUDED.agency_id, service_id = EXCLUDED.service_id, agency_role = EXCLUDED.agency_role,",
          "agency_roles = EXCLUDED.agency_roles, access_level = EXCLUDED.access_level, budget_access = EXCLUDED.budget_access,",
          "adaptive_planning = EXCLUDED.adaptive_planning, performance_plan_access = EXCLUDED.performance_plan_access, updated_at = now()"
        ),
        params = list(user_id, entity_id, agency_id, service_id, agency_role, agency_roles, access_level, budget_access, adaptive_planning, performance_plan_access)
      )
      existing_roles <- DBI::dbGetQuery(
        connection,
        paste(
          "SELECT user_role_id, app_role, budget_access, adaptive_planning, performance_plan_access",
          "FROM access.user_role",
          "WHERE user_id = $1",
          "ORDER BY user_role_id"
        ),
        params = list(user_id)
      )
      selected_role <- highest_performance_role(c(existing_roles$app_role, app_role))
      budget_access <- isTRUE(budget_access) || any(existing_roles$budget_access %in% TRUE, na.rm = TRUE)
      adaptive_planning <- isTRUE(adaptive_planning) || any(existing_roles$adaptive_planning %in% TRUE, na.rm = TRUE)
      performance_plan_access <- isTRUE(performance_plan_access) || any(existing_roles$performance_plan_access %in% TRUE, na.rm = TRUE)
      if (nrow(existing_roles)) {
        selected_rows <- existing_roles[existing_roles$app_role == selected_role, , drop = FALSE]
        keep_role_id <- if (nrow(selected_rows)) selected_rows$user_role_id[[1]] else existing_roles$user_role_id[[1]]
        DBI::dbExecute(
          connection,
          "UPDATE access.user_role SET app_role = $2::varchar(30), agency_id = NULL, budget_access = $3, adaptive_planning = $4, performance_plan_access = $5, updated_at = now() WHERE user_role_id = $1",
          params = list(keep_role_id, selected_role, budget_access, adaptive_planning, performance_plan_access)
        )
        DBI::dbExecute(
          connection,
          "DELETE FROM access.user_role WHERE user_id = $1 AND user_role_id <> $2",
          params = list(user_id, keep_role_id)
        )
      } else {
        DBI::dbExecute(
          connection,
          "INSERT INTO access.user_role (user_id, app_role, agency_id, budget_access, adaptive_planning, performance_plan_access) VALUES ($1, $2::varchar(30), NULL, $3, $4, $5)",
          params = list(user_id, selected_role, budget_access, adaptive_planning, performance_plan_access)
        )
      }
    }
    consolidate_user_performance_roles(connection)
  })
  invisible(TRUE)
}

reset_identity_sequence <- function(connection, table_name, id_column) {
  DBI::dbExecute(
    connection,
    paste0(
      "SELECT setval(pg_get_serial_sequence($1, $2), ",
      "COALESCE((SELECT MAX(", DBI::dbQuoteIdentifier(connection, id_column), ") FROM ", table_name, "), 1), ",
      "(SELECT COUNT(*) > 0 FROM ", table_name, "))"
    ),
    params = list(table_name, id_column)
  )
  invisible(TRUE)
}

ensure_measure_identity_sequences <- function(connection) {
  reset_identity_sequence(connection, "performance.performance_measure", "measure_id")
  reset_identity_sequence(connection, "performance.measure_actuals", "actual_id")
  reset_identity_sequence(connection, "performance.measure_entity_link", "link_id")
  reset_identity_sequence(connection, "performance.pm_service_link", "link_id")
  reset_identity_sequence(connection, "performance.pm_goal_link", "link_id")
  invisible(TRUE)
}

# Small introspection helpers so migrations can be conditional on what a given
# database already has, rather than relying on ALTER ... IF EXISTS alone.
column_exists <- function(connection, schema, table, column) {
  nrow(DBI::dbGetQuery(
    connection,
    paste(
      "SELECT 1 FROM information_schema.columns",
      "WHERE table_schema = $1 AND table_name = $2 AND column_name = $3"
    ),
    params = list(schema, table, column)
  )) > 0
}

column_type <- function(connection, schema, table, column) {
  row <- DBI::dbGetQuery(
    connection,
    paste(
      "SELECT data_type FROM information_schema.columns",
      "WHERE table_schema = $1 AND table_name = $2 AND column_name = $3"
    ),
    params = list(schema, table, column)
  )
  if (!nrow(row)) NA_character_ else as.character(row$data_type[[1]])
}

# Convert a text "who touched this" column that stored a display name into an
# integer FK to access.user. Postgres rejects a subquery inside
# ALTER COLUMN ... USING, so this goes add -> backfill by name -> swap.
retype_modified_by_to_user_id <- function(connection, schema, table, column) {
  qualified <- paste0(schema, ".", table)
  if (!column_exists(connection, schema, table, column)) {
    DBI::dbExecute(connection, sprintf("ALTER TABLE %s ADD COLUMN %s integer", qualified, column))
  }
  if (!identical(column_type(connection, schema, table, column), "text")) {
    return(invisible(FALSE))
  }
  tmp <- paste0(column, "_uid")
  DBI::dbExecute(connection, sprintf("ALTER TABLE %s ADD COLUMN IF NOT EXISTS %s integer", qualified, tmp))
  DBI::dbExecute(
    connection,
    sprintf(
      paste(
        "UPDATE %1$s SET %2$s = u.user_id FROM access.\"user\" u",
        "WHERE u.full_name = %1$s.%3$s AND %1$s.%3$s IS NOT NULL"
      ),
      qualified, tmp, column
    )
  )
  DBI::dbExecute(connection, sprintf("ALTER TABLE %s DROP COLUMN %s", qualified, column))
  DBI::dbExecute(connection, sprintf("ALTER TABLE %s RENAME COLUMN %s TO %s", qualified, tmp, column))
  invisible(TRUE)
}

ensure_review_schema <- function(connection) {
  ensure_measure_identity_sequences(connection)
  DBI::dbExecute(connection, "CREATE SCHEMA IF NOT EXISTS application")
  DBI::dbExecute(
    connection,
    paste(
      "CREATE TABLE IF NOT EXISTS application.seed_applied (",
      "seed_name varchar(200) PRIMARY KEY,",
      "applied_at timestamptz NOT NULL DEFAULT now()",
      ")"
    )
  )

  # Generic history log: captures the row as it was immediately before an
  # UPDATE/DELETE on a handful of plan-builder tables that either have no
  # history at all today, or -- for reference.service -- are a shared
  # reference table that a single plan's approval can silently overwrite
  # for every other agency using that service. See set_audit_actor() for
  # how changed_by gets populated for tables that don't already track an
  # editor on the row itself.
  DBI::dbExecute(
    connection,
    paste(
      "CREATE TABLE IF NOT EXISTS application.audit_log (",
      "audit_id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,",
      "table_name text NOT NULL,",
      "row_pk text NOT NULL,",
      "operation varchar(10) NOT NULL,",
      "old_data jsonb NOT NULL,",
      "changed_by integer REFERENCES access.\"user\"(user_id),",
      "changed_at timestamptz NOT NULL DEFAULT now()",
      ")"
    )
  )
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_audit_log_table_row ON application.audit_log(table_name, row_pk)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_audit_log_changed_at ON application.audit_log(changed_at)")
  DBI::dbExecute(
    connection,
    paste(
      "CREATE OR REPLACE FUNCTION application.log_row_change() RETURNS trigger AS $BODY$",
      "DECLARE actor_id integer;",
      "BEGIN",
      "  actor_id := NULLIF(current_setting('app.current_user_id', true), '')::integer;",
      "  IF actor_id IS NULL AND (to_jsonb(OLD) ? 'updated_by') THEN",
      "    actor_id := NULLIF(to_jsonb(OLD) ->> 'updated_by', '')::integer;",
      "  END IF;",
      "  INSERT INTO application.audit_log (table_name, row_pk, operation, old_data, changed_by)",
      "  VALUES (TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, to_jsonb(OLD) ->> TG_ARGV[0], TG_OP, to_jsonb(OLD), actor_id);",
      # A BEFORE trigger's return value becomes the row Postgres actually
      # writes. RETURN OLD unconditionally (matching the target_schema.sql
      # copy of this same function, before the 2026-07-24 fix) silently
      # discarded every UPDATE to the 5 audited tables: the update
      # "succeeded" with no error, but the row was rewritten with its own
      # pre-update value. DELETE still needs OLD. Keep both copies of this
      # function in sync -- see the header comment on target_schema.sql.
      "  IF TG_OP = 'DELETE' THEN",
      "    RETURN OLD;",
      "  END IF;",
      "  RETURN NEW;",
      "END;",
      "$BODY$ LANGUAGE plpgsql"
    )
  )
  audit_targets <- list(
    list(schema_table = "planning.plan_section_draft", trigger = "trg_audit_plan_section_draft", pk = "draft_id"),
    list(schema_table = "reference.service", trigger = "trg_audit_reference_service", pk = "service_id"),
    list(schema_table = "performance.agency_goal", trigger = "trg_audit_agency_goal", pk = "agency_goal_id"),
    list(schema_table = "performance.overview_vision", trigger = "trg_audit_overview_vision", pk = "mv_id"),
    list(schema_table = "performance.service_risk", trigger = "trg_audit_service_risk", pk = "risk_id")
  )
  for (target in audit_targets) {
    DBI::dbExecute(
      connection,
      sprintf(
        "CREATE OR REPLACE TRIGGER %s BEFORE UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION application.log_row_change('%s')",
        target$trigger, target$schema_table, target$pk
      )
    )
  }

  # save_service_risk()'s UPDATE has always set updated_at; the live
  # database already carries this column (and several others -- risk_id,
  # created_at, modified_by, plan_service_id -- that target_schema.sql
  # doesn't declare at all, confirming the schema has drifted further
  # from that file than documented). Declared here too so a fresh install
  # matches reality instead of erroring the first time a risk is edited.
  DBI::dbExecute(connection, "ALTER TABLE performance.service_risk ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now()")
  # Renamed 2026-07-30: reference.agency.fiscal_analyst -> budget_analyst.
  # Postgres has no "RENAME COLUMN IF EXISTS", so check first -- this is a
  # no-op once the rename has already happened on a given database.
  if (nrow(DBI::dbGetQuery(connection, "SELECT 1 FROM information_schema.columns WHERE table_schema = 'reference' AND table_name = 'agency' AND column_name = 'fiscal_analyst'"))) {
    DBI::dbExecute(connection, "ALTER TABLE reference.agency RENAME COLUMN fiscal_analyst TO budget_analyst")
  }
  DBI::dbExecute(connection, "ALTER TABLE reference.agency ADD COLUMN IF NOT EXISTS budget_analyst varchar(200)")
  DBI::dbExecute(connection, "ALTER TABLE access.user_agency_access ADD COLUMN IF NOT EXISTS agency_roles text")
  DBI::dbExecute(
    connection,
    "UPDATE reference.agency SET submit_plan = true WHERE agency_id = 'AGC4317'"
  )
  DBI::dbExecute(connection, "ALTER TABLE reference.plan_entity DROP CONSTRAINT IF EXISTS plan_entity_entity_type_check")
  DBI::dbExecute(
    connection,
    "ALTER TABLE reference.plan_entity ADD CONSTRAINT plan_entity_entity_type_check CHECK (entity_type IN ('Agency', 'MayoraltyOffice', 'QuasiAgency', 'Other'))"
  )
  DBI::dbExecute(connection, "SELECT setval(pg_get_serial_sequence('reference.plan_entity', 'entity_id'), COALESCE((SELECT MAX(entity_id) FROM reference.plan_entity), 1), (SELECT COUNT(*) > 0 FROM reference.plan_entity))")
  DBI::dbExecute(
    connection,
    paste(
      "INSERT INTO reference.plan_entity (parent_agency_id, public_name, entity_type, has_own_plan, active)",
      "SELECT agency_id, COALESCE(NULLIF(public_name, ''), agency_name), 'Agency', true, COALESCE(active, true)",
      "FROM reference.agency",
      "WHERE COALESCE(active, true) AND COALESCE(submit_plan, true)",
      "ON CONFLICT (parent_agency_id, public_name) DO NOTHING"
    )
  )
  DBI::dbExecute(
    connection,
    paste(
      "UPDATE reference.plan_entity pe",
      "SET active = true, has_own_plan = true",
      "FROM reference.agency a",
      "WHERE pe.parent_agency_id = a.agency_id",
      "AND pe.entity_type = 'Agency'",
      "AND pe.public_name = COALESCE(NULLIF(a.public_name, ''), a.agency_name)",
      "AND COALESCE(a.active, true)",
      "AND COALESCE(a.submit_plan, true)"
    )
  )
  DBI::dbExecute(
    connection,
    paste(
      "UPDATE reference.plan_entity pe",
      "SET active = false, has_own_plan = false",
      "FROM reference.agency a",
      "WHERE pe.parent_agency_id = a.agency_id",
      "AND pe.entity_type = 'Agency'",
      "AND NOT COALESCE(a.submit_plan, true)"
    )
  )
  DBI::dbExecute(
    connection,
    paste(
      "INSERT INTO reference.plan_entity (parent_agency_id, public_name, entity_type, has_own_plan, active)",
      "VALUES ('AGC4301', 'Mayor''s Office', 'Other', false, true)",
      "ON CONFLICT (parent_agency_id, public_name) DO UPDATE SET",
      "entity_type = 'Other', has_own_plan = false, active = true"
    )
  )
  DBI::dbExecute(
    connection,
    paste(
      "CREATE OR REPLACE VIEW reference.entity_service_crosswalk AS",
      "SELECT",
      "  pe.entity_id,",
      "  pe.public_name,",
      "  pe.entity_type,",
      "  pe.has_own_plan,",
      "  pe.active AS entity_active,",
      "  a.agency_id,",
      "  a.agency_name,",
      "  a.public_name AS agency_public_name,",
      "  a.submit_plan AS agency_submits_plan,",
      "  s.service_id,",
      "  s.service_name,",
      "  s.service_type,",
      "  s.active AS service_active,",
      "  pes.is_primary",
      "FROM reference.plan_entity pe",
      "JOIN reference.agency a ON a.agency_id = pe.parent_agency_id",
      "LEFT JOIN reference.plan_entity_service pes ON pes.entity_id = pe.entity_id",
      "LEFT JOIN reference.service s ON s.service_id = pes.service_id"
    )
  )
  DBI::dbExecute(
    connection,
    paste(
      "CREATE TABLE IF NOT EXISTS access.user_entity_access (",
      "entity_access_id serial PRIMARY KEY,",
      "user_id integer NOT NULL REFERENCES access.\"user\"(user_id) ON DELETE CASCADE,",
      "entity_id integer NOT NULL REFERENCES reference.plan_entity(entity_id) ON DELETE CASCADE,",
      "agency_id varchar(20) REFERENCES reference.agency(agency_id),",
      "service_id varchar(20) REFERENCES reference.service(service_id),",
      "agency_role varchar(30),",
      "agency_roles text,",
      "access_level varchar(20),",
      "budget_access boolean NOT NULL DEFAULT false,",
      "performance_plan_access boolean NOT NULL DEFAULT true,",
      "created_at timestamptz NOT NULL DEFAULT now(),",
      "updated_at timestamptz NOT NULL DEFAULT now(),",
      "modified_by integer REFERENCES access.\"user\"(user_id),",
      "UNIQUE (user_id, entity_id)",
      ")"
    )
  )
  DBI::dbExecute(connection, "ALTER TABLE access.user_entity_access ADD COLUMN IF NOT EXISTS adaptive_planning boolean NOT NULL DEFAULT false")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_user_entity_access_entity ON access.user_entity_access(entity_id)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_user_entity_access_user ON access.user_entity_access(user_id)")
  DBI::dbExecute(
    connection,
    paste(
      "CREATE TABLE IF NOT EXISTS access.user_login_session (",
      "session_id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,",
      "user_id integer NOT NULL REFERENCES access.\"user\"(user_id) ON DELETE CASCADE,",
      "token_hash varchar(128) NOT NULL UNIQUE,",
      "expires_at timestamptz NOT NULL,",
      "last_seen_at timestamptz,",
      "revoked_at timestamptz,",
      "created_at timestamptz NOT NULL DEFAULT now()",
      ")"
    )
  )
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS user_login_session_user_idx ON access.user_login_session (user_id)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS user_login_session_active_idx ON access.user_login_session (token_hash, expires_at) WHERE revoked_at IS NULL")
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
      "created_at timestamptz NOT NULL DEFAULT now(),",
      "updated_at timestamptz NOT NULL DEFAULT now(),",
      "modified_by integer REFERENCES access.\"user\"(user_id)",
      ")"
    )
  )
  # Backfills these two columns onto databases where this table already
  # existed before they were added above -- CREATE TABLE IF NOT EXISTS alone
  # is a no-op against an existing table, so without this an
  # already-provisioned database (e.g. production) would never pick them up.
  DBI::dbExecute(connection, "ALTER TABLE workflow.plan_approval_stamp ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now()")
  DBI::dbExecute(connection, "ALTER TABLE workflow.plan_approval_stamp ADD COLUMN IF NOT EXISTS modified_by integer REFERENCES access.\"user\"(user_id)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_plan_approval_stamp_plan_stage ON workflow.plan_approval_stamp(plan_id, approval_stage, approved_at DESC)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_plan_approval_stamp_modified_by ON workflow.plan_approval_stamp(modified_by)")
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
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_entity_role_assignment_modified_by ON workflow.entity_role_assignment(modified_by)")
  # This reconciliation backfilled access.user_entity_access from
  # access.user_agency_access and the legacy workflow.entity_role_assignment
  # import table -- a one-time migration from when entity-level access was
  # introduced, not a perpetual sync. Re-running it on every restart was
  # deleting entity access for reviewer/DM/CA users every time, and
  # silently re-inserting entity access rows admins had deleted through the
  # Team & Roles UI, as long as the underlying agency-level access or the
  # stale legacy assignment row still existed. Gated to run once.
  if (!seed_already_applied(connection, "entity_access_legacy_reconciliation")) {
    DBI::dbExecute(
      connection,
      paste(
        "DELETE FROM access.user_entity_access uea",
        "USING workflow.entity_role_assignment era",
        "WHERE uea.entity_id = era.entity_id",
        "AND uea.user_id IN (era.reviewer_user_id, era.deputy_mayor_user_id, era.ca_office_user_id)",
        "AND uea.user_id IS DISTINCT FROM era.submitter_user_id"
      )
    )
    DBI::dbExecute(
      connection,
      paste(
        "INSERT INTO access.user_entity_access",
        "(user_id, entity_id, agency_id, service_id, agency_role, agency_roles, access_level, budget_access, adaptive_planning, performance_plan_access)",
        "SELECT DISTINCT source.user_id, source.entity_id, source.agency_id, source.service_id, source.agency_role, source.agency_roles,",
        "source.access_level, source.budget_access, source.adaptive_planning, source.performance_plan_access",
        "FROM (",
        "  SELECT era.submitter_user_id AS user_id, era.entity_id, era.agency_id, NULL::varchar(20) AS service_id,",
        "    'Agency Staff'::varchar(30) AS agency_role, 'Agency Staff'::text AS agency_roles,",
        "    'Submit'::varchar(20) AS access_level, false AS budget_access, false AS adaptive_planning, true AS performance_plan_access",
        "  FROM workflow.entity_role_assignment era",
        "  WHERE era.submitter_user_id IS NOT NULL AND era.entity_id IS NOT NULL",
        "  UNION ALL",
        "  SELECT uaa.user_id, pes.entity_id, uaa.agency_id, uaa.service_id, uaa.agency_role,",
        "    COALESCE(NULLIF(uaa.agency_roles, ''), uaa.agency_role) AS agency_roles,",
        "    uaa.access_level, uaa.budget_access, false AS adaptive_planning, uaa.performance_plan_access",
        "  FROM access.user_agency_access uaa",
        "  JOIN reference.plan_entity_service pes ON pes.service_id = uaa.service_id",
        "  JOIN reference.plan_entity pe ON pe.entity_id = pes.entity_id",
        "  JOIN (",
        "    SELECT pes2.service_id, COUNT(DISTINCT pe2.entity_id)::integer AS entity_count",
        "    FROM reference.plan_entity_service pes2",
        "    JOIN reference.plan_entity pe2 ON pe2.entity_id = pes2.entity_id",
        "    WHERE pe2.active AND pe2.has_own_plan",
        "    GROUP BY pes2.service_id",
        "  ) counts ON counts.service_id = uaa.service_id AND counts.entity_count = 1",
        "  WHERE pe.active AND pe.has_own_plan AND uaa.service_id IS NOT NULL",
        "  UNION ALL",
        "  SELECT uaa.user_id, pe.entity_id, uaa.agency_id, NULL::varchar(20) AS service_id, uaa.agency_role,",
        "    COALESCE(NULLIF(uaa.agency_roles, ''), uaa.agency_role) AS agency_roles,",
        "    uaa.access_level, uaa.budget_access, false AS adaptive_planning, uaa.performance_plan_access",
        "  FROM access.user_agency_access uaa",
        "  JOIN reference.plan_entity pe ON pe.parent_agency_id = uaa.agency_id AND pe.entity_type = 'Agency'",
        "  WHERE (uaa.service_id IS NULL OR trim(uaa.service_id) = '')",
        "    AND pe.active AND pe.has_own_plan",
        "    AND NOT EXISTS (",
        "      SELECT 1",
        "      FROM access.user_entity_access existing",
        "      JOIN reference.plan_entity existing_entity ON existing_entity.entity_id = existing.entity_id",
        "      WHERE existing.user_id = uaa.user_id",
        "        AND existing_entity.parent_agency_id = uaa.agency_id",
        "        AND existing_entity.entity_type <> 'Agency'",
        "    )",
        "    AND NOT EXISTS (",
        "      SELECT 1",
        "      FROM access.user_agency_access specific_uaa",
        "      JOIN reference.plan_entity_service specific_pes ON specific_pes.service_id = specific_uaa.service_id",
        "      JOIN reference.plan_entity specific_entity ON specific_entity.entity_id = specific_pes.entity_id",
        "      JOIN (",
        "        SELECT pes3.service_id, COUNT(DISTINCT pe3.entity_id)::integer AS entity_count",
        "        FROM reference.plan_entity_service pes3",
        "        JOIN reference.plan_entity pe3 ON pe3.entity_id = pes3.entity_id",
        "        WHERE pe3.active AND pe3.has_own_plan",
        "        GROUP BY pes3.service_id",
        "      ) specific_counts ON specific_counts.service_id = specific_uaa.service_id AND specific_counts.entity_count = 1",
        "      WHERE specific_uaa.user_id = uaa.user_id",
        "        AND specific_uaa.agency_id = uaa.agency_id",
        "        AND specific_uaa.service_id IS NOT NULL",
        "        AND specific_entity.parent_agency_id = uaa.agency_id",
        "        AND specific_entity.entity_type <> 'Agency'",
        "    )",
        ") source",
        "JOIN access.\"user\" u ON u.user_id = source.user_id AND u.active",
        "WHERE source.user_id IS NOT NULL",
        "ON CONFLICT (user_id, entity_id) DO NOTHING"
      )
    )
    mark_seed_applied(connection, "entity_access_legacy_reconciliation")
  }
  apply_user_entity_access_seed_once(connection)
  apply_agency_budget_analyst_seed_once(connection)
  apply_change_mapping_by_created_date_once(connection)
  apply_percent_value_scale_backfill_once(connection)
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
      "status varchar(30) NOT NULL DEFAULT 'New',",
      "assigned_admin_id integer REFERENCES access.\"user\"(user_id),",
      "created_at timestamptz NOT NULL DEFAULT now(),",
      "updated_at timestamptz NOT NULL DEFAULT now(),",
      "modified_by text",
      ")"
    )
  )
  DBI::dbExecute(connection, "ALTER TABLE application.feedback_request ADD COLUMN IF NOT EXISTS assigned_admin_id integer REFERENCES access.\"user\"(user_id)")
  DBI::dbExecute(connection, "ALTER TABLE application.feedback_request ALTER COLUMN status SET DEFAULT 'New'")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_feedback_request_status ON application.feedback_request(status, priority, category)")

  # Current Level of Service (CLS) budget requests. Mirrors the CLS_REQUEST /
  # CLS_REQUEST_LINE / CLS_REQUEST_POSITION spec, translated to Postgres and
  # placed in the budget schema alongside the other plan_service-linked tables.
  DBI::dbExecute(
    connection,
    paste(
      "CREATE TABLE IF NOT EXISTS budget.cls_request (",
      "cls_id serial PRIMARY KEY,",
      "plan_service_id integer NOT NULL REFERENCES performance.plan_service(plan_service_id),",
      "request_name varchar(500) NOT NULL,",
      "request_type varchar(100),",
      "request_amount numeric(18,2),",
      "one_time boolean NOT NULL DEFAULT false,",
      "overall_summary text,",
      "status varchar(30) NOT NULL DEFAULT 'In Progress',",
      "amount_next_fy numeric(18,2),",
      "amount_2next_fy numeric(18,2),",
      "created_at timestamptz NOT NULL DEFAULT now(),",
      "updated_at timestamptz NOT NULL DEFAULT now(),",
      "modified_by integer REFERENCES access.user(user_id)",
      ")"
    )
  )
  # `status` is the single source of truth for where a request sits in the
  # workflow. It replaced the target schema's `completed` BIT, which could only
  # express two of the six states the workflow needs.
  DBI::dbExecute(connection, "ALTER TABLE budget.cls_request ADD COLUMN IF NOT EXISTS status varchar(30) NOT NULL DEFAULT 'In Progress'")
  if (column_exists(connection, "budget", "cls_request", "completed")) {
    DBI::dbExecute(
      connection,
      paste(
        "UPDATE budget.cls_request SET status = CASE WHEN completed THEN 'BBMR Review' ELSE 'In Progress' END",
        "WHERE status IS NULL OR status NOT IN ('In Progress','Agency Review','BBMR Review','Approved','Denied','Partially Approved')"
      )
    )
    DBI::dbExecute(connection, "ALTER TABLE budget.cls_request DROP COLUMN completed")
  }
  # Retired: `justified` was an early validation flag with no UI and no meaning
  # now that gaps are computed from the line items.
  DBI::dbExecute(connection, "ALTER TABLE budget.cls_request DROP COLUMN IF EXISTS justified")
  # modified_by holds the user id; the display name is resolved from
  # access.user.full_name at render time rather than copied in here.
  retype_modified_by_to_user_id(connection, "budget", "cls_request", "modified_by")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_cls_request_plan_service ON budget.cls_request(plan_service_id)")
  DBI::dbExecute(
    connection,
    paste(
      "CREATE TABLE IF NOT EXISTS budget.cls_request_line (",
      "line_id serial PRIMARY KEY,",
      "cls_id integer NOT NULL REFERENCES budget.cls_request(cls_id) ON DELETE CASCADE,",
      "object_category varchar(200),",
      "spend_category varchar(200),",
      "amount numeric(18,2),",
      "justification text,",
      "sort_order integer NOT NULL DEFAULT 0",
      ")"
    )
  )
  DBI::dbExecute(connection, "ALTER TABLE budget.cls_request_line ADD COLUMN IF NOT EXISTS spend_category varchar(200)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_cls_request_line_cls ON budget.cls_request_line(cls_id)")
  DBI::dbExecute(
    connection,
    paste(
      "CREATE TABLE IF NOT EXISTS budget.cls_request_position (",
      "pos_id serial PRIMARY KEY,",
      "cls_id integer NOT NULL REFERENCES budget.cls_request(cls_id) ON DELETE CASCADE,",
      "classification varchar(200) NOT NULL,",
      "position_count integer NOT NULL DEFAULT 0,",
      "estimated_salary numeric(18,2),",
      "justification text,",
      "explanation text",
      ")"
    )
  )
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_cls_request_position_cls ON budget.cls_request_position(cls_id)")
  DBI::dbExecute(
    connection,
    paste(
      "CREATE TABLE IF NOT EXISTS budget.cls_review (",
      "review_id serial PRIMARY KEY,",
      "cls_id integer NOT NULL UNIQUE REFERENCES budget.cls_request(cls_id) ON DELETE CASCADE,",
      "analyst_notes text,",
      "analyst_approval varchar(20),",
      "bbmr_approval varchar(20),",
      "reviewed_by integer REFERENCES access.user(user_id),",
      "updated_at timestamptz NOT NULL DEFAULT now()",
      ")"
    )
  )
  # Retired: the evaluation score came off the CLS Review page, so the column had
  # no writer left.
  DBI::dbExecute(connection, "ALTER TABLE budget.cls_review DROP COLUMN IF EXISTS evaluation_score")
  retype_modified_by_to_user_id(connection, "budget", "cls_review", "reviewed_by")
  # USER_ROLE.assigned_by from the target schema: which admin granted the role.
  DBI::dbExecute(connection, "ALTER TABLE access.user_role ADD COLUMN IF NOT EXISTS assigned_by integer REFERENCES access.user(user_id)")
  # AgencyApprover is retired (AgencySubmitter is the approving agency role).
  # target_schema.sql only runs on a fresh database, so the CHECK constraint on
  # an already-provisioned one has to be replaced here or it keeps accepting a
  # role nothing can assign. Any surviving row is moved over first so the new
  # constraint can be validated.
  DBI::dbExecute(connection, "UPDATE access.user_role SET app_role = 'AgencySubmitter' WHERE app_role = 'AgencyApprover'")
  DBI::dbExecute(connection, "ALTER TABLE access.user_role DROP CONSTRAINT IF EXISTS user_role_app_role_check")
  DBI::dbExecute(
    connection,
    paste(
      "ALTER TABLE access.user_role ADD CONSTRAINT user_role_app_role_check CHECK (app_role IN (",
      "'AgencySubmitter', 'AgencyWriter', 'OPIReviewer', 'BBMRReviewer',",
      "'DeputyMayor', 'CAOffice', 'SystemAdmin', 'AgencyViewer'))"
    )
  )

  # Foreign-key columns with no covering index (found via a live pg_constraint
  # audit). target_schema.sql only runs on a fresh database, so already-
  # provisioned databases (local Docker, Fly Postgres) need these applied here.
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_user_entity_access_agency_id ON access.user_entity_access(agency_id)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_user_entity_access_service_id ON access.user_entity_access(service_id)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_user_entity_access_modified_by ON access.user_entity_access(modified_by)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_user_role_pillar_id ON access.user_role(pillar_id)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_plan_amendment_initiated_by ON amendment.plan_amendment(initiated_by)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_feedback_request_assigned_admin_id ON application.feedback_request(assigned_admin_id)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_coa_request_reviewed_by ON budget.coa_request(reviewed_by)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_slide_deck_export_generated_by ON output.slide_deck_export(generated_by)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_measure_actuals_reported_by ON performance.measure_actuals(reported_by)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_performance_measure_pillar_goal_id ON performance.performance_measure(pillar_goal_id)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_plan_pillar_alignment_pillar_id ON performance.plan_pillar_alignment(pillar_id)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_pm_service_reassignment_changed_by ON performance.pm_service_reassignment(changed_by)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_pm_service_reassignment_cycle_id ON performance.pm_service_reassignment(cycle_id)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_pm_service_reassignment_measure_id ON performance.pm_service_reassignment(measure_id)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_pm_service_reassignment_new_service_id ON performance.pm_service_reassignment(new_service_id)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_pm_service_reassignment_old_service_id ON performance.pm_service_reassignment(old_service_id)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_service_goal_link_agency_goal_id ON performance.service_goal_link(agency_goal_id)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_service_goal_link_initiative_id ON performance.service_goal_link(initiative_id)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_agency_plan_assigned_reviewer ON planning.agency_plan(assigned_reviewer)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_plan_cycle_created_by ON planning.plan_cycle(created_by)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_measure_review_modified_by ON review.measure_review(modified_by)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_entity_role_assignment_ca_office_user_id ON workflow.entity_role_assignment(ca_office_user_id)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_entity_role_assignment_deputy_mayor_user_id ON workflow.entity_role_assignment(deputy_mayor_user_id)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_entity_role_assignment_modified_by ON workflow.entity_role_assignment(modified_by)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_entity_role_assignment_reviewer_user_id ON workflow.entity_role_assignment(reviewer_user_id)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_plan_approval_stamp_added_by ON workflow.plan_approval_stamp(added_by)")
  DBI::dbExecute(connection, "CREATE INDEX IF NOT EXISTS idx_plan_approval_stamp_approved_by ON workflow.plan_approval_stamp(approved_by)")
  # Enforce one performance role per user. Every code path that writes
  # access.user_role already checks for an existing row first (see
  # save_team_role_assignment, save_entity_team_role_assignment,
  # apply_user_entity_access_seed), so this should never fire in normal
  # operation -- it's a safety net against a bad import or manual edit
  # silently giving someone two conflicting roles.
  DBI::dbExecute(
    connection,
    paste(
      "DO $$",
      "BEGIN",
      "  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_role_user_id_key') THEN",
      "    ALTER TABLE access.user_role ADD CONSTRAINT user_role_user_id_key UNIQUE (user_id);",
      "  END IF;",
      "END $$;"
    )
  )
  invisible(TRUE)
}

load_app_data <- function(connection) {
  query <- function(sql) DBI::dbGetQuery(connection, sql)
  data <- list(
    reference_agency = query(
      "SELECT agency_id, agency_name, public_name, deputy_mayor_pillar, submit_plan, budget_analyst FROM reference.agency WHERE active ORDER BY COALESCE(public_name, agency_name), agency_name"
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
      "SELECT entity_id, parent_agency_id, public_name, entity_type, has_own_plan, active FROM reference.plan_entity WHERE active AND has_own_plan ORDER BY public_name"
    ),
    reference_access_entity = query(
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
    access_user_entity_access = query(
      paste(
        "SELECT uea.entity_access_id, ('entity:' || uea.entity_access_id::text) AS access_id,",
        "u.user_id, uea.entity_id, pe.public_name, pe.entity_type, uea.agency_id, uea.service_id,",
        "u.full_name, u.email, uea.agency_role, COALESCE(NULLIF(uea.agency_roles, ''), uea.agency_role) AS agency_roles,",
        "uea.access_level, uea.budget_access, uea.adaptive_planning, uea.performance_plan_access",
        "FROM access.user_entity_access uea",
        "JOIN access.\"user\" u ON u.user_id = uea.user_id",
        "JOIN reference.plan_entity pe ON pe.entity_id = uea.entity_id",
        "WHERE u.active AND pe.active AND pe.has_own_plan ORDER BY pe.public_name, u.full_name"
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
    ),
    budget_cls_request = query(
      paste(
        "SELECT cr.cls_id, cr.plan_service_id, cr.request_name, cr.request_type, cr.request_amount,",
        "cr.one_time, cr.overall_summary, cr.status, cr.amount_next_fy, cr.amount_2next_fy,",
        "cr.created_at AT TIME ZONE 'America/New_York' AS created_at,",
        "cr.updated_at AT TIME ZONE 'America/New_York' AS updated_at,",
        "cr.modified_by, modifier.full_name AS modified_by_name,",
        "ps.plan_id, ps.service_id, agp.agency_id",
        "FROM budget.cls_request cr",
        "JOIN performance.plan_service ps ON ps.plan_service_id = cr.plan_service_id",
        "LEFT JOIN planning.agency_plan agp ON agp.plan_id = ps.plan_id",
        "LEFT JOIN access.\"user\" modifier ON modifier.user_id = cr.modified_by",
        "ORDER BY cr.created_at DESC, cr.cls_id DESC"
      )
    ),
    budget_cls_request_line = query(
      paste(
        "SELECT line_id, cls_id, object_category, spend_category, amount, justification, sort_order",
        "FROM budget.cls_request_line ORDER BY cls_id, sort_order, line_id"
      )
    ),
    budget_cls_request_position = query(
      paste(
        "SELECT pos_id, cls_id, classification, position_count, estimated_salary, justification, explanation",
        "FROM budget.cls_request_position ORDER BY cls_id, pos_id"
      )
    ),
    budget_cls_review = query(
      paste(
        "SELECT rv.review_id, rv.cls_id, rv.analyst_notes, rv.analyst_approval, rv.bbmr_approval,",
        "rv.reviewed_by, reviewer.full_name AS reviewed_by_name,",
        "rv.updated_at AT TIME ZONE 'America/New_York' AS updated_at",
        "FROM budget.cls_review rv",
        "LEFT JOIN access.\"user\" reviewer ON reviewer.user_id = rv.reviewed_by"
      )
    )
  )

  action_plan_initiatives <- query(
    "SELECT pillar_goal_id, initiative_title, sort_order FROM reference.action_plan_initiative ORDER BY pillar_goal_id, sort_order"
  )
  # Real Action Plan measures: any performance_measure marked Citywide
  # (is_city = TRUE), via the measure editor's admin-only "Citywide
  # measure"/"Action Plan pillar" fields (see measure_review_app_roles in
  # app.R). Replaces the old reference.action_plan_measure table, which
  # held dummy data generated by another bot, not real measures (found
  # 2026-07-27; the table itself is dropped, see
  # database/schema/target_schema.sql). Latest actual/target uses the
  # same "last complete year / this year's target" snapshot shown on the
  # Measures page's summary column, for consistency. Exposed as its own
  # top-level data$city_measures (not scoped to a pillar -- a measure can
  # be marked Citywide before a pillar is assigned, and the Action Plan
  # Measures admin page needs to surface those too) and also used below,
  # filtered per pillar, for each pillar's modal.
  city_measure_target_fy <- current_fiscal_year()
  city_measure_actual_fy <- city_measure_target_fy - 1L
  data$city_measures <- query(
    sprintf(
      paste(
        "SELECT pm.measure_id, pm.pillar_id, pm.pillar_goal_id, pm.title, pm.desired_direction,",
        "pm.display_unit, pm.format_type, pm.approval_status, pm.agency_id,",
        "a.agency_name, COALESCE(mel.public_name, a.public_name) AS agency_public_name,",
        "p.pillar_name, pg.goal_code AS pillar_goal_code, pg.goal_title AS pillar_goal_title,",
        "actual_row.annual_actual AS current_value, target_row.target_value AS target_value",
        "FROM performance.performance_measure pm",
        "JOIN reference.agency a ON a.agency_id = pm.agency_id",
        "LEFT JOIN reference.pillar p ON p.pillar_id = pm.pillar_id",
        "LEFT JOIN reference.pillar_goal pg ON pg.pillar_goal_id = pm.pillar_goal_id",
        "LEFT JOIN performance.measure_actuals actual_row ON actual_row.measure_id = pm.measure_id AND actual_row.fiscal_year = %d",
        "LEFT JOIN performance.measure_actuals target_row ON target_row.measure_id = pm.measure_id AND target_row.fiscal_year = %d",
        # A Citywide measure's entity_link (if any) names the specific
        # mayoral service/quasi-agency that actually owns it -- e.g. OPI,
        # not just the shared parent agency (Mayor's Office) every mayoral
        # suboffice measure is otherwise indistinguishable under. Pick one
        # deterministically since a measure could in principle have more
        # than one link row.
        "LEFT JOIN LATERAL (",
        "  SELECT mel.public_name FROM performance.measure_entity_link mel",
        "  WHERE mel.measure_id = pm.measure_id ORDER BY mel.updated_at DESC LIMIT 1",
        ") mel ON TRUE",
        "WHERE pm.is_city AND pm.active",
        "ORDER BY p.pillar_name NULLS FIRST, pm.title"
      ),
      city_measure_actual_fy, city_measure_target_fy
    )
  )
  data$strategic_plan <- lapply(seq_len(nrow(data$reference_pillar)), function(index) {
    pillar <- data$reference_pillar[index, , drop = FALSE]
    pillar_goals <- data$reference_pillar_goal[data$reference_pillar_goal$pillar_id == pillar$pillar_id, , drop = FALSE]
    goals <- lapply(seq_len(nrow(pillar_goals)), function(goal_index) {
      goal <- pillar_goals[goal_index, , drop = FALSE]
      initiatives <- action_plan_initiatives$initiative_title[action_plan_initiatives$pillar_goal_id == goal$pillar_goal_id]
      list(code = goal$goal_code[[1]], title = goal$goal_title[[1]], lead = goal$goal_lead[[1]], initiatives = initiatives)
    })
    pillar_measures <- data$city_measures[!is.na(data$city_measures$pillar_id) & data$city_measures$pillar_id == pillar$pillar_id, , drop = FALSE]
    metrics <- lapply(seq_len(nrow(pillar_measures)), function(measure_index) {
      measure <- pillar_measures[measure_index, , drop = FALSE]
      list(
        measure_id = measure$measure_id[[1]],
        name = measure$title[[1]],
        current = as.numeric(measure$current_value[[1]]),
        target = as.numeric(measure$target_value[[1]]),
        direction = measure$desired_direction[[1]],
        unit = if (is.na(measure$display_unit[[1]])) NULL else measure$display_unit[[1]],
        format_type = measure$format_type[[1]]
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
  valid_status <- c("New", "Open", "In Review", "Complete", "Archived")
  category <- as.character(category %||% "Uncategorized")
  priority <- as.character(priority %||% "Unassigned")
  status <- as.character(status %||% "New")
  assigned_admin_id <- suppressWarnings(as.integer(assigned_admin_id %||% NA_integer_))
  if (!category %in% valid_category) category <- "Uncategorized"
  if (!priority %in% valid_priority) priority <- "Unassigned"
  if (!status %in% valid_status) status <- "New"
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

# ---- CLS (Current Level of Service) budget requests -------------------------

# PLACEHOLDER DATA. Spend categories are a chart-of-accounts concept (the SC6xxx
# codes in the budget system). These stand-ins let the field be used and tested;
# replace them with the real COA spend-category list when it is available.
cls_spend_category_choices <- c(
  "SC6001 - Professional Services",
  "SC6002 - Consultants",
  "SC6003 - Non-Operating Costs (NOC)",
  "SC6004 - Subcontractors",
  "SC6005 - Software and Subscriptions",
  "SC6006 - Fuel and Lubricants",
  "SC6007 - Building Maintenance",
  "SC6008 - Fleet Parts and Repairs",
  "SC6009 - Training and Travel",
  "SC6010 - Office Supplies"
)

cls_object_choices <- c(
  "Transfers",
  "Salaries",
  "Other Personnel Costs",
  "Contractual Services",
  "Materials and Supplies",
  "Minor Equipment (<$5k)",
  "Major Equipment (>$5k)",
  "Grants, Subsidies, and Contributions",
  "Debt Service"
)

cls_request_type_choices <- c(
  "Annualization of Cost",
  "Capital Project",
  "Cyclical Cost",
  "Debt Service",
  "Extraordinary Inflation",
  "Grant Match",
  "Mandated Cost",
  "Remove One-Time Item"
)

# Reference content for the request-type information icon on the CLS request page.
cls_adjustment_type_guidance <- list(
  list("Annualization of Cost", "Provide full-year funding for programs funded for a partial year in Fiscal 2027.", "Fiscal 2027 includes a partial year of funding for a new lease that needs to be annualized in Fiscal 2028."),
  list("Capital Project", "Operating cost for a capital project that will come online in Fiscal 2028.", "A facility is being renovated and will reopen in Fiscal 2028. The CLS adjustment will include costs for the newly renovated facility."),
  list("Cyclical Cost", "Service costs due to the nature of the service.", "Adjustments for election costs."),
  list("Debt Service", "Adjustment based on projected changes to debt service in Fiscal 2028.", "An agency's budget includes debt funding for a conditional purchase agreement; the CLS adjustment will update the budget based on the debt schedule."),
  list("Extraordinary Inflation", "Expenditure or contract that is anticipated to grow faster than the standard CLS inflationary adjustment.", "Specific expenditures anticipated to grow by more than 5% driven by inflation."),
  list("Grant Match", "Local matching funds associated with state or federal grants; does not include funding to replace loss of grant funding.", "The local match for a 3-year grant grows each year; the CLS adjustment updates the local match for Fiscal 2028."),
  list("Mandated Cost", "Increased cost driven either by legal or contractual mandate.", "Updates to agency budgets to reflect operating costs from recent Council legislation."),
  list("Remove One-Time Item", "Items included in the Fiscal 2027 budget that were only intended for one year for a specific purpose.", "The Fiscal 2027 budget included funding to purchase new equipment; the CLS adjustment will remove the one-time funding.")
)

nullable_numeric_param <- function(value) {
  value <- suppressWarnings(as.numeric(value))
  if (length(value) != 1 || is.na(value)) NA_real_ else value
}

nullable_integer_param <- function(value) {
  value <- suppressWarnings(as.integer(value))
  if (length(value) != 1 || is.na(value)) NA_integer_ else value
}

create_cls_request <- function(connection, plan_service_id, request_name, request_type = NULL,
                               request_amount = NULL, one_time = FALSE, overall_summary = NULL,
                               amount_next_fy = NULL, amount_2next_fy = NULL, modified_by = NULL) {
  plan_service_id <- as.integer(plan_service_id)
  if (is.na(plan_service_id)) stop("Choose a service for this request.")
  request_name <- trimws(as.character(request_name %||% ""))
  if (!nzchar(request_name)) stop("Add a request name.")
  service_rows <- DBI::dbGetQuery(
    connection,
    "SELECT plan_service_id FROM performance.plan_service WHERE plan_service_id = $1",
    params = list(plan_service_id)
  )
  if (!nrow(service_rows)) stop("That service is no longer available.")
  request_type <- as.character(request_type %||% "")
  if (!nzchar(request_type)) request_type <- NA_character_
  DBI::dbGetQuery(
    connection,
    paste(
      "INSERT INTO budget.cls_request",
      "(plan_service_id, request_name, request_type, request_amount, one_time, overall_summary, amount_next_fy, amount_2next_fy, modified_by)",
      "VALUES ($1::integer, $2::text, $3::text, $4::numeric, $5::boolean, NULLIF($6::text, ''), $7::numeric, $8::numeric, $9::integer)",
      "RETURNING cls_id"
    ),
    params = list(
      plan_service_id, request_name, request_type,
      nullable_numeric_param(request_amount), isTRUE(one_time),
      as.character(overall_summary %||% ""),
      nullable_numeric_param(amount_next_fy), nullable_numeric_param(amount_2next_fy),
      nullable_integer_param(modified_by)
    )
  )$cls_id[[1]]
}

update_cls_request <- function(connection, cls_id, request_name, request_type = NULL,
                               request_amount = NULL, one_time = FALSE, overall_summary = NULL,
                               amount_next_fy = NULL, amount_2next_fy = NULL,
                               plan_service_id = NULL, modified_by = NULL) {
  cls_id <- as.integer(cls_id)
  if (is.na(cls_id)) stop("Choose a valid request.")
  request_name <- trimws(as.character(request_name %||% ""))
  if (!nzchar(request_name)) stop("Add a request name.")
  request_type <- as.character(request_type %||% "")
  if (!nzchar(request_type)) request_type <- NA_character_
  plan_service_id <- suppressWarnings(as.integer(plan_service_id %||% NA_integer_))
  if (!is.na(plan_service_id)) {
    service_rows <- DBI::dbGetQuery(
      connection,
      "SELECT plan_service_id FROM performance.plan_service WHERE plan_service_id = $1",
      params = list(plan_service_id)
    )
    if (!nrow(service_rows)) stop("That service is no longer available.")
  }
  # `status` is managed by the hand-off actions, not this edit form, so it is
  # intentionally omitted from the SET clause.
  DBI::dbExecute(
    connection,
    paste(
      "UPDATE budget.cls_request SET",
      "request_name = $2::text, request_type = $3::text, request_amount = $4::numeric,",
      "one_time = $5::boolean, overall_summary = NULLIF($6::text, ''),",
      "amount_next_fy = $7::numeric, amount_2next_fy = $8::numeric,",
      "plan_service_id = COALESCE($9::integer, plan_service_id),",
      "modified_by = COALESCE($10::integer, modified_by),",
      "updated_at = now() WHERE cls_id = $1"
    ),
    params = list(
      cls_id, request_name, request_type, nullable_numeric_param(request_amount),
      isTRUE(one_time), as.character(overall_summary %||% ""),
      nullable_numeric_param(amount_next_fy), nullable_numeric_param(amount_2next_fy),
      if (is.na(plan_service_id)) NA_integer_ else plan_service_id,
      nullable_integer_param(modified_by)
    )
  )
  invisible(cls_id)
}

cls_status_choices <- c(
  "In Progress",
  "Agency Review",
  "BBMR Review",
  "Approved",
  "Partially Approved",
  "Denied"
)

# "Complete" now means only "has left the agency for BBMR" - derived from status,
# which replaced the target schema's `completed` BIT.
cls_status_is_complete <- function(status) {
  as.character(status) %in% c("BBMR Review", "Approved", "Partially Approved", "Denied")
}

# Advance every CLS request on a plan to a new workflow status.
set_plan_cls_status <- function(connection, plan_id, status, modified_by = NULL, only_from = NULL) {
  plan_id <- suppressWarnings(as.integer(plan_id))
  if (is.na(plan_id)) stop("Choose a valid plan.")
  status <- as.character(status %||% "")
  if (!status %in% cls_status_choices) stop("Choose a valid request status.")
  sql <- paste(
    "UPDATE budget.cls_request SET status = $2::varchar, updated_at = now(),",
    "modified_by = COALESCE($3::integer, modified_by)",
    "WHERE plan_service_id IN (SELECT plan_service_id FROM performance.plan_service WHERE plan_id = $1)"
  )
  params <- list(plan_id, status, nullable_integer_param(modified_by))
  if (length(only_from)) {
    placeholders <- paste0("$", seq_along(only_from) + length(params), "::varchar", collapse = ", ")
    sql <- paste0(sql, " AND status IN (", placeholders, ")")
    params <- c(params, as.list(as.character(only_from)))
  }
  DBI::dbExecute(connection, sql, params = params)
  invisible(plan_id)
}

# Set the status of a single request (used by the BBMR decision).
set_cls_status <- function(connection, cls_id, status, modified_by = NULL) {
  cls_id <- suppressWarnings(as.integer(cls_id))
  if (is.na(cls_id)) stop("Choose a valid request.")
  status <- as.character(status %||% "")
  if (!status %in% cls_status_choices) stop("Choose a valid request status.")
  DBI::dbExecute(
    connection,
    paste(
      "UPDATE budget.cls_request SET status = $2::varchar, updated_at = now(),",
      "modified_by = COALESCE($3::integer, modified_by) WHERE cls_id = $1"
    ),
    params = list(cls_id, status, nullable_integer_param(modified_by))
  )
  invisible(cls_id)
}

mark_plan_cls_complete <- function(connection, plan_id, modified_by = NULL) {
  set_plan_cls_status(connection, plan_id, "BBMR Review", modified_by)
}

# BBMR review record for a CLS request — kept separate so the submitted request
# data is retained unchanged while reviewers add their evaluation.
save_cls_review <- function(connection, cls_id, analyst_notes = NULL,
                            analyst_approval = NULL, bbmr_approval = NULL, reviewed_by = NULL) {
  cls_id <- as.integer(cls_id)
  if (is.na(cls_id)) stop("Choose a valid request.")
  bbmr_approval <- as.character(bbmr_approval %||% "")
  if (!bbmr_approval %in% c("Approved", "Partial", "Denied")) bbmr_approval <- NA_character_
  analyst_approval <- as.character(analyst_approval %||% "")
  if (!analyst_approval %in% c("Approved", "Partial", "Denied")) analyst_approval <- NA_character_
  DBI::dbExecute(
    connection,
    paste(
      "INSERT INTO budget.cls_review (cls_id, analyst_notes, analyst_approval, bbmr_approval, reviewed_by, updated_at)",
      "VALUES ($1::integer, NULLIF($2::text, ''), $3::text, $4::text, $5::integer, now())",
      "ON CONFLICT (cls_id) DO UPDATE SET",
      "analyst_notes = EXCLUDED.analyst_notes, analyst_approval = EXCLUDED.analyst_approval,",
      "bbmr_approval = EXCLUDED.bbmr_approval, reviewed_by = EXCLUDED.reviewed_by, updated_at = now()"
    ),
    params = list(cls_id, as.character(analyst_notes %||% ""), analyst_approval, bbmr_approval, nullable_integer_param(reviewed_by))
  )
  # A BBMR decision advances the request's workflow status.
  decided <- switch(
    as.character(bbmr_approval %||% ""),
    "Approved" = "Approved",
    "Partial" = "Partially Approved",
    "Denied" = "Denied",
    NULL
  )
  if (!is.null(decided)) {
    set_cls_status(connection, cls_id, decided, reviewed_by)
  }
  invisible(cls_id)
}

delete_cls_request <- function(connection, cls_id) {
  cls_id <- as.integer(cls_id)
  if (is.na(cls_id)) stop("Choose a valid request.")
  # Remove children explicitly rather than relying on ON DELETE CASCADE: the FK
  # cascade is only present on freshly created tables, and databases where the
  # CLS tables predate the cascade would otherwise block the delete.
  DBI::dbWithTransaction(connection, {
    DBI::dbExecute(connection, "DELETE FROM budget.cls_request_line WHERE cls_id = $1", params = list(cls_id))
    DBI::dbExecute(connection, "DELETE FROM budget.cls_request_position WHERE cls_id = $1", params = list(cls_id))
    DBI::dbExecute(connection, "DELETE FROM budget.cls_review WHERE cls_id = $1", params = list(cls_id))
    DBI::dbExecute(connection, "DELETE FROM budget.cls_request WHERE cls_id = $1", params = list(cls_id))
  })
  invisible(cls_id)
}

add_cls_request_line <- function(connection, cls_id, object_category = NULL, amount = NULL, justification = NULL,
                                 spend_category = NULL) {
  cls_id <- as.integer(cls_id)
  if (is.na(cls_id)) stop("Choose a valid request.")
  next_sort <- DBI::dbGetQuery(
    connection,
    "SELECT COALESCE(MAX(sort_order), 0) + 1 AS next_sort FROM budget.cls_request_line WHERE cls_id = $1",
    params = list(cls_id)
  )$next_sort[[1]]
  DBI::dbGetQuery(
    connection,
    paste(
      "INSERT INTO budget.cls_request_line (cls_id, object_category, spend_category, amount, justification, sort_order)",
      "VALUES ($1::integer, NULLIF($2::text, ''), NULLIF($3::text, ''), $4::numeric, NULLIF($5::text, ''), $6::integer)",
      "RETURNING line_id"
    ),
    params = list(cls_id, as.character(object_category %||% ""), as.character(spend_category %||% ""),
                  nullable_numeric_param(amount), as.character(justification %||% ""), as.integer(next_sort))
  )$line_id[[1]]
}

delete_cls_request_line <- function(connection, line_id) {
  line_id <- as.integer(line_id)
  if (is.na(line_id)) stop("Choose a valid line item.")
  DBI::dbExecute(connection, "DELETE FROM budget.cls_request_line WHERE line_id = $1", params = list(line_id))
  invisible(line_id)
}

add_cls_request_position <- function(connection, cls_id, classification, position_count = 0,
                                     estimated_salary = NULL, justification = NULL, explanation = NULL) {
  cls_id <- as.integer(cls_id)
  if (is.na(cls_id)) stop("Choose a valid request.")
  classification <- trimws(as.character(classification %||% ""))
  if (!nzchar(classification)) stop("Add a job classification.")
  position_count <- nullable_integer_param(position_count)
  if (is.na(position_count)) position_count <- 0L
  DBI::dbGetQuery(
    connection,
    paste(
      "INSERT INTO budget.cls_request_position (cls_id, classification, position_count, estimated_salary, justification, explanation)",
      "VALUES ($1::integer, $2::text, $3::integer, $4::numeric, NULLIF($5::text, ''), NULLIF($6::text, ''))",
      "RETURNING pos_id"
    ),
    params = list(cls_id, classification, position_count, nullable_numeric_param(estimated_salary), as.character(justification %||% ""), as.character(explanation %||% ""))
  )$pos_id[[1]]
}

delete_cls_request_position <- function(connection, pos_id) {
  pos_id <- as.integer(pos_id)
  if (is.na(pos_id)) stop("Choose a valid position request.")
  DBI::dbExecute(connection, "DELETE FROM budget.cls_request_position WHERE pos_id = $1", params = list(pos_id))
  invisible(pos_id)
}

# Baltimore's fiscal year runs July 1 - June 30, named by the calendar
# year it ends in (e.g. FY2027 = July 1, 2026 - June 30, 2027). Computed
# fresh from the real date (not tied to whichever planning cycle happens
# to be active) since the validated-measure lock below is meant to track
# the calendar, not the plan cycle. `today` is a parameter (not always
# Sys.Date() internally) so this is deterministically testable against a
# specific date rather than only ever reflecting whenever a test happens
# to run.
current_fiscal_year <- function(today = Sys.Date()) {
  calendar_year <- as.integer(format(today, "%Y"))
  fiscal_year_start <- as.Date(sprintf("%s-07-01", calendar_year))
  if (today >= fiscal_year_start) calendar_year + 1L else calendar_year
}

# July 1 of the calendar year before fiscal_year -- e.g. FY27 starts
# 2026-07-01.
fiscal_year_start_date <- function(fiscal_year) {
  as.Date(sprintf("%d-07-01", as.integer(fiscal_year) - 1L))
}

# "New" means established during the current fiscal year -- not "was
# ever marked New," which let a measure stay exempt from the recent-
# actual/next-target publish requirement forever after its first save.
# Only re-evaluates measures whose existing status is already New/blank;
# a real classification (Removed, Replaced, Modified) is left alone, since
# those track something other than "how old is this."
measure_change_mapping_for_date <- function(existing_mapping, created_date, today = Sys.Date()) {
  is_new_or_unset <- is.na(existing_mapping) || identical(existing_mapping, "New")
  if (!is_new_or_unset) return(existing_mapping)
  if (is.na(created_date)) return("New")
  if (as.Date(created_date) >= fiscal_year_start_date(current_fiscal_year(today))) "New" else "Unchanged"
}

# One-time backfill for existing measures created before this fiscal year
# that are still marked "New" (or never had change_mapping set at all) --
# see measure_change_mapping_for_date() above. Gated so it runs exactly
# once per database (including production, automatically on its next
# deploy/restart -- direct production DB access isn't available from this
# environment, so self-applying via the same seed_applied marker used
# elsewhere is how this reaches prod, not a manually-run script).
apply_change_mapping_by_created_date_once <- function(connection) {
  seed_name <- "change_mapping_by_created_date_backfill"
  if (seed_already_applied(connection, seed_name)) return(invisible(FALSE))
  boundary <- fiscal_year_start_date(current_fiscal_year())
  DBI::dbExecute(
    connection,
    paste(
      "UPDATE performance.performance_measure",
      "SET change_mapping = 'Unchanged', last_updated = now()",
      "WHERE (change_mapping IS NULL OR change_mapping = 'New') AND created_date < $1"
    ),
    params = list(boundary)
  )
  mark_seed_applied(connection, seed_name)
  invisible(TRUE)
}

# Percent measures used to be entered as decimal fractions (0.61 for 61%);
# the app now requires whole numbers (61), and a value of exactly 1 reads
# as "1%" instead of the "100%" it was meant to be.
#
# Rule: only a NON-INTEGER value (0.61, 0.9954, 1.015...) is touched here.
# Confirmed against both local dev and production (2026-07-28): zero
# Percent actual/target values >= 2 have any decimal precision, meaning
# nobody has ever entered a fractional-but-not-whole percent under the
# current whole-number rule -- so any decimal-precision value is
# unambiguously pre-dating that rule and safe to *100 automatically.
# A clean integer (0, 1, 2, 45, 100...) is never touched here, INCLUDING
# the one genuinely ambiguous case, a bare "1" (could mean 1% already
# correct, or 100% under the old convention) -- that requires comparing
# each measure's own history and was resolved manually, per-row, not by
# this blanket rule (see outputs/percent_*_review.xlsx from 2026-07-28).
#
# Scoped to measure_ids when given (tests use this -- the database also
# holds real, already-correct tiny percentages like 0.01, and re-running
# the unscoped version a second time would be a no-op anyway since 0.01
# is non-integer only on the FIRST pass -- scoping just keeps a test from
# touching unrelated rows). NULL (the production/default case) means
# every Percent measure.
percent_value_scale_backfill <- function(connection, measure_ids = NULL) {
  scope_clause <- ""
  scope_params <- list()
  if (!is.null(measure_ids)) {
    measure_ids <- unique(suppressWarnings(as.integer(measure_ids)))
    measure_ids <- measure_ids[!is.na(measure_ids)]
    if (!length(measure_ids)) return(invisible(FALSE))
    placeholders <- paste0("$", seq_along(measure_ids), collapse = ", ")
    scope_clause <- sprintf("AND pm.measure_id IN (%s)", placeholders)
    scope_params <- as.list(measure_ids)
  }
  actual_sql <- paste(
    "UPDATE performance.measure_actuals ma",
    "SET annual_actual = round(ma.annual_actual * 100, 2), updated_at = now()",
    "FROM performance.performance_measure pm",
    "WHERE pm.measure_id = ma.measure_id AND pm.format_type = 'Percent'",
    "AND ma.annual_actual IS NOT NULL AND ma.annual_actual != round(ma.annual_actual)",
    scope_clause
  )
  target_sql <- paste(
    "UPDATE performance.measure_actuals ma",
    "SET target_value = round(ma.target_value * 100, 2), updated_at = now()",
    "FROM performance.performance_measure pm",
    "WHERE pm.measure_id = ma.measure_id AND pm.format_type = 'Percent'",
    "AND ma.target_value IS NOT NULL AND ma.target_value != round(ma.target_value)",
    scope_clause
  )
  # dbExecute()'s params argument must be omitted entirely (not passed as an
  # empty list) when the statement has no placeholders -- some DBI/RPostgres
  # versions treat params = list() on a zero-placeholder query as an error
  # ("Query does not require parameters"), which only surfaces on the
  # unscoped call path (measure_ids = NULL), i.e. exactly how
  # ensure_review_schema() calls this on every app boot.
  if (length(scope_params)) {
    DBI::dbExecute(connection, actual_sql, params = scope_params)
    DBI::dbExecute(connection, target_sql, params = scope_params)
  } else {
    DBI::dbExecute(connection, actual_sql)
    DBI::dbExecute(connection, target_sql)
  }
  invisible(TRUE)
}

# Gated the same way as apply_change_mapping_by_created_date_once(): runs
# once per database, automatically on next restart, reaching production
# without needing direct DB access.
apply_percent_value_scale_backfill_once <- function(connection) {
  seed_name <- "percent_value_scale_backfill"
  if (seed_already_applied(connection, seed_name)) return(invisible(FALSE))
  percent_value_scale_backfill(connection)
  mark_seed_applied(connection, seed_name)
  invisible(TRUE)
}

# Once a measure is validated, its historic data and definition lock to
# everyone except a SystemAdmin (see can_edit_locked_measure_data() in
# app.R), except the current fiscal year's actual (still being actively
# reported) and the following fiscal year's target (still being actively
# planned). All three return FALSE for a not-yet-validated measure, so
# nothing is locked until validation happens. Enforced in two places:
# app.R's collect_measure_form()/collect_measure_years() (so a tampered
# client request can't slip a change past a disabled UI control) and
# again here in save_measure_record() itself, since that's the only
# function that actually writes these rows -- a second, independent
# guard rather than trusting a single call site to always get it right.
measure_actual_is_locked <- function(year, is_validated) {
  # The most recently completed fiscal year's actual stays open too (not
  # just the current year's) -- publishing requires it be reported, so a
  # non-admin must still be able to fill it in after validation.
  isTRUE(is_validated) && as.integer(year) < current_fiscal_year() - 1L
}

measure_target_is_locked <- function(year, is_validated) {
  isTRUE(is_validated) && as.integer(year) <= current_fiscal_year()
}

measure_definition_is_locked <- function(is_validated) {
  isTRUE(is_validated)
}

save_measure_record <- function(connection, values, yearly_values, reported_by, submit = FALSE, is_admin = FALSE) {
  DBI::dbWithTransaction(connection, {
    is_validated <- !is.null(values$measure_id) && identical(values$approval_status, "Validated")
    # A non-admin can only ever touch the current fiscal year's actual and
    # the following fiscal year's target on a validated measure -- every
    # other field gets forced back to its existing value below, before
    # this function ever writes anything. Since that kind of save doesn't
    # represent a real change requiring re-review, it shouldn't knock the
    # measure back to Draft the way any other edit to a
    # Validated/PendingApproval/Returned measure normally does. An admin's
    # edit to genuinely locked content still goes through the existing
    # re-validation-required path below.
    revalidation_required <- !is.null(values$measure_id) &&
      values$approval_status %in% c("Validated", "PendingApproval", "Returned") &&
      !(is_validated && !is_admin)
    if (is_validated && !is_admin && !is.null(values$measure_id)) {
      existing_measure <- DBI::dbGetQuery(
        connection,
        paste(
          "SELECT title, measure_type, description, data_source, data_owner, data_owner_role, update_frequency, formula,",
          "desired_direction, baseline_value, baseline_fy, format_type, display_unit, context_required, replicability,",
          "disaggregation, data_location, collection_method, how_data_used, why_meaningful, proxy_measure, improvement_notes,",
          "pillar_id, pillar_goal_id, is_city, is_agency, is_service",
          "FROM performance.performance_measure WHERE measure_id = $1"
        ),
        params = list(as.integer(values$measure_id))
      )
      if (nrow(existing_measure)) {
        for (field in names(existing_measure)) values[[field]] <- existing_measure[[field]][[1]]
      }
      existing_actuals <- DBI::dbGetQuery(
        connection,
        "SELECT fiscal_year, annual_actual, annual_actual_notes, target_value, target_value_notes FROM performance.measure_actuals WHERE measure_id = $1",
        params = list(as.integer(values$measure_id))
      )
      yearly_values <- lapply(yearly_values, function(year_value) {
        existing_row <- existing_actuals[existing_actuals$fiscal_year == year_value$fiscal_year, , drop = FALSE]
        if (!nrow(existing_row)) return(year_value)
        if (measure_actual_is_locked(year_value$fiscal_year, is_validated)) {
          year_value$annual_actual <- existing_row$annual_actual[[1]]
          year_value$annual_actual_notes <- existing_row$annual_actual_notes[[1]]
        }
        if (measure_target_is_locked(year_value$fiscal_year, is_validated)) {
          year_value$target_value <- existing_row$target_value[[1]]
          year_value$target_value_notes <- existing_row$target_value_notes[[1]]
        }
        year_value
      })
    }
    status <- if (submit) {
      "PendingApproval"
    } else if (revalidation_required) {
      "Draft"
    } else {
      values$approval_status
    }
    submitted_at <- if (submit) {
      Sys.time()
    } else if (revalidation_required) {
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

delete_measure_record <- function(connection, measure_id) {
  measure_id <- suppressWarnings(as.integer(measure_id))
  if (is.na(measure_id)) stop("Measure not found.")
  DBI::dbWithTransaction(connection, {
    DBI::dbExecute(connection, "DELETE FROM review.measure_review WHERE measure_id = $1", params = list(measure_id))
    DBI::dbExecute(connection, "DELETE FROM performance.measure_actuals WHERE measure_id = $1", params = list(measure_id))
    DBI::dbExecute(connection, "DELETE FROM performance.pm_goal_link WHERE measure_id = $1", params = list(measure_id))
    DBI::dbExecute(connection, "DELETE FROM performance.pm_service_link WHERE measure_id = $1", params = list(measure_id))
    DBI::dbExecute(connection, "DELETE FROM performance.measure_entity_link WHERE measure_id = $1", params = list(measure_id))
    DBI::dbExecute(connection, "DELETE FROM performance.pm_service_reassignment WHERE measure_id = $1", params = list(measure_id))
    changed <- DBI::dbExecute(connection, "DELETE FROM performance.performance_measure WHERE measure_id = $1", params = list(measure_id))
    if (changed != 1) stop("Measure not found.")
  })
  invisible(measure_id)
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
    if (next_status %in% c("DeputyMayorReview", "CAReview", "Approved")) {
      opi_stamp <- DBI::dbGetQuery(
        connection,
        "SELECT COUNT(*)::integer AS n FROM workflow.plan_approval_stamp WHERE plan_id = $1 AND approval_stage = 'OPIApproval'",
        params = list(plan_id)
      )$n[[1]]
      if (opi_stamp < 1L) {
        stop("OPI approval is required before routing this plan to Deputy Mayor, CA Office, or publishing.")
      }
    }
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

route_plan_from_review_admin <- function(connection, plan_id, routed_by = NULL, next_status = "UnderReview", route_note = NULL) {
  plan_id <- as.integer(plan_id)
  routed_by <- if (is.null(routed_by) || is.na(routed_by)) NA_integer_ else as.integer(routed_by)
  next_status <- as.character(next_status %||% "UnderReview")
  route_note <- trimws(as.character(route_note %||% ""))
  valid_next_statuses <- c("Returned", "UnderReview", "DeputyMayorReview", "CAReview", "Approved")
  if (is.na(plan_id)) stop("Plan is required.")
  if (!next_status %in% valid_next_statuses) stop("Choose a valid route for this plan.")
  DBI::dbWithTransaction(connection, {
    plan <- DBI::dbGetQuery(
      connection,
      "SELECT plan_id, plan_status FROM planning.agency_plan WHERE plan_id = $1",
      params = list(plan_id)
    )
    if (!nrow(plan)) stop("Plan not found.")
    if (plan$plan_status[[1]] %in% c("Published", "Amended")) {
      stop("Published plans cannot be routed from plan review.")
    }
    DBI::dbExecute(
      connection,
      "UPDATE planning.agency_plan SET plan_status = $2, updated_at = now(), modified_by = $3 WHERE plan_id = $1",
      params = list(plan_id, next_status, routed_by)
    )
    history_note <- if (nzchar(route_note)) {
      route_note
    } else {
      paste("System Admin routed plan to", next_status, "from plan review.")
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

opi_approval_user_allowed <- function(connection, user_id) {
  user_id <- if (is.null(user_id) || is.na(user_id)) NA_integer_ else as.integer(user_id)
  if (is.na(user_id)) return(FALSE)
  approver <- DBI::dbGetQuery(
    connection,
    'SELECT lower(trim(email)) AS email FROM access."user" WHERE user_id = $1 AND active = true',
    params = list(user_id)
  )
  nrow(approver) &&
    approver$email[[1]] %in% c("melanie.lada@baltimorecity.gov", "danny.heller@baltimorecity.gov")
}

add_plan_approval_stamp <- function(connection, plan_id, approval_stage, added_by = NULL, approved_by = NULL, notes = NULL) {
  plan_id <- as.integer(plan_id)
  added_by <- if (is.null(added_by) || is.na(added_by)) NA_integer_ else as.integer(added_by)
  approved_by <- if (is.null(approved_by) || is.na(approved_by)) added_by else as.integer(approved_by)
  approval_stage <- as.character(approval_stage %||% "")
  valid_stages <- c("Reviewer", "OPIApproval", "DeputyMayor", "CAOffice")
  if (is.na(plan_id)) stop("Plan is required.")
  if (!approval_stage %in% valid_stages) stop("Choose a valid approval stage.")
  if (identical(approval_stage, "OPIApproval") && !opi_approval_user_allowed(connection, added_by)) {
    stop("Only Melanie Lada or Danny Heller can add the OPI approval stamp.")
  }
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
  valid_stages <- c("Reviewer", "OPIApproval", "DeputyMayor", "CAOffice")
  if (is.na(plan_id)) stop("Plan is required.")
  if (!approval_stage %in% valid_stages) stop("Choose a valid approval stage.")
  if (identical(approval_stage, "OPIApproval") && !opi_approval_user_allowed(connection, removed_by)) {
    stop("Only Melanie Lada or Danny Heller can remove the OPI approval stamp.")
  }
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
      Reviewer = c("Reviewer", "OPIApproval", "DeputyMayor", "CAOffice"),
      OPIApproval = c("OPIApproval", "DeputyMayor", "CAOffice"),
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
      OPIApproval = if (plan$plan_status[[1]] %in% c("DeputyMayorReview", "CAReview", "Approved")) "UnderReview" else plan$plan_status[[1]],
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
      Returned = c("Reviewer", "OPIApproval", "DeputyMayor", "CAOffice"),
      UnderReview = c("Reviewer", "OPIApproval", "DeputyMayor", "CAOffice"),
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
  performance_role_values <- c("AgencySubmitter", "AgencyWriter", "AgencyViewer", "OPIReviewer", "BBMRReviewer", "DeputyMayor", "CAOffice", "SystemAdmin")
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
    # Upserting on the user_id unique constraint (rather than a
    # SELECT-then-branch) keeps this atomic: two overlapping saves for the
    # same user_id (a double-click, or two admins saving around the same
    # time) used to both see "no existing row" and race to INSERT, with the
    # second hitting user_role_user_id_key and failing the whole save.
    DBI::dbExecute(
      connection,
      paste(
        "INSERT INTO access.user_role (user_id, app_role, agency_id, budget_access, adaptive_planning, performance_plan_access)",
        "VALUES ($1, $2::varchar(30), NULL, $3, $4, $5)",
        "ON CONFLICT (user_id) DO UPDATE SET",
        "app_role = EXCLUDED.app_role, agency_id = NULL, budget_access = EXCLUDED.budget_access,",
        "adaptive_planning = EXCLUDED.adaptive_planning, performance_plan_access = EXCLUDED.performance_plan_access"
      ),
      params = list(user_id, performance_role, isTRUE(budget_access), isTRUE(adaptive_planning), isTRUE(performance_plan_access))
    )
  })
  invisible(TRUE)
}

save_entity_team_role_assignment <- function(connection, entity_access_id, entity_id, agency_id, full_name, email, agency_role, performance_role, budget_access, adaptive_planning, performance_plan_access, service_id = NULL) {
  agency_role_values <- c("Agency Head", "Agency Director", "Chief of Staff", "Fiscal Officer", "Fiscal Staff", "Agency Staff", "Program Staff", "Performance Lead", "Admin")
  performance_role_values <- c("AgencySubmitter", "AgencyWriter", "AgencyViewer", "OPIReviewer", "BBMRReviewer", "DeputyMayor", "CAOffice", "SystemAdmin")
  is_new <- identical(as.character(entity_access_id), "new")
  entity_access_id <- if (is_new) NA_integer_ else as.integer(entity_access_id)
  entity_id <- as.integer(entity_id)
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
  if (is.na(entity_id)) stop("Entity assignment is required.")
  if (!nzchar(agency_id)) stop("Agency assignment is required.")
  if (!nzchar(full_name)) stop("Person name is required.")
  if (!nzchar(email) || !grepl("@", email, fixed = TRUE)) stop("A valid email is required.")
  if (!length(agency_roles) || any(!agency_roles %in% agency_role_values)) stop("Choose valid agency roles.")
  if (!performance_role %in% performance_role_values) stop("Choose a valid performance role.")

  DBI::dbWithTransaction(connection, {
    DBI::dbExecute(connection, "SELECT setval(pg_get_serial_sequence('access.\"user\"', 'user_id'), COALESCE((SELECT MAX(user_id) FROM access.\"user\"), 1), (SELECT COUNT(*) > 0 FROM access.\"user\"))")
    DBI::dbExecute(connection, "SELECT setval(pg_get_serial_sequence('access.user_entity_access', 'entity_access_id'), COALESCE((SELECT MAX(entity_access_id) FROM access.user_entity_access), 1), (SELECT COUNT(*) > 0 FROM access.user_entity_access))")
    DBI::dbExecute(connection, "SELECT setval(pg_get_serial_sequence('access.user_role', 'user_role_id'), COALESCE((SELECT MAX(user_role_id) FROM access.user_role), 1), (SELECT COUNT(*) > 0 FROM access.user_role))")
    if (is_new) {
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
        "SELECT entity_access_id, user_id, entity_id, agency_id, service_id FROM access.user_entity_access WHERE user_id = $1 AND entity_id = $2 ORDER BY entity_access_id LIMIT 1",
        params = list(user_id, entity_id)
      )
      if (nrow(access)) {
        entity_access_id <- access$entity_access_id[[1]]
      } else {
        access <- DBI::dbGetQuery(
          connection,
          "INSERT INTO access.user_entity_access (user_id, entity_id, agency_id, service_id, agency_role, agency_roles, access_level, budget_access, adaptive_planning, performance_plan_access) VALUES ($1, $2, $3::varchar(20), $4::varchar(20), $5::varchar(30), $6, CASE WHEN $5::text = 'Agency Staff' THEN 'ReadOnly' WHEN $5::text IN ('Agency Head', 'Agency Director') THEN 'Submit' ELSE 'Edit' END, $7, $8, $9) RETURNING entity_access_id, user_id, entity_id, agency_id, service_id",
          params = list(user_id, entity_id, agency_id, service_id, agency_role, agency_roles_value, isTRUE(budget_access), isTRUE(adaptive_planning), isTRUE(performance_plan_access))
        )
        entity_access_id <- access$entity_access_id[[1]]
      }
    } else {
      access <- DBI::dbGetQuery(connection, "SELECT entity_access_id, user_id, entity_id, agency_id, service_id FROM access.user_entity_access WHERE entity_access_id = $1", params = list(entity_access_id))
      if (!nrow(access)) stop("Team entity access row not found.")
      user_id <- access$user_id[[1]]
    }
    DBI::dbExecute(
      connection,
      'UPDATE access."user" SET full_name = $2, email = $3, updated_at = now() WHERE user_id = $1',
      params = list(user_id, full_name, email)
    )
    DBI::dbExecute(
      connection,
      "UPDATE access.user_entity_access SET agency_id = $2::varchar(20), service_id = $3::varchar(20), agency_role = $4::varchar(30), agency_roles = $5, access_level = CASE WHEN $4::text = 'Agency Staff' THEN 'ReadOnly' WHEN $4::text IN ('Agency Head', 'Agency Director') THEN 'Submit' ELSE 'Edit' END, budget_access = $6, adaptive_planning = $7, performance_plan_access = $8, updated_at = now() WHERE entity_access_id = $1",
      params = list(entity_access_id, agency_id, service_id, agency_role, agency_roles_value, isTRUE(budget_access), isTRUE(adaptive_planning), isTRUE(performance_plan_access))
    )
    # Upserting on the user_id unique constraint (rather than a
    # SELECT-then-branch) keeps this atomic: two overlapping saves for the
    # same user_id (a double-click, or two admins saving around the same
    # time) used to both see "no existing row" and race to INSERT, with the
    # second hitting user_role_user_id_key and failing the whole save.
    DBI::dbExecute(
      connection,
      paste(
        "INSERT INTO access.user_role (user_id, app_role, agency_id, budget_access, adaptive_planning, performance_plan_access)",
        "VALUES ($1, $2::varchar(30), NULL, $3, $4, $5)",
        "ON CONFLICT (user_id) DO UPDATE SET",
        "app_role = EXCLUDED.app_role, agency_id = NULL, budget_access = EXCLUDED.budget_access,",
        "adaptive_planning = EXCLUDED.adaptive_planning, performance_plan_access = EXCLUDED.performance_plan_access"
      ),
      params = list(user_id, performance_role, isTRUE(budget_access), isTRUE(adaptive_planning), isTRUE(performance_plan_access))
    )
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

delete_entity_team_role_assignment <- function(connection, entity_access_id, acting_user_id = NULL) {
  entity_access_id <- as.integer(entity_access_id)
  acting_user_id <- suppressWarnings(as.integer(acting_user_id %||% NA_integer_))
  access <- DBI::dbGetQuery(
    connection,
    "SELECT entity_access_id, user_id, entity_id, agency_id FROM access.user_entity_access WHERE entity_access_id = $1",
    params = list(entity_access_id)
  )
  if (!nrow(access)) stop("Team entity access row not found.")
  if (!is.na(acting_user_id) && access$user_id[[1]] == acting_user_id) {
    stop("You cannot delete your own team access row.")
  }
  DBI::dbWithTransaction(connection, {
    DBI::dbExecute(
      connection,
      "DELETE FROM access.user_entity_access WHERE entity_access_id = $1",
      params = list(entity_access_id)
    )
    remaining_access_for_agency <- DBI::dbGetQuery(
      connection,
      "SELECT COUNT(*)::integer AS n FROM access.user_entity_access WHERE user_id = $1 AND agency_id = $2",
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
      "SELECT (SELECT COUNT(*) FROM access.user_entity_access WHERE user_id = $1) + (SELECT COUNT(*) FROM access.user_agency_access WHERE user_id = $1) + (SELECT COUNT(*) FROM access.user_role WHERE user_id = $1) AS n",
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

save_service_risk <- function(connection, risk_id, plan_id, risk_type, description, changed_by = NULL) {
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
  result <- DBI::dbWithTransaction(connection, {
    set_audit_actor(connection, changed_by)
    changed <- DBI::dbExecute(
      connection,
      "UPDATE performance.service_risk SET risk_type=$3, description=$4, updated_at=now() WHERE risk_id=$1 AND plan_id=$2",
      params = list(as.integer(risk_id), as.integer(plan_id), risk_type, description)
    )
    if (changed != 1) stop("Risk not found for this plan")
    as.integer(risk_id)
  })
  result
}

delete_service_risk <- function(connection, risk_id, plan_id, changed_by = NULL) {
  risk_id <- suppressWarnings(as.integer(risk_id))
  plan_id <- suppressWarnings(as.integer(plan_id))
  if (is.na(risk_id) || is.na(plan_id)) stop("Risk not found.")
  DBI::dbWithTransaction(connection, {
    set_audit_actor(connection, changed_by)
    changed <- DBI::dbExecute(
      connection,
      "DELETE FROM performance.service_risk WHERE risk_id=$1 AND plan_id=$2",
      params = list(risk_id, plan_id)
    )
    if (changed != 1) stop("Risk not found for this plan.")
  })
  invisible(TRUE)
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

# Parses a stored section-draft payload, warning (rather than silently
# returning NULL) if it's corrupted. Every caller that hits this treats a
# NULL as "no draft exists yet" and proceeds from scratch -- correct for a
# genuinely missing row, but for a *corrupted* one it means whatever was
# stored is discarded with zero trace. A warning at least makes that
# discoverable (visible in `flyctl logs`) instead of indistinguishable from
# the normal "first save ever" case. jsonb columns shouldn't normally hold
# invalid JSON, so this is defensive, not expected to fire in practice.
parse_stored_draft_payload <- function(payload_text, context = "") {
  tryCatch(
    jsonlite::fromJSON(payload_text, simplifyVector = FALSE),
    error = function(error) {
      warning(
        "Failed to parse stored section-draft payload",
        if (nzchar(context)) paste0(" (", context, ")") else "",
        ": ", conditionMessage(error),
        call. = FALSE
      )
      NULL
    }
  )
}

# Shared by every draft-payload merge below: existing entries survive
# unless the incoming payload actually has that same key, in which case
# incoming wins for that key only.
merge_named_list <- function(existing_list, incoming_list) {
  if (is.null(existing_list) || !is.list(existing_list)) existing_list <- list()
  if (is.null(incoming_list) || !is.list(incoming_list)) incoming_list <- list()
  merged <- existing_list
  for (key in names(incoming_list)) merged[[key]] <- incoming_list[[key]]
  merged
}

# Deep-merges an incoming Goals-section draft payload against whatever is
# already stored, keyed by field id / goal id, instead of replacing it
# outright. Every team member's "quiet" autosave sends a full snapshot of
# their own browser's Goals page, and that browser only syncs with the
# shared draft once per page load -- so a tab that's been open a while has
# no idea about a goal/field a teammate added afterward. A blind overwrite
# (the previous behavior) silently erased it the moment that stale tab's
# next autosave landed. Merging means a save that doesn't mention a given
# field or goal id leaves the existing value alone.
#
# Trade-off: this can't distinguish "my browser never knew this goal
# existed" from "I just deleted this goal" -- both look identical (the
# payload just doesn't mention that goal id). A goal deleted by one team
# member could reappear if another team member's already-stale tab saves
# afterward. Accepted as a much narrower, more visible failure mode than
# the one being fixed (any conflicting save silently dropping *all* of
# another user's unsynced additions, every time -- reported 2026-07-24).
merge_goals_draft_payload <- function(existing, incoming) {
  if (is.null(existing) || !is.list(existing)) return(incoming)
  merged <- incoming
  merged$values <- merge_named_list(existing$values, incoming$values)
  merged$kpis <- merge_named_list(existing$kpis, incoming$kpis)
  merged$initiatives <- merge_named_list(existing$initiatives, incoming$initiatives)
  existing_goal_ids <- if (is.null(existing$goalIds)) character(0) else vapply(existing$goalIds, as.character, character(1))
  incoming_goal_ids <- if (is.null(incoming$goalIds)) character(0) else vapply(incoming$goalIds, as.character, character(1))
  merged$goalIds <- as.list(union(existing_goal_ids, incoming_goal_ids))
  merged
}

# Same idea as merge_goals_draft_payload(), for the Services page's "quiet"
# autosave (services_draft_quiet_save in app.R, fed by
# scheduleServicesQuietAutosave()/collectBuilderDraft() in app.js) --
# discovered 2026-07-24 to be the *actual* live Services autosave path.
# save_services_draft_field()/with_section_draft_lock() below were added
# earlier the same day believing service_description_draft_save and
# service_metrics_draft_save were the live path; they turned out to be
# unreachable from the client (flushServiceDescriptionAutosave() and
# flushServiceMetricsAutosave() are defined in app.js but never called),
# so that fix touched code the browser never actually invokes. This is the
# one that matters: collectBuilderDraft() sends a full snapshot of every
# values/serviceMetrics key on the page, same as Goals' collectGoalsDraft(),
# and was going through the same blind overwrite_section_draft() Goals used
# to. No goalIds-equivalent array to reconcile here, just two dictionaries.
merge_services_draft_payload <- function(existing, incoming) {
  if (is.null(existing) || !is.list(existing)) return(incoming)
  merged <- incoming
  merged$values <- merge_named_list(existing$values, incoming$values)
  merged$serviceMetrics <- merge_named_list(existing$serviceMetrics, incoming$serviceMetrics)
  merged
}

# Runs `mutate` against the current section-draft payload under a row
# lock, then saves whatever it returns -- an atomic read-modify-write, so
# two concurrent saves to the same (plan_id, section_key) draft serialize
# against each other correctly instead of both reading the same stale
# payload and racing to overwrite it. `mutate` receives the current payload
# as a parsed list (NULL if no draft row exists yet) and must return the
# full new payload to store. Shared by both save_goals_draft_merged() and
# the Services per-field/per-metric save path below -- Services was found
# to have the same class of lost-update race as Goals (2026-07-24), just
# narrower in scope (each save already only touches one field/service
# instead of a whole-page snapshot).
with_section_draft_lock <- function(connection, plan_id, section_key, mutate, updated_by = NULL) {
  plan_id <- as.integer(plan_id)
  section_key <- as.character(section_key)
  DBI::dbWithTransaction(connection, {
    existing_row <- DBI::dbGetQuery(
      connection,
      "SELECT payload::text AS payload FROM planning.plan_section_draft WHERE plan_id = $1 AND section_key = $2 FOR UPDATE",
      params = list(plan_id, section_key)
    )
    existing_payload <- if (nrow(existing_row)) {
      parse_stored_draft_payload(existing_row$payload[[1]], context = paste0("plan_id=", plan_id, " section_key=", section_key))
    } else {
      NULL
    }
    new_payload <- mutate(existing_payload)
    new_payload_json <- jsonlite::toJSON(new_payload, auto_unbox = TRUE, null = "null")
    overwrite_section_draft(connection, plan_id, section_key, new_payload_json, updated_by)
  })
}

save_goals_draft_merged <- function(connection, plan_id, payload_json, updated_by = NULL) {
  incoming_payload <- jsonlite::fromJSON(payload_json, simplifyVector = FALSE)
  with_section_draft_lock(connection, plan_id, "goals", function(existing_payload) {
    merge_goals_draft_payload(existing_payload, incoming_payload)
  }, updated_by)
}

# The actual fix for Services' "quiet" full-snapshot autosave -- see
# merge_services_draft_payload()'s comment for why this is the one that
# matters (a same-day, since-removed save_services_draft_field() targeted
# the wrong, unreachable code path first).
save_services_draft_quiet_merged <- function(connection, plan_id, payload_json, updated_by = NULL) {
  incoming_payload <- jsonlite::fromJSON(payload_json, simplifyVector = FALSE)
  with_section_draft_lock(connection, plan_id, "services", function(existing_payload) {
    merge_services_draft_payload(existing_payload, incoming_payload)
  }, updated_by)
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
      Returned = c("Reviewer", "OPIApproval", "DeputyMayor", "CAOffice"),
      UnderReview = c("Reviewer", "OPIApproval", "DeputyMayor", "CAOffice"),
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
    set_audit_actor(connection, approved_by)
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

# Given a set of measure_ids, returns the subset that are not marked "New"
# (a measure added this cycle has nothing prior to report yet) and are
# missing either the most recently completed year's actual (actual_fy) or
# the upcoming budget year's target (next_target_fy) -- both required to
# publish a *plan*, never to save or submit an individual measure. Re-
# queries fresh from the database rather than trusting a caller-supplied
# "already checked" flag -- the goal/service *selection* logic (which
# measure_ids belong to a plan) still lives in app.R's
# plan_selected_measure_ids(), since duplicating that in SQL here would
# risk drifting out of sync with its draft/administration-service handling.
measure_ids_missing_required_fiscal_data <- function(connection, measure_ids, actual_fy, next_target_fy) {
  measure_ids <- unique(suppressWarnings(as.integer(measure_ids)))
  measure_ids <- measure_ids[!is.na(measure_ids)]
  if (!length(measure_ids)) return(integer(0))
  placeholders <- paste0("$", seq_along(measure_ids) + 2L, collapse = ", ")
  rows <- DBI::dbGetQuery(
    connection,
    sprintf(
      paste(
        "SELECT pm.measure_id FROM performance.performance_measure pm",
        "WHERE pm.measure_id IN (%s)",
        "AND (pm.change_mapping IS NULL OR pm.change_mapping != 'New')",
        "AND (",
        "  NOT EXISTS (",
        "    SELECT 1 FROM performance.measure_actuals ma",
        "    WHERE ma.measure_id = pm.measure_id AND ma.fiscal_year = $1 AND ma.annual_actual IS NOT NULL",
        "    AND ma.annual_actual_notes IS NOT NULL AND btrim(ma.annual_actual_notes) <> ''",
        "  )",
        "  OR NOT EXISTS (",
        "    SELECT 1 FROM performance.measure_actuals mt",
        "    WHERE mt.measure_id = pm.measure_id AND mt.fiscal_year = $2 AND mt.target_value IS NOT NULL",
        "    AND mt.target_value_notes IS NOT NULL AND btrim(mt.target_value_notes) <> ''",
        "  )",
        ")"
      ),
      placeholders
    ),
    params = c(list(as.integer(actual_fy), as.integer(next_target_fy)), as.list(measure_ids))
  )
  rows$measure_id
}

publish_agency_plan <- function(connection, plan_id, published_by = NULL, required_measure_ids = NULL, actual_fy = NULL, next_target_fy = NULL) {
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
    if (length(required_measure_ids) && !is.null(actual_fy) && !is.null(next_target_fy)) {
      missing_ids <- measure_ids_missing_required_fiscal_data(connection, required_measure_ids, actual_fy, next_target_fy)
      if (length(missing_ids)) {
        id_placeholders <- paste0("$", seq_along(missing_ids), collapse = ", ")
        titles <- DBI::dbGetQuery(
          connection,
          sprintf("SELECT title FROM performance.performance_measure WHERE measure_id IN (%s) ORDER BY title", id_placeholders),
          params = as.list(as.integer(missing_ids))
        )$title
        stop(sprintf(
          "Cannot publish: FY%02d actual or FY%02d target missing for %s%s",
          actual_fy %% 100L, next_target_fy %% 100L,
          paste(head(titles, 5), collapse = ", "),
          if (length(titles) > 5) sprintf(" and %d more", length(titles) - 5) else ""
        ))
      }
    }
    set_audit_actor(connection, published_by)
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
