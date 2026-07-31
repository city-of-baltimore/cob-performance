#!/usr/bin/env python3
"""Generate the CLS technical / code guide PDF.

Describes how the CLS feature is built: the data model, where each page is
constructed, the reactive wiring, the client-side behaviours, and the export
pipeline. Intended for a developer picking this up cold.
"""
import argparse

from reportlab.lib import colors
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import inch
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, HRFlowable,
    ListFlowable, ListItem, PageBreak,
)

BRAND = colors.HexColor("#2f1c3d")
MUTED = colors.HexColor("#526270")
LINE = colors.HexColor("#c4d1d9")
SUBTLE = colors.HexColor("#f3eef9")
CODEBG = colors.HexColor("#f4f6f8")
GREEN = colors.HexColor("#2f7d61")


def S():
    s = getSampleStyleSheet()
    s.add(ParagraphStyle("T", parent=s["Title"], textColor=BRAND, fontSize=21, spaceAfter=2, alignment=0))
    s.add(ParagraphStyle("Sub", parent=s["Normal"], textColor=MUTED, fontSize=10, spaceAfter=13))
    s.add(ParagraphStyle("H", parent=s["Heading2"], textColor=BRAND, fontSize=12.5, spaceBefore=13, spaceAfter=4))
    s.add(ParagraphStyle("H3", parent=s["Heading3"], textColor=BRAND, fontSize=10.3, spaceBefore=9, spaceAfter=3))
    s.add(ParagraphStyle("B", parent=s["Normal"], fontSize=9.6, leading=13.4, spaceAfter=5))
    s.add(ParagraphStyle("Small", parent=s["Normal"], fontSize=8.6, leading=11.8, textColor=MUTED))
    s.add(ParagraphStyle("Snippet", parent=s["Code"], fontSize=8.2, leading=11, textColor=colors.HexColor("#22303a")))
    s.add(ParagraphStyle("Cell", parent=s["Normal"], fontSize=8.5, leading=11.4))
    s.add(ParagraphStyle("CellH", parent=s["Normal"], fontSize=8.5, leading=11.4, textColor=colors.white))
    s.add(ParagraphStyle("Mono", parent=s["Normal"], fontName="Courier", fontSize=8.3, leading=11.4))
    return s


def table(rows, widths, styles):
    data = [[Paragraph(str(c), styles["CellH" if i == 0 else "Cell"]) for c in row] for i, row in enumerate(rows)]
    t = Table(data, colWidths=widths, repeatRows=1)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), BRAND),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, SUBTLE]),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("GRID", (0, 0), (-1, -1), 0.5, LINE),
        ("LEFTPADDING", (0, 0), (-1, -1), 5), ("RIGHTPADDING", (0, 0), (-1, -1), 5),
        ("TOPPADDING", (0, 0), (-1, -1), 4), ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]))
    return t


def code(lines, styles, width):
    body = [[Paragraph(l.replace(" ", "&nbsp;"), styles["Mono"])] for l in lines]
    t = Table(body, colWidths=[width])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), CODEBG),
        ("BOX", (0, 0), (-1, -1), 0.5, LINE),
        ("LEFTPADDING", (0, 0), (-1, -1), 8), ("RIGHTPADDING", (0, 0), (-1, -1), 8),
        ("TOPPADDING", (0, 0), (-1, -1), 2), ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
    ]))
    return t


def bullets(items, styles):
    return ListFlowable([ListItem(Paragraph(s, styles["B"])) for s in items], bulletType="bullet", leftIndent=14)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    st = S()
    W = 6.9 * inch
    story = []

    story.append(Paragraph("CLS Requests — Technical Guide", st["T"]))
    story.append(Paragraph("How the CLS feature is built &bull; Beacon Performance &amp; Budgeting "
                           "(R Shiny + Postgres)", st["Sub"]))
    story.append(HRFlowable(width="100%", thickness=2, color=BRAND))

    # ---- Orientation ----
    story.append(Paragraph("Orientation", st["H"]))
    story.append(Paragraph(
        "Beacon is a single-file R Shiny application. <b>app.R</b> holds the UI, every page-building function and the "
        "server; <b>R/database.R</b> holds all SQL, the startup migration and the data loader; <b>R/auth.R</b> holds "
        "authentication. Client behaviour lives in <b>www/app.js</b> and styling in <b>www/styles.css</b>. Both R files "
        "are pulled in with <font face='Courier'>source(..., local = TRUE)</font> at the top of app.R, so anything "
        "defined in them is visible app-wide.", st["B"]))
    story.append(Paragraph(
        "The app follows a load-everything-then-render model: <font face='Courier'>load_app_data()</font> reads the "
        "database into a named list of data frames, pages read from that list, and any write is followed by "
        "<font face='Courier'>refresh_app_data()</font>. The CLS feature plugs into that cycle rather than inventing "
        "its own persistence path.", st["B"]))

    story.append(Paragraph("Files touched", st["H"]))
    story.append(table([
        ["File", "What the CLS work added"],
        ["R/database.R", "Four tables in the startup migration, four loader queries, the write helpers, and the "
                         "request-type / object / status vocabularies."],
        ["app.R", "Role helpers, three page functions, the export builders, routing, nav entries and all "
                  "<font face='Courier'>input$cls_*</font> observers."],
        ["www/app.js", "The request-page controller (validation, toggles, autosave trigger), table sorting, "
                       "collapsible review rows and the <font face='Courier'>data-cls-*</font> click handlers."],
        ["www/styles.css", "Everything under the <font face='Courier'>.cls-</font> prefix plus two nav-visibility "
                           "body classes."],
        ["scripts/build_cls_pdf.py", "The PDF export renderer (reportlab)."],
        ["Dockerfile", "<font face='Courier'>writexl</font> for the Excel export; copies the CLS PDF script."],
    ], [1.55 * inch, 5.35 * inch], st))

    # ---- Data model ----
    story.append(Paragraph("Data model", st["H"]))
    story.append(Paragraph(
        "Four tables in the Postgres <font face='Courier'>budget</font> schema. The first three are the BBMR target "
        "schema's CLS_REQUEST / CLS_REQUEST_LINE / CLS_REQUEST_POSITION translated to Postgres types; "
        "<font face='Courier'>cls_review</font> is additive and holds BBMR's decision so the agency's submission is "
        "never overwritten. The canonical DDL is <font face='Courier'>database/schema/target_schema.sql</font>; "
        "<font face='Courier'>ensure_review_schema()</font> migrates existing databases to match. <b>Both must be "
        "changed together</b> &mdash; <font face='Courier'>CREATE TABLE IF NOT EXISTS</font> never alters an existing "
        "table, and CI builds from the canonical schema alone. Three CI failures on this feature were exactly this "
        "mistake.", st["B"]))
    story.append(table([
        ["Table", "Key columns", "Notes"],
        ["budget.cls_request", "cls_id PK, plan_service_id FK, request_name, request_type, request_amount, one_time, "
                               "overall_summary, <b>status</b>, amount_next_fy, amount_2next_fy, <b>created_by</b>, "
                               "modified_by",
         "One row per request. <b>status</b> replaced the target schema's completed BIT (six states, not two); "
         "<b>justified</b> was dropped. created_by / modified_by are user_id FKs."],
        ["budget.cls_request_line", "line_id PK, cls_id FK, object_category, <b>spend_category</b>, amount, "
                                    "justification, sort_order",
         "One row per expenditure object."],
        ["budget.cls_request_position", "pos_id PK, cls_id FK, classification, position_count, estimated_salary, "
                                        "justification, explanation", "One row per position request."],
        ["budget.cls_review", "review_id PK, cls_id FK UNIQUE, analyst_notes, analyst_approval, bbmr_approval, "
                              "<b>approved_amount</b>, <b>approved_positions</b>, reviewed_by",
         "One review per request; additive by design. evaluation_score was dropped."],
    ], [1.5 * inch, 3.1 * inch, 2.3 * inch], st))

    story.append(Paragraph("Migration strategy", st["H3"]))
    story.append(Paragraph(
        "Everything is created inside <font face='Courier'>ensure_review_schema()</font>, which app.R calls once per "
        "session start. Statements are written to be safely re-runnable &mdash; "
        "<font face='Courier'>CREATE TABLE IF NOT EXISTS</font>, <font face='Courier'>ADD COLUMN IF NOT EXISTS</font>, "
        "and a guarded backfill &mdash; so an existing database picks up the feature with no manual step. Two hazards "
        "were handled explicitly:", st["B"]))
    story.append(bullets([
        "<b>Columns that already existed with the wrong type.</b> <font face='Courier'>modified_by</font> existed as "
        "<font face='Courier'>integer</font> on a development database, which broke a text COALESCE. The migration "
        "coerces it: <font face='Courier'>ALTER COLUMN modified_by TYPE text USING modified_by::text</font>.",
        "<b>Cascades that only exist on fresh tables.</b> <font face='Courier'>IF NOT EXISTS</font> never adds a "
        "missing <font face='Courier'>ON DELETE CASCADE</font>, so on older databases deleting a request failed on a "
        "foreign key. <font face='Courier'>delete_cls_request()</font> therefore deletes lines, positions and the "
        "review row itself inside a transaction rather than relying on the constraint.",
    ], st))

    story.append(Paragraph("Status is the state machine", st["H3"]))
    story.append(Paragraph(
        "<font face='Courier'>status</font> drives the workflow and the UI; the target schema's boolean "
        "<font face='Courier'>completed</font> is kept in sync as a derived value so it stays meaningful for anything "
        "downstream that expects it.", st["B"]))
    story.append(code([
        "cls_status_choices <- c(\"In Progress\", \"Agency Review\", \"BBMR Review\",",
        "                       \"Approved\", \"Partially Approved\", \"Denied\")",
        "",
        "cls_status_is_complete <- function(status)",
        "  status %in% c(\"BBMR Review\", \"Approved\", \"Partially Approved\", \"Denied\")",
    ], st, W))
    story.append(Spacer(1, 5))
    story.append(Paragraph(
        "<font face='Courier'>set_cls_status()</font> moves one request and writes both columns together. "
        "<font face='Courier'>set_plan_cls_status()</font> can move a whole plan and takes an "
        "<font face='Courier'>only_from</font> guard so a sweep never overwrites an already-decided request &mdash; it "
        "is retained for bulk operations even though the UI now submits one request at a time. A BBMR decision is "
        "applied inside <font face='Courier'>save_cls_review()</font>: Approved / Partial / Denied map to Approved / "
        "Partially Approved / Denied.", st["B"]))

    # ---- Pages ----
    story.append(PageBreak())
    story.append(Paragraph("How the pages are built", st["H"]))
    story.append(Paragraph(
        "Pages are plain functions returning htmltools tags. <font face='Courier'>page_ui()</font> is a "
        "<font face='Courier'>switch()</font> that maps a page key to one of them, and it is also where server-side "
        "access gating happens &mdash; an unauthorised page key is rewritten before anything renders. "
        "<font face='Courier'>output$page</font> calls <font face='Courier'>page_ui()</font> with the current page, the "
        "loaded data, the user's roles and any selection state.", st["B"]))
    story.append(code([
        "page_ui <- function(page, db, agency_id, ..., selected_cls_id, cls_review_filters) {",
        "  if (page %in% c(\"cls_requests\", \"cls_request_detail\") &&",
        "      !can_view_cls_requests(app_roles)) page <- \"landing\"",
        "  if (identical(page, \"cls_review\") && !can_review_cls(app_roles)) page <- \"landing\"",
        "  switch(page,",
        "    cls_requests       = page_cls_requests(db, agency_id, app_roles),",
        "    cls_request_detail = page_cls_request_detail(db, selected_cls_id, app_roles, agency_id),",
        "    cls_review         = page_cls_review(db, app_roles, ...))",
        "}",
    ], st, W))

    story.append(Paragraph("Roles", st["H3"]))
    story.append(Paragraph(
        "Four predicates over the user's app roles decide everything: "
        "<font face='Courier'>can_view_cls_requests()</font>, <font face='Courier'>can_edit_cls_requests()</font>, "
        "<font face='Courier'>can_approve_cls()</font> (approvers and admins), and "
        "<font face='Courier'>can_review_cls()</font> (BBMR and admins). They are checked in three places: in "
        "<font face='Courier'>page_ui()</font>, again inside every mutating observer, and in the nav-visibility message "
        "so hidden pages are not merely invisible but unreachable.", st["B"]))

    story.append(Paragraph("page_cls_requests() — the list", st["H3"]))
    story.append(bullets([
        "Scopes to the agency's current plan: <font face='Courier'>cls_requests_for_plan()</font> filters loaded "
        "requests by <font face='Courier'>plan_id</font>.",
        "Column headers are buttons carrying <font face='Courier'>data-cls-sort</font>; each row carries "
        "<font face='Courier'>data-sort-name/-service/-amount/-status</font> so sorting happens client-side with no "
        "server round-trip.",
        "The row's hand-off action is chosen by role and status: approvers get <i>Send to BBMR</i>, writers get "
        "<i>Submit</i>, and only when the status makes it valid.",
        "Amounts render through <font face='Courier'>cls_format_km()</font> ($X.XK / $X.XM); status renders as a chip "
        "toned by <font face='Courier'>cls_status_tone()</font>.",
    ], st))

    story.append(Paragraph("page_cls_request_detail() — the request", st["H3"]))
    story.append(Paragraph(
        "One function serves three modes, decided by whether an id was passed and what the user may do: <b>new</b> "
        "(empty form plus a Create button), <b>edit</b> (prefilled, autosaving, no Save button), and <b>read-only</b> "
        "(values rendered as text, no add-forms). It is built as three stacked sections:", st["B"]))
    story.append(bullets([
        "<b>Summary</b> &mdash; name, service, request type, duration toggle, the three fiscal-year amounts, and the "
        "word-limited narrative. Labels that need an explanation are built by a small local helper, "
        "<font face='Courier'>cls_labelled_info()</font>, which emits the label, an info button carrying "
        "<font face='Courier'>data-cls-info</font>, and a hidden panel rendered after the input so it opens below the "
        "field.",
        "<b>Request details</b> &mdash; the balance banner, then the add-form, then the object table. The banner text "
        "is computed server-side from <font face='Courier'>request_amount - (line_total + position_total)</font> and "
        "recomputed live in JavaScript as the user types.",
        "<b>Position requests</b> &mdash; rendered but hidden behind a checkbox, off unless positions already exist.",
    ], st))
    story.append(Paragraph(
        "Rows carry <font face='Courier'>data-cls-line-amount</font> and "
        "<font face='Courier'>data-cls-position-amount</font> specifically so the client can total them without "
        "re-querying.", st["Small"]))

    story.append(Paragraph("page_cls_review() — the BBMR workspace", st["H3"]))
    story.append(bullets([
        "<font face='Courier'>cls_review_rows()</font> flattens every request across every agency into one frame: "
        "agency label, line/position rollups, and any review fields joined on.",
        "<font face='Courier'>cls_review_chart()</font> emits an inline SVG bar chart &mdash; no plotting library. "
        "Tooltips are native <font face='Courier'>&lt;title&gt;</font> elements, so they work without JavaScript and "
        "are readable by assistive tech.",
        "Requests render as a compact table whose rows are buttons carrying "
        "<font face='Courier'>data-cls-rv-toggle</font>; the detail panel below each row is collapsed by default.",
        "Filters are deliberately <i>not</i> live. Applied values are held in "
        "<font face='Courier'>cls_applied_status</font> / <font face='Courier'>cls_applied_agency</font> reactives that "
        "only update when <i>Apply filters</i> is pressed; <i>Reset</i> clears them and pushes the full choice lists "
        "back into the inputs.",
    ], st))

    # ---- Server wiring ----
    story.append(PageBreak())
    story.append(Paragraph("Server wiring", st["H"]))
    story.append(Paragraph(
        "Every CLS action is an <font face='Courier'>observeEvent</font> on an <font face='Courier'>input$cls_*</font> "
        "value, and they all follow the same shape: check permission, coerce the id, call the helper inside "
        "<font face='Courier'>tryCatch</font>, surface any error with "
        "<font face='Courier'>showNotification</font>, then refresh and notify.", st["B"]))
    story.append(code([
        "observeEvent(input$cls_delete, {",
        "  if (!cls_guard_edit()) return()",
        "  cls_id <- suppressWarnings(as.integer(input$cls_delete$clsId))",
        "  if (is.na(cls_id)) return()",
        "  result <- tryCatch(delete_cls_request(database, cls_id), error = function(e) e)",
        "  if (inherits(result, \"error\")) { showNotification(conditionMessage(result), type = \"error\"); return() }",
        "  refresh_app_data()",
        "  showNotification(\"CLS request deleted.\", type = \"message\")",
        "}, ignoreInit = TRUE)",
    ], st, W))

    story.append(Paragraph("Selection state", st["H3"]))
    story.append(Paragraph(
        "<font face='Courier'>current_cls_id()</font> is the single source of truth for which request the detail page "
        "is showing; <font face='Courier'>NA</font> means &ldquo;new&rdquo;. Opening a row sets it and pushes a page "
        "change; creating a request sets it to the new id so the user lands on the saved request. "
        "<font face='Courier'>cls_pending_submit()</font> holds the id and mode behind a confirmation dialog so the "
        "confirm handler acts on exactly the request that was clicked.", st["B"]))

    story.append(Paragraph("Autosave", st["H3"]))
    story.append(Paragraph(
        "Typing in the summary section schedules a debounced (~0.9s) "
        "<font face='Courier'>cls_autosave</font> event. The observer writes through "
        "<font face='Courier'>update_cls_request()</font> stamped with the current user and records the time in "
        "<font face='Courier'>cls_last_save()</font>, which feeds the indicator. It deliberately does <b>not</b> call "
        "<font face='Courier'>refresh_app_data()</font> &mdash; that would re-render the form under the user's cursor. "
        "The list picks up the changes instead when they navigate away, via a check in the "
        "<font face='Courier'>input$current_page</font> observer.", st["B"]))

    story.append(Paragraph("Client behaviour (www/app.js)", st["H"]))
    story.append(Paragraph(
        "One delegated <font face='Courier'>click</font> listener handles every <font face='Courier'>data-cls-*</font> "
        "attribute and forwards to Shiny with <font face='Courier'>setInputValue(..., {priority: \"event\"})</font>, "
        "each payload carrying a nonce so repeated identical actions still fire. Destructive actions confirm first.",
        st["B"]))
    story.append(table([
        ["Function", "Responsibility"],
        ["clsValidate()", "Umbrella: word count, balance banner, red required fields."],
        ["clsUpdateWordCount()", "150-word limit; reports the exact overage in red."],
        ["clsUpdateRemaining()", "Recomputes FY28 minus (objects + positions); swaps the banner between neutral, "
                                 "green and red."],
        ["clsApplyOneTime() / …Label()", "Hides and clears FY29/FY30; flips the label between One-Time and Recurring."],
        ["clsApplyPositionsToggle()", "Shows or hides the positions body; clears the entry fields when switched off."],
        ["clsSyncTitle()", "Mirrors the request name into the page heading and the intro sentence as it is typed."],
        ["clsScheduleAutosave()", "Debounces the autosave event and shows &lsquo;Saving…&rsquo;."],
        ["clsRequestIsComplete()", "Whether the request balances; gates the warning shown on the way out. A "
                                   "complete request leaves silently."],
        ["clsSummaryGaps()", "Which mandatory summary fields are empty, by label. Blocks navigation. Skips hidden "
                             "fields, so a one-time request is not asked for FY29/FY30."],
        ["clsNumberValue() / clsGroupDigits()", "Read and format separated numbers. Anything reading an amount field "
                                                "must use these &mdash; parseFloat(&ldquo;1,000&rdquo;) is 1."],
        ["clsApplyCheckDropdown()", "Pushes a filter dropdown's held ticks to Shiny as one change event."],
        ["clearStaleOverlays()", "Removes an orphaned modal backdrop on navigation."],
    ], [1.85 * inch, 5.05 * inch], st))
    story.append(Spacer(1, 4))

    story.append(Paragraph("The money input binding", st["H3"]))
    story.append(Paragraph(
        "Amount and count fields are <b>not</b> <font face='Courier'>numericInput()</font>. A native "
        "<font face='Courier'>&lt;input type=&quot;number&quot;&gt;</font> cannot display a thousands separator "
        "&mdash; the value is invalid the moment a comma appears. "
        "<font face='Courier'>cls_money_input()</font> emits the markup Shiny's own numericInput would, with a text "
        "input classed <font face='Courier'>cls-money-input</font>, and app.js registers a custom input binding "
        "(<font face='Courier'>beacon.clsMoneyInput</font>) that strips separators and truncates decimals on the way "
        "to the server, re-groups them on the way back, blocks &lsquo;.&rsquo; on keydown, and debounces at 350ms. "
        "Round-trip: &ldquo;1,234,567&rdquo; &rarr; 1234567; &ldquo;1234.99&rdquo; &rarr; 1234; &ldquo;&rdquo; and "
        "&ldquo;abc&rdquo; &rarr; null.", st["B"]))

    story.append(Paragraph("Batched filter dropdowns", st["H3"]))
    story.append(Paragraph(
        "Every tick in a CLS Review filter used to reach Shiny on its own, re-rendering the table and closing the "
        "panel mid-selection. A <b>capture-phase</b> change listener on document now stops the event before it "
        "reaches the container Shiny's checkbox-group binding listens on, marks the panel dirty and updates the "
        "summary locally. Applying dispatches one synthetic change &mdash; the binding reads the whole container, not "
        "the box that fired &mdash; guarded by a flag so the capture listener lets that one through.", st["B"]))

    story.append(Paragraph(
        "Re-initialisation matters: Shiny replaces the page's DOM on every render, so "
        "<font face='Courier'>clsInitPage()</font> is re-run on the <font face='Courier'>shiny:value</font> event to "
        "reapply toggles and validation to the new nodes.", st["Small"]))

    story.append(Paragraph("Exports", st["H"]))
    story.append(bullets([
        "<b>Excel.</b> <font face='Courier'>cls_export_sheets()</font> returns a named list of three data frames &mdash; "
        "Request summary, Line items, Personnel &mdash; and <font face='Courier'>writexl::write_xlsx()</font> turns each "
        "into a worksheet. Amounts stay numeric so Excel can total them.",
        "<b>PDF.</b> <font face='Courier'>cls_export_payload()</font> builds nested JSON (request &rarr; lines, "
        "positions), writes it to a temp file, and "
        "<font face='Courier'>scripts/build_cls_pdf.py</font> renders it with reportlab through the existing "
        "<font face='Courier'>PLAN_EXPORT_PYTHON</font> virtualenv. The R side treats a missing or empty output file as "
        "an error rather than serving a broken download.",
    ], st))

    story.append(Paragraph("Conventions worth keeping", st["H"]))
    story.append(bullets([
        "Permission is checked at render <b>and</b> at mutation &mdash; never rely on a hidden control.",
        "SQL is always parameterised; no string interpolation of user input.",
        "Vocabularies (types, objects, statuses) live in R/database.R as single sources of truth and are read by the UI, "
        "so a label changes in exactly one place.",
        "Client-side work is limited to presentation and validation; the database remains the authority.",
        "Migrations are re-runnable and defensive, because they execute against databases that already exist.",
    ], st))

    doc = SimpleDocTemplate(args.output, pagesize=letter, leftMargin=0.75 * inch, rightMargin=0.75 * inch,
                           topMargin=0.7 * inch, bottomMargin=0.7 * inch,
                           title="CLS Requests — Technical Guide")
    doc.build(story)


if __name__ == "__main__":
    main()
