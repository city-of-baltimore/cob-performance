from __future__ import annotations

import re
from pathlib import Path

import pandas as pd


OUTPUT_DIR = Path("outputs/performance_entity_table")
ENTITY_TABLE = OUTPUT_DIR / "performance_entity_table.csv"
SOURCE_WORKBOOK = Path("database/reference/Performance_Data.xlsx")
LINK_OUTPUT = OUTPUT_DIR / "measure_entity_link_load.csv"
MEASURE_OUTPUT = OUTPUT_DIR / "missing_measure_load.csv"
ACTUAL_OUTPUT = OUTPUT_DIR / "missing_measure_actuals_load.csv"


def clean(value: object) -> str:
    if value is None or pd.isna(value):
        return ""
    return str(value).strip()


def normalize(value: object) -> str:
    return re.sub(r"\s+", " ", clean(value)).lower()


def parse_number(value: object, format_type: str = "") -> float | None:
    text = clean(value)
    if not text or text.lower() in {"nan", "n/a", "na", "none"}:
        return None
    is_percent_text = "%" in text
    text = text.replace(",", "").replace("$", "").replace("%", "").strip()
    try:
        number = float(text)
    except ValueError:
        return None
    if is_percent_text or format_type == "Percent":
        if number > 1:
            return number / 100
    return number


def format_type(value: object) -> str:
    text = normalize(value)
    if "percent" in text:
        return "Percent"
    if "currency" in text or "dollar" in text:
        return "Currency"
    return "Count"


def direction(value: object) -> str:
    text = normalize(value)
    if text in {"increase", "decrease", "maintain"}:
        return text.title()
    return "Not Applicable"


def measure_type(value: object) -> str:
    text = clean(value).title()
    return text if text in {"Output", "Efficiency", "Effectiveness", "Outcome"} else "Output"


def main() -> None:
    entity = pd.read_csv(ENTITY_TABLE, dtype=str).fillna("")
    source = pd.read_excel(SOURCE_WORKBOOK, dtype=str).fillna("")
    source = source[source["Fiscal Year"].str.strip().eq("FY27")].copy()
    source["_old_measure_id"] = source["Measure ID"].map(clean)
    source["_measure_name"] = source["Performance Measure"].map(normalize)

    link_rows = entity[
        ["new_measure_id", "agency_id", "service_id", "entity_type", "entity_id", "public_name", "old_measure_id"]
    ].copy()
    link_rows = link_rows.rename(columns={"new_measure_id": "measure_id", "old_measure_id": "source_old_measure_id"})
    link_rows.to_csv(LINK_OUTPUT, index=False)

    assigned_ids = pd.to_numeric(entity["new_measure_id"], errors="coerce")
    generated = entity[assigned_ids >= 705].copy()
    source_lookup = source.set_index(["_old_measure_id", "_measure_name"], drop=False)
    measure_rows = []
    actual_rows = []

    for _, row in generated.iterrows():
        key = (clean(row["old_measure_id"]), normalize(row["measure_name"]))
        if key not in source_lookup.index:
            continue
        source_row = source_lookup.loc[key]
        if isinstance(source_row, pd.DataFrame):
            source_row = source_row.iloc[0]
        fmt = format_type(source_row.get("Percent or Count"))
        measure_rows.append(
            {
                "measure_id": clean(row["new_measure_id"]),
                "agency_id": clean(row["agency_id"]),
                "title": clean(row["measure_name"]),
                "measure_type": measure_type(source_row.get("Performance Measure Type")),
                "description": clean(source_row.get("Service Description")) or "Definition pending.",
                "data_source": clean(source_row.get("Data Source")) or "Source pending.",
                "data_owner": clean(source_row.get("Contact")) or "Owner pending.",
                "data_owner_role": "Owner role pending.",
                "update_frequency": clean(source_row.get("Interval")) or "Frequency pending.",
                "formula": clean(source_row.get("Measure Formula")) or "Formula pending.",
                "desired_direction": direction(source_row.get("Desired Outcome")),
                "format_type": fmt,
                "change_mapping": clean(source_row.get("Status")) if clean(source_row.get("Status")) in {"New", "Modified", "Unchanged", "Replaced", "Removed"} else "New",
                "active": "false" if normalize(source_row.get("Deprecated")) == "yes" else "true",
                "validated": "true",
                "approval_status": "Validated",
            }
        )
        for fiscal_year in range(2021, 2028):
            actual_col = f"FY {str(fiscal_year)[-2:]} Actual"
            target_col = f"FY {str(fiscal_year)[-2:]} Target"
            actual = parse_number(source_row.get(actual_col), fmt)
            target = parse_number(source_row.get(target_col), fmt)
            if actual is None and target is None:
                continue
            actual_rows.append(
                {
                    "measure_id": clean(row["new_measure_id"]),
                    "fiscal_year": fiscal_year,
                    "annual_actual": actual,
                    "annual_actual_notes": clean(source_row.get(f"{actual_col} Explanation")),
                    "target_value": target,
                    "target_value_notes": clean(source_row.get(f"{target_col} Explanation")),
                }
            )

    pd.DataFrame(measure_rows).drop_duplicates(subset=["measure_id"]).to_csv(MEASURE_OUTPUT, index=False)
    pd.DataFrame(actual_rows).drop_duplicates(subset=["measure_id", "fiscal_year"]).to_csv(ACTUAL_OUTPUT, index=False)
    print(f"link_rows={len(link_rows)}")
    print(f"missing_measure_rows={len(measure_rows)}")
    print(f"missing_actual_rows={len(actual_rows)}")


if __name__ == "__main__":
    main()
