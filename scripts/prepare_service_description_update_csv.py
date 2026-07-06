from __future__ import annotations

import csv
import sys
from pathlib import Path

import pandas as pd


DEFAULT_INPUT = Path(r"C:\Users\melanie.lada\Downloads\service_descriptions_with_analysts.xlsx")
OUTPUT_CSV = Path("database/seed/service_descriptions_update.csv")
OUTPUT_SQL = Path("database/seed/service_description_seed.sql")


def clean(value: object) -> str:
    if value is None or pd.isna(value):
        return ""
    return str(value).strip()


def sql_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def main() -> None:
    input_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_INPUT
    if not input_path.exists():
        raise FileNotFoundError(f"Missing workbook: {input_path}")

    df = pd.read_excel(input_path, sheet_name="Service Descriptions", dtype=str)
    required = ["Agency ID", "Agency", "Service ID", "Service", "Analyst Name", "Service Description"]
    missing = [column for column in required if column not in df.columns]
    if missing:
        raise ValueError(f"Missing required columns: {missing}")

    rows_by_service: dict[str, dict[str, str]] = {}
    skipped_blank_description = 0
    duplicate_identical = 0
    duplicate_conflicts: list[str] = []

    for _, source in df.iterrows():
        service_id = clean(source["Service ID"])
        description = clean(source["Service Description"])
        if not service_id:
            continue
        if not description:
            skipped_blank_description += 1
            continue

        row = {
            "agency_id": clean(source["Agency ID"]),
            "agency": clean(source["Agency"]),
            "service_id": service_id,
            "service": clean(source["Service"]),
            "analyst_name": clean(source["Analyst Name"]),
            "service_description": description,
        }

        existing = rows_by_service.get(service_id)
        if existing is None:
            rows_by_service[service_id] = row
        elif existing["service_description"] == description:
            duplicate_identical += 1
        else:
            duplicate_conflicts.append(service_id)

    if duplicate_conflicts:
        conflict_list = ", ".join(sorted(set(duplicate_conflicts)))
        raise ValueError(f"Duplicate service IDs with conflicting descriptions: {conflict_list}")

    rows = [rows_by_service[key] for key in sorted(rows_by_service)]
    OUTPUT_CSV.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT_CSV.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["agency_id", "agency", "service_id", "service", "analyst_name", "service_description"],
        )
        writer.writeheader()
        writer.writerows(rows)

    values = ",\n".join(
        f"    ({sql_quote(row['service_id'])}, {sql_quote(row['service_description'])})"
        for row in rows
    )
    OUTPUT_SQL.write_text(
        "\n".join(
            [
                "-- Generated from service_descriptions_with_analysts.xlsx service descriptions.",
                "-- Updates canonical reference.service descriptions by service_id.",
                "",
                "UPDATE reference.service AS service",
                "SET service_description = seed.service_description,",
                "    updated_at = now()",
                "FROM (VALUES",
                values,
                ") AS seed(service_id, service_description)",
                "WHERE service.service_id = seed.service_id;",
                "",
            ]
        ),
        encoding="utf-8",
    )

    print(f"Prepared {len(rows)} nonblank service descriptions.")
    print(f"Skipped blank descriptions: {skipped_blank_description}")
    print(f"Removed identical duplicate rows: {duplicate_identical}")
    print(f"Wrote {OUTPUT_CSV}")
    print(f"Wrote {OUTPUT_SQL}")


if __name__ == "__main__":
    main()
