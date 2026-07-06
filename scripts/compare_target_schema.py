from __future__ import annotations

import csv
import re
from pathlib import Path

from docx import Document


TARGET_DOCX = Path(r"C:\Users\melanie.lada\Downloads\Target_Database_Schema_v2.docx")
CURRENT_COLUMNS = Path("outputs/database_documentation/columns.csv")
CURRENT_TABLES = Path("outputs/database_documentation/tables.csv")
OUTPUT_DIR = Path("outputs/schema_gap_analysis")
OUTPUT_CSV = OUTPUT_DIR / "schema_gap_analysis.csv"
TARGET_TABLES_CSV = OUTPUT_DIR / "target_schema_tables.csv"


INTENTIONAL_DIFFERENCES = {
    ("mission_vision", "mission"): "Renamed in the product to overview; performance.overview_vision.overview is canonical.",
    ("performance_measure", "is_kpi"): "Removed by product decision; goal KPIs and service metrics are represented by link tables and measure flags.",
}


def normalize_table_name(name: str) -> str:
    name = name.strip()
    name = name.splitlines()[0].strip()
    name = re.split(r"\s*/\s*", name, maxsplit=1)[0]
    name = re.sub(r"[^A-Za-z0-9_]+", "_", name)
    return name.strip("_").lower()


def canonical_to_current_location(table_name: str) -> tuple[str, str]:
    aliases = {
        "mission_vision": ("performance", "overview_vision"),
    }
    if table_name in aliases:
        return aliases[table_name]
    if table_name in {
        "pillar",
        "pillar_goal",
        "agency",
        "service",
        "cost_center",
        "plan_entity",
        "plan_entity_service",
        "action_plan_initiative",
        "action_plan_measure",
    }:
        return "reference", table_name
    if table_name in {"user", "user_role", "user_agency_access", "user_functions"}:
        return "access", table_name
    if table_name in {"plan_cycle", "agency_plan", "plan_section_draft", "budget_proposal"}:
        return "planning", table_name
    if table_name in {
        "plan_header",
        "overview_vision",
        "plan_pillar_alignment",
        "agency_goal",
        "agency_goal_pillar_link",
        "initiative",
        "agency_goal_initiative_link",
        "performance_measure",
        "measure_actuals",
        "pm_pillar_link",
        "pm_goal_link",
        "pm_service_link",
        "pm_service_reassignment",
        "plan_service",
        "service_goal_link",
        "service_risk",
        "data_reporting",
        "measure_entity_link",
    }:
        return "performance", table_name
    if table_name in {
        "service_fund_amount",
        "general_fund_change",
        "key_spend_category",
        "proposal_narrative",
        "cls_request",
        "cls_request_line",
        "cls_request_position",
        "enhancement",
        "enhancement_measure",
        "coa_request",
    }:
        return "budget", table_name
    if table_name in {"review_assignment", "plan_review", "section_score", "section_feedback"}:
        return "review", table_name
    if table_name in {"approval_record", "plan_status_history"}:
        return "workflow", table_name
    if table_name in {"plan_amendment", "amendment_unlock"}:
        return "amendment", table_name
    if table_name in {"slide_deck_export", "notification"}:
        return "output", table_name
    return "", table_name


def canonical_to_current_schema(table_name: str) -> str:
    return canonical_to_current_location(table_name)[0]


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def extract_target_tables() -> list[dict[str, str]]:
    doc = Document(TARGET_DOCX)
    records: list[dict[str, str]] = []
    for table in doc.tables:
        if len(table.rows) < 3 or len(table.columns) < 4:
            continue
        title = table.rows[0].cells[0].text.strip()
        header = [cell.text.strip().lower() for cell in table.rows[1].cells[:4]]
        if header[:3] != ["field", "type", "null?"]:
            continue
        table_name = normalize_table_name(title)
        if not table_name:
            continue
        for row in table.rows[2:]:
            cells = [cell.text.strip().replace("\n", " ") for cell in row.cells[:4]]
            if not any(cells) or cells[0].lower() == "field":
                continue
            field_raw = cells[0]
            field_name = re.sub(r"\s+(PK|FK[0-9]*|FK)\b.*$", "", field_raw, flags=re.I).strip()
            field_name = normalize_table_name(field_name)
            if not field_name:
                continue
            records.append(
                {
                    "target_table": table_name,
                    "target_field": field_name,
                    "target_type": cells[1],
                    "target_nullable": cells[2],
                    "target_notes": cells[3],
                }
            )
    return records


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    target = extract_target_tables()
    current_columns = read_csv(CURRENT_COLUMNS)
    current_tables = read_csv(CURRENT_TABLES)
    current_table_set = {(row["table_schema"], row["table_name"]) for row in current_tables}
    current_column_set = {(row["table_schema"], row["table_name"], row["column_name"]) for row in current_columns}

    target_table_names = sorted(set(row["target_table"] for row in target))
    with TARGET_TABLES_CSV.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=["target_table", "mapped_schema", "current_table", "current_exists"])
        writer.writeheader()
        for table_name in target_table_names:
            mapped_schema, current_table = canonical_to_current_location(table_name)
            writer.writerow(
                {
                    "target_table": table_name,
                    "mapped_schema": mapped_schema,
                    "current_table": current_table,
                    "current_exists": bool(mapped_schema and (mapped_schema, current_table) in current_table_set),
                }
            )

    rows = []
    for row in target:
        mapped_schema, current_table = canonical_to_current_location(row["target_table"])
        table_exists = bool(mapped_schema and (mapped_schema, current_table) in current_table_set)
        column_exists = bool(
            mapped_schema
            and (mapped_schema, current_table, row["target_field"]) in current_column_set
        )
        status = "matches current"
        if not mapped_schema:
            status = "unmapped target table"
        elif not table_exists:
            status = "missing table"
        elif (row["target_table"], row["target_field"]) in INTENTIONAL_DIFFERENCES:
            status = "intentionally different"
        elif not column_exists:
            status = "missing column"
        rows.append(
            {
                **row,
                "mapped_schema": mapped_schema,
                "current_table": current_table,
                "status": status,
                "decision_note": INTENTIONAL_DIFFERENCES.get((row["target_table"], row["target_field"]), ""),
            }
        )

    with OUTPUT_CSV.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    print(f"target_tables={len(target_table_names)}")
    print(f"target_fields={len(target)}")
    print(f"missing_tables={sum(1 for row in rows if row['status'] == 'missing table')}")
    print(f"missing_columns={sum(1 for row in rows if row['status'] == 'missing column')}")
    print(OUTPUT_CSV)


if __name__ == "__main__":
    main()
