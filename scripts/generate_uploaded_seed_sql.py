from __future__ import annotations

import argparse
import csv
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

import openpyxl


DEFAULT_PERFORMANCE_OUTPUT = Path("database/seed/performance_plan_seed.sql")
DEFAULT_USER_OUTPUT = Path("database/seed/user_roles_seed.sql")
DEFAULT_REFERENCE_SERVICE = Path("database/reference/service.csv")
FY2027_CYCLE_ID = 4
FY2027_DATE = date(2026, 6, 1)


def clean_header(value: Any) -> str:
    text = "" if value is None else str(value).strip()
    text = text.replace(" PK", "").replace(" FK2", "").replace(" FK", "")
    return text.strip().lower().replace(" ", "_")


def clean_value(value: Any) -> Any:
    if isinstance(value, str):
        value = value.strip()
        if value == "":
            return None
    return value


def read_sheet(workbook_path: Path, sheet_name: str) -> list[dict[str, Any]]:
    workbook = openpyxl.load_workbook(workbook_path, read_only=True, data_only=True)
    worksheet = workbook[sheet_name]
    rows = worksheet.iter_rows(values_only=True)
    headers = [clean_header(value) for value in next(rows)]
    records: list[dict[str, Any]] = []
    for raw_row in rows:
        record = {
            header: clean_value(value)
            for header, value in zip(headers, raw_row[: len(headers)])
            if header
        }
        if any(value is not None for value in record.values()):
            records.append(record)
    return records


def sql_identifier(identifier: str) -> str:
    return '"' + identifier.replace('"', '""') + '"'


def sql_literal(value: Any) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float, Decimal)):
        return str(value)
    if isinstance(value, (date, datetime)):
        return "'" + value.isoformat().replace("'", "''") + "'"
    return "'" + str(value).replace("'", "''") + "'"


def yes_no(value: Any, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"yes", "true", "1", "y"}


def normalize_app_role(value: Any) -> str:
    return str(value).strip()


def normalize_agency_role(value: Any) -> str:
    role = "" if value is None else str(value).strip()
    if role == "Performance Metric Updates":
        return "Performance Lead"
    return role


def normalize_direction(value: Any) -> str:
    direction = "" if value is None else str(value).strip()
    if direction.lower() == "increase":
        return "Increase"
    return direction or "Not Applicable"


def normalize_format(value: Any) -> str:
    return "N/A" if value is None else str(value).strip()


def normalize_change_mapping(value: Any) -> Any:
    if value is None:
        return None
    mapping = str(value).strip()
    return mapping or None


def normalize_cycle_id(value: Any) -> int:
    if value is None:
        return FY2027_CYCLE_ID
    try:
        numeric = int(value)
    except (TypeError, ValueError):
        return FY2027_CYCLE_ID
    if numeric == 2027:
        return FY2027_CYCLE_ID
    return numeric


def normalize_plan_date(value: Any) -> date:
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    if isinstance(value, str) and value.strip().upper() == "FY27":
        return FY2027_DATE
    return FY2027_DATE


def insert_values(table: str, columns: list[str], rows: list[list[Any]], pk: str | None = None) -> str:
    if not rows:
        return f"-- No rows for {table}."
    column_sql = ", ".join(sql_identifier(column) for column in columns)
    value_sql = ",\n".join(
        "    (" + ", ".join(sql_literal(value) for value in row) + ")"
        for row in rows
    )
    sql = f"INSERT INTO {table} ({column_sql})\nVALUES\n{value_sql}"
    if pk:
        update_columns = [column for column in columns if column != pk]
        update_sql = ", ".join(
            f"{sql_identifier(column)} = EXCLUDED.{sql_identifier(column)}"
            for column in update_columns
        )
        sql += f"\nON CONFLICT ({sql_identifier(pk)}) DO UPDATE SET\n    {update_sql};"
    else:
        sql += "\nON CONFLICT DO NOTHING;"
    return sql


def reset_sequence(table: str, pk: str) -> str:
    return (
        "SELECT setval(\n"
        f"    pg_get_serial_sequence('{table}', '{pk}'),\n"
        f"    COALESCE((SELECT MAX({sql_identifier(pk)}) FROM {table}), 1),\n"
        f"    (SELECT COUNT(*) > 0 FROM {table})\n"
        ");"
    )


def generate_user_seed(user_workbook: Path, output_path: Path) -> None:
    users = read_sheet(user_workbook, "USER")
    roles = read_sheet(user_workbook, "USER_ROLE")
    functions = read_sheet(user_workbook, "USER_FUNCTIONS")

    sections = [
        "-- Generated from User_Roles.xlsx.",
        "-- Run after database/schema/target_schema.sql and database/seed/load_reference_seed.sql.",
        "BEGIN;",
    ]

    user_email_by_id = {
        row.get("user_id"): row.get("email")
        for row in users
        if row.get("user_id") and row.get("email")
    }
    user_columns = ["email", "full_name", "phone", "auth_type", "password_hash", "active", "created_at"]
    user_rows = [
        [
            row.get("email"),
            row.get("full_name"),
            row.get("phone"),
            row.get("auth_type") or "MicrosoftAD",
            row.get("password_hash"),
            True if row.get("active") is None else yes_no(row.get("active"), True),
            row.get("created_at") or datetime.now(),
        ]
        for row in users
        if row.get("user_id") and row.get("email")
    ]
    sections.append("")
    sections.append(
        insert_values('access."user"', user_columns, user_rows, None).replace(
            "ON CONFLICT DO NOTHING;",
            "ON CONFLICT (email) DO UPDATE SET\n"
            "    full_name = EXCLUDED.full_name, phone = EXCLUDED.phone, auth_type = EXCLUDED.auth_type,\n"
            "    password_hash = EXCLUDED.password_hash, active = EXCLUDED.active, updated_at = now();",
        )
    )
    sections.append(reset_sequence('access."user"', "user_id"))

    role_rows = []
    for row in roles:
        app_role = normalize_app_role(row.get("app_role"))
        if not row.get("user_role_id") or not row.get("user_id") or not app_role or app_role == "None":
            continue
        role_rows.append(
            [
                row.get("user_role_id"),
                row.get("user_id"),
                app_role,
                row.get("agency_id"),
                row.get("granted_at") or datetime.now(),
                yes_no(row.get("budget_access"), False),
                yes_no(row.get("adaptive_planning"), False),
                yes_no(row.get("performance_plan_access"), False),
            ]
        )
    role_values = ",\n".join(
        "    (" + ", ".join(sql_literal(value) for value in role) + ")"
        for role in role_rows
    )
    sections.append("")
    sections.append(
        "INSERT INTO access.user_role (user_role_id, user_id, app_role, agency_id, granted_at, budget_access, adaptive_planning, performance_plan_access)\n"
        "SELECT seed.user_role_id, u.user_id, seed.app_role, seed.agency_id, seed.granted_at::timestamptz, seed.budget_access, seed.adaptive_planning, seed.performance_plan_access\n"
        f"FROM (VALUES\n{role_values}\n"
        ") AS seed(user_role_id, email, app_role, agency_id, granted_at, budget_access, adaptive_planning, performance_plan_access)\n"
        "JOIN access.\"user\" u ON lower(u.email) = lower(seed.email)\n"
        "ON CONFLICT (user_role_id) DO UPDATE SET\n"
        "    user_id = EXCLUDED.user_id, app_role = EXCLUDED.app_role, agency_id = EXCLUDED.agency_id,\n"
        "    granted_at = EXCLUDED.granted_at, budget_access = EXCLUDED.budget_access,\n"
        "    adaptive_planning = EXCLUDED.adaptive_planning, performance_plan_access = EXCLUDED.performance_plan_access;"
    )
    sections.append(reset_sequence("access.user_role", "user_role_id"))

    access_rows = []
    for row in functions:
        if not row.get("user_id") or not row.get("agency_id"):
            continue
        email = user_email_by_id.get(row.get("user_id"))
        if not email:
            continue
        agency_role = normalize_agency_role(row.get("agency_role"))
        if not agency_role:
            continue
        access_rows.append(
            [
                email,
                row.get("agency_id"),
                row.get("service_id"),
                agency_role,
            ]
        )
    sections.append("")
    sections.append(
        "INSERT INTO access.user_agency_access (user_id, agency_id, service_id, agency_role)\n"
        "SELECT u.user_id, seed.agency_id, seed.service_id, seed.agency_role\n"
        "FROM (VALUES\n"
        + ",\n".join("    (" + ", ".join(sql_literal(value) for value in row) + ")" for row in access_rows)
        + "\n) AS seed(email, agency_id, service_id, agency_role)\n"
        "JOIN access.\"user\" u ON lower(u.email) = lower(seed.email)\n"
        "WHERE NOT EXISTS (\n"
        "    SELECT 1 FROM access.user_agency_access existing\n"
        "    WHERE existing.user_id = u.user_id\n"
        "      AND existing.agency_id = seed.agency_id\n"
        "      AND COALESCE(existing.service_id, '') = COALESCE(seed.service_id, '')\n"
        ")\n"
        "ON CONFLICT DO NOTHING;"
    )
    sections.append(reset_sequence("access.user_agency_access", "access_id"))
    sections.append("")
    sections.append("COMMIT;")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(sections) + "\n", encoding="utf-8")
    print(f"Wrote {output_path}")


def service_agency_lookup(reference_service_csv: Path) -> dict[str, str]:
    with reference_service_csv.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        return {row["service_id"]: row["agency_id"] for row in reader}


def generate_performance_seed(performance_workbook: Path, output_path: Path, reference_service_csv: Path) -> None:
    service_agency = service_agency_lookup(reference_service_csv)
    agency_plan = {"AGC2600": 1, "AGC4346": 2}
    plan_agency = {1: "AGC2600", 2: "AGC4346"}

    sections = [
        "-- Generated from Group4_PerformancePlan_Tables.xlsx.",
        "-- Run after schema, reference seed, and user role seed.",
        "BEGIN;",
        "",
        "INSERT INTO planning.plan_cycle (cycle_id, fiscal_year, summer_open, summer_close, fall_open, fall_close, cycle_status, created_by)\n"
        "SELECT 4, 2027, '2026-06-01', '2026-08-31', '2026-09-15', '2026-11-15', 'FallOpen', MIN(user_id) FROM access.\"user\"\n"
        "ON CONFLICT (cycle_id) DO UPDATE SET fiscal_year = EXCLUDED.fiscal_year, cycle_status = EXCLUDED.cycle_status;",
    ]

    plan_rows = [
        [plan_id, agency_id, None, FY2027_CYCLE_ID, "Draft", "Draft", 1, None, None, None, datetime.now(), datetime.now()]
        for plan_id, agency_id in plan_agency.items()
    ]
    sections.append("")
    sections.append(insert_values("planning.agency_plan", ["plan_id", "agency_id", "entity_id", "cycle_id", "plan_status", "budget_status", "version", "assigned_reviewer", "submitted_at", "approved_at", "created_at", "updated_at"], plan_rows, "plan_id"))
    sections.append(reset_sequence("planning.agency_plan", "plan_id"))

    plan_header = read_sheet(performance_workbook, "PLAN_HEADER")
    sections.append("")
    sections.append(insert_values("performance.plan_header", ["header_id", "plan_id", "primary_contact_name", "primary_contact_email", "plan_date", "version_label"], [[r.get("header_id"), r.get("plan_id"), r.get("primary_contact_name"), r.get("primary_contact_email"), normalize_plan_date(r.get("plan_date")), r.get("version_label")] for r in plan_header], "header_id"))
    sections.append(reset_sequence("performance.plan_header", "header_id"))

    overview = read_sheet(performance_workbook, "OVERVIEW_VISION")
    sections.append("")
    sections.append(insert_values("performance.overview_vision", ["mv_id", "plan_id", "overview", "vision", "web_address"], [[r.get("ov_id"), r.get("plan_id"), r.get("overview"), r.get("vision"), None] for r in overview], "mv_id"))
    sections.append(reset_sequence("performance.overview_vision", "mv_id"))

    mappings = [
        ("PLAN_PILLAR_ALIGNMENT", "performance.plan_pillar_alignment", ["alignment_id", "plan_id", "pillar_id"], "alignment_id"),
        ("AGENCY_GOAL", "performance.agency_goal", ["agency_goal_id", "plan_id", "title", "sort_order"], "agency_goal_id"),
        ("AGENCY_GOAL_PILLAR_LINK", "performance.agency_goal_pillar_link", ["link_id", "agency_goal_id", "pillar_goal_id", "link_type", "alignment_narrative"], "link_id"),
        ("INITIATIVE", "performance.initiative", ["initiative_id", "title", "description", "status"], "initiative_id"),
        ("AGENCY_GOAL_INITIATIVE_LINK", "performance.agency_goal_initiative_link", ["link_id", "agency_goal_id", "initiative_id", "link_type"], "link_id"),
        ("PLAN_RISK", "performance.service_risk", ["risk_id", "plan_id", "description"], "risk_id"),
    ]
    for sheet, table, columns, pk in mappings:
        rows = read_sheet(performance_workbook, sheet)
        sections.append("")
        sections.append(insert_values(table, columns, [[row.get(column) for column in columns] for row in rows], pk))
        sections.append(reset_sequence(table, pk))

    measures = []
    for row in read_sheet(performance_workbook, "PERFORMANCE_MEASURE"):
        is_city = row.get("is_city") or False
        is_agency = row.get("is_agency") or False
        is_service = row.get("is_service") or False
        if not is_city and not is_agency and not is_service:
            is_service = True
        measures.append([
            row.get("measure_id"),
            row.get("agency_id"),
            normalize_cycle_id(row.get("initial_cycle")),
            row.get("title"),
            row.get("measure_type") or "Output",
            row.get("description") or "Definition pending.",
            row.get("data_source") or "Source pending.",
            row.get("data_owner") or "Owner pending.",
            row.get("data_owner_title") or "Owner role pending.",
            row.get("update_frequency") or "Frequency pending.",
            row.get("formula") or "Formula pending.",
            normalize_direction(row.get("desired_direction")),
            row.get("baseline_value"),
            row.get("baseline_fy"),
            normalize_format(row.get("format_type")),
            row.get("display_unit"),
            row.get("context_required"),
            row.get("replicability"),
            row.get("disaggregation"),
            row.get("data_location"),
            row.get("collection_method"),
            row.get("how_data_used"),
            row.get("why_meaningful"),
            row.get("proxy_measure"),
            row.get("improvement_notes"),
            normalize_change_mapping(row.get("change_mapping")),
            row.get("pillar_id"),
            row.get("pillar_goal_id"),
            is_city,
            is_agency,
            is_service,
            row.get("validated") or False,
            "Validated" if row.get("validated") else "Draft",
            row.get("created_date") or FY2027_DATE,
            row.get("last_updated") or datetime.now(),
        ])
    measure_columns = ["measure_id", "agency_id", "initial_cycle", "title", "measure_type", "description", "data_source", "data_owner", "data_owner_role", "update_frequency", "formula", "desired_direction", "baseline_value", "baseline_fy", "format_type", "display_unit", "context_required", "replicability", "disaggregation", "data_location", "collection_method", "how_data_used", "why_meaningful", "proxy_measure", "improvement_notes", "change_mapping", "pillar_id", "pillar_goal_id", "is_city", "is_agency", "is_service", "validated", "approval_status", "created_date", "last_updated"]
    sections.append("")
    sections.append(insert_values("performance.performance_measure", measure_columns, measures, "measure_id"))
    sections.append(reset_sequence("performance.performance_measure", "measure_id"))

    actuals = []
    for row in read_sheet(performance_workbook, "MEASURE_ACTUALS"):
        actuals.append([row.get(column) for column in ["actual_id", "measure_id", "fiscal_year", "q1_value", "q1_notes", "q2_value", "q2_notes", "q3_value", "q3_notes", "q4_value", "q4_notes", "annual_actual", "annual_actual_notes", "target_value", "target_value_notes"]] + [row.get("reported_by") or 2, row.get("created_at") or datetime.now(), row.get("updated_at") or datetime.now()])
    actual_columns = ["actual_id", "measure_id", "fiscal_year", "q1_value", "q1_notes", "q2_value", "q2_notes", "q3_value", "q3_notes", "q4_value", "q4_notes", "annual_actual", "annual_actual_notes", "target_value", "target_value_notes", "reported_by", "created_at", "updated_at"]
    sections.append("")
    sections.append(insert_values("performance.measure_actuals", actual_columns, actuals, "actual_id"))
    sections.append(reset_sequence("performance.measure_actuals", "actual_id"))

    pm_service = read_sheet(performance_workbook, "PM_SERVICE_LINK")
    service_ids = []
    for row in pm_service:
        service_id = row.get("service_id")
        if service_id and service_id not in service_ids:
            service_ids.append(service_id)
    plan_service_rows = []
    plan_service_lookup = {}
    local_service_order_by_plan: dict[int, int] = {}
    for index, service_id in enumerate(service_ids, start=1):
        agency_id = service_agency.get(service_id)
        plan_id = agency_plan.get(agency_id)
        if plan_id is None:
            continue
        local_order = local_service_order_by_plan.get(plan_id, 0) + 1
        local_service_order_by_plan[plan_id] = local_order
        plan_service_lookup[(plan_id, local_order)] = index
        plan_service_rows.append([index, plan_id, service_id, local_order])
    sections.append("")
    sections.append(insert_values("performance.plan_service", ["plan_service_id", "plan_id", "service_id", "sort_order"], plan_service_rows, "plan_service_id"))
    sections.append(reset_sequence("performance.plan_service", "plan_service_id"))

    for sheet, table, columns, pk in [
        ("PM_GOAL_LINK", "performance.pm_goal_link", ["link_id", "measure_id", "agency_goal_id"], "link_id"),
        ("PM_SERVICE_LINK", "performance.pm_service_link", ["link_id", "measure_id", "service_id"], "link_id"),
    ]:
        rows = read_sheet(performance_workbook, sheet)
        sections.append("")
        sections.append(insert_values(table, columns, [[row.get(column) for column in columns] for row in rows], pk))
        sections.append(reset_sequence(table, pk))

    agency_goal_plan = {
        row.get("agency_goal_id"): row.get("plan_id")
        for row in read_sheet(performance_workbook, "AGENCY_GOAL")
        if row.get("agency_goal_id") and row.get("plan_id")
    }
    service_goal_rows = []
    skipped_service_goal_rows = []
    for row in read_sheet(performance_workbook, "SERVICE_GOAL_LINK"):
        plan_id = agency_goal_plan.get(row.get("agency_goal_id"))
        plan_service_id = plan_service_lookup.get((plan_id, row.get("plan_service_id")))
        if plan_service_id is None:
            skipped_service_goal_rows.append(row.get("sgl_id"))
            continue
        service_goal_rows.append([
            row.get("sgl_id"),
            plan_service_id,
            row.get("agency_goal_id"),
            row.get("initiative_id"),
        ])

    sections.append("")
    sections.append("-- SERVICE_GOAL_LINK plan_service_id values are plan-local in the workbook and are mapped by the linked agency goal's plan.")
    if skipped_service_goal_rows:
        sections.append(f"-- Skipped SERVICE_GOAL_LINK rows with unresolved plan service references: {', '.join(str(row_id) for row_id in skipped_service_goal_rows)}")
    sections.append(insert_values("performance.service_goal_link", ["sgl_id", "plan_service_id", "agency_goal_id", "initiative_id"], service_goal_rows, "sgl_id"))
    sections.append(reset_sequence("performance.service_goal_link", "sgl_id"))
    sections.append("")
    sections.append("COMMIT;")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(sections) + "\n", encoding="utf-8")
    print(f"Wrote {output_path}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate real seed SQL from uploaded Beacon seed workbooks.")
    parser.add_argument("--performance-workbook", type=Path, required=True)
    parser.add_argument("--user-workbook", type=Path, required=True)
    parser.add_argument("--performance-output", type=Path, default=DEFAULT_PERFORMANCE_OUTPUT)
    parser.add_argument("--user-output", type=Path, default=DEFAULT_USER_OUTPUT)
    parser.add_argument("--reference-service", type=Path, default=DEFAULT_REFERENCE_SERVICE)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    generate_user_seed(args.user_workbook, args.user_output)
    generate_performance_seed(args.performance_workbook, args.performance_output, args.reference_service)


if __name__ == "__main__":
    main()
