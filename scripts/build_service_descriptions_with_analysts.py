from __future__ import annotations

import re
from pathlib import Path

import pandas as pd


ASSIGNMENTS_PATH = Path(r"C:\Users\melanie.lada\Downloads\BBMR Analyst Assignments - Spring 2026.xlsx")
INPUT_CSV = Path("outputs/service_descriptions_simple/service_descriptions_simple.csv")
OUTPUT_DIR = Path("outputs/service_descriptions_with_analysts")
OUTPUT_CSV = OUTPUT_DIR / "service_descriptions_with_analysts.csv"


def extract_agency_id(value: object) -> str:
    if value is None or pd.isna(value):
        return ""
    match = re.search(r"\bAGC[0-9A-Za-z]+\b", str(value))
    return match.group(0) if match else ""


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    services = pd.read_csv(INPUT_CSV, dtype=str).fillna("")
    assignments = pd.read_excel(ASSIGNMENTS_PATH, sheet_name="AFO View", header=1, dtype=str).fillna("")
    assignments["Agency ID"] = assignments["Agency ID"].map(extract_agency_id)
    analyst_lookup = (
        assignments[["Agency ID", "Analyst"]]
        .dropna()
        .drop_duplicates(subset=["Agency ID"], keep="first")
        .set_index("Agency ID")["Analyst"]
        .to_dict()
    )
    by_analyst = pd.read_excel(ASSIGNMENTS_PATH, sheet_name="By Analyst", header=1, dtype=str).fillna("")
    by_analyst["Agency ID"] = by_analyst["Agency ID"].map(extract_agency_id)
    fallback_lookup = (
        by_analyst[["Agency ID", "Analyst"]]
        .dropna()
        .drop_duplicates(subset=["Agency ID"], keep="first")
        .set_index("Agency ID")["Analyst"]
        .to_dict()
    )
    analyst_lookup.update({key: value for key, value in fallback_lookup.items() if key not in analyst_lookup})

    output = services[["Agency ID", "Agency", "Service ID", "Service"]].copy()
    output["Analyst Name"] = output["Agency ID"].map(analyst_lookup).fillna("")
    output["Service Description"] = ""
    output.to_csv(OUTPUT_CSV, index=False)

    missing = output[output["Analyst Name"].eq("")]["Agency ID"].drop_duplicates().tolist()
    print(f"rows={len(output)}")
    print(f"missing_analyst_agencies={len(missing)}")
    if missing:
        print("missing_agency_ids=" + ", ".join(missing))


if __name__ == "__main__":
    main()
