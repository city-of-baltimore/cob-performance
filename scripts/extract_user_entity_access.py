from __future__ import annotations

import json
from pathlib import Path

import pandas as pd


SOURCE = Path(r"C:\Users\melanie.lada\Downloads\User_Roles (1).xlsx")
OUTPUT = Path("tmp/user_entity_access.json")
SHEET = "DH_USERLIST With Entities"


def clean(value):
    if pd.isna(value):
        return ""
    text = str(value).replace("\xa0", " ").strip()
    return "" if text.lower() == "nan" else text


def yes_no(value):
    text = clean(value).lower()
    if text in {"yes", "true", "1", "y"}:
        return "Yes"
    if text in {"no", "false", "0", "n"}:
        return "No"
    return ""


df = pd.read_excel(SOURCE, sheet_name=SHEET)
records = []

for _, row in df.iterrows():
    entity_id = clean(row.get("Entity ID"))
    entity_name = clean(row.get("Entity Name"))
    final_name = clean(row.get("Final Tracking Name"))
    agency_name = clean(row.get("Agency Name"))
    scope_type = "entity" if entity_id or entity_name else "agency"
    records.append(
        {
            "assignment_id": clean(row.get("ID")),
            "user_email": clean(row.get("user_id FK2")).lower(),
            "app_role": clean(row.get("app_role")),
            "agency_id": clean(row.get("agency_id FK")),
            "agency_name": agency_name,
            "entity_id": entity_id,
            "entity_name": entity_name,
            "scope_type": scope_type,
            "scope_label": final_name or entity_name or agency_name,
            "budget_access": yes_no(row.get("budget_access")),
            "adaptive_planning": yes_no(row.get("adaptive_planning")),
            "performance_plan_access": yes_no(row.get("performance_plan_access")),
            "assigned_by": clean(row.get("assigned_by")),
        }
    )

OUTPUT.parent.mkdir(parents=True, exist_ok=True)
OUTPUT.write_text(json.dumps(records, indent=2), encoding="utf-8")
print(f"Wrote {len(records)} rows to {OUTPUT}")
