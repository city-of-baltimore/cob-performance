from __future__ import annotations

import argparse
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

import openpyxl


DEFAULT_OUTPUT = Path("database/dummy/target_dummy_load.sql")

BOOLEAN_COLUMNS = {
    "active",
    "adaptive_planning",
    "arpa_funded",
    "budget_access",
    "completed",
    "external_funds",
    "has_own_plan",
    "is_agency",
    "is_city",
    "is_kpi",
    "is_primary",
    "is_quasi",
    "is_service",
    "one_time",
    "performance_plan_access",
    "quasi",
    "replicability",
    "return_required",
    "review_complete",
    "service_impact",
    "validated",
}

TEXT_PRIMARY_KEYS = {"agency_id", "service_id", "cost_center_id"}

TARGET_TABLES: list[dict[str, Any]] = [
    {"sheet": "PILLAR", "table": "reference.pillar", "pk": "pillar_id"},
    {"sheet": "PILLAR_GOAL", "table": "reference.pillar_goal", "pk": "pillar_goal_id"},
    {"sheet": "AGENCY", "table": "reference.agency", "pk": "agency_id"},
    {"sheet": "SERVICE", "table": "reference.service", "pk": "service_id"},
    {"sheet": "COST_CENTER", "table": "reference.cost_center", "pk": "cost_center_id"},
    {"sheet": "PLAN_ENTITY", "table": "reference.plan_entity", "pk": "entity_id"},
    {"sheet": "PLAN_ENTITY_SERVICE", "table": "reference.plan_entity_service", "pk": "pes_id"},
    {"sheet": "USER", "table": 'access."user"', "pk": "user_id"},
    {"sheet": "USER_ROLE", "table": "access.user_role", "pk": "user_role_id"},
    {"sheet": "USER_FUNCTIONS", "table": "access.user_agency_access", "pk": "access_id"},
    {"sheet": "PLAN_CYCLE", "table": "planning.plan_cycle", "pk": "cycle_id"},
    {"sheet": "AGENCY_PLAN", "table": "planning.agency_plan", "pk": "plan_id"},
    {"sheet": "PLAN_HEADER", "table": "performance.plan_header", "pk": "header_id"},
    {"sheet": "MISSION_VISION", "table": "performance.mission_vision", "pk": "mv_id"},
    {"sheet": "PLAN_PILLAR_ALIGNMENT", "table": "performance.plan_pillar_alignment", "pk": "alignment_id"},
    {"sheet": "AGENCY_GOAL", "table": "performance.agency_goal", "pk": "agency_goal_id"},
    {"sheet": "AGENCY_GOAL_PILLAR_LINK", "table": "performance.agency_goal_pillar_link", "pk": "link_id"},
    {"sheet": "INITIATIVE", "table": "performance.initiative", "pk": "initiative_id"},
    {"sheet": "AGENCY_GOAL_INITIATIVE_LINK", "table": "performance.agency_goal_initiative_link", "pk": "link_id"},
    {"sheet": "PERFORMANCE_MEASURE", "table": "performance.performance_measure", "pk": "measure_id"},
    {"sheet": "MEASURE_ACTUALS", "table": "performance.measure_actuals", "pk": "actual_id"},
    {"sheet": "PM_GOAL_LINK", "table": "performance.pm_goal_link", "pk": "link_id"},
    {"sheet": "PM_SERVICE_LINK", "table": "performance.pm_service_link", "pk": "link_id"},
    {"sheet": "PM_SERVICE_REASSIGNMENT", "table": "performance.pm_service_reassignment", "pk": "reassignment_id"},
    {"sheet": "PLAN_SERVICE", "table": "performance.plan_service", "pk": "plan_service_id"},
    {"sheet": "SERVICE_GOAL_LINK", "table": "performance.service_goal_link", "pk": "sgl_id"},
    {"sheet": "PLAN_RISK", "table": "performance.service_risk", "pk": "risk_id"},
    {"sheet": "SERVICE_FUND_AMOUNT", "table": "budget.service_fund_amount", "pk": "sfa_id"},
    {"sheet": "GENERAL_FUND_CHANGE", "table": "budget.general_fund_change", "pk": "change_id"},
    {"sheet": "KEY_SPEND_CATEGORY", "table": "budget.key_spend_category", "pk": "ksc_id"},
    {"sheet": "PROPOSAL_NARRATIVE", "table": "budget.proposal_narrative", "pk": "narrative_id"},
    {"sheet": "CLS_REQUEST", "table": "budget.cls_request", "pk": "cls_id"},
    {"sheet": "CLS_REQUEST_LINE", "table": "budget.cls_request_line", "pk": "line_id"},
    {"sheet": "CLS_REQUEST_POSITION", "table": "budget.cls_request_position", "pk": "pos_id"},
    {"sheet": "ENHANCEMENT", "table": "budget.enhancement", "pk": "enhancement_id"},
    {"sheet": "ENHANCEMENT_MEASURE", "table": "budget.enhancement_measure", "pk": "em_id"},
    {"sheet": "COA_REQUEST", "table": "budget.coa_request", "pk": "coa_id"},
    {"sheet": "PLAN_REVIEW", "table": "review.plan_review", "pk": "review_id"},
    {"sheet": "SECTION_SCORE", "table": "review.section_score", "pk": "score_id"},
    {"sheet": "SECTION_FEEDBACK", "table": "review.section_feedback", "pk": "feedback_id"},
    {"sheet": "APPROVAL_RECORD", "table": "workflow.approval_record", "pk": "approval_id"},
    {"sheet": "PLAN_STATUS_HISTORY", "table": "workflow.plan_status_history", "pk": "history_id"},
    {"sheet": "PLAN_AMENDMENT", "table": "amendment.plan_amendment", "pk": "amendment_id"},
    {"sheet": "AMENDMENT_UNLOCK", "table": "amendment.amendment_unlock", "pk": "unlock_id"},
    {"sheet": "SLIDE_DECK_EXPORT", "table": "output.slide_deck_export", "pk": "export_id"},
    {"sheet": "NOTIFICATION", "table": "output.notification", "pk": "notification_id"},
]


TARGET_COLUMNS: dict[str, list[str]] = {
    "reference.pillar": ["pillar_id", "pillar_name", "pillar_lead", "sort_order", "updated_at"],
    "reference.pillar_goal": ["pillar_goal_id", "pillar_id", "goal_code", "goal_title", "goal_lead", "sort_order"],
    "reference.agency": ["agency_id", "agency_name", "public_name", "deputy_mayor_pillar", "is_quasi", "active"],
    "reference.service": ["service_id", "service_name", "agency_id", "service_type", "service_description", "active"],
    "reference.cost_center": ["cost_center_id", "cost_center_name", "service_id", "agency_id", "active"],
    "reference.plan_entity": ["entity_id", "parent_agency_id", "public_name", "entity_type", "has_own_plan", "active"],
    "reference.plan_entity_service": ["pes_id", "entity_id", "service_id", "is_primary"],
    'access."user"': ["user_id", "email", "full_name", "phone", "auth_type", "password_hash", "active", "created_at"],
    "access.user_role": ["user_role_id", "user_id", "app_role", "agency_id", "pillar_id", "granted_at", "budget_access", "adaptive_planning", "performance_plan_access", "quasi"],
    "access.user_agency_access": ["access_id", "user_id", "agency_id", "service_id", "agency_role"],
    "planning.plan_cycle": ["cycle_id", "fiscal_year", "summer_open", "summer_close", "fall_open", "fall_close", "cycle_status", "created_by"],
    "planning.agency_plan": ["plan_id", "agency_id", "entity_id", "cycle_id", "plan_status", "budget_status", "version", "assigned_reviewer", "submitted_at", "approved_at", "created_at", "updated_at"],
    "performance.plan_header": ["header_id", "plan_id", "primary_contact_name", "primary_contact_email", "plan_date", "version_label"],
    "performance.mission_vision": ["mv_id", "plan_id", "mission", "vision"],
    "performance.plan_pillar_alignment": ["alignment_id", "plan_id", "pillar_id"],
    "performance.agency_goal": ["agency_goal_id", "plan_id", "title", "description", "sort_order", "created_at"],
    "performance.agency_goal_pillar_link": ["link_id", "agency_goal_id", "pillar_goal_id", "link_type", "alignment_narrative", "created_date"],
    "performance.initiative": ["initiative_id", "title", "description", "start_date", "end_date", "status", "created_date", "last_updated"],
    "performance.agency_goal_initiative_link": ["link_id", "agency_goal_id", "initiative_id", "link_type", "created_date"],
    "performance.performance_measure": ["measure_id", "agency_id", "initial_cycle", "title", "is_kpi", "measure_type", "description", "data_source", "data_owner", "data_owner_role", "update_frequency", "formula", "desired_direction", "baseline_value", "baseline_fy", "format_type", "display_unit", "context_required", "replicability", "disaggregation", "data_location", "collection_method", "how_data_used", "why_meaningful", "proxy_measure", "improvement_notes", "change_mapping", "pillar_id", "pillar_goal_id", "is_city", "is_agency", "is_service", "validated", "created_date", "last_updated"],
    "performance.measure_actuals": ["actual_id", "measure_id", "fiscal_year", "q1_value", "q1_notes", "q2_value", "q2_notes", "q3_value", "q3_notes", "q4_value", "q4_notes", "annual_actual", "annual_actual_notes", "target_value", "target_value_notes", "reported_by", "created_at", "updated_at"],
    "performance.pm_goal_link": ["link_id", "measure_id", "agency_goal_id"],
    "performance.pm_service_link": ["link_id", "measure_id", "service_id"],
    "performance.pm_service_reassignment": ["reassignment_id", "measure_id", "old_service_id", "new_service_id", "cycle_id", "reason", "changed_date", "changed_by"],
    "performance.plan_service": ["plan_service_id", "plan_id", "service_id", "sort_order"],
    "performance.service_goal_link": ["sgl_id", "plan_service_id", "agency_goal_id", "initiative_id"],
    "performance.service_risk": ["risk_id", "plan_id", "description"],
    "budget.service_fund_amount": ["sfa_id", "plan_service_id", "fund_id", "fy_adopted", "cls_amount", "request_amount", "positions_adopted", "positions_cls", "positions_request", "fy25_actuals", "fy26_actuals"],
    "budget.general_fund_change": ["change_id", "plan_service_id", "object_type", "description", "dollar_change", "position_change", "service_impact", "sort_order"],
    "budget.key_spend_category": ["ksc_id", "plan_service_id", "category", "amount", "description"],
    "budget.proposal_narrative": ["narrative_id", "plan_service_id", "major_changes", "service_impact", "position_impact", "equity_narrative", "assumed_rates_desc", "grant_award_desc"],
    "budget.cls_request": ["cls_id", "plan_service_id", "request_name", "request_type", "request_amount", "one_time", "overall_summary", "justified", "completed", "amount_next_fy", "amount_2next_fy"],
    "budget.cls_request_line": ["line_id", "cls_id", "object_category", "amount", "justification", "sort_order"],
    "budget.cls_request_position": ["pos_id", "cls_id", "classification", "position_count", "estimated_salary", "justification", "explanation"],
    "budget.enhancement": ["enhancement_id", "plan_service_id", "name", "description", "total_cost", "position_cost", "position_count", "position_classification", "q1_service_delivery", "q2_revenue", "q3_cost_savings", "q4_future_savings", "external_funds", "arpa_funded", "completed"],
    "budget.enhancement_measure": ["em_id", "enhancement_id", "measure_title", "measure_type", "baseline_value", "target_value", "data_type", "sort_order"],
    "budget.coa_request": ["coa_id", "plan_service_id", "request_type", "new_cost_center_name", "justification", "criteria_met", "approval_status", "reviewed_by"],
    "review.plan_review": ["review_id", "plan_id", "reviewer_id", "review_started_at", "feedback_released_at", "overall_score", "internal_notes", "review_complete"],
    "review.section_score": ["score_id", "review_id", "section_code", "criterion_code", "score", "weight", "weighted_score", "justification"],
    "review.section_feedback": ["feedback_id", "review_id", "section_code", "feedback_text", "return_required", "resolved_at"],
    "workflow.approval_record": ["approval_id", "plan_id", "approver_id", "approver_role", "action", "notes", "return_target", "action_at"],
    "workflow.plan_status_history": ["history_id", "plan_id", "changed_by", "from_status", "to_status", "plan_phase", "changed_at", "notes"],
    "amendment.plan_amendment": ["amendment_id", "plan_id", "initiated_by", "reason", "amendment_status", "initiated_at", "reapproved_at", "version_before", "version_after"],
    "amendment.amendment_unlock": ["unlock_id", "amendment_id", "section_code", "unlock_reason", "relocked_at"],
    "output.slide_deck_export": ["export_id", "plan_id", "generated_by", "generated_at", "plan_version", "file_path", "trigger"],
    "output.notification": ["notification_id", "plan_id", "recipient_id", "notification_type", "sent_at", "read_at", "channel"],
}


def sql_identifier(identifier: str) -> str:
    return '"' + identifier.replace('"', '""') + '"'


def clean_value(value: Any) -> Any:
    if isinstance(value, str):
        value = value.strip()
        if value == "":
            return None
    return value


def sql_literal(value: Any, column: str) -> str:
    if value is None:
        return "NULL"
    if column in BOOLEAN_COLUMNS:
        if isinstance(value, str):
            return "true" if value.lower() in {"true", "yes", "y", "1"} else "false"
        return "true" if bool(value) else "false"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float, Decimal)):
        return str(value)
    if isinstance(value, (date, datetime)):
        return "'" + value.isoformat().replace("'", "''") + "'"
    return "'" + str(value).replace("'", "''") + "'"


def load_rows(workbook_path: Path, sheet_name: str) -> list[dict[str, Any]]:
    workbook = openpyxl.load_workbook(workbook_path, read_only=True, data_only=True)
    worksheet = workbook[sheet_name]
    rows = worksheet.iter_rows(values_only=True)
    headers = [str(value).strip().lower() for value in next(rows)]
    records = []

    for raw_row in rows:
        record = {
            column: clean_value(value)
            for column, value in zip(headers, raw_row[: len(headers)])
        }
        if any(value is not None for value in record.values()):
            records.append(record)

    return records


def insert_sql(table: str, pk: str, rows: list[dict[str, Any]]) -> str:
    columns = TARGET_COLUMNS[table]
    if not rows:
        return f"-- No rows found for {table}."

    values = []
    for row in rows:
        values.append(
            "    ("
            + ", ".join(sql_literal(row.get(column), column) for column in columns)
            + ")"
        )

    column_list = ", ".join(sql_identifier(column) for column in columns)
    update_columns = [column for column in columns if column != pk]
    update_list = ", ".join(
        f"{sql_identifier(column)} = EXCLUDED.{sql_identifier(column)}"
        for column in update_columns
    )

    return (
        f"INSERT INTO {table} ({column_list})\n"
        "VALUES\n"
        + ",\n".join(values)
        + f"\nON CONFLICT ({sql_identifier(pk)}) DO UPDATE SET\n"
        f"    {update_list};"
    )


def reset_sequence_sql(table: str, pk: str) -> str:
    if pk in TEXT_PRIMARY_KEYS:
        return f"-- {table}.{pk} is text; no identity sequence to reset."

    table_literal = table.replace("'", "''")
    return (
        "SELECT setval(\n"
        f"    pg_get_serial_sequence('{table_literal}', '{pk}'),\n"
        f"    COALESCE((SELECT MAX({sql_identifier(pk)}) FROM {table}), 1),\n"
        f"    (SELECT COUNT(*) > 0 FROM {table})\n"
        ");"
    )


def build_sql(workbook_path: Path) -> str:
    sections = [
        "-- Generated from CivicAlign_DummyData.xlsx for the target namespaced schema.",
        "-- Run database/schema/target_schema.sql before this file.",
        "BEGIN;",
    ]

    for table_config in TARGET_TABLES:
        sheet_name = table_config["sheet"]
        table = table_config["table"]
        pk = table_config["pk"]
        rows = load_rows(workbook_path, sheet_name)

        sections.append("")
        sections.append(f"-- {sheet_name} -> {table}")
        sections.append(insert_sql(table, pk, rows))
        sections.append(reset_sequence_sql(table, pk))

    sections.append("")
    sections.append("COMMIT;")
    return "\n".join(sections) + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate target-schema Postgres dummy seed SQL from CivicAlign_DummyData.xlsx."
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
