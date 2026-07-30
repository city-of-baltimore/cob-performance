# CLS Requests — Build Log

A running account of the work to add the **CLS (Current Level of Service) request**
workflow to the Beacon performance & budgeting app. Newest entries at the bottom.

This log is the "what I did and why" narrative. The companion file
[`cls-requests.md`](cls-requests.md) is the reference doc for the finished feature
(data model, roles, workflow).

---

## Goal

Build the agency side of the CLS request workflow described by BBMR / OPI:

1. An agency **writer** enters CLS requests.
2. An agency **approver** approves them.
3. **BBMR** reviews and approves/denies.
4. Agencies see the approval/denial.

This build starts at the beginning of that chain: a page where agency users
(AgencyViewer / AgencyWriter / AgencyApprover) create and manage requests, and a
detail view where each request is broken down into **line items** and
**position requests**.

## Decisions locked in with the user

- **Service link on create.** `CLS_REQUEST.plan_service_id` is `NOT NULL`, so the
  create form asks the agency to pick one of their plan's services first.
- **Feature name:** "CLS Requests" (nav + page title).
- **Schema source of truth:** `Target_Database_Schema_BBMR.docx` (Group 5 — Budget
  Proposal). The three CLS tables are built exactly to that spec.
- The Azure SQL target schema uses `INT IDENTITY` / `NVARCHAR` / `BIT`; this app runs
  on **Postgres**, so types are translated (`serial`, `text`/`varchar`, `boolean`,
  `numeric(18,2)`) and the tables live in the existing `budget` schema next to the
  other `plan_service`-linked budget tables.

---

## Entry 1 — Data layer (`R/database.R`)

**What:** the three CLS tables now exist and are read/written by the app.

- **Schema migration** — added `budget.cls_request`, `budget.cls_request_line`, and
  `budget.cls_request_position` to `ensure_review_schema()` as
  `CREATE TABLE IF NOT EXISTS` statements. This function runs at every startup
  (`app.R` calls `ensure_review_schema(database)` right after connecting), so the
  tables are created automatically on existing databases — no manual migration step.
  Fields match the BBMR spec 1:1; the two line/position child tables use
  `ON DELETE CASCADE` so deleting a request cleans up its children.
- **Loader** — added `budget_cls_request`, `budget_cls_request_line`, and
  `budget_cls_request_position` to `load_app_data()`. The parent query joins through
  `performance.plan_service` → `planning.agency_plan` so each request also carries its
  `plan_id`, `service_id`, and `agency_id` for filtering on the page.
- **Write helpers** — `create_cls_request()`, `update_cls_request()`,
  `delete_cls_request()`, `add_cls_request_line()`, `delete_cls_request_line()`,
  `add_cls_request_position()`, `delete_cls_request_position()`. Each validates its
  inputs (required name, valid service, `justified` limited to Yes/No, etc.) and uses
  parameterized SQL. Follows the exact pattern of the existing
  `create_feedback_request` / `delete_feedback_request` helpers.

**Why this shape:** the app already loads all data into in-memory data frames and
reloads them (`refresh_app_data()`) after any write. The CLS feature plugs into that
same cycle rather than inventing a new persistence path.

**Status:** ✅ complete.

## Entry 2 — List page, create, delete (`app.R`, `www/`)

**What:** the agency-facing **CLS Requests** page.

- `page_cls_requests()` renders a "Create CLS request" button and a table of the
  current plan's requests (name · service · summary · amount · Open/Delete). Empty and
  no-plan states are handled. The summary column shows a truncated `overall_summary`,
  falling back to `request_type`.
- Create uses a shared custom modal (`cls_modal_ui()` + `cls_modal_state` reactiveVal +
  `output$cls_modal`). The create form leads with the **service picker** (per the
  agreed decision) sourced from the plan's `plan_service_rows()`.
- New nav item "CLS Requests" under a "Budget Planning" group in both the desktop and
  mobile navs, gated by the `cls-requests-nav-item` class + a `hide-cls-requests` body
  class driven from `set-navigation-scope`.
- Delete is a `data-cls-delete` button → JS confirm → `input$cls_delete` → server
  `delete_cls_request()` → `refresh_app_data()`.
- Access enforced two ways: `page_ui()` redirects non-viewers off the page, and every
  server mutation calls `cls_guard_edit()`.

**Status:** ✅ complete.

## Entry 3 — Detail page: line items + positions (`app.R`, `www/`)

**What:** `page_cls_request_detail()` — opened from a request's "Open" button
(`data-cls-open` → `input$cls_open_detail` → sets `current_cls_id` and navigates).

- Shows the request's fields and status chips (type, one-time/ongoing, justified,
  completed) plus projected FY+2 / FY+3 amounts and the summary.
- A **line-item** table and a **position** table, each with add (modal) and remove
  (`data-cls-delete-line` / `data-cls-delete-position`) actions wired to the
  `add_cls_request_line` / `add_cls_request_position` / delete helpers.
- The same modal drives all three add flows via `cls_modal_state$mode`
  (`create` / `add_line` / `add_position`).

**Status:** ✅ complete.

## Entry 4 — Documentation & verification

- Reference doc written: [`cls-requests.md`](cls-requests.md) (workflow, roles, data
  model, code map, and the planned steps 3–6 for agency approval + BBMR review).
- Verification performed:
  - **Static cross-layer check** — every `cls_*` identifier reconciled across
    `R/database.R` (helper defs), `app.R` (server reads, UI input ids), and
    `www/app.js` (`data-cls-*` producers). No mismatches.
  - **Schema conformance** — table/column defs checked field-by-field against
    `Target_Database_Schema_BBMR.docx` Group 5.
  - **Read-through** — each inserted block reviewed for balance and correctness.
- **Not run live:** this machine has no local R toolchain, so the only runtime is the
  Docker stack (`docker compose up app`). Docker Desktop was launched but its engine
  did not come up during the session, so a live smoke-test was not completed. Recommend
  running `docker compose up app` and exercising: create request → open detail → add a
  line item and a position → delete each → delete the request, as an
  AgencyWriter/Approver, and confirming the nav item is hidden for a reviewer role.

**Status:** implementation complete; live smoke-test outstanding.

## Entry 5 — Design change: drop the pop-up, use a dedicated entry page

Per review feedback ("instead of a pop up, add an arrow to enter the request and add
the line item/personnel details"), the modal was removed entirely:

- **List page** — each row's action changed from an "Open" button to a primary
  **Enter →** arrow (`cls-enter-arrow`). Delete remains.
- **Create + Enter both navigate to the full detail page.** The "Create CLS request"
  button now routes to `cls_request_detail` in **new mode** (no `cls_id` yet), which
  renders the request form inline on the page. Saving creates the request and lands on
  its detail page.
- **Line items / positions** are now added via **inline forms beneath each table**
  (`cls-add-form` + `cls-form-grid`), not a modal.
- Removed: `cls_modal_ui()`, `output$cls_modal`, `uiOutput("cls_modal")`, the
  `cls_modal_state` reactiveVal, and the modal open/close/cancel observers. The
  create/line/position submit handlers now read `current_cls_id()` directly. The
  `.cls-modal*` CSS was replaced with `.cls-form-grid` / `.cls-form-actions` /
  `.cls-add-form` / `.cls-enter-arrow`.
- Verified statically: no dangling `cls_modal*` references remain; all `input$cls_*`
  reads reconcile with the inputs now rendered on the pages / produced by JS.

**Status:** design updated; still pending the live smoke-test.

## Entry 6 — Live smoke-test + bug fix

Ran the stack for real: `docker compose up -d --build app` (Postgres 18 + the app image),
then exercised the data layer against the live seeded database via `Rscript` inside the
app container (sourcing `R/database.R`, calling the real helpers and `load_app_data`).

- **Confirmed:** `ensure_review_schema()` creates all three `budget.cls_request*` tables
  with no startup errors; `create_cls_request()` + `add_cls_request_line()` +
  `add_cls_request_position()` persist correctly and reload through `load_app_data()`
  with the right joins (`service_id`, `plan_id`, `agency_id`).
- **Bug found & fixed:** deleting a request failed —
  `violates foreign key constraint "cls_request_line_cls_id_fkey"`. On databases where
  the CLS tables predate the `ON DELETE CASCADE` (the FK showed `confdeltype = 'a'`,
  NO ACTION), `CREATE TABLE IF NOT EXISTS` never adds the cascade, so the delete was
  blocked. Fixed `delete_cls_request()` to remove child rows (lines, then positions,
  then the request) inside a transaction — correct regardless of the FK's delete rule.
- **Re-verified:** after the fix, create → add line → add position → delete leaves
  0 rows across all three tables. Smoke test passes.

**Not covered:** the authenticated in-app UI was not click-tested, because reaching the
CLS pages requires signing in with a password (out of scope for automated testing here).
The UI markup was verified statically (cross-layer symbol reconciliation) and via a
faithful static preview; the data layer it calls is verified live as above.

**Status:** ✅ data layer verified live; UI verified statically + by preview.

## Entry 7 — Combine the entry form and the detail page

Per review feedback ("combine page 2 and 3"), the separate new-request entry page and
the request detail page are now **one page** (`page_cls_request_detail`):

- **Request details** is now an editable form on the same page as the line items and
  positions. New requests → empty form + "Create request"; existing requests → prefilled
  form + "Save changes" (service read-only); AgencyViewers → read-only summary.
- Wired `update_cls_request()` to a new `cls_submit_update` handler; the create form now
  also captures projected FY+2 / FY+3 amounts. Create/edit inputs share `cls_form_*` ids.
- Line-item and position sections sit directly below and unlock once the request exists.
- Verified live against the running database: `create_cls_request` (with projected
  amounts) and `update_cls_request` (name, type, amount, one-time, completed, justified,
  projected) both round-trip correctly through `load_app_data`; delete still clean.

**Status:** ✅ combined page built; data layer re-verified live.

## Entry 8 — Formatting pass + Excel export

Review feedback round:

- **List page:** button relabeled **Add CLS Request**; row action relabeled **Modify →**;
  summary column now truncates to one line with a CSS ellipsis.
- **Request page:** the header title is now the request's name (one line, ellipsis); the
  service is an editable **dropdown** (persisted via `update_cls_request(plan_service_id=)`,
  verified live moving a request across services); request amount + projected FY+2/FY+3
  share one row; the whole page sits on a slightly darker canvas (`cls-detail-shell`) for
  contrast with the list.
- **Section order:** on the request page the **add form now sits above the table** in both
  the line-item and position sections.
- **Excel export:** an **Export to Excel** button on the list page downloads one worksheet
  with three stacked tables — request summary, line-item breakdown, and personnel — for all
  of the plan's requests. Built with `cls_export_rows()` + `writexl` (added to the
  Dockerfile). Verified live: builder returns an 11×10 sheet with all three section labels
  and writes a valid `.xlsx`.

**Status:** ✅ built; export + service-change verified live against the running database.

## Entry 9 — Autosave, Object dropdown, and field polish

- **Autosave** replaced the Save button on existing requests: edits debounce ~0.9s and
  write through `update_cls_request()`, with a **"Last Saved 7/29/26 at 2:45 PM"**
  indicator on the back-link row (hover shows who saved). Added a `modified_by` column
  (and coerced it to `text` — this dev database had it as `integer` from an earlier pass).
  Data is deliberately *not* refreshed mid-edit so the form isn't re-rendered under the
  user; the list refreshes when they leave the page.
- **Object** (was "Expenditure Object") is now a dropdown of the nine expenditure objects;
  the table column is just "Amount".
- Removed number spinners and `($)` suffixes; FY labels became **FY28 / FY29 / FY30**;
  service label shortened to **Service**; the remaining-$ note reads *"Select Add Details
  to describe the remaining $… in this request."*; multi-line fields are resizable; table
  text is smaller; the Positions box stays hidden until its checkbox is ticked.
- Fixed the request title to sit on one line **and update live** as the name is typed; the
  request-type ⓘ icon moved inline next to the label with no accompanying text.

## Entry 10 — Approver hand-off, status lifecycle, and the BBMR CLS Review page

- **Status replaces the True/False Complete field** in the UI. Added a `status` column with
  a six-state lifecycle (In Progress → Agency Review → BBMR Review → Approved / Partially
  Approved / Denied), backfilled from `completed`, with `completed` kept in sync (true once
  a request reaches BBMR) so the target-schema field stays meaningful. Surfaced as a
  sortable, colour-coded **Status** column; the list-page buttons are now `small`.
- **Agency Approver** gets *Send for BBMR Review* in place of *Submit for approval*;
  each action advances only requests in an appropriate prior state (`only_from`).
- **New BBMR-only page, CLS Review** (`page_cls_review`): four metric cards (pending = all,
  for-review = complete, total requested, total positions), a dependency-free SVG bar chart
  with `<title>` tooltips, multi-select Status/Agency filters, and a card per request showing
  the submitted data plus new review fields — **evaluation score, analyst notes, analyst
  approval, BBMR approval**. Recording a BBMR decision sets the request's final status.
- Review data lives in a **separate `budget.cls_review` table** (1:1, additive) so the
  agency's submission is never overwritten — verified explicitly in testing.
- Per the latest direction, **BBMR reviewers see requests read-only**: `can_edit_cls_requests`
  no longer includes them, each review card links to **Open request**, and that view renders
  with no inputs or add-forms and a back link to CLS Review. (This reverses an earlier
  instruction that BBMR could edit requests.)

**Verified live** against the running stack: the full status chain
(created → Agency Review → BBMR Review → Partially Approved / Approved / Denied) with
`completed` tracking correctly; review save round-trips (score 87.5, BBMR "Partial") while
the submitted request data stays byte-identical; role gating (writer blocked from CLS
Review, BBMR read-only on requests); per-role buttons; the status column, chips, K/M
amounts and sorting. A six-page interactive walkthrough was assembled from the app's real
rendered HTML, and browser-tested: sorting, live title, one-time hide/clear, the 300-word
counter, chart tooltips, and the read-only view (0 inputs, 0 add-forms).

**Status:** ✅ built and verified live.

## Entry 11 — Review decisions applied

Three changes from the plain-English review:

1. **Submission is now per request.** The batch header button was replaced with a per-row
   action: **Submit** for writers (only while *In Progress*) and **Send to BBMR** for
   approvers (while *In Progress* or *Agency Review*). Each opens a confirmation naming
   that specific request and calls `set_cls_status()` on that one row.
   Verified live: advancing one request left the other at *In Progress*.
2. **BBMR reviewers can edit agency requests again** — `can_edit_cls_requests()` includes
   `BBMRReviewer` once more (this reverses Entry 10's read-only decision, per the user's
   final call). Their back link still returns to CLS Review, now keyed off agency roles
   rather than edit permission.
3. **Equipment labels corrected** to `Minor Equipment (<$5k)` / `Major Equipment (>$5k)`
   — the source list had the comparisons reversed.

**Status:** ✅ verified live; committed.

## Entry 12 — Making incomplete requests impossible to miss

Six items from the last review pass.

1. **Red row + badge on the list page.** A new helper `cls_request_gaps(db, row)` returns
   which required pieces a request is still missing (name, type, summary, FY28 amount, or a
   breakdown that doesn't add up to the amount). Rows with gaps get
   `.cls-request-row-missing` — a pink fill and a 3px red left edge — and the name carries a
   solid-red **MISSING INFO** pill. The tooltip reads *"This request has missing
   information. Still needed: …"* and lists the actual gaps, and the badge is
   keyboard-focusable so the tooltip isn't mouse-only.
2. **The balance banner is properly red when out of balance.** `.cls-remaining-over`
   already applied in both directions (under- and over-described); it now renders as a red
   panel with a red border, a heavy red left edge, bold dark-red text and a ⚠ marker,
   instead of the near-invisible tint it had. The ⚠ is a CSS `::before` on
   `.cls-remaining-text` so it survives the JS rewriting the text on every keystroke.
3. **"You have missing fields."** Clicking back from an unfinished request alerts that;
   a complete one still says *"This request has been justified."*
4. **Reviewers can't wander into the agency list.** The back destination is no longer
   inferred from roles alone. `cls_detail_origin` records the page the request was opened
   from and `page_cls_request_detail()` takes it as `origin_page`: anyone arriving from CLS
   Review returns to CLS Review, even if they also hold an agency role. Verified across six
   role/origin combinations.
5. **Info panels collapse.** Re-verified after the two earlier fixes (computed-style read,
   id lookup scoped to the owning field): four clicks on each icon give
   none → block → none → block → none, with four copies of the same id in the document.
6. **All eight review fields on one line.** `.cls-rv-submitted` moved from eight equal
   columns to weighted ones (Service widest, the money columns narrowest), so **Positions**
   no longer wraps. Below 1120px the type shrinks rather than wrapping; the four-column
   fallback now waits until 820px. `cls_detail_field()` adds a `title` so the few values
   that do get truncated are still readable on hover.

**Verified live** against the running stack: `cls_request_gaps()` flags exactly one of
seven seeded requests; the rendered list page carries one `.cls-request-row-missing`
of three rows; the back-link matrix resolves correctly for BBMR-only, BBMR+SystemAdmin,
BBMR+Writer and Writer-only, from both origins. Browser-tested on the real rendered pages:
the banner reads *"The total request needs to explain $185,000.00"* in red, both alerts
fire on the right requests, both dropdown types toggle closed, and all eight review fields
measure to a single line at 900px and above with nothing clipped.

**Status:** ✅ built and verified live; not yet committed.
