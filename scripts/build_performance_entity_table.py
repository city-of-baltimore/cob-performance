from __future__ import annotations

import re
import unicodedata
from pathlib import Path

import pandas as pd


OUTPUT_DIR = Path("outputs/performance_entity_table")
SOURCE_WORKBOOK = Path("database/reference/Performance_Data.xlsx")
DB_MEASURE_SOURCE = OUTPUT_DIR / "db_measure_entity_source.csv"
DB_SERVICE_SOURCE = OUTPUT_DIR / "db_service_entity_source.csv"
OUTPUT_CSV = OUTPUT_DIR / "performance_entity_table.csv"
SERVICE_OUTPUT_CSV = OUTPUT_DIR / "performance_entity_service_table.csv"

PLACEHOLDER_AGENCY_IDS = [
    "AGC1000",
    "AGC1100",
    "AGC1311",
    "AGC1321",
    "AGC2100",
    "AGC3101",
    "AGC3102",
    "AGC3103",
    "AGC4317",
    "AGC4371",
    "AGC6500",
    "AGC6900",
]

PLACEHOLDER_ENTITY_IDS = [
    "8",  # Innovation Team
]


def normalize_text(value: object) -> str:
    if value is None or pd.isna(value):
        return ""
    text = unicodedata.normalize("NFKD", str(value))
    text = text.replace("\u00a0", " ")
    text = text.lower()
    text = re.sub(r"[^a-z0-9]+", " ", text)
    return " ".join(text.split())


def extract_code(value: object, prefix: str) -> str:
    if value is None or pd.isna(value):
        return ""
    match = re.search(rf"\b{re.escape(prefix)}[0-9A-Za-z]+\b", str(value))
    return match.group(0) if match else ""


def clean_label_without_code(value: object, prefix: str) -> str:
    if value is None or pd.isna(value):
        return ""
    text = str(value).strip()
    code = extract_code(text, prefix)
    if code:
        text = text.replace(code, "", 1).strip()
    return re.sub(r"\s+", " ", text)


def map_entity_type(source_type: object) -> str:
    value = normalize_text(source_type)
    if value == "mayoraltyoffice":
        return "mayoral service"
    if value == "quasiagency":
        return "quasi agency"
    return ""


def parse_candidate_entities(value: object) -> list[dict[str, str]]:
    text = as_string(value)
    if not text:
        return []
    candidates = []
    for record in text.split(";;"):
        parts = record.split("|")
        if len(parts) != 3:
            continue
        candidates.append(
            {
                "entity_id": parts[0].strip(),
                "public_name": parts[1].strip(),
                "entity_type": map_entity_type(parts[2].strip()),
            }
        )
    return candidates


def match_candidate_by_public_name(candidates: list[dict[str, str]], source_name: object) -> dict[str, str] | None:
    source_key = normalize_text(source_name)
    if not source_key:
        return None
    exact_matches = [candidate for candidate in candidates if normalize_text(candidate.get("public_name")) == source_key]
    if len(exact_matches) == 1:
        return exact_matches[0]
    contains_matches = [
        candidate
        for candidate in candidates
        if source_key in normalize_text(candidate.get("public_name"))
        or normalize_text(candidate.get("public_name")) in source_key
    ]
    if len(contains_matches) == 1:
        return contains_matches[0]
    return None


def as_string(value: object) -> str:
    if value is None or pd.isna(value):
        return ""
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value).strip()


def first_nonblank(*values: object) -> str:
    for value in values:
        text = as_string(value)
        if text:
            return text
    return ""


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    source = pd.read_excel(SOURCE_WORKBOOK, dtype=str).fillna("")
    source = source[source["Fiscal Year"].str.strip().eq("FY27")].copy()
    source["agency_id"] = source["Agency ID"].map(lambda value: extract_code(value, "AGC"))
    source["service_id"] = source["Service ID"].map(lambda value: extract_code(value, "SRV"))
    source["source_agency_label"] = source["Agency"].where(
        source["Agency"].str.strip().ne(""),
        source["Agency ID"].map(lambda value: clean_label_without_code(value, "AGC")),
    )
    source["source_service_label"] = source["Service"].where(
        source["Service"].str.strip().ne(""),
        source["Service ID"].map(lambda value: clean_label_without_code(value, "SRV")),
    )
    source["measure_key"] = source["Performance Measure"].map(normalize_text)

    db_measures = pd.read_csv(DB_MEASURE_SOURCE, dtype=str).fillna("")
    db_services = pd.read_csv(DB_SERVICE_SOURCE, dtype=str).fillna("")
    db_measures["measure_key"] = db_measures["measure_name"].map(normalize_text)

    unique_measure_matches = (
        db_measures[["agency_id", "measure_key", "new_measure_id"]]
        .drop_duplicates()
        .groupby(["agency_id", "measure_key"], as_index=False)
        .agg(
            new_measure_id=("new_measure_id", lambda values: "; ".join(sorted(set(v for v in values if v)))),
            new_measure_match_count=("new_measure_id", lambda values: len(set(v for v in values if v))),
        )
    )

    service_lookup = (
        db_services.sort_values(["service_id"])
        .drop_duplicates(subset=["service_id"], keep="first")
        .set_index("service_id")
        .to_dict("index")
    )
    agency_lookup = (
        db_services[["agency_id", "agency_public_name"]]
        .drop_duplicates()
        .set_index("agency_id")["agency_public_name"]
        .to_dict()
    )

    merged = source.merge(unique_measure_matches, on=["agency_id", "measure_key"], how="left")

    rows = []
    for _, row in merged.iterrows():
        service_id = as_string(row.get("service_id"))
        service = service_lookup.get(service_id, {})
        active_entity_count = int(float(first_nonblank(service.get("active_entity_count"), 0) or 0))
        source_entity_type = service.get("source_entity_type")
        entity_type = ""
        entity_id = ""
        public_name = ""
        mapping_status = ""

        if active_entity_count == 1:
            entity_type = map_entity_type(source_entity_type)
            public_name = as_string(service.get("entity_public_name"))
            entity_id = as_string(service.get("entity_id"))
            mapping_status = "resolved from plan entity service"
        elif active_entity_count > 1:
            candidates = parse_candidate_entities(service.get("candidate_entity_records"))
            matched_candidate = match_candidate_by_public_name(candidates, row.get("source_agency_label"))
            if not matched_candidate and service_id == "SRV0385":
                family_league_matches = [
                    candidate
                    for candidate in candidates
                    if normalize_text(candidate.get("public_name")) == "family league"
                ]
                if len(family_league_matches) == 1:
                    matched_candidate = family_league_matches[0]
            if matched_candidate:
                entity_type = matched_candidate["entity_type"]
                entity_id = matched_candidate["entity_id"]
                public_name = matched_candidate["public_name"]
                mapping_status = "resolved from source agency public name"
                if service_id == "SRV0385":
                    mapping_status = "resolved to Family League per analyst direction"
            else:
                mapping_status = "blank: service maps to multiple public entities"
        elif service:
            entity_type = "service"
            public_name = first_nonblank(service.get("service_name"), row.get("source_service_label"))
            mapping_status = "resolved as service"
        else:
            mapping_status = "blank: service not found in seeded reference"

        if entity_type and not public_name:
            mapping_status = "blank: public name unavailable"

        match_count = int(float(first_nonblank(row.get("new_measure_match_count"), 0) or 0))
        new_measure_id = as_string(row.get("new_measure_id"))
        if match_count != 1:
            new_measure_id = ""
            if match_count > 1:
                mapping_status = f"{mapping_status}; new measure match is ambiguous"
            else:
                mapping_status = f"{mapping_status}; no seeded measure match"

        rows.append(
            {
                "entity_type": entity_type,
                "entity_id": entity_id,
                "public_name": public_name,
                "agency": first_nonblank(service.get("agency_public_name"), agency_lookup.get(as_string(row.get("agency_id"))), row.get("source_agency_label")),
                "service": first_nonblank(service.get("service_name"), row.get("source_service_label")),
                "measure_name": as_string(row.get("Performance Measure")),
                "old_measure_id": as_string(row.get("Measure ID")),
                "new_measure_id": new_measure_id,
                "mapping_status": mapping_status,
                "candidate_entity_names": as_string(service.get("candidate_entity_names")),
                "agency_id": as_string(row.get("agency_id")),
                "service_id": service_id,
                "source_fiscal_year": as_string(row.get("Fiscal Year")),
                "source_deprecated": as_string(row.get("Deprecated")),
                "source_status": as_string(row.get("Status")),
            }
        )

    output = pd.DataFrame(rows)
    column_order = [
        "entity_type",
        "agency_id",
        "service_id",
        "entity_id",
        "public_name",
        "agency",
        "service",
        "measure_name",
        "old_measure_id",
        "new_measure_id",
        "mapping_status",
        "candidate_entity_names",
        "source_fiscal_year",
        "source_deprecated",
        "source_status",
    ]
    output = output[column_order]
    numeric_ids = [int(value) for value in output["new_measure_id"] if str(value).isdigit()]
    next_measure_id = (max(numeric_ids) if numeric_ids else 0) + 1
    missing_measure_id = output["new_measure_id"].eq("")
    for index in output.index[missing_measure_id]:
        output.at[index, "new_measure_id"] = str(next_measure_id)
        status = output.at[index, "mapping_status"]
        output.at[index, "mapping_status"] = f"{status}; assigned sequential new measure ID"
        next_measure_id += 1
    output.to_csv(OUTPUT_CSV, index=False)

    service_rows = db_services[
        db_services["agency_id"].isin(PLACEHOLDER_AGENCY_IDS)
        | db_services["entity_id"].map(as_string).isin(PLACEHOLDER_ENTITY_IDS)
    ].copy()
    if not service_rows.empty:
        service_rows["entity_type"] = service_rows.apply(
            lambda row: map_entity_type(row.get("source_entity_type")) if as_string(row.get("entity_id")) else "service",
            axis=1,
        )
        service_rows["entity_id"] = service_rows["entity_id"].map(as_string)
        service_rows["public_name"] = service_rows.apply(
            lambda row: first_nonblank(row.get("entity_public_name"), row.get("service_name")),
            axis=1,
        )
        service_rows["agency"] = service_rows["agency_public_name"]
        service_rows["service"] = service_rows["service_name"]
        service_rows["mapping_status"] = service_rows.apply(
            lambda row: "placeholder: no FY27 performance measures in source data"
            if as_string(row.get("agency_id"))
            else "placeholder: agency not found in seeded reference",
            axis=1,
        )
        service_rows["source_fiscal_year"] = "FY27"
        service_rows = service_rows[
            [
                "entity_type",
                "agency_id",
                "service_id",
                "entity_id",
                "public_name",
                "agency",
                "service",
                "mapping_status",
                "candidate_entity_names",
                "source_fiscal_year",
            ]
        ]
    else:
        service_rows = pd.DataFrame(
            columns=[
                "entity_type",
                "agency_id",
                "service_id",
                "entity_id",
                "public_name",
                "agency",
                "service",
                "mapping_status",
                "candidate_entity_names",
                "source_fiscal_year",
            ]
        )

    missing_agency_rows = []
    known_agencies = set(db_services["agency_id"])
    for agency_id in PLACEHOLDER_AGENCY_IDS:
      if agency_id not in known_agencies:
        missing_agency_rows.append(
            {
                "entity_type": "service",
                "agency_id": agency_id,
                "service_id": "",
                "entity_id": "",
                "public_name": "",
                "agency": "",
                "service": "",
                "mapping_status": "placeholder: agency not found in seeded reference",
                "candidate_entity_names": "",
                "source_fiscal_year": "FY27",
            }
        )
    if missing_agency_rows:
        service_rows = pd.concat([service_rows, pd.DataFrame(missing_agency_rows)], ignore_index=True)

    measure_free = output[
        [
            "entity_type",
            "agency_id",
            "service_id",
            "entity_id",
            "public_name",
            "agency",
            "service",
            "mapping_status",
            "candidate_entity_names",
            "source_fiscal_year",
        ]
    ].copy()
    measure_free = pd.concat([measure_free, service_rows], ignore_index=True)
    measure_free = measure_free.drop_duplicates(
        subset=["entity_type", "agency_id", "service_id", "entity_id", "public_name", "agency", "service"],
        keep="first",
    )
    measure_free.to_csv(SERVICE_OUTPUT_CSV, index=False)
    print(f"performance_entity_rows={len(output)}")
    print(f"blank_public_names={(output['public_name'].eq('')).sum()}")
    print(f"output={OUTPUT_CSV}")
    print(f"measure_free_rows={len(measure_free)}")
    print(f"measure_free_output={SERVICE_OUTPUT_CSV}")


if __name__ == "__main__":
    main()
