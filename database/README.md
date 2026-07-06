# Database

This folder contains the Postgres schema and development seed SQL for the COB performance / CivicAlign app.

## Target Schema

`schema/target_schema.sql` is the source-of-truth app schema adapted from `Target_Database_Schema.pdf`.

It creates these namespaces:

- `reference`: city lookup tables such as agencies, services, pillars, and cost centers
- `access`: users, roles, and agency/service access
- `planning`: annual cycles, top-level agency plans, and revisioned shared section drafts
- `performance`: performance plan content, goals, initiatives, measures, services, risks, and data reporting
- `budget`: budget proposal detail
- `review`: OPI review and scoring
- `workflow`: approvals and status history
- `amendment`: post-approval amendment workflow
- `output`: slide exports and notifications

Load the target schema:

```powershell
psql "postgresql://postgres:<password>@localhost:5432/cob_performance" -v ON_ERROR_STOP=1 -f database/schema/target_schema.sql
```

App code should reference namespaced tables directly, such as `planning.agency_plan`, or set the DB connection `search_path`.

`planning.plan_section_draft` stores one shared working draft per plan section. The app uses its `revision` column for optimistic locking and keeps browser storage only as recovery for changes that have not reached Postgres.

## Reference Seed Data

`seed/load_reference_seed.sql` is the canonical loader for real reference data used by the app. It loads:

- `seed/city_reference_seed.sql` for the agency, service, and plan entity hierarchy
- `seed/action_plan_seed.sql` for the 2026 Mayor's Action Plan pillars, goals, strategies, narratives, and measures
- `seed/service_description_seed.sql` for service descriptions sourced from `budget_metadata.xlsx`

Load the schema, then load the reference seed:

```powershell
psql "postgresql://postgres:<password>@localhost:5432/cob_performance" -v ON_ERROR_STOP=1 -f database/schema/target_schema.sql
psql "postgresql://postgres:<password>@localhost:5432/cob_performance" -v ON_ERROR_STOP=1 -f database/seed/load_reference_seed.sql
```

The app should treat these records as baseline reference data, not dummy data.

## Prototype Data

`dummy/target_dummy_load.sql` is generated from `CivicAlign_DummyData.xlsx` and loads the namespaced target schema created by `schema/target_schema.sql`.

The target loader also includes the canonical reference seeds from `database/seed`, then adds prototype users, plans, measures, reviews, workflow rows, budget examples, and other demo records.

`dummy/civicalign_dummy_load.sql` is the older public-schema bootstrap seed. Keep it only for compatibility with early prototypes that still query unqualified `public` tables.

The prototype seed is a bootstrap artifact. Use it only for local/demo data until the corresponding production workflows exist.

Regenerate the target-schema dummy SQL after workbook changes:

```powershell
python scripts/generate_target_dummy_sql.py C:\Users\melanie.lada\Downloads\CivicAlign_DummyData.xlsx --output database/dummy/target_dummy_load.sql
```

Load the target schema, reference seed, then optional prototype data:

```powershell
psql "postgresql://postgres:<password>@localhost:5432/cob_performance" -v ON_ERROR_STOP=1 -f database/schema/target_schema.sql
psql "postgresql://postgres:<password>@localhost:5432/cob_performance" -v ON_ERROR_STOP=1 -f database/seed/load_reference_seed.sql
psql "postgresql://postgres:<password>@localhost:5432/cob_performance" -v ON_ERROR_STOP=1 -f database/dummy/target_dummy_load.sql
```

The target seed is idempotent by primary key and resets identity sequences after inserting explicit workbook IDs.

## Uploaded Seed Workbooks

`scripts/generate_uploaded_seed_sql.py` converts the uploaded seed workbooks into canonical SQL:

```powershell
python scripts/generate_uploaded_seed_sql.py `
  --performance-workbook "C:\Users\melanie.lada\Downloads\Group4_PerformancePlan_Tables (6).xlsx" `
  --user-workbook "C:\Users\melanie.lada\Downloads\User_Roles.xlsx"
```

It writes:

- `database/seed/user_roles_seed.sql`
- `database/seed/performance_plan_seed.sql`

Load the full uploaded seed stack:

```powershell
psql "postgresql://postgres:<password>@localhost:5432/cob_performance" -v ON_ERROR_STOP=1 -f database/schema/target_schema.sql
psql "postgresql://postgres:<password>@localhost:5432/cob_performance" -v ON_ERROR_STOP=1 -f database/seed/load_uploaded_seed.sql
```

Current workbook normalization rules:

- `AgencyWriter` is a valid app role.
- `Program Staff`, `Fiscal Staff`, and `Performance Lead` are valid agency roles.
- `Performance Metric Updates` maps to `Performance Lead`.
- Lowercase `increase` maps to `Increase`.
- `Not Applicable` is a valid desired direction.
- `N/A` is preserved as a legacy measure format.
- `Modified` is a valid change mapping.
- Blank or FY2027 measure `initial_cycle` values map to the FY2027 cycle id.
- Missing DGS and MONSE agency plan rows are generated for plan ids `1` and `2`.
- `performance.plan_service` rows are generated from service metric links.
- `SERVICE_GOAL_LINK.plan_service_id` is treated as a plan-local service order and is mapped through the linked agency goal's `plan_id` before loading to `performance.service_goal_link`.

## Legacy City Reference Data

`group1_city_reference_load.sql` is the original city reference seed generated by `scripts/generate_city_reference_sql.py`.
