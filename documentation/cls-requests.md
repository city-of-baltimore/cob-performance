# CLS Requests

Reference for the **Current Level of Service (CLS)** budget-request feature in the
Beacon performance & budgeting app.

CLS requests are part of the fall **budget proposal** cycle. An agency uses them to
ask BBMR to fund the cost of maintaining its current level of service — mandated cost
increases, cyclical costs, extraordinary inflation, and similar. Each request breaks
down into line items (object categories) and position requests.

## The workflow

The full intended lifecycle, and where this build sits within it:

| Step | Actor | Status |
|------|-------|--------|
| 1. Enter CLS requests | Agency **Writer** | ✅ built |
| 2. Submit for approval | Agency **Writer** | ✅ built (→ *Agency Review*) |
| 3. Send for BBMR review | Agency **Approver** | ✅ built (→ *BBMR Review*) |
| 4. Review requests | **BBMR Reviewer** | ✅ built (CLS Review page) |
| 5. Approve / partially approve / deny | **BBMR Reviewer** | ✅ built (sets final status) |
| 6. See the decision | Agencies | ✅ built (Status column) |

### Request status lifecycle

Every request carries a `status` that drives the whole workflow:

| Status | Set when | Chip |
|--------|----------|------|
| **In Progress** | the request is created | grey |
| **Agency Review** | a Writer clicks *Submit for approval* | amber |
| **BBMR Review** | an Approver clicks *Send for BBMR Review* | blue |
| **Approved** | BBMR records an Approved decision | green |
| **Partially Approved** | BBMR records a Partial decision | amber |
| **Denied** | BBMR records a Denied decision | red |

The target-schema `completed` flag is kept in sync automatically (true once a request
reaches BBMR), so it stays meaningful without being the thing users see.

## Who can see / do what

Access is by app role, checked both server-side (page gate) and in the nav:

- **AgencyViewer** — can open the CLS Requests page and view requests (read-only).
- **AgencyWriter**, **AgencySubmitter** — create/edit/delete requests, objects and
  positions; can *Submit for approval*.
- **AgencyApprover** — same editing UI as writers, plus *Send to BBMR* per request.
- **BBMRReviewer** — sees the **CLS Review** page and records the review decision; can
  also open and **edit** a request (their back link returns to CLS Review).
- **SystemAdmin** — full access, for support and testing.
- Everyone else (OPIReviewer, DeputyMayor, CAOffice) — the nav items are hidden and the
  pages redirect to the timeline.

Helpers in `app.R`: `can_view_cls_requests()`, `can_edit_cls_requests()`,
`can_approve_cls()`, `can_review_cls()`.

## Pages

- **CLS Requests** (`cls_requests`) — nav item under "Budget Planning". One white card
  titled *"{Agency} Requests"*, with **Add CLS Request** in the header. The table is
  sortable by **Request name / Service / Amount / Status**; amounts show as `$X.XK` /
  `$X.XM`, and each row has its own hand-off action (**Submit** for writers, **Send to
  BBMR** for approvers, shown only at the right status) plus **Delete** and **Modify →**. Below the table, **Export request(s)** offers **Excel**
  (one worksheet per table: Request summary, Line items, Personnel — `cls_export_sheets()`
  + `writexl`) and **PDF** (full detail of every request — `scripts/build_cls_pdf.py`).
- **CLS Request page** (`cls_request_detail`) — one page holding the request and its
  whole breakdown. Sits on a slightly darker canvas than the list, with a high-contrast
  back link and the autosave indicator ("Last Saved 7/29/26 at 2:45 PM"; hover shows who
  saved) on the same row.
  - **Summary** — request name first and full width (the page title updates live as you
    type), **Service** dropdown, **Request type** with an ⓘ icon that expands the
    adjustment-type reference table, then **FY28 / FY29 / FY30 Amount** on one row.
    Checking **One-time request** hides *and clears* the FY29/FY30 amounts.
    **Summarize the request** is mandatory with a live 300-word limit — over the limit the
    field and counter turn red and report the exact overage.
    New requests show a **Create request** button; after that the page **autosaves**
    (no Save button).
  - **Request details** — a live "Select Add Details to describe the remaining $…" note
    (green when the objects balance, red when they exceed the request), then an add form
    (**Object** dropdown, **Amount**, one-line **Justification**) above the table of
    objects, each removable.
  - **Position requests** — hidden until **Add positions to this request** is checked.
  - Empty required fields highlight red; a fully justified request shows *"This request
    has been justified."* when you return to the list. AgencyViewers and BBMR reviewers
    see this page entirely read-only.
- **CLS Review** (`cls_review`) — **BBMRReviewer only**. Four cards (Pending Requests =
  all, Requests for Review = complete only, total requested $, total positions), a bar
  chart of requested dollars by agency with hover tooltips, multi-select **Status** and
  **Agency** filters, and one card per request showing the submitted data plus the
  reviewer's fields: **Evaluation score**, **Analyst notes**, **Analyst approval**, and
  **BBMR approval** (Approved / Partial / Denied — which sets the request's final status).
  Each card links to **Open request** for the read-only detail view.

Agency requests are scoped to the agency's **current plan**; the BBMR review page spans
every agency.

## Data model

Four tables in the Postgres `budget` schema, created at startup by
`ensure_review_schema()` in `R/database.R`. The first three mirror the BBMR Azure SQL
target schema (`Target_Database_Schema_BBMR.docx`, Group 5 — Budget Proposal), translated
to Postgres types; `cls_review` is additive so the agency's submission is never
overwritten by review edits.

### `budget.cls_request` — the parent request

| Column | Type | Notes |
|--------|------|-------|
| `cls_id` | serial PK | |
| `plan_service_id` | int NOT NULL → `performance.plan_service` | the service the request is tied to |
| `request_name` | varchar(500) NOT NULL | |
| `request_type` | varchar(100) | one of the 8 adjustment types (Annualization of Cost … Remove One-Time Item) |
| `request_amount` | numeric(18,2) | FY28 amount |
| `one_time` | boolean NOT NULL | one-time vs ongoing |
| `overall_summary` | text | |
| `justified` | varchar(10) | Yes \| No |
| `completed` | boolean NOT NULL | derived from `status` (true once at BBMR) |
| `status` | varchar(30) NOT NULL | In Progress \| Agency Review \| BBMR Review \| Approved \| Partially Approved \| Denied *(added)* |
| `amount_next_fy` | numeric(18,2) | FY29 projected |
| `amount_2next_fy` | numeric(18,2) | FY30 projected |
| `created_at` / `updated_at` | timestamptz | |
| `modified_by` | text | last saver, shown by the autosave indicator *(added)* |

### `budget.cls_request_line` — line-item breakdown

| Column | Type | Notes |
|--------|------|-------|
| `line_id` | serial PK | |
| `cls_id` | int NOT NULL → `budget.cls_request` (ON DELETE CASCADE) | |
| `object_category` | varchar(200) | e.g. Grants & Subsidies; Major Equipment |
| `amount` | numeric(18,2) | |
| `justification` | text | |
| `sort_order` | int NOT NULL | |

### `budget.cls_request_position` — position requests

| Column | Type | Notes |
|--------|------|-------|
| `pos_id` | serial PK | |
| `cls_id` | int NOT NULL → `budget.cls_request` (ON DELETE CASCADE) | |
| `classification` | varchar(200) NOT NULL | job classification title |
| `position_count` | int NOT NULL | |
| `estimated_salary` | numeric(18,2) | |
| `justification` | text | |
| `explanation` | text | |

### `budget.cls_review` — BBMR review (additive)

| Column | Type | Notes |
|--------|------|-------|
| `review_id` | serial PK | |
| `cls_id` | int NOT NULL UNIQUE → `budget.cls_request` (ON DELETE CASCADE) | one review per request |
| `evaluation_score` | numeric(6,2) | |
| `analyst_notes` | text | |
| `analyst_approval` | varchar(20) | Approved \| Partial \| Denied |
| `bbmr_approval` | varchar(20) | Approved \| Partial \| Denied — drives the request's final status |
| `reviewed_by` | text | |
| `updated_at` | timestamptz | |

Deleting a request removes its lines, positions, and review row (done explicitly in a
transaction, so it works even where the FK cascade predates this feature).

## Code map

| Concern | Location |
|---------|----------|
| Tables + migration | `R/database.R` → `ensure_review_schema()` |
| Data load | `R/database.R` → `load_app_data()` (`budget_cls_request*` keys) |
| Write helpers | `R/database.R` → `create_cls_request()`, `update_cls_request()`, `delete_cls_request()`, `add/delete_cls_request_line()`, `add/delete_cls_request_position()`, `set_cls_status()`, `set_plan_cls_status()`, `save_cls_review()` |
| Vocabularies | `R/database.R` → `cls_request_type_choices`, `cls_object_choices`, `cls_status_choices`, `cls_adjustment_type_guidance` |
| Pages | `app.R` → `page_cls_requests()` (list), `page_cls_request_detail()` (request), `page_cls_review()` (BBMR) |
| Exports | `app.R` → `cls_export_sheets()` (Excel), `cls_export_payload()` + `build_cls_request_pdf()` → `scripts/build_cls_pdf.py` |
| Routing / roles | `app.R` → `page_ui()` switch, `can_view_cls_requests()`, `can_edit_cls_requests()`, `can_approve_cls()`, `can_review_cls()` |
| Server handlers | `app.R` → `input$cls_*` observers (incl. `cls_autosave`, `cls_review_save`) |
| Client | `www/app.js` (`data-cls-*` handlers, word count, one-time toggle, remaining-$ math, sorting, `hide-cls-requests` / `hide-cls-review` toggles), `www/styles.css` (`.cls-*`) |

## Notes and open items

- **Submission is per request.** Each row carries its own action — **Submit** for writers
  (while the request is *In Progress*) and **Send to BBMR** for approvers (while it is
  *In Progress* or *Agency Review*) — each with a confirmation naming that request. There
  is no batch submit.
- **Email notification is deliberately disabled.** The hook where the Agency Submitter
  would be emailed on submission is in place but switched off
  (`notify_agency_submitter_of_cls <- FALSE`).
- **Deadline text is generic.** The reminder names the Agency Approver but not a real
  date; wire it to the plan cycle when that date is available.
- **Object list** uses `Minor Equipment (<$5k)` / `Major Equipment (>$5k)` (the source
  document had these reversed; corrected on review).
