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

## Round 8 — first round analyst feedback

Commits `a566cee`, `02c0720`, `b08ac7f`. Budget Planning stayed SystemAdmin-only
throughout.

| # | Note | Status |
|---|------|--------|
| 88 | Pen icon on every object/position row opens an inline editor with Save / Cancel | ✅ |
| 89 | "Create a spend category" free text becomes a **Create Spend Category** dropdown option | ✅ prompts for a description beside Justification |
| 90 | Drop the "Create request" button — a request is created by its first autosave | ✅ superseded in round 9 |
| 91 | Nothing is added to either table until every field is filled | ✅ buttons disabled + server check |
| 92 | Block leaving the page while a mandatory summary field is empty, naming the fields | ✅ |
| 93 | Once a request reaches BBMR it is view-only for the agency; BBMR opens it view-only too | ✅ reverses #66 |
| 94 | Missing-info badge reads **NOT DETAILED** | ✅ |
| 95 | Agency-wide cards and a bar chart, broken out by service rather than agency | ✅ reuses `cls_review_chart(group_col=)` |
| 96 | "Add CLS Request" in its own full-width bar under the notice | ✅ |
| 97 | Rewrite the notice: initiative/project summary, named Submitters, Sept 15 COB deadline | ✅ |
| 98 | Nobody can send a request on while anything is missing; the dialog lists what | ✅ |
| 99 | Submitters can send any request to BBMR, submitted by a writer or not | ✅ |
| 100 | Sending to BBMR needs a named attestation | ✅ "I, {name}, have reviewed this request…" |
| 101 | Rolled-up review table: Agency, Service, unrounded FY28, Positions, Status | ✅ |
| 102 | Filters apply live — drop the Apply step that made them look broken | ✅ revisited in round 11 |
| 103 | The expanded panel stops repeating the collapsed row | ✅ summary, Type + definition, Duration, FY28–FY30 |
| 104 | Analyst block in a contrasting panel; "Analyst recommendation"; red warning on BBMR approval | ✅ |
| 105 | Approved FY28 / Approved positions for Approved (prefilled) and Partial (blank) | ✅ new `approved_amount` / `approved_positions` |
| 106 | Bulk Approve over the filtered set | ✅ reworked in round 10 |
| 107 | Group **everything** by agency, never by entity; Mayoralty entities show together | ✅ parent from `plan_entity.parent_agency_id` |
| 108 | A request that reached BBMR can no longer be deleted | ✅ lock icon + server refusal |
| 109 | Collapsible chart; the request title on its own line | ✅ |

## Round 9 — editable on entry, checkbox filters

Commit `55b36f2`.

| # | Note | Status |
|---|------|--------|
| 110 | On a new request, Request details and Position requests stayed empty after name + service | ✅ the draft row is now created when "Add CLS Request" is clicked |
| 111 | Make every field editable as soon as the request is opened | ✅ |
| 112 | A sent request stays uneditable | ✅ re-verified |
| 113 | The autosave indicator was pushed off the page | ✅ top bar wraps, indicator pinned right |
| 114 | Back from a request opened via CLS Review returns to CLS Review — for SystemAdmins too | ✅ "where Back goes" split from "is it read-only" |
| 115 | Replace the review multi-selects with check-multiple dropdowns | ✅ Select all / Clear + summary |
| 116 | Only allow a line or position to be added when every field is filled | ✅ |

## Round 10 — bulk approve as an inline mode

Commit `cf87ed9`.

| # | Note | Status |
|---|------|--------|
| 117 | Bulk Approve should only be on CLS Review | ✅ it always was — the section heading said "Review requests", which now reads "Bulk approve" |
| 118 | Bulk mode hides the collapsible request table | ✅ replaced, not overlaid |
| 119 | Show Agency, Service, Request, FY28, FY29, FY30, Duration, Positions | ✅ revised in round 11 |
| 120 | Keep it inside the screen, one row per request | ✅ measured at 1280px and 845px, no wrap, no sideways scroll |
| 121 | A Save button that exits bulk approval | ✅ "Save and close" / "Cancel" |

## Round 11 — notes for 7/31

Second round of analyst feedback.

| # | Note | Status |
|---|------|--------|
| 122 | No popup on leaving a request that is already justified | ✅ silent; the alert only fires when something is missing |
| 123 | A recurring request must have FY29 **and** FY30 amounts before it can be left or sent | ✅ enforced in the browser and in `cls_request_gaps()` |
| 124 | Thinner bars and much smaller text on the bar chart | ✅ 24px → 13px bars, 11px → 8.5px labels |
| 125 | On a partial approval, only the **approved** amount is yellow | ✅ the shortfall shows as a separate "Not approved" segment |
| 126 | Bulk approval: drop FY29 and FY30, add Request type | ✅ 11 columns → 10 |
| 127 | Let me tick every status filter before the table reloads | ✅ ticks are held locally and pushed once, on Apply or on close |
| 128 | Narrower Status and Agency filter fields | ✅ and all four controls now sit on one row — only three columns were declared before, so Service and Reset wrapped |
| 129 | Add Created date, Created by email, Modified date, Modified by email to both Excel exports | ✅ new `created_by` column on `budget.cls_request` |
| 130 | Give every status its own colour | ✅ six distinct chips; amber was doing duty for two states |
| 131 | Narrower Request name column; long names wrap to two lines | ✅ clamped at two lines, full name on hover |
| 132 | Number inputs: no decimals, thousands separators | ✅ custom Shiny input binding — a native number input cannot show a comma |
| 133 | Summarize-the-request subtext → "Provide a short explanation of the request for review." | ✅ |
| 134 | Justification subtext → "Explain the proposed amount." | ✅ both the field and the section copy |
| 135 | Position count must not default to 1; label it "Position Count" | ✅ starts empty |
| 136 | Put the agency in the export file name | ✅ `cls-requests-<agency>-<date>`; the review workbook names the agency when the filter is down to one |
| 137 | Pages sometimes turn grey when clicking between them | ⚠ **could not reproduce** — a leftover modal backdrop is the likeliest cause and is now cleared on every navigation. See the build log. |
| 138 | Commas in the Total requested card | ✅ `$2,837,000` rather than `$2.8M` |
| 139 | Name the Submitter and the Budget Analyst under the Agency Requests subtext | ✅ and the submitter lookup now resolves through entity access — 103 of 104 submitter roles carry no `agency_id`, so the old lookup named almost nobody |
| 140 | The request-page notice should name every Agency Submitter in the agency | ✅ same lookup |
| 141 | Load `agency_budget_analyst_seed.csv` | ✅ 55 of 57 agencies now have an analyst — and fixed the seed guard that had made this impossible (see below) |

**The analyst seed could never have run.** `apply_agency_budget_analyst_seed_once()`
recorded the seed as applied *whether or not it did anything*. The CSV was not in the
Docker image on the day it first ran, so `apply_agency_budget_analyst_seed()` returned
early on `!file.exists(path)`, wrote nothing, and was marked done anyway — permanently.
Shipping the CSV later could not help, because the marker already said "applied". The
wrapper now marks the seed only when it actually ran, and treats an entirely empty
`budget_analyst` column as proof that a recorded run never happened, so it self-heals.
Verified: the seed applied 55 rows, and a second run correctly short-circuits.

## Outstanding

- **#79 — the "Estimated Cost" link has no destination yet.** It is a live-looking
  hyperlink wired to a placeholder handler; point it at the salary/benefit cost
  reference when that exists.
- **The spend-category list is invented.** The ten `SC6xxx` values in
  `cls_spend_category_choices` are placeholders. They need replacing with the real
  chart of accounts before agencies see the pages — the main reason Budget Planning
  is still SystemAdmin-only.
- **#137 — the grey page.** Not reproduced, so the fix is a mitigation rather than a
  confirmed cure. If it recurs, note whether the page is *dimmed but usable*
  (Shiny recalculating) or *dimmed and unclickable* (a modal backdrop), and whether
  the browser console shows a disconnect.
- **Two agencies have no budget analyst.** The seed CSV covers 55 of 57 active agencies;
  **AGC7000 Transportation** and **AGC9900 CAFR Adjustments** are absent from it and read
  "Unassigned". Transportation looks like a real omission worth filling in.
- The **submitter email** (#24) is deliberately switched off.
- The **deadline** in the reminder text is generic; wire it to the plan cycle when a
  real date is available.
- The instructions PDF uses **diagrams rather than screenshots** (screens are behind a
  login).
- Nobody has yet **click-tested the live, logged-in app** — see the build log. All
  verification to date is server-side rendering plus browser measurement of those
  renders.

## Round 12 — open CLS to BBMR's analysts

| # | Note | Status |
|---|------|--------|
| 142 | Branch protection on `main` | ✅ PRs required, `test` check required, 0 approvals, admins exempt, force-push and deletion blocked |
| 143 | Commas missing on the chart, the requests list and the review page | ✅ `cls_format_km()` deleted outright — every CLS surface now shows separated whole dollars |
| 144 | Don't create a request if the user never gives it a name or an amount and leaves | ✅ `discard_empty_cls_draft()`, on navigate-away and on session end |
| 145 | A **Return** button on Bulk approval that unlocks the request for agencies | ✅ sets status to *In Progress* and clears the decision; analyst notes are kept |
| 146 | Total requested is broken — make it the sum of all requests | ✅ the CLS Review card counted only sent-to-BBMR requests; both totals now count every request |
| 147 | Open the CLS pages to BBMR review roles | ✅ `can_access_budget_planning()` admits **BBMRReviewer** + SystemAdmin. Agencies still excluded |

**The 14 BBMR reviewers now with access** — all active, none agency-scoped, so each sees
every agency: Devlin Tricamo-Palmer, Eric Duneman, Gabriel Stuart-Sikowitz, John Burklew,
Kamaria Harmon, Malachi Gaines, Mara James, Matthew Rappaport, Matthew Zachary, Michael
Brede, Robert Feehley, Stephanie Hentemann, Sumaiya Binta Islam, Zachary Harris.

Several are also the named budget analysts in `agency_budget_analyst_seed.csv`, which is
the expected overlap — the BBMRReviewer role *is* the analyst roster.

**What BBMR reviewers get:** the **CLS Review** page and the **individual request page**
(read-only, per round 8). They deliberately do **not** get the agency-facing CLS Requests
list — `can_view_cls_requests()` excludes them and `page_ui()` redirects them to CLS
Review, which was the round-8 decision that reviewers should not wander into an agency's
list. Say so if that should change.

**Why `cls_format_km()` went entirely** rather than being kept for the chart: the whole
point of the request was that a rounded "$2.3M" hides the figure being checked, and that is
as true in a chart label as in a table cell. The chart's right gutter grew from 74px to
112px to fit a full figure, and the bulk grid's FY28 column dropped its cents — always
".00" now that amounts are integers — to make room for the Return column.

## Round 13 — money formatting fix, and CLS for BBMR to test with

| # | Note | Status |
|---|------|--------|
| 148 | Amounts above $2.1bn rendered as **$NA** | ✅ `cls_format_commas()` used `formatC(format = "d")`, which coerces to a 32-bit integer. Now `format = "f", digits = 0` |
| 149 | BBMR reviewers should be able to **edit** requests on the test entities | ✅ read-only carve-out for test agencies only |
| 150 | …and **flip through** all the test entities | ✅ the agency switcher now offers them to reviewers, who previously had no entries at all |
| 151 | Add a section to CLS Review so all reviewers can see the Budget Planning section and its 2 pages | ✅ `cls_budget_planning_section()` |

**The $NA bug was not cosmetic.** Reported as "the application is down". The app was
serving normally; what was real was a log full of `NAs introduced by coercion to integer
range` and one figure rendering as `$NA`. Production held a request of $23,232,322,322 (a
test entry) which tripped it on every render. Baltimore's budget runs to billions, so the
citywide *Total requested* card — changed in round 12 to sum every request — would have
shown `$NA` as soon as real data arrived. 18 regression assertions now cover both sides of
the 32-bit boundary, and `cls_format_dollars()` was checked for the same class of bug and
is clean.

**Test agencies.** Production has three, one of each entity type:

| agency_id | Name | Type |
|---|---|---|
| `TST9001` | TEST Agency of Sparkly Sidewalks | Agency |
| `TST9002` | TEST Quasi Bureau of Waffle Forecasting | QuasiAgency |
| `TST9003` | TEST Mayor's Office of Tiny Triumphs | MayoraltyOffice |

There is **no `is_test` column**, so membership is derived from the naming convention — a
`TST` agency_id or a name starting `TEST` — in `cls_test_agency_ids()`. That one function is
the only place to change if it should become data-driven. It is covered by tests that
deliberately include near-misses ("Office of Protest and Testimony", "Contested Elections
Board", "Latest Initiatives Office", "Attestation Services") because a false positive would
silently hand reviewers edit rights over a real agency's submissions.

**What changed for reviewers, precisely:**

- `can_view_cls_requests()` now includes `BBMRReviewer`, so they get the agency-facing page.
  This reverses the round-8 decision that kept them out of it; their switcher offers only
  test agencies, so no real agency's list is put in front of them.
- The switcher previously gave reviewers **nothing** — `user_submitter_choices()` keys off
  agency/entity grants and `BBMRReviewer` rows carry none, so `current_submitter_value()`
  returned `""`. `cls_add_test_choices_for_reviewers()` adds the test agencies and their
  entities on top of whatever a user already has.
- On a test agency a reviewer may edit at **any** status, including a request already sent
  to BBMR. On a real agency they remain read-only, unchanged. A dashed amber banner marks
  the sandbox on the request page.
- `current_submitter_value()` and `current_user_submitter_choices()` had duplicated the same
  role-branching logic; the former now calls the latter, so the resolved value can never be
  something the visible dropdown does not offer.
- `reviewer_view` was deleted — it had had no readers since round 9.
