# CLS Requests — Build Notes

A short description of what was built for the **CLS (Current Level of Service) request**
feature and how it fits the app. For the full running account see
[`cls-requests-build-log.md`](cls-requests-build-log.md); for the reference see
[`cls-requests.md`](cls-requests.md).

## What it is

The agency-facing side of the CLS budget-request workflow: agency writers enter requests,
break them out by expenditure object, add any position requests, and submit them to their
Agency Approver. Built to the BBMR target schema (Group 5 — Budget Proposal).

## What was built

**Data (Postgres, `R/database.R`).** Three tables — `budget.cls_request`,
`budget.cls_request_line`, `budget.cls_request_position` — created automatically at
startup (`ensure_review_schema`), loaded in `load_app_data`, with create / update /
delete helpers. Deletes remove child rows in a transaction (independent of the FK
cascade). `update_cls_request` can also move a request between services.

**List page (`page_cls_requests`).** One white card titled *"{Agency} Requests"* with the
BBMR guidance subtext. A sortable table (request name / service / amount, amounts shown as
`$K`/`$M`), a **Modify →** action per row, an orange **Submit for approval** button (opens
a confirmation naming the Agency Submitter; the email hook is wired but disabled), and
**Excel** / **PDF** exports below the table.

**Request page (`page_cls_request_detail`).** One page, three parts:

- *Summary* — request name (first, wide), service dropdown, request type with an info
  icon explaining every adjustment type, Request / FY29 / FY30 amounts (one-time hides &
  clears the out-years), and a mandatory 300-word "Summarize the request" field.
- *Request details* — a remaining-$ note plus **Add Details** to add one line per
  expenditure object.
- *Position requests* — hidden until "Add positions to this request" is checked.

Client behaviors (`www/app.js`): live word count with a red over-limit warning, one-time
show/hide + clear, live remaining-$ math, red highlighting of empty required fields, the
request-type info disclosure, the positions toggle, and a "This request has been
justified" confirmation when a complete request returns to the list.

**Exports.** Excel (`writexl`) writes three worksheets — Request summary, Line items,
Personnel. PDF (`reportlab`, `scripts/build_cls_pdf.py`) renders every request with its
full detail.

**Access.** Viewers can view; writers/approvers/submitters (and SystemAdmin) can edit.
Enforced server-side in `page_ui` and on every mutation, and reflected in the nav.

## Verification

The data layer and both exports were exercised **live** against the seeded database
(create, update incl. service change, add line/position, delete cascade, Excel 3-sheet,
PDF). `app.R` sources cleanly. The authenticated UI was not click-tested (sign-in
required) — it was verified statically and via rendered previews.

## Workflow and review (later additions)

The full chain is now in place. Each request carries a **status** — In Progress → Agency
Review (writer submits) → BBMR Review (approver sends) → **Approved / Partially Approved /
Denied** (BBMR decides) — shown as a sortable, colour-coded column. The legacy `completed`
flag is kept in sync automatically.

**CLS Review** is a BBMR-only page: metric cards, a bar chart of requested dollars by
agency with tooltips, multi-select status/agency filters, and per-request review fields
(evaluation score, analyst notes, analyst approval, BBMR approval). Those live in a
separate `budget.cls_review` table, so the agency's submitted data is never overwritten.
BBMR reviewers can open a request but see it **read-only**.

## Open items

Batch (rather than per-request) submission; the submitter email hook is present but
disabled; the deadline text is generic pending a cycle date. See the notes section of
`cls-requests.md`.
