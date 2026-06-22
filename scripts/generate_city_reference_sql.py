from __future__ import annotations

import argparse
from datetime import date, datetime
from pathlib import Path
from typing import Any

import openpyxl


TABLES: dict[str, dict[str, Any]] = {
    "PILLAR": {
        "name": "pillar",
        "columns": {
            "pillar_id": "integer PRIMARY KEY",
            "pillar_name": "text",
            "pillar_lead": "text",
            "sort_order": "integer",
            "updated_at": "timestamptz",
        },
    },
    "PILLAR_GOAL": {
        "name": "pillar_goal",
        "columns": {
            "pillar_goal_id": "integer PRIMARY KEY",
            "pillar_id": "integer NOT NULL REFERENCES pillar(pillar_id)",
            "goal_code": "text NOT NULL UNIQUE",
            "goal_title": "text NOT NULL",
            "goal_lead": "text",
            "sort_order": "integer",
        },
    },
    "AGENCY": {
        "name": "agency",
        "columns": {
            "agency_id": "text PRIMARY KEY",
            "agency_name": "text",
            "public_name": "text",
            "deputy_mayor_pillar": "text",
            "submit_plan": "boolean",
            "is_quasi": "boolean",
            "active": "boolean",
        },
    },
    "SERVICE": {
        "name": "service",
        "columns": {
            "service_id": "text PRIMARY KEY",
            "service_name": "text",
            "agency_id": "text REFERENCES agency(agency_id)",
            "service_type": "text",
            "pillar_id": "integer REFERENCES pillar(pillar_id)",
            "pillar_name": "text",
            "active": "boolean",
        },
    },
    "COST_CENTER": {
        "name": "cost_center",
        "columns": {
            "cost_center_id": "text PRIMARY KEY",
            "cost_center_name": "text",
            "service_id": "text REFERENCES service(service_id)",
            "agency_id": "text REFERENCES agency(agency_id)",
            "active": "boolean",
        },
    },
    "PLAN_ENTITY": {
        "name": "plan_entity",
        "columns": {
            "entity_id": "integer PRIMARY KEY",
            "parent_agency_id": "text REFERENCES agency(agency_id)",
            "public_name": "text",
            "entity_type": "text",
            "has_own_plan": "boolean",
            "active": "boolean",
        },
    },
    "PLAN_ENTITY_SERVICE": {
        "name": "plan_entity_service",
        "columns": {
            "pes_id": "integer PRIMARY KEY",
            "entity_id": "integer REFERENCES plan_entity(entity_id)",
            "service_id": "text REFERENCES service(service_id)",
            "service_name": "text",
            "is_primary": "boolean",
        },
    },
}

LOAD_ORDER = [
    "PILLAR",
    "PILLAR_GOAL",
    "AGENCY",
    "SERVICE",
    "COST_CENTER",
    "PLAN_ENTITY",
    "PLAN_ENTITY_SERVICE",
]

HISTORICAL_SERVICES = [
    {
        "service_id": "SRV0904",
        "service_name": "Office of Immigrant Affairs",
        "agency_id": "AGC4301",
        "service_type": "Performance",
        "pillar_id": 2,
        "pillar_name": "Prioritizing Youth, Older Adults, and Vulnerable Communities",
        "active": False,
    },
    {
        "service_id": "SRV9009",
        "service_name": "Capital Projects (MYR)",
        "agency_id": "AGC4301",
        "service_type": "Performance",
        "pillar_id": None,
        "pillar_name": None,
        "active": False,
    },
]

NOTE_PREFIXES = (
    "ACTION:",
    "LEGEND:",
    "NOTE:",
    "REVIEW NEEDED:",
    "SOURCE:",
)

NULL_MARKERS = {
    "",
    "(no SRV - capital/reserve)",
    "(no SRV -- capital/reserve)",
    "(no SRV — capital/reserve)",
}


def find_header_row(rows: list[tuple[Any, ...]], expected_headers: list[str]) -> int:
    for index, row in enumerate(rows):
        values = [value for value in row[: len(expected_headers)]]
        if values == expected_headers:
            return index
    raise ValueError(f"Could not find header row: {expected_headers}")


def is_note_row(row: tuple[Any, ...]) -> bool:
    first_value = row[0] if row else None
    return isinstance(first_value, str) and first_value.strip().startswith(NOTE_PREFIXES)


def is_data_row(sheet_name: str, row: tuple[Any, ...]) -> bool:
    if is_note_row(row):
        return False

    primary_key = next(iter(TABLES[sheet_name]["columns"]))
    primary_key_type = TABLES[sheet_name]["columns"][primary_key]
    primary_key_value = row[0] if row else None

    if primary_key_type.startswith("integer"):
        try:
            int(primary_key_value)
        except (TypeError, ValueError):
            return False

    return True


def clean_value(column: str, value: Any) -> Any:
    if isinstance(value, str):
        value = value.strip()
        if value in NULL_MARKERS:
            return None
        if column == "parent_agency_id" and value == "AGC4327":
            return "AGC4326"
    if value is None:
        return None
    if column in {"active", "submit_plan", "is_quasi", "has_own_plan", "is_primary"}:
        return bool(value)
    if column.endswith("_id") and column not in {
        "agency_id",
        "service_id",
        "cost_center_id",
        "parent_agency_id",
    }:
        return int(value)
    if column in {"pillar_id", "sort_order"}:
        return int(value)
    return value


def load_rows(workbook_path: Path) -> dict[str, list[dict[str, Any]]]:
    workbook = openpyxl.load_workbook(workbook_path, read_only=True, data_only=True)
    loaded: dict[str, list[dict[str, Any]]] = {}

    for sheet_name in LOAD_ORDER:
        worksheet = workbook[sheet_name]
        columns = list(TABLES[sheet_name]["columns"].keys())
        all_rows = list(worksheet.iter_rows(values_only=True))
        header_index = find_header_row(all_rows, columns)
        records: list[dict[str, Any]] = []

        for row in all_rows[header_index + 1 :]:
            row = row[: len(columns)]
            if not any(value is not None for value in row):
                continue
            if not is_data_row(sheet_name, row):
                continue

            record = {
                column: clean_value(column, value)
                for column, value in zip(columns, row)
            }
            records.append(record)

        loaded[sheet_name] = dedupe_records(sheet_name, records)

    return loaded


def completeness_score(record: dict[str, Any]) -> int:
    return sum(value is not None and value != "" for value in record.values())


def dedupe_records(sheet_name: str, records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    primary_key = next(iter(TABLES[sheet_name]["columns"]))
    by_key: dict[Any, dict[str, Any]] = {}

    for record in records:
        key = record[primary_key]
        existing = by_key.get(key)
        if existing is None or completeness_score(record) > completeness_score(existing):
            by_key[key] = record

    return list(by_key.values())


def add_historical_references(rows_by_sheet: dict[str, list[dict[str, Any]]]) -> None:
    service_ids = {row["service_id"] for row in rows_by_sheet["SERVICE"]}
    referenced_service_ids = {
        row["service_id"]
        for sheet_name in ("COST_CENTER", "PLAN_ENTITY_SERVICE")
        for row in rows_by_sheet[sheet_name]
        if row.get("service_id")
    }

    for service in HISTORICAL_SERVICES:
        if (
            service["service_id"] in referenced_service_ids
            and service["service_id"] not in service_ids
        ):
            rows_by_sheet["SERVICE"].append(service)
            service_ids.add(service["service_id"])


def sql_identifier(identifier: str) -> str:
    return '"' + identifier.replace('"', '""') + '"'


def sql_literal(value: Any) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, (date, datetime)):
        return "'" + value.isoformat().replace("'", "''") + "'"
    return "'" + str(value).replace("'", "''") + "'"


def create_table_sql(sheet_name: str) -> str:
    table = TABLES[sheet_name]
    lines = [
        f"CREATE TABLE IF NOT EXISTS {sql_identifier(table['name'])} (",
    ]
    column_defs = [
        f"    {sql_identifier(column)} {definition}"
        for column, definition in table["columns"].items()
    ]
    lines.append(",\n".join(column_defs))
    lines.append(");")
    return "\n".join(lines)


def alter_table_sql(sheet_name: str) -> str:
    table = TABLES[sheet_name]
    table_name = table["name"]
    statements = []

    for column, definition in list(table["columns"].items())[1:]:
        statements.append(
            f"ALTER TABLE {sql_identifier(table_name)} "
            f"ADD COLUMN IF NOT EXISTS {sql_identifier(column)} {definition};"
        )

    return "\n".join(statements)


def insert_sql(sheet_name: str, rows: list[dict[str, Any]]) -> str:
    table = TABLES[sheet_name]
    table_name = table["name"]
    columns = list(table["columns"].keys())
    primary_key = columns[0]
    update_columns = columns[1:]

    if not rows:
        return f"-- No rows found for {table_name}."

    values = []
    for row in rows:
        values.append(
            "    ("
            + ", ".join(sql_literal(row.get(column)) for column in columns)
            + ")"
        )

    column_list = ", ".join(sql_identifier(column) for column in columns)
    update_list = ", ".join(
        f"{sql_identifier(column)} = EXCLUDED.{sql_identifier(column)}"
        for column in update_columns
    )

    return (
        f"INSERT INTO {sql_identifier(table_name)} ({column_list})\n"
        "VALUES\n"
        + ",\n".join(values)
        + f"\nON CONFLICT ({sql_identifier(primary_key)}) DO UPDATE SET\n"
        f"    {update_list};"
    )


def build_sql(workbook_path: Path) -> str:
    rows_by_sheet = load_rows(workbook_path)
    add_historical_references(rows_by_sheet)
    sections = [
        "-- Generated from Group1_CityReference_Tables.xlsx.",
        "-- Run against the local cob_performance Postgres database.",
        "BEGIN;",
    ]

    for sheet_name in LOAD_ORDER:
        sections.append("")
        sections.append(f"-- {TABLES[sheet_name]['name']}")
        sections.append(create_table_sql(sheet_name))
        sections.append(alter_table_sql(sheet_name))
        sections.append(insert_sql(sheet_name, rows_by_sheet[sheet_name]))

    sections.append("")
    sections.append("COMMIT;")
    return "\n".join(sections) + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate Postgres SQL for the city reference workbook."
    )
    parser.add_argument("workbook", type=Path, help="Path to the source .xlsx file.")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("database/group1_city_reference_load.sql"),
        help="Path for the generated SQL file.",
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
