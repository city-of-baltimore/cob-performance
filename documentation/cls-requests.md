# CLS Requests

Reference for the **Current Level of Service (CLS)** budget-request feature in the
Beacon performance & budgeting app.

CLS requests are part of the fall **budget proposal** cycle. An agency uses them to
ask BBMR to fund the cost of maintaining its current level of service — mandated cost
increases, cyclical costs, extraordinary inflation, and similar. Each request breaks
down into line items (object categories) and position requests.

> **Gated to BBMR.** Budget Planning — and therefore all three CLS pages — is visible to
> **BBMRReviewer** and **SystemAdmin** only (`can_access_budget_planning()`). Opened to
> BBMR's 14 analysts on 2026-08-03. **Agencies still cannot reach any of this**, and that
> stays true until the real spend-category list lands; see
> [Open items](#notes-and-open-items).
>
> Reviewers get **both** pages and the **full** agency selector, but every request they
> open is **read-only** — decisions are recorded on CLS Review, not by editing a submission.

## The workflow

| Step | Actor | Status |
|------|-------|--------|
| 1. Enter CLS requests | Agency **Writer** | ✅ built |
| 2. Submit for approval | Agency **Writer** | ✅ built (→ *Agency Review*) |
| 3. Send for BBMR review | Agency **Submitter** | ✅ built (→ *BBMR Review*) |
| 4. Review requests | **BBMR Reviewer** | ✅ built (CLS Review page) |
| 5. Approve / partially approve / deny | **BBMR Reviewer** | ✅ built (sets final status) |
| 6. See the decision | Agencies | ✅ built (Status column) |

Everything is organised **by agency, never by entity**. A user can be routed into an
entity's plan — Mayoralty alone has nine — but every request belongs to the parent
agency, and all of that agency's entities are listed together. Entity plans carry no
`agency_id`, so the parent is resolved through `reference.plan_entity.parent_agency_id`
(`cls_agency_id_for_submitter()`, `cls_plan_ids_for_agency()`).

### Request status lifecycle

Every request carries a `status` that drives the whole workflow. Each has its own chip
colour — the generic `tone-*` classes only offer five, so `cls_status_chip()` and
`.cls-status-*` in `styles.css` provide six.

| Status | Set when | Chip |
|--------|----------|------|
| **In Progress** | the request is created | grey |
| **Agency Review** | a Writer clicks *Submit for approval* | amber |
| **BBMR Review** | a Submitter clicks *Send for BBMR Review* | blue |
| **Approved** | BBMR records an Approved decision | green |
| **Partially Approved** | BBMR records a Partial decision | purple |
| **Denied** | BBMR records a Denied decision | red |

"Complete" is derived from status rather than stored: `cls_status_is_complete()` is true
from *BBMR Review* onward. The target schema's `completed` BIT and the early `justified`
flag were both dropped — two states could not express the six the workflow needs.

### What makes a request complete

`cls_request_gaps()` is the single definition, used by the red **NOT DETAILED** badge on
the list, the blocking dialog when sending a request on, and (mirrored in `app.js`) the
alert when leaving the page. A request is missing something if it has no name, no type,
no summary, no positive FY28 amount, or if objects + positions do not add up to the FY28
amount. **A recurring request additionally needs FY29 and FY30 amounts**; a one-time
request has neither, and the fields are hidden.

## Who can see / do what

Access is by app role, checked both server-side (page gate) and in the nav:

- **AgencyViewer** — can open the CLS Requests page and view requests (read-only).
- **AgencyWriter** — create/edit/delete requests, objects and positions; can *Submit for
  approval*.
- **AgencySubmitter** — the same, plus *Send to BBMR* per request, with a named
  attestation. Holds final sign-off for the agency.
- **BBMRReviewer** — sees **both** Budget Planning pages and every agency in the switcher,
  and records the decision on CLS Review. Every request opens **read-only**, whatever its
  status and wherever it was opened from: the decision belongs on the review page, not in the
  agency's submission.
- **SystemAdmin** — full access, for support and testing.
- Everyone else (OPIReviewer, DeputyMayor, CAOffice) — nav items hidden, pages redirect.

Helpers in `app.R`: `can_access_budget_planning()`, `can_view_cls_requests()`,
`can_edit_cls_requests()`, `can_approve_cls()`, `can_review_cls()`.

`AgencyApprover` was **retired**; its duties moved to `AgencySubmitter`.

## Pages

### CLS Requests (`cls_requests`)

Titled *"{Agency} Requests"*. Under the heading sit the submission notice, then the
people who matter for it:

```
Submitter:       Bill Henry, Charmaine Callahan, and Tony Bedon
Budget Analyst:  <from reference.agency.budget_analyst>
```

Submitters come from `cls_submitter_user_ids_for_agency()`, which checks the
`AgencySubmitter` role **and** falls back to `access.user_entity_access` — most role rows
carry no `agency_id`, so a role-table-only lookup names almost nobody. The analyst comes
from `agency_budget_analyst()`, shared with the plan screens.

Then agency-wide cards (Requests in progress, Sent for BBMR review, Total requested,
Total positions), a **collapsible** bar chart broken out by service, the **Add CLS
Request** bar, and the table.

The table sorts by **Request name / Service / Amount / Status**. Long request names wrap
to two lines and then ellipsise, with the full name on hover. Amounts show as separated whole
dollars (`$60,000`) everywhere — the `$X.XK` / `$X.XM` abbreviation was removed, because it
hid the figure people were checking. Each row
carries its own hand-off action — **Submit** for writers, **Send to BBMR** for submitters,
shown only at the right status — plus **Delete** and **Modify →**. A request that has
reached BBMR shows a lock instead of Delete, and `delete_cls_request()` refuses it
server-side whatever calls it.

**Export request(s)** offers **Excel** (`cls_export_sheets()` + `writexl`; worksheets
Request summary / Line items / Personnel) and **PDF** (`scripts/build_cls_pdf.py`). Both
file names carry the agency: `cls-requests-comptroller-20260731.xlsx`.

### CLS Request page (`cls_request_detail`)

One page holding the request and its whole breakdown, with a back link and the autosave
indicator on the top row.

- **Summary** — request name (the page title updates live as you type), **Service**,
  **Request type** with an ⓘ icon that expands the adjustment-type reference table,
  **Request duration** as a One-Time / Recurring toggle with its own ⓘ, then **FY28 /
  FY29 / FY30 Amount**. One-Time hides *and clears* the out-years; Recurring requires
  them. **Summarize the request** is mandatory with a live 150-word limit.
- **Request details** — a live balance banner ("The total request needs to explain
  $185,000.00"), green when objects and positions balance the FY28 amount and red in
  either direction. Then the add form (**Object**, **Spend category**, **Amount**,
  **Justification**) and the table of objects. Choosing **Create Spend Category** reveals
  a prompt to describe it in the Justification.
- **Position requests** — hidden until **Add positions to this request** is checked.
  **Position Count** starts empty; **Estimated Cost** is a placeholder hyperlink.
- Every row in both tables has a **pen** that opens an inline editor with save/cancel
  icons. **Add Details** / **Add position** stay disabled until every field in their form
  is filled; the server re-checks regardless.
- There is no create or save button. The draft row is created when **Add CLS Request** is
  clicked, so objects and positions have a `cls_id` to attach to immediately, and
  everything autosaves from the first keystroke.
- **An abandoned draft is discarded.** Creating the row up front means walking away would
  otherwise leave a blank request on the agency's list. `discard_empty_cls_draft()` removes
  it, on navigating away *and* on the browser session ending. It only deletes a row that is
  genuinely untouched — no real name, no amounts, no summary, no type, no objects, no
  positions, and still *In Progress* — so nobody's work in progress is at risk.
- Leaving with a mandatory field empty is **blocked**, with the fields named. Leaving an
  unbalanced request warns. Leaving a complete one says nothing.
- A request that has reached BBMR is read-only, as is any request opened by a BBMR
  reviewer.

### CLS Review (`cls_review`)

Four cards — Pending Requests (all), Requests for Review (only those sent to BBMR), and
**Total requested / Total positions, both across every request**. The two totals used to
count only the sent ones, which made the card disagree with the sum of the table under it
and read as broken. Then a
collapsible bar chart by agency, three filters, and the request table.

**Filters** are checkbox dropdowns (`cls_check_dropdown()`) for **Status**, **Agency** and
**Service**, each with Select all / Clear / **Apply**. Ticks are held locally and pushed
to the server **once** — on Apply, or when the panel closes. Without that, every tick
re-rendered the table and shut the panel mid-choice.

**Normal mode** lists one collapsible row per request (Request, Agency, Service,
Positions, FY28, Status). Expanding shows the summary, Type with its definition on hover,
Duration, FY28–FY30, the object and position tables, and the analyst panel: **Analyst
recommendation** (advisory), **BBMR approval** (drives status, flagged *THIS STATUS IS
SENT TO AGENCIES*), **Approved FY28** / **Approved positions**, and **Analyst notes**.

**Bulk approve** replaces that table with one line per request:

```
Agency | Service | Request | Type | FY28 | Duration | Pos. | BBMR approval | Appr. FY28 | Appr. pos. | Return
```

The first seven are read-only context; the next three are editable. **Save and close**
writes every row with a decision set; **Cancel** leaves without saving.

**Return** sends a request back to the agency to rework. Because "locked" is derived from
status, this moves it to *In Progress*, which is what makes it editable again, and clears
any recorded decision (`clear_cls_review_decision()`) so the agency is not looking at a
stale approval. **Analyst notes are kept** — they are the reason it went back. The button
only appears on a request that is actually locked; anything still In Progress or in Agency
Review shows a dash.

The Excel export covers every agency, or names the agency when the filter is down to one.

### The bar chart

`cls_review_chart()` — a dependency-free inline SVG, grouped by agency on CLS Review and
by service on CLS Requests. Bars are 13px with 8.5px labels. Each request contributes its
FY28 amount to one segment, except a **Partially Approved** request, which is split: the
**approved** amount is yellow and the shortfall shows separately as **Not approved**. A
partial with no approved amount recorded therefore shows entirely as Not approved — which
is the honest reading, since nobody has said what was approved.

## Data model

Four tables in the Postgres `budget` schema. The canonical DDL is
`database/schema/target_schema.sql`; `ensure_review_schema()` in `R/database.R` migrates
existing databases to match. **Both must be changed together** — `CREATE TABLE IF NOT
EXISTS` never alters an existing table, and CI builds from the canonical schema alone.

The first three mirror the BBMR Azure SQL target schema (Group 5 — Budget Proposal),
translated to Postgres types; `cls_review` is additive so the agency's submission is never
overwritten by review edits.

### `budget.cls_request` — the parent request

| Column | Type | Notes |
|--------|------|-------|
| `cls_id` | serial PK | |
| `plan_service_id` | int NOT NULL → `performance.plan_service` | the service the request is tied to |
| `request_name` | varchar(500) NOT NULL | drafts start as `Untitled CLS request`, treated as unnamed |
| `request_type` | varchar(100) | one of the 8 adjustment types |
| `request_amount` | numeric(18,2) | FY28 amount |
| `one_time` | boolean NOT NULL | one-time vs recurring |
| `overall_summary` | text | |
| `status` | varchar(30) NOT NULL | the six workflow states *(replaced `completed`)* |
| `amount_next_fy` | numeric(18,2) | FY29 — required when recurring |
| `amount_2next_fy` | numeric(18,2) | FY30 — required when recurring |
| `created_at` / `updated_at` | timestamptz | |
| `created_by` | int → `access.user` | who opened the request *(added)* |
| `modified_by` | int → `access.user` | last saver, shown by the autosave indicator *(added)* |

`justified`, `completed` and `evaluation_score` were dropped.

### `budget.cls_request_line` — line-item breakdown

| Column | Type | Notes |
|--------|------|-------|
| `line_id` | serial PK | |
| `cls_id` | int NOT NULL → `budget.cls_request` (ON DELETE CASCADE) | |
| `object_category` | varchar(200) | e.g. Grants & Subsidies; Major Equipment (>$5k) |
| `spend_category` | varchar(200) | chart-of-accounts code *(added — currently placeholders)* |
| `amount` | numeric(18,2) | |
| `justification` | text | doubles as the description for a new spend category |
| `sort_order` | int NOT NULL | |

### `budget.cls_request_position` — position requests

| Column | Type | Notes |
|--------|------|-------|
| `pos_id` | serial PK | |
| `cls_id` | int NOT NULL → `budget.cls_request` (ON DELETE CASCADE) | |
| `classification` | varchar(200) NOT NULL | job classification title |
| `position_count` | int NOT NULL | |
| `estimated_salary` | numeric(18,2) | labelled **Estimated Cost** in the UI |
| `justification` | text | |
| `explanation` | text | |

### `budget.cls_review` — BBMR review (additive)

| Column | Type | Notes |
|--------|------|-------|
| `review_id` | serial PK | |
| `cls_id` | int NOT NULL UNIQUE → `budget.cls_request` (ON DELETE CASCADE) | one review per request |
| `analyst_notes` | text | |
| `analyst_approval` | varchar(20) | Approved \| Partial \| Denied — advisory only |
| `bbmr_approval` | varchar(20) | Approved \| Partial \| Denied — drives the request's final status |
| `approved_amount` | numeric(18,2) | what BBMR actually approved for FY28 |
| `approved_positions` | int | |
| `reviewed_by` | int → `access.user` | |
| `updated_at` | timestamptz | |

Deleting a request removes its lines, positions, and review row (done explicitly in a
transaction, so it works even where the FK cascade predates this feature).

## Exports

Both Excel workbooks carry the audit trail on their first sheet: **Created date**,
**Created by email**, **Modified date**, **Modified by email**. Dates format as
`2026-07-31 14:05`; emails come from `access.user` joined on `created_by` / `modified_by`.
Rows created before the `created_by` column existed inherit `modified_by`, which for an
untouched request is the same person.

## Code map

| Concern | Location |
|---------|----------|
| Canonical DDL | `database/schema/target_schema.sql` |
| Migration | `R/database.R` → `ensure_review_schema()` |
| Data load | `R/database.R` → `load_app_data()` (`budget_cls_request*` keys) |
| Write helpers | `R/database.R` → `create_cls_request()`, `update_cls_request()`, `delete_cls_request()`, `add/update/delete_cls_request_line()`, `add/update/delete_cls_request_position()`, `set_cls_status()`, `set_plan_cls_status()`, `save_cls_review()` |
| Vocabularies | `R/database.R` → `cls_request_type_choices`, `cls_object_choices`, `cls_spend_category_choices`, `cls_status_choices`, `cls_adjustment_type_guidance` |
| Pages | `app.R` → `page_cls_requests()`, `page_cls_request_detail()`, `page_cls_review()` |
| Agency grouping | `app.R` → `cls_agency_id_for_submitter()`, `cls_plan_ids_for_agency()`, `cls_requests_for_agency()`, `cls_agency_service_choices()` |
| People | `app.R` → `cls_submitter_user_ids_for_agency()`, `cls_submitter_names_for_agency()`, `agency_budget_analyst()` |
| UI building blocks | `app.R` → `cls_money_input()`, `cls_check_dropdown()`, `cls_collapsible_chart()`, `cls_status_chip()`, `cls_bulk_grid()` |
| Formatting | `app.R` → `cls_format_dollars()`, `cls_format_commas()`, `cls_format_km()`, `cls_export_stamp()`, `cls_export_email()` |
| Exports | `app.R` → `cls_export_sheets()`, `cls_review_export_sheets()`, `cls_export_payload()` + `build_cls_request_pdf()` → `scripts/build_cls_pdf.py` |
| Routing / roles | `app.R` → `page_ui()` switch, `can_access_budget_planning()` and friends |
| Server handlers | `app.R` → `input$cls_*` observers (incl. `cls_autosave`, `cls_review_save`, `cls_bulk_save`) |
| Client | `www/app.js` (`data-cls-*` handlers, the money input binding, batched filter dropdowns, word count, one-time toggle, remaining-$ math, sorting), `www/styles.css` (`.cls-*`) |

### The money input binding

Amount and count fields are **not** `numericInput()`. A native `<input type="number">`
cannot display a thousands separator, so `cls_money_input()` emits a text input with class
`cls-money-input`, and `www/app.js` registers a custom Shiny input binding
(`beacon.clsMoneyInput`) that:

- strips separators and returns an integer to the server (`"1,234,567"` → `1234567`);
- truncates decimals (`"1234.99"` → `1234`) and blocks `.`, `e`, `E` on keydown;
- returns `null` for empty or non-numeric input;
- reformats with separators on input and on blur, preserving caret position.

Anything in JS reading these fields must use `clsNumberValue(el)`, not `parseFloat` —
`parseFloat("1,000")` is `1`.

## Notes and open items

- **The spend-category list is invented.** The ten `SC6xxx` values in
  `cls_spend_category_choices` are placeholders pending the real chart of accounts. This
  is the main reason Budget Planning is still SystemAdmin-only.
- **The "Estimated Cost" link has no destination.** It is a live-looking hyperlink wired
  to a placeholder handler.
- **Two agencies have no budget analyst.** `agency_budget_analyst_seed.csv` covers 55 of
  the 57 active agencies; **AGC7000 Transportation** and **AGC9900 CAFR Adjustments** are
  not in it and show "Unassigned". Transportation looks like a genuine omission.
- **Submission is per request.** There is no batch submit; bulk approve is a BBMR-side
  action only.
- **Email notification is deliberately disabled**
  (`notify_agency_submitter_of_cls <- FALSE`).
- **Deadline text is hard-coded** to September 15th COB (4:30pm); wire it to the plan
  cycle when that date is available.
- **Object list** uses `Minor Equipment (<$5k)` / `Major Equipment (>$5k)` (the source
  document had these reversed; corrected on review).

## Spend categories

The chart-of-accounts spend-category codes are **not in this repository**, which is public.
They are city budget data and live only in the database.

| Piece | In git? |
|---|---|
| `reference.spend_category` table structure | ✅ yes, empty |
| The codes themselves | ❌ **never** |
| `scripts/load_spend_categories.R` (loader, no data) | ✅ yes |
| `database/seed/spend_category_seed.csv` | ❌ gitignored |
| `www/_*.html` render harnesses (contain the rendered dropdown) | ❌ gitignored |

Load or refresh them with:

```bash
Rscript scripts/load_spend_categories.R --file <path-to-csv> --dry-run
```

Drop `--dry-run` to write. The script is idempotent, reports what it would insert, update
and retire, and needs `--prune` before it will deactivate a code missing from the file —
codes are only ever deactivated, never deleted, because a request line may already point at
one.

**The app reads the table, never the file.** `spend_category_labels(db)` returns
`"<code> - <label>"` in chart order; `cls_spend_category_options(db)` appends any category an
existing request already references so a stored value never vanishes from its own row. This
separation matters — the CSV is not in the Docker image, so anything reading it at runtime
would find nothing.

**An empty catalogue is a supported state.** A fresh database and CI have no codes; the
dropdown then offers only what existing requests reference. Nothing errors and no
placeholder data is invented.
