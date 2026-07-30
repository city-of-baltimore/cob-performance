# CLS Requests — condensed change notes

Every change requested during review, in short form, with where it landed and whether
it is done. Newest round last. Fuller narrative lives in
[`cls-requests-build-log.md`](cls-requests-build-log.md).

## Round 1 — first build

| # | Note | Status |
|---|------|--------|
| 1 | Page for Agency Viewers/Writers/Approvers with a create button | ✅ |
| 2 | Table of requests: name, short description, dollar value, delete | ✅ |
| 3 | Each request creates a `CLS_REQUEST`; details hold line items + positions | ✅ |
| 4 | Follow `Target_Database_Schema_BBMR.docx` | ✅ 3 tables built to spec |

## Round 2 — no pop-ups

| # | Note | Status |
|---|------|--------|
| 5 | Replace the create pop-up with an arrow into a full page | ✅ |
| 6 | Add line-item / personnel detail on that page | ✅ |
| 7 | Combine the entry page and the detail page into one | ✅ |

## Round 3 — formatting

| # | Note | Status |
|---|------|--------|
| 8 | Page 2 slightly darker than page 1 for contrast | ✅ `cls-detail-shell` |
| 9 | Button label → "Add CLS Request" | ✅ |
| 10 | Ellipsis on the summary column | ✅ (column later removed) |
| 11 | "Enter" → "Modify" | ✅ |
| 12 | Page-2 title = request name, one line | ✅ |
| 13 | Service dropdown field | ✅ persisted via `update_cls_request()` |
| 14 | Request amount + FY+2 + FY+3 on one line | ✅ |
| 15 | Append "Requests" to the agency header | ✅ |
| 16 | Sort by service or amount | ✅ (name/service/amount/status) |

## Round 4 — exports, page-1 rebuild, page-2 fields

| # | Note | Status |
|---|------|--------|
| 17 | Export as Excel / PDF | ✅ Excel (3 tabs) + PDF |
| 18 | Excel: one tab per table | ✅ Request summary / Line items / Personnel |
| 19 | Move exports below the table | ✅ |
| 20 | One white card; drop the "Agency CLS Requests" header | ✅ |
| 21 | Title = agency name + BBMR subtext | ✅ |
| 22 | Wider request-name column; amounts as $X.XK / $X.XM; drop summary | ✅ |
| 23 | Orange "Submit for approval" + pop-up naming the Agency Submitter | ✅ |
| 24 | Email the submitter — **disabled for now** | ✅ hook present, off |
| 25 | Merge header + request details into one summary box | ✅ |
| 26 | Higher-contrast, better-placed back button | ✅ pill, top-left |
| 27 | Request name first and much wider | ✅ |
| 28 | Service selector below it | ✅ |
| 29 | Request type + info icon with the adjustment-type table | ✅ all 8 types |
| 30 | Request/FY29/FY30 amounts; one-time hides & clears out-years | ✅ |
| 31 | "Summarize the request" with a word limit + red overflow warning | ✅ |
| 32 | "Request details" rename + subtext | ✅ |
| 33 | Remaining-amount validation line | ✅ live |
| 34 | Justification on its own single line | ✅ |
| 35 | Hide positions unless "Add positions" is selected | ✅ |
| 36 | Relabel position justification / explanation | ✅ |
| 37 | Wayfinding: "This request has been justified", red blanks, approver + date | ✅ |
| 38 | Three documents (instructions PDF, build notes, UCD notes) | ✅ |

## Round 5 — objects, autosave, polish

| # | Note | Status |
|---|------|--------|
| 39 | "Expenditure Object" → **Object**, as a dropdown of 9 objects | ✅ |
| 40 | Table header "Object Amount" → "Amount" | ✅ |
| 41 | Remove number spinner arrows | ✅ |
| 42 | Make the three long text boxes resizable | ✅ |
| 43 | Remove "(hides the FY29 and FY30 amounts)" | ✅ |
| 44 | "Select a service…" → "Service"; drop "($)"; first amount → FY28 | ✅ |
| 45 | Reword the remaining-amount line | ✅ (reworded again in round 7) |
| 46 | Autosave; drop the Save button; last-saved + user indicator | ✅ |
| 47 | Slightly smaller table text | ✅ |
| 48 | Keep positions hidden unless selected | ✅ |
| 49 | Move the save indicator up to the back-link row; hover shows the user | ✅ |

## Round 6 — status, approver hand-off, BBMR review

| # | Note | Status |
|---|------|--------|
| 50 | Smaller "Submit"/"Add CLS Request" buttons | ✅ |
| 51 | Replace the Complete true/false with a **Status** column | ✅ 6 states |
| 52 | Status flow: In Progress → Agency Review → BBMR Review → Approved/Denied/Partial | ✅ verified end to end |
| 53 | Info icon next to Request Type, no text | ✅ (re-fixed in round 7) |
| 54 | Confirm all request types appear | ✅ all 8 |
| 55 | Writer, Approver and BBMR can all edit requests | ✅ |
| 56 | Approver gets "Send for BBMR Review" → marks Complete | ✅ |
| 57 | New BBMR-only page named **CLS Review** | ✅ |
| 58 | Card: Pending Requests (all) | ✅ |
| 59 | Card: Requests for Review (complete only) + total $ + total positions | ✅ |
| 60 | A chart with tooltips | ✅ bar chart, hover |
| 61 | "Review requests" table + multi-select status and agency filters | ✅ |
| 62 | All request fields + new evaluation/notes/approval fields | ✅ |
| 63 | Retain submitted data while recording decisions | ✅ separate `cls_review` table |
| 64 | Link from CLS Review to the request page | ✅ "Open request" |

## Round 7 — latest round

| # | Note | Status |
|---|------|--------|
| 65 | Submit requests **one at a time** | ✅ per-row Submit / Send to BBMR |
| 66 | BBMR can edit an agency request | ✅ restored |
| 67 | Correct the equipment labels | ✅ Minor (<$5k) / Major (>$5k) |
| 68 | Clear the position form when "Add positions" is unselected | ✅ |
| 69 | Total must include line items **and** positions | ✅ verified |
| 70 | Move the total warning above the "Request details" header | ✅ |
| 71 | Reword: "The total request exceeds / needs to explain $… Reduce / Describe the request amount by object or positions." | ✅ |
| 72 | Reduce the summary word limit to 150 | ✅ |
| 73 | Default Position Requests to unselected | ✅ |
| 74 | Smaller, left-aligned, full-width request-name header | ✅ |
| 75 | Add "Describe the {Request name} by line item and any positions below…" | ✅ live-updates with the name |
| 76 | Restore the Request Type info icon beside the label; table opens below the field | ✅ |
| 77 | Move One-Time above the FY amounts; make it a toggle labelled One-Time / Recurring | ✅ |
| 78 | Add the recurring-vs-one-time info icon and copy | ✅ |
| 79 | "Estimated salary" → **Estimated Cost**, as a hyperlink for later linking | ✅ placeholder link — **still needs a destination** |
| 80 | Remove the subtext under the CLS Review cards | ✅ |
| 81 | Apply and Reset buttons for the filters | ✅ filters apply on click |
| 82 | Status filter lists every status | ✅ all 6 |
| 83 | Stronger separation between the cards/chart and the review table | ✅ shaded block + labelled divider |
| 84 | Make the review list look like a table: smaller text, collapsible details | ✅ |
| 85 | Remove evaluation score | ✅ removed from UI (stored values preserved) |
| 86 | Analyst approval must **not** drive status; BBMR approval must | ✅ labelled in the UI |
| 87 | "Open request" lets BBMR edit and jump into the request page | ✅ |

## Outstanding

- **#79 — the "Estimated Cost" link has no destination yet.** It is a live-looking
  hyperlink wired to a placeholder handler; point it at the salary/benefit cost
  reference when that exists.
- The **submitter email** (#24) is deliberately switched off.
- The **deadline** in the reminder text is generic; wire it to the plan cycle when a
  real date is available.
- The instructions PDF uses **diagrams rather than screenshots** (screens are behind a
  login).
- Nobody has yet **click-tested the live, logged-in app** — see the build log.
