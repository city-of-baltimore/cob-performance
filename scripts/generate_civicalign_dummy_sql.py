from __future__ import annotations

import argparse
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path
from re import fullmatch
from typing import Any

import openpyxl


DEFAULT_OUTPUT = Path("database/dummy/civicalign_dummy_load.sql")
SKIP_SHEETS = {"README"}

TEXT_ID_COLUMNS = {
    "agency_id",
    "service_id",
    "cost_center_id",
    "old_service_id",
    "new_service_id",
    "parent_agency_id",
    "fund_id",
}

BOOLEAN_COLUMNS = {
    "active",
    "adaptive_planning",
    "arpa_funded",
    "budget_access",
    "completed",
    "context_required",
    "has_own_plan",
    "is_agency",
    "is_city",
    "is_kpi",
    "is_primary",
    "is_quasi",
    "is_service",
    "justified",
    "performance_plan_access",
    "quasi",
    "replicability",
    "return_required",
    "review_complete",
    "validated",
}

INDEX_SUFFIXES = ("_id", "_by", "_status", "_type", "_role", "_code")
INDEX_COLUMNS = {
    "email",
    "fiscal_year",
    "service_type",
    "app_role",
    "agency_role",
    "plan_status",
    "budget_status",
    "cycle_status",
    "approval_status",
    "amendment_status",
    "notification_type",
    "section_code",
}


def sql_identifier(identifier: str) -> str:
    return '"' + identifier.lower().replace('"', '""') + '"'


def sheet_to_table_name(sheet_name: str) -> str:
    return sheet_name.lower()


def normalize_header(value: Any) -> str:
    if value is None:
        raise ValueError("Header cells cannot be blank.")
    return str(value).strip().lower()


def clean_value(value: Any) -> Any:
    if isinstance(value, str):
        value = value.strip()
        if value == "":
            return None
    return value


def normalize_bool(value: Any) -> bool | None:
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)) and value in (0, 1):
        return bool(value)
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in {"true", "yes", "y", "1"}:
            return True
        if lowered in {"false", "no", "n", "0"}:
            return False
    return bool(value)


def is_iso_date_string(value: Any) -> bool:
    return isinstance(value, str) and fullmatch(r"\d{4}-\d{2}-\d{2}", value) is not None


def infer_column_type(column: str, values: list[Any]) -> str:
    present = [value for value in values if value is not None]
    if column in TEXT_ID_COLUMNS:
        return "text"
    if column in BOOLEAN_COLUMNS:
        return "boolean"
    if column.endswith("_at"):
        return "timestamptz"
    if column.endswith("_date") or column in {
        "summer_open",
        "summer_close",
        "fall_open",
        "fall_close",
        "submitted_at",
        "approved_at",
        "granted_at",
        "created_at",
        "updated_at",
        "changed_at",
        "action_at",
        "review_started_at",
        "feedback_released_at",
        "resolved_at",
        "initiated_at",
        "reapproved_at",
        "relocked_at",
        "generated_at",
        "sent_at",
        "read_at",
    }:
        return "timestamptz" if column.endswith("_at") else "date"
    if present and all(isinstance(value, (date, datetime)) or is_iso_date_string(value) for value in present):
        return "date"
    if present and all(isinstance(value, bool) for value in present):
        return "boolean"
    if present and all(isinstance(value, int) and not isinstance(value, bool) for value in present):
        return "integer"
    if present and all(isinstance(value, (int, float, Decimal)) and not isinstance(value, bool) for value in present):
        return "numeric"
    return "text"


def sql_literal(value: Any, column_type: str) -> str:
    if value is None:
        return "NULL"
    if column_type == "boolean":
        return "true" if normalize_bool(value) else "false"
    if column_type in {"integer", "numeric"}:
        return str(value)
    if isinstance(value, (date, datetime)):
        return "'" + value.isoformat().replace("'", "''") + "'"
    return "'" + str(value).replace("'", "''") + "'"


def load_sheet_rows(workbook_path: Path) -> dict[str, list[dict[str, Any]]]:
    workbook = openpyxl.load_workbook(workbook_path, read_only=True, data_only=True)
    tables: dict[str, list[dict[str, Any]]] = {}

    for worksheet in workbook.worksheets:
        if worksheet.title in SKIP_SHEETS:
            continue

        row_iter = worksheet.iter_rows(values_only=True)
        headers = [normalize_header(value) for value in next(row_iter)]
        rows: list[dict[str, Any]] = []

        for raw_row in row_iter:
            record = {
                column: clean_value(value)
                for column, value in zip(headers, raw_row[: len(headers)])
            }
            if any(value is not None for value in record.values()):
                rows.append(record)

        tables[sheet_to_table_name(worksheet.title)] = rows

    return tables


def build_column_types(rows: list[dict[str, Any]]) -> dict[str, str]:
    if not rows:
        return {}

    columns = list(rows[0].keys())
    return {
        column: infer_column_type(column, [row.get(column) for row in rows])
        for column in columns
    }


def create_table_sql(table_name: str, column_types: dict[str, str]) -> str:
    primary_key = next(iter(column_types))
    column_defs = []
    for column, column_type in column_types.items():
        definition = f"    {sql_identifier(column)} {column_type}"
        if column == primary_key:
            definition += " PRIMARY KEY"
        column_defs.append(definition)

    return (
        f"CREATE TABLE IF NOT EXISTS {sql_identifier(table_name)} (\n"
        + ",\n".join(column_defs)
        + "\n);"
    )


def alter_table_sql(table_name: str, column_types: dict[str, str]) -> str:
    statements = []
    for column, column_type in list(column_types.items())[1:]:
        statements.append(
            f"ALTER TABLE {sql_identifier(table_name)} "
            f"ADD COLUMN IF NOT EXISTS {sql_identifier(column)} {column_type};"
        )
    return "\n".join(statements)


def insert_sql(table_name: str, rows: list[dict[str, Any]], column_types: dict[str, str]) -> str:
    if not rows:
        return f"-- No rows found for {table_name}."

    columns = list(column_types.keys())
    primary_key = columns[0]
    update_columns = columns[1:]

    values = []
    for row in rows:
        values.append(
            "    ("
            + ", ".join(sql_literal(row.get(column), column_types[column]) for column in columns)
            + ")"
        )

    column_list = ", ".join(sql_identifier(column) for column in columns)
    update_list = ", ".join(
        f"{sql_identifier(column)} = EXCLUDED.{sql_identifier(column)}"
        for column in update_columns
    )

    if update_list:
        conflict_action = f"DO UPDATE SET\n    {update_list}"
    else:
        conflict_action = "DO NOTHING"

    return (
        f"INSERT INTO {sql_identifier(table_name)} ({column_list})\n"
        "VALUES\n"
        + ",\n".join(values)
        + f"\nON CONFLICT ({sql_identifier(primary_key)}) {conflict_action};"
    )


def index_sql(table_name: str, column_types: dict[str, str]) -> str:
    columns = list(column_types.keys())
    if not columns:
        return ""

    primary_key = columns[0]
    statements = []
    for column in columns[1:]:
        if (
            column.endswith(INDEX_SUFFIXES)
            or column in INDEX_COLUMNS
        ) and column != primary_key:
            index_name = f"idx_{table_name}_{column}"
            statements.append(
                f"CREATE INDEX IF NOT EXISTS {sql_identifier(index_name)} "
                f"ON {sql_identifier(table_name)} ({sql_identifier(column)});"
            )
    return "\n".join(statements)


def build_sql(workbook_path: Path) -> str:
    tables = load_sheet_rows(workbook_path)
    sections = [
        "-- Generated from CivicAlign_DummyData.xlsx.",
        "-- Development seed data for the CivicAlign / COB performance app.",
        "-- Rebuild with: python scripts/generate_civicalign_dummy_sql.py <path-to-workbook>",
        "BEGIN;",
    ]

    for table_name, rows in tables.items():
        column_types = build_column_types(rows)
        sections.append("")
        sections.append(f"-- {table_name}")
        sections.append(create_table_sql(table_name, column_types))
        sections.append(alter_table_sql(table_name, column_types))
        sections.append(insert_sql(table_name, rows, column_types))
        indexes = index_sql(table_name, column_types)
        if indexes:
            sections.append(indexes)

    sections.append("")
    sections.append("COMMIT;")
    return "\n".join(sections) + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate Postgres SQL from the CivicAlign dummy data workbook."
    )
    parser.add_argument("workbook", type=Path, help="Path to CivicAlign_DummyData.xlsx.")
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"Output SQL path. Defaults to {DEFAULT_OUTPUT}.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    sql = build_sql(args.workbook)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(sql, encoding="utf-8")
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()
