source("R/database.R")

output_dir <- "outputs/database_documentation"
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

con <- connect_app_database()
on.exit(DBI::dbDisconnect(con), add = TRUE)

query <- function(sql) DBI::dbGetQuery(con, sql)

documented_schemas <- "('reference','access','planning','performance','budget','review','workflow','amendment','output')"

tables <- query(
  paste(
    "SELECT n.nspname AS table_schema, c.relname AS table_name,",
    "  COALESCE(obj_description(c.oid), '') AS table_comment,",
    "  GREATEST(c.reltuples::bigint, 0) AS estimated_rows",
    "FROM pg_class c",
    "JOIN pg_namespace n ON n.oid = c.relnamespace",
    "WHERE c.relkind = 'r'",
    "  AND n.nspname IN", documented_schemas,
    "ORDER BY n.nspname, c.relname"
  )
)

columns <- query(
  paste(
    "SELECT c.table_schema, c.table_name, c.ordinal_position, c.column_name,",
    "  c.data_type, c.udt_name, c.character_maximum_length, c.numeric_precision, c.numeric_scale,",
    "  c.is_nullable, COALESCE(c.column_default, '') AS column_default",
    "FROM information_schema.columns c",
    "WHERE c.table_schema IN", documented_schemas,
    "ORDER BY c.table_schema, c.table_name, c.ordinal_position"
  )
)

primary_keys <- query(
  paste(
    "SELECT kcu.table_schema, kcu.table_name, kcu.column_name, kcu.ordinal_position",
    "FROM information_schema.table_constraints tc",
    "JOIN information_schema.key_column_usage kcu",
    "  ON tc.constraint_schema = kcu.constraint_schema",
    " AND tc.constraint_name = kcu.constraint_name",
    " AND tc.table_schema = kcu.table_schema",
    " AND tc.table_name = kcu.table_name",
    "WHERE tc.constraint_type = 'PRIMARY KEY'",
    "  AND tc.table_schema IN", documented_schemas,
    "ORDER BY kcu.table_schema, kcu.table_name, kcu.ordinal_position"
  )
)

foreign_keys <- query(
  paste(
    "SELECT",
    "  tc.constraint_name,",
    "  kcu.table_schema AS source_schema,",
    "  kcu.table_name AS source_table,",
    "  kcu.column_name AS source_column,",
    "  ccu.table_schema AS target_schema,",
    "  ccu.table_name AS target_table,",
    "  ccu.column_name AS target_column",
    "FROM information_schema.table_constraints tc",
    "JOIN information_schema.key_column_usage kcu",
    "  ON tc.constraint_schema = kcu.constraint_schema",
    " AND tc.constraint_name = kcu.constraint_name",
    "JOIN information_schema.constraint_column_usage ccu",
    "  ON ccu.constraint_schema = tc.constraint_schema",
    " AND ccu.constraint_name = tc.constraint_name",
    "WHERE tc.constraint_type = 'FOREIGN KEY'",
    "  AND kcu.table_schema IN", documented_schemas,
    "ORDER BY source_schema, source_table, source_column"
  )
)

schema_summary <- aggregate(
  table_name ~ table_schema,
  data = tables,
  FUN = length
)
names(schema_summary) <- c("table_schema", "table_count")

write.csv(tables, file.path(output_dir, "tables.csv"), row.names = FALSE, na = "")
write.csv(columns, file.path(output_dir, "columns.csv"), row.names = FALSE, na = "")
write.csv(primary_keys, file.path(output_dir, "primary_keys.csv"), row.names = FALSE, na = "")
write.csv(foreign_keys, file.path(output_dir, "foreign_keys.csv"), row.names = FALSE, na = "")
write.csv(schema_summary, file.path(output_dir, "schema_summary.csv"), row.names = FALSE, na = "")

cat("tables=", nrow(tables), "\n", sep = "")
cat("columns=", nrow(columns), "\n", sep = "")
cat("foreign_keys=", nrow(foreign_keys), "\n", sep = "")
