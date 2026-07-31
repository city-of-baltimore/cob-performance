# CLS pages ↔ target schema reconciliation

Every field on the three CLS pages checked against the seven tables you supplied, plus what
the live database actually has. Read against the running stack on 2026-07-30 — column types
are from `information_schema`, value counts from the seeded data.

Legend: ✅ matches · ⚠ matches with a caveat · ❌ mismatch or missing · ➕ exists in the app
but not in your tables.

> **Status: answered and applied (2026-07-31).** This is the point-in-time snapshot that
> raised questions Q1–Q14 for review. All fourteen were answered and the changes are in
> `main`. The tables below have been marked up with what was actually done, so the
> document still reads as a reconciliation rather than a to-do list. Two items remain
> open and are tracked in [`cls-change-log-notes.md`](cls-change-log-notes.md): the real
> `SC6xxx` spend-category list (Q3) and the "Estimated Cost" link destination (Q9).
>
> Column-level outcomes: `justified`, `completed` and `evaluation_score` **dropped**;
> `status` **added** as the single source of truth; `spend_category` **added**;
> `modified_by` **retyped** from text to a `user_id` FK; `approved_amount` /
> `approved_positions` **added** to `cls_review`; `created_by` **added** to `cls_request`;
> `AgencyApprover` **retired** in favour of `AgencySubmitter`.

---

## 1. CLS_REQUEST

| Your field | Your type | DB column | DB type | Page field | |
|---|---|---|---|---|---|
| `cls_id` PK | INT IDENTITY N | `cls_id` | integer NOT NULL | — | ✅ |
| `plan_service_id` FK | INT N | `plan_service_id` | integer NOT NULL | **Service** dropdown | ✅ |
| `request_name` | NVARCHAR(500) N | `request_name` | varchar(500) NOT NULL | **Request name** | ✅ |
| `request_type` | NVARCHAR(100) Y | `request_type` | varchar(100) NULL | **Request type** | ⚠ see Q6 |
| `request_amount` | DECIMAL(18,2) Y | `request_amount` | numeric(18,2) NULL | **FY28 Amount** | ⚠ see Q5 |
| `one_time` | BIT N | `one_time` | boolean NOT NULL | **Request duration** toggle | ✅ |
| `overall_summary` | NVARCHAR(MAX) Y | `overall_summary` | text NULL | **Summarize the request** | ✅ |
| `justified` | NVARCHAR(10) Y — Yes\|No | *dropped* | — | **nothing** | ❌ Q1 → removed |
| `completed` | BIT N | *dropped* | — | derived from `status` | ⚠ Q4 → replaced by `status` |
| `amount_next_fy` | DECIMAL(18,2) Y — FY+2 | `amount_next_fy` | numeric(18,2) NULL | **FY29 Amount** | ⚠ see Q5 — now required when recurring |
| `amount_2next_fy` | DECIMAL(18,2) Y — FY+3 | `amount_2next_fy` | numeric(18,2) NULL | **FY30 Amount** | ⚠ see Q5 — now required when recurring |
| — | | `status` | varchar(30) NOT NULL, default 'In Progress' | status chip | ➕ Q4 → added |
| — | | `created_at` / `updated_at` | timestamptz NOT NULL | "Last Saved" indicator, export columns | ➕ |
| — | | `created_by` | integer NULL → `access.user` | **Created by email** in the exports | ➕ added 2026-07-31 |
| — | | `modified_by` | integer NULL → `access.user` | hover on "Last Saved", **Modified by email** | ➕ Q10 → retyped from text |

Nine of your eleven fields land exactly. `justified` was dropped as an unused early
validation flag, and `completed` was replaced by `status`, which can express all six
workflow states rather than two.

## 2. CLS_REQUEST_LINE

| Your field | Your type | DB column | DB type | Page field | |
|---|---|---|---|---|---|
| `line_id` PK | INT IDENTITY N | `line_id` | integer NOT NULL | — | ✅ |
| `cls_id` FK | INT N | `cls_id` | integer NOT NULL | — | ✅ |
| `object_category` | NVARCHAR(200) Y | `object_category` | varchar(200) NULL | **Object** dropdown | ⚠ see Q7 |
| `amount` | DECIMAL(18,2) Y | `amount` | numeric(18,2) NULL | **Amount** | ✅ |
| `justification` | NVARCHAR(MAX) Y | `justification` | text NULL | **Justification** | ✅ |
| `sort_order` | INT N | `sort_order` | integer NOT NULL | set automatically | ✅ |
| — | | `spend_category` | varchar(200) NULL | **Spend category** dropdown | ➕ see Q3 |
| — | | `created_at` / `updated_at` / `modified_by` | | — | ➕ |

## 3. CLS_REQUEST_POSITION

| Your field | Your type | DB column | DB type | Page field | |
|---|---|---|---|---|---|
| `pos_id` PK | INT IDENTITY N | `pos_id` | integer NOT NULL | — | ✅ |
| `cls_id` FK | INT N | `cls_id` | integer NOT NULL | — | ✅ |
| `classification` | NVARCHAR(200) N | `classification` | varchar(200) NOT NULL | **Job classification** | ⚠ free text, see Q8 |
| `position_count` | INT N | `position_count` | integer NOT NULL | **Number of positions** | ✅ |
| `estimated_salary` | DECIMAL(18,2) Y | `estimated_salary` | numeric(18,2) NULL | **Estimated Cost** | ⚠ see Q9 |
| `justification` | NVARCHAR(MAX) Y | `justification` | text NULL | **Justify the need for creating additional positions** | ✅ |
| `explanation` | NVARCHAR(MAX) Y | `explanation` | text NULL | **Explain how the additional positions are needed to maintain the current level of service** | ✅ |
| — | | `created_at` / `updated_at` / `modified_by` | | — | ➕ |

This table is a clean 1:1. Note `explanation` is captured but only read back on the CLS
Review row and in the PDF export, not in the agency's own position table — deliberate, to
keep that table to four columns.

## 4. CLS_REVIEW ➕ — not in your tables at all

BBMR's evaluation lives in a separate 1:1 table so a reviewer's decision never overwrites
what the agency submitted.

| DB column | DB type | Page field | |
|---|---|---|---|
| `review_id` PK | integer | — | ➕ |
| `cls_id` FK | integer NOT NULL | — | ➕ |
| `evaluation_score` | numeric(6,2) NULL | **nothing** — removed from the UI on request | ❌ see Q2 |
| `analyst_notes` | text NULL | **Analyst notes** | ➕ |
| `analyst_approval` | varchar(20) NULL | **Analyst approval** | ➕ |
| `bbmr_approval` | varchar(20) NULL | **BBMR approval** → drives `status` | ➕ |
| `reviewed_by` | **text** NULL | — | ➕ see Q10 |
| `updated_at` | timestamptz NOT NULL | — | ➕ |

## 5. USER ↔ `access.user`

Exact match on all eight of your fields: `user_id`, `email`, `full_name`, `phone`,
`auth_type`, `password_hash`, `active`, `created_at`. The DB adds `updated_at` and
`modified_by`. ✅ Nothing to reconcile.

## 6. USER_ROLE ↔ `access.user_role`

| Your field | DB column | |
|---|---|---|
| `user_role_id` PK | `user_role_id` | ✅ |
| `user_id` FK | `user_id` | ✅ |
| `app_role` | `app_role` varchar(30) | ⚠ see Q11 |
| `agency_id` FK | `agency_id` varchar(20) NULL | ✅ |
| `granted_at` | `granted_at` timestamptz | ✅ |
| `budget_access` | `budget_access` boolean | ✅ |
| `adaptive_planning` | `adaptive_planning` boolean | ✅ |
| `performance_plan_access` | `performance_plan_access` boolean | ✅ |
| `assigned_by` NVARCHAR(300) N | **absent** | ❌ see Q12 |
| — | `pillar_id` integer NULL | ➕ carries DeputyMayor's "Assigned Pillar" scope |
| — | `quasi` boolean NOT NULL | ➕ |

## 7. USER_FUNCTIONS ↔ `access.user_agency_access`

Different name, same job. Your four content fields are all present.

| Your field | DB column | |
|---|---|---|
| `access_id` PK | `access_id` | ✅ |
| `user_id` FK | `user_id` | ✅ |
| `agency_id` FK | `agency_id` varchar(20) NOT NULL | ✅ |
| `service_id` FK (null = all) | `service_id` varchar(20) NULL | ✅ |
| `agency_role` (MULTI SELECT) | `agency_role` varchar(30) + `agency_roles` text | ⚠ see Q13 |
| — | `access_level` varchar(20), default 'Edit' | ➕ |
| — | `budget_access`, `performance_plan_access` | ➕ duplicated from USER_ROLE |

There is also a whole extra table, **`access.user_entity_access`** (14 columns), for
mayoral-service/entity-level access. It has no counterpart in your list. See Q14.

---

# Questions for review

Ordered by how much they change the build. Q1–Q4 affect the CLS pages directly.

### Q1. `justified` — what is this field for? (highest impact)

It is in your CLS_REQUEST as `NVARCHAR(10)` Yes|No, and the column exists in the database,
but **no page collects it**. The create path writes `input$cls_form_justified`, which
doesn't exist, so every request created through the UI stores NULL. The six seeded rows say
"Yes" only because the seed SQL sets it.

Three readings, and I can't tell which you meant:

- **(a) A reviewer's attestation** — "is this request justified?", answered by BBMR. If so
  it belongs in CLS_REVIEW next to `analyst_approval`, not on the agency's form.
- **(b) A completeness flag** — "has the agency justified every line?". That is exactly
  what `cls_request_gaps()` computes today, live, from the line items. If that's the intent
  the column is redundant and should be dropped.
- **(c) An agency self-certification** — a Yes/No the writer ticks before submitting.
  Then it needs a control on the request page, which doesn't exist yet.

Which one? If (b), I'd drop the column.

### Q2. `evaluation_score` — drop it?

You asked me to remove the evaluation score from the CLS Review UI, which I did, but the
column is still there and is now never written (all three review rows are NULL). Keep it as a
placeholder for a future scoring pass, or drop it?

### Q3. `spend_category` — confirm, and I need the real codes

I added this to CLS_REQUEST_LINE at your request ("add Spend Category as an additional row
for Request Details"). It is **not in your CLS_REQUEST_LINE**, so either your table needs
the column or the field should come off the page.

Separately, the ten values in the dropdown are **placeholders I invented** (`SC6001 -
Professional Services` … `SC6010 - Office Supplies`) and are flagged as such in the code. I
need the real chart-of-accounts spend-category list before this field is trustworthy —
agencies picking from a fake list will produce data you can't use.

### Q4. `status` and `completed` — should `status` be in your schema?

Your CLS_REQUEST has `completed BIT` and nothing else. The workflow you specified needs six
states, so I added `status`:

> In Progress → Agency Review → BBMR Review → Approved / Partially Approved / Denied

`completed` is kept in sync automatically (true from BBMR Review onward). So `completed` is
now derived from `status`, not entered. Two questions: should `status` be added to the
target schema as the real field, and is `completed` still needed, or is it redundant?

Related: you have no status-history table. `modified_by` holds only the last person to touch
a request, so "who sent this to BBMR, and when" is not answerable. That was R6 in the
workflow recommendations.

### Q5. FY labels — confirming my reading of "FY+2 / FY+3"

Your notes call `amount_next_fy` "FY+2 projected" and `amount_2next_fy` "FY+3 projected".
The pages label the three amounts **FY28 / FY29 / FY30**, and `request_amount` is FY28.

That reconciles **if** the base year is the current plan year, FY2027: request_amount =
FY+1 = 2028, next = FY+2 = 2029, 2next = FY+3 = 2030. The plan lookup is hard-coded to
`fiscal_year == 2027`, so this holds for the current cycle. Confirm that's what you meant —
and note the FY labels are currently hard-coded strings, so next cycle they need bumping (or
deriving from the plan year, which I'd recommend).

### Q6. `request_type` — confirm the list of eight

Your note says "Mandated Cost | Cyclical | Extraordinary Inflation etc." The app offers
eight, each with guidance text behind the ⓘ icon:

> Annualization of Cost · Capital Project · Cyclical Cost · Debt Service ·
> Extraordinary Inflation · Grant Match · Mandated Cost · Remove One-Time Item

Two things: is this the complete and correct list, and is it **"Cyclical Cost"** (the app)
or **"Cyclical"** (your note)? These are stored as free text, so the strings must be exact.

### Q7. `object_category` — the label wording differs from your examples

Your examples are "Grants & Subsidies" and "Major Equipment". The app stores:

> Transfers · Salaries · Other Personnel Costs · Contractual Services ·
> Materials and Supplies · Minor Equipment (<$5k) · Major Equipment (>$5k) ·
> Grants, Subsidies, and Contributions · Debt Service

These came from your list two rounds ago, so I believe the app is right and your table's
examples are shorthand — but confirm, since again these are stored as literal strings and
"Grants & Subsidies" ≠ "Grants, Subsidies, and Contributions" to any downstream join.

### Q8. `classification` — free text or a controlled list?

Your note says "Job classification title" and the column is NOT NULL. Today it's a free-text
box, so two agencies can enter "Election Clerk II" and "Elections Clerk 2" for the same
class. If there is a canonical classification list (from the HR or payroll system) this
should be a dropdown. Is there one I can load?

### Q9. "Estimated Cost" — still no destination for the link

Your field is `estimated_salary`. The page labels it **Estimated Cost** and renders it as a
hyperlink, which currently goes nowhere — a deliberate placeholder with a `TODO` in the
code, and the item you asked me not to let you forget.

Two questions: should the field mean salary only or salary **plus** benefits (the label says
cost, the column says salary — if it's fully loaded cost, the column name is misleading);
and what should the link point to?

### Q10. `modified_by` / `reviewed_by` — name text or user FK?

Inconsistent today, and it's my doing:

- `cls_request.modified_by` → **text**, holding a display name ("Sarah Schulte")
- `cls_review.reviewed_by` → **text**, same
- `cls_request_line.modified_by`, `cls_request_position.modified_by` → **integer**, always NULL
- every `access.*` table → **integer**, FK to USER

Storing the name was expedient for the "Last Saved … hover for the user" indicator, but it
breaks if someone's name changes and it can't be joined. I'd switch both to
`INT FK -> USER` and resolve the name at render time. Agree?

### Q11. `app_role` — your two tables disagree, and the data has no AgencyApprover

This is the one that has a live functional consequence.

Your **USER_ROLE** notes list: AgencySubmitter | **AgencyApprover** | OPIReviewer |
DeputyMayor | CAOffice | SystemAdmin | AgencyViewer — no AgencyWriter, no BBMRReviewer.

Your **USER_TYPES** table lists: SystemAdmin | OPIReviewer | **BBMRReviewer** | CAOffice |
DeputyMayor | AgencySubmitter | **AgencyWriter** | AgencyViewer — no AgencyApprover.

The live database has 8 distinct roles and **zero AgencyApprover rows**:

| app_role | rows |
|---|---|
| AgencyWriter | 199 |
| AgencyViewer | 118 |
| AgencySubmitter | 104 |
| BBMRReviewer | 14 |
| SystemAdmin | 5 |
| OPIReviewer | 4 |
| DeputyMayor | 6 |
| CAOffice | 2 |

But the CLS code gates the approval step on `AgencyApprover`:

- `can_approve_cls()` requires AgencyApprover or SystemAdmin → **with today's data, nobody
  at any agency can press "Send to BBMR"**; only a SystemAdmin can.
- the submit modal looks up an AgencyApprover for the agency to name in "Submit this request
  to ___ for approval?" → always falls back to the generic "your Agency Submitter".

Reading your USER_TYPES, I think the intent is that **AgencySubmitter *is* the approver** —
it's the only agency role with `A`/`S` rights, described as "in leadership and has final
approval", mapped to Agency Head. AgencyWriter is `W|V`, data entry.

So: should I retire `AgencyApprover` and move the CLS approval gate to **AgencySubmitter**?
That is a small change (three role predicates) and it would make the workflow function with
real data. I did not make it unilaterally because it changes who can approve budget
requests, which is a policy call, not a technical one.

### Q12. `USER_ROLE.assigned_by` is missing from the database

You have it as `NVARCHAR(300) NOT NULL` — "system admin who assigned role to user". There is
no such column. Should I add it? Note it has the same text-vs-FK question as Q10, and a NOT
NULL column needs a backfill value for the 452 existing rows.

### Q13. `agency_role` — the value lists don't match the data

Your USER_FUNCTIONS lists: Agency Head | Agency Director | Chief of Staff | Fiscal Officer |
**Agency Staff** | Performance Lead | **Admin**.

The live data contains: Agency Head (50) | Agency Director (58) | Chief of Staff (27) |
Fiscal Officer (65) | **Fiscal Staff (55)** | Performance Lead (10) | **Program Staff (150)**.

So "Agency Staff" and "Admin" appear nowhere, and "Fiscal Staff" and "Program Staff" — 205
rows between them, the largest single category — are not in your list. Did "Agency Staff"
get split into Fiscal Staff and Program Staff, and should "Admin" be dropped?

Also: your note marks this MULTI SELECT. The DB implements that as a second column,
`agency_roles` (text), alongside the single `agency_role`. Worth deciding which is
authoritative before anything reads it.

### Q14. `access.user_entity_access` — should it be in your schema?

A 14-column table with no counterpart in your list, handling entity-level (mayoral service)
access as distinct from agency-level. It predates the CLS work. Is it intentionally out of
scope for this document, or does it need adding?

---

## Summary

- **CLS_REQUEST_POSITION** is a clean 1:1. **USER** is a clean 1:1.
- **CLS_REQUEST** matches on 9 of 11; `justified` is unused (Q1) and `completed` is now
  derived from an added `status` column (Q4).
- **CLS_REQUEST_LINE** matches on all 6, plus the added `spend_category` whose values are
  placeholders (Q3).
- **CLS_REVIEW** is entirely additive and needs a decision on whether it joins the target
  schema (Q2, Q4).
- **USER_ROLE** is missing `assigned_by` (Q12) and the role vocabulary is contradictory in a
  way that currently breaks the approval step (Q11) — the most consequential item here.
- **USER_FUNCTIONS** matches under a different table name; the `agency_role` value list is
  out of date against the data (Q13).
