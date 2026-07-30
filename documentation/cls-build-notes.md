# CLS Requests — Build Notes

Detailed notes on **how the CLS pages were built** — the structure of each page, the
decisions behind it, and the traps hit along the way. Written for whoever maintains this
next.

Companion documents:

- [`cls-code-guide.pdf`](cls-code-guide.pdf) — the same material as a shareable PDF
- [`cls-requests.md`](cls-requests.md) — field-level reference and data model
- [`cls-requests-build-log.md`](cls-requests-build-log.md) — chronological log of each round
- [`cls-change-log-notes.md`](cls-change-log-notes.md) — every change request, condensed
- [`cls-ucd-notes.md`](cls-ucd-notes.md) — design rationale
- [`cls-instructions.pdf`](cls-instructions.pdf) — end-user guide, by role

---

## 1. Where the code lives

Beacon is a single-file Shiny app, so the CLS feature is spread across five files by
concern rather than by feature:

| File | CLS contribution |
|------|------------------|
| `R/database.R` | schema migration, loader queries, all write helpers, the shared vocabularies |
| `app.R` | role predicates, three page functions, export builders, routing, nav, all observers |
| `www/app.js` | request-page controller, sorting, collapsible rows, `data-cls-*` handlers |
| `www/styles.css` | everything under the `.cls-` prefix, plus two nav-visibility body classes |
| `scripts/build_cls_pdf.py` | the PDF export renderer |

`app.R` sources both R files with `local = TRUE` at the top, so helpers defined in
`database.R` (including constants like `cls_object_choices`) are visible everywhere.

## 2. The app's data pattern, and how CLS fits it

Beacon loads the whole database into memory as a named list of data frames
(`load_app_data()`), renders pages from that list, and calls `refresh_app_data()` after
any write. CLS follows this exactly rather than introducing per-page queries:

```
user action → observeEvent → write helper (parameterised SQL) → refresh_app_data() → re-render
```

The single deliberate exception is **autosave**, which skips the refresh — see §6.

## 3. Schema migration: written to run against live databases

All four tables are created inside `ensure_review_schema()`, called once per session
start. Every statement is re-runnable (`CREATE TABLE IF NOT EXISTS`,
`ADD COLUMN IF NOT EXISTS`, a guarded `UPDATE` for the status backfill), so an existing
database picks the feature up with no manual migration step.

Two problems surfaced only when running against a real database, and both are worth
remembering because they will recur:

**`IF NOT EXISTS` does not fix an existing column's type.** `modified_by` already existed
as `integer` on a dev database from an earlier iteration, so a `text` COALESCE failed at
prepare time. Fixed by coercing explicitly:

```r
ALTER TABLE budget.cls_request ALTER COLUMN modified_by TYPE text USING modified_by::text
```

**`IF NOT EXISTS` does not add a missing cascade.** The child tables are declared with
`ON DELETE CASCADE`, but tables created by an earlier version lacked it
(`pg_constraint.confdeltype = 'a'`), so deleting a request with line items failed on a
foreign key. Rather than trying to rewrite constraints, `delete_cls_request()` removes
children explicitly inside a transaction — correct regardless of how the table was
created:

```r
DBI::dbWithTransaction(connection, {
  DELETE FROM budget.cls_request_line     WHERE cls_id = $1
  DELETE FROM budget.cls_request_position WHERE cls_id = $1
  DELETE FROM budget.cls_review           WHERE cls_id = $1
  DELETE FROM budget.cls_request          WHERE cls_id = $1
})
```

**Status vs. `completed`.** The target schema specifies a boolean `completed`. The UI needs
six states, so a `status` column was added and `completed` is maintained as a derived
value (`cls_status_is_complete()`), keeping the schema field meaningful without making it
the thing users see. Both columns are written together in the same statement so they can
never drift.

## 4. Page 1 — `page_cls_requests()`

Structure: a single `surface()` card titled `"{Agency} Requests"`, with `Add CLS Request`
in the header, the table, and the export bar beneath it.

- **Scoping.** `cls_requests_for_plan()` filters the loaded requests to the agency's
  current plan. Requests reach the plan through
  `cls_request.plan_service_id → performance.plan_service.plan_id`, which the loader query
  resolves so the page never has to join in R.
- **Sorting is client-side.** Header cells are `<button data-cls-sort="...">` and each row
  carries `data-sort-name`, `-service`, `-amount`, `-status`. The JS reorders DOM nodes, so
  sorting costs no server round-trip and cannot disturb in-flight edits. Numeric sorting
  reads the raw amount from the attribute, not the formatted `$1.4M` text.
- **The row action is computed, not just styled.** Approvers get *Send to BBMR*, writers
  get *Submit*, and only when the current status makes that transition valid. This was
  originally a single batch button in the card header; it moved per-row when submission
  became one-at-a-time, which also removed the need for the `only_from` guard in the common
  path (the guard is retained for bulk use).
- **Formatting helpers.** `cls_format_km()` for `$X.XK` / `$X.XM`; `cls_status_tone()` maps
  a status to an existing chip tone so no new colour vocabulary was introduced.

## 5. Page 2 — `page_cls_request_detail()`

One function, three modes, chosen from whether an id was supplied and what the user may do:

| Mode | Condition | Renders |
|------|-----------|---------|
| new | `is.na(cls_id)` | empty form + **Create request** |
| edit | id present, `can_edit` | prefilled form, autosaving, **no Save button** |
| read-only | id present, no edit right | values as text, no add-forms |

Three stacked sections, on a slightly darker shell (`cls-detail-shell`) so drilling in
reads as a change of level:

**Summary.** Field order was iterated several times and now runs: request name (full
width, first) → service → request type → request duration → the three fiscal-year amounts
→ the narrative. Labels needing explanation are emitted by a small local helper:

```r
cls_labelled_info(label, panel, id)  # label + info button + hidden panel
```

It renders the panel *after* the input in the DOM so the reference table opens **below**
the field rather than pushing the field down. This replaced an earlier `<details>` element
whose disclosure text ("What do these request types mean?") the review asked to remove —
and which, once the label moved inside `<summary>`, made the icon disappear entirely. The
lesson: keep the label a plain label and the icon a separate button beside it.

**The balance banner.** Computed server-side as
`request_amount − (line_total + position_total)` and re-computed live in JS as the user
types. It sits *above* the "Request details" heading, because it is a statement about the
whole request rather than about the table beneath it. Three states — needs to explain,
fully described (green), exceeds (red).

**Request details.** Add-form above the table (deliberate: the common action is adding,
and burying it under a growing table pushes it off-screen). Object is a dropdown from
`cls_object_choices`; justification is a single-line input by request.

**Position requests.** Rendered but hidden behind a checkbox, off unless positions already
exist. Unchecking clears the entry fields, so an abandoned half-entry is not silently kept.

Rows carry `data-cls-line-amount` / `data-cls-position-amount` purely so the client can
total them for the banner without re-querying.

## 6. Autosave

Typing in the summary section schedules a debounced (~0.9s) `cls_autosave` event. The
observer writes through `update_cls_request()`, stamps `modified_by` with the current user,
and records the time in `cls_last_save()` which feeds the indicator on the back-link row
(hover shows who saved).

**It deliberately does not call `refresh_app_data()`.** Doing so re-renders the page and
would move the cursor mid-sentence. The list picks up autosaved changes instead when the
user navigates away, via a check in the `input$current_page` observer:

```r
if (identical(current_page(), "cls_request_detail") &&
    !identical(input$current_page, "cls_request_detail")) refresh_app_data()
```

New requests still use an explicit **Create request** — there is nothing to autosave into
until the row exists.

## 7. Page 3 — `page_cls_review()` (BBMR only)

- `cls_review_rows()` flattens every request across every agency into one frame: agency
  label, line/position rollups, and review fields joined on. It tolerates a missing
  `status` column and a missing review row, so it works against a database mid-migration.
- `cls_review_chart()` emits an **inline SVG** bar chart. No plotting library was added:
  tooltips are native `<title>` elements, which work without JavaScript and are exposed to
  assistive tech. (An earlier version used `aggregate()` with a formula referencing a
  different data frame than `data=` — a real bug, caught in review before it ran. It now
  uses `tapply()`.)
- Requests render as a compact table whose rows are `<button data-cls-rv-toggle>` with a
  collapsed detail panel beneath — chosen over cards so many requests can be scanned at
  once, with full detail on demand.
- **Filters are not live.** Applied values live in `cls_applied_status` /
  `cls_applied_agency` reactives that only change when *Apply filters* is pressed; *Reset*
  clears them and pushes the full choice lists back with `updateSelectInput()`. This was an
  explicit request and it also avoids re-rendering a long table on every keystroke.
- **Analyst vs. BBMR approval.** Analyst approval is advisory and touches nothing else.
  BBMR approval is the decision: `save_cls_review()` maps Approved / Partial / Denied onto
  the request's status. The UI labels both so the difference is visible, not just
  documented.
- Review data lives in its own `budget.cls_review` table, 1:1 with the request. The
  agency's submission is never overwritten — verified explicitly in testing by re-reading
  the request row after saving a review.

## 8. Server wiring

Every action is an `observeEvent` on an `input$cls_*` value, all following one shape:

```r
observeEvent(input$cls_delete, {
  if (!cls_guard_edit()) return()                 # permission
  cls_id <- suppressWarnings(as.integer(...))     # coerce
  if (is.na(cls_id)) return()                     # validate
  result <- tryCatch(delete_cls_request(database, cls_id), error = function(e) e)
  if (inherits(result, "error")) { showNotification(...); return() }
  refresh_app_data(); showNotification(...)
}, ignoreInit = TRUE)
```

**Permission is checked twice** — once in `page_ui()` (so an unauthorised page key is
rewritten before rendering) and again inside every mutating observer (so a forged event
cannot bypass a hidden control). Nav visibility is a third, cosmetic layer.

**Selection state.** `current_cls_id()` is the single source of truth for the detail page;
`NA` means "new". `cls_pending_submit()` holds the id *and* mode behind a confirmation
dialog, so the confirm handler acts on exactly the request that was clicked rather than
whatever is currently selected.

## 9. Client behaviour (`www/app.js`)

One delegated `click` listener handles all `data-cls-*` attributes and forwards to Shiny
with `setInputValue(..., {priority: "event"})`. Each payload carries a nonce so repeating
an identical action still fires. Destructive actions confirm first.

| Function | Responsibility |
|----------|----------------|
| `clsValidate()` | umbrella: word count, banner, red required fields |
| `clsUpdateWordCount()` | 150-word limit, exact overage in red |
| `clsUpdateRemaining()` | FY28 − (objects + positions); swaps banner state |
| `clsApplyOneTime()` / `…Label()` | hide + clear FY29/FY30; flip One-Time ⇄ Recurring |
| `clsApplyPositionsToggle()` | show/hide positions; clear fields when switched off |
| `clsSyncTitle()` | mirror the name into the heading and intro sentence live |
| `clsScheduleAutosave()` | debounce the autosave event, show "Saving…" |
| `clsRequestIsComplete()` | gate for the "request has been justified" confirmation |

**Re-initialisation is essential.** Shiny replaces the page's DOM on every render, so
`clsInitPage()` re-runs on the `shiny:value` event to reapply toggles and validation to the
new nodes. Anything that sets initial UI state must be idempotent and hooked there.

## 10. Exports

- **Excel** — `cls_export_sheets()` returns a named list of three data frames and
  `writexl::write_xlsx()` writes one worksheet each. Amounts stay numeric so Excel can
  total them. `writexl` was chosen over `openxlsx` for having no system dependencies.
  (It originally produced one sheet with three stacked tables; per review it became one
  sheet per table, which is also simpler code.)
- **PDF** — `cls_export_payload()` builds nested JSON, and `scripts/build_cls_pdf.py`
  renders it with reportlab through the existing `PLAN_EXPORT_PYTHON` virtualenv, reusing
  the plan-export pattern. The R side treats a missing or zero-byte output as an error
  rather than serving a broken download.

## 11. Conventions to preserve

- Check permission at render **and** at mutation.
- Parameterise all SQL; never interpolate user input.
- Keep vocabularies (types, objects, statuses) in `R/database.R` as single sources of
  truth, read by the UI — a label then changes in exactly one place.
- Keep client-side work to presentation and validation; the database stays authoritative.
- Write migrations defensively: they run against databases that already exist.
- Prefer existing helpers (`surface()`, `status_chip()`, `metric_tile()`, `app-table`) over
  new markup, so CLS pages inherit the app's look automatically.

## 12. Known gaps

- **"Estimated Cost" is a link with no destination** — wired to a placeholder handler,
  awaiting the salary/benefit cost reference.
- The **submitter email** hook exists but is switched off
  (`notify_agency_submitter_of_cls <- FALSE`).
- The **deadline** in the reminder is generic text, not a real cycle date.
- `evaluation_score` remains in `cls_review` but is no longer collected; saves preserve any
  stored value rather than nulling it.
- The instructions PDF uses **schematic figures**, not screenshots (the screens are behind
  a login).
- **The authenticated UI has not been click-tested by a human.** Verification covered the
  data layer live, server-side page rendering, and client behaviour in a browser harness.
