#!/usr/bin/env python3
"""Render CLS (Current Level of Service) budget requests to a PDF.

Reads a JSON payload (see cls_export_payload in app.R) and writes a PDF that
lists every request with its full detail: the request summary, the line-item
breakdown, and the position/personnel requests.
"""
import argparse
import json

from reportlab.lib import colors
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import inch
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, HRFlowable,
)

BRAND = colors.HexColor("#2f1c3d")
ACCENT = colors.HexColor("#fabe21")
MUTED = colors.HexColor("#526270")
LINE = colors.HexColor("#c4d1d9")


def money(value):
    if value is None or value == "":
        return "—"
    try:
        return "${:,.2f}".format(float(value))
    except (TypeError, ValueError):
        return str(value)


def build_styles():
    styles = getSampleStyleSheet()
    styles.add(ParagraphStyle("CLSTitle", parent=styles["Title"], textColor=BRAND, fontSize=20, spaceAfter=2))
    styles.add(ParagraphStyle("CLSsub", parent=styles["Normal"], textColor=MUTED, fontSize=10, spaceAfter=14))
    styles.add(ParagraphStyle("CLSReq", parent=styles["Heading2"], textColor=BRAND, fontSize=14, spaceBefore=16, spaceAfter=2))
    styles.add(ParagraphStyle("CLSService", parent=styles["Normal"], textColor=MUTED, fontSize=9.5, spaceAfter=8))
    styles.add(ParagraphStyle("CLSSection", parent=styles["Heading3"], textColor=BRAND, fontSize=11, spaceBefore=10, spaceAfter=4))
    styles.add(ParagraphStyle("CLSCell", parent=styles["Normal"], fontSize=9, leading=12))
    styles.add(ParagraphStyle("CLSHead", parent=styles["Normal"], fontSize=9, leading=12, textColor=colors.white))
    styles.add(ParagraphStyle("CLSBody", parent=styles["Normal"], fontSize=10, leading=14, spaceAfter=6))
    return styles


def cell(text, styles, head=False):
    return Paragraph("" if text is None else str(text), styles["CLSHead" if head else "CLSCell"])


def styled_table(data, col_widths, styles):
    tbl = Table(data, colWidths=col_widths, repeatRows=1)
    tbl.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), BRAND),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("GRID", (0, 0), (-1, -1), 0.5, LINE),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#f3eef9")]),
        ("LEFTPADDING", (0, 0), (-1, -1), 6),
        ("RIGHTPADDING", (0, 0), (-1, -1), 6),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]))
    return tbl


def request_flowables(req, styles):
    out = []
    out.append(Paragraph(req.get("name") or "(untitled request)", styles["CLSReq"]))
    out.append(Paragraph("Service: %s" % (req.get("service") or "—"), styles["CLSService"]))

    fields = [
        ["Type", req.get("type") or "—", "One-time", "Yes" if req.get("one_time") else "No"],
        ["Request amount", money(req.get("amount")), "Status", req.get("status") or "—"],
        ["Projected FY+2", money(req.get("amount_next_fy")), "Projected FY+3", money(req.get("amount_2next_fy"))],
        ["Completed", "Yes" if req.get("completed") else "No", "", ""],
    ]
    fld = [[cell(a, styles), cell(b, styles), cell(c, styles), cell(d, styles)] for a, b, c, d in fields]
    ft = Table(fld, colWidths=[1.3 * inch, 2.0 * inch, 1.3 * inch, 2.0 * inch])
    ft.setStyle(TableStyle([
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LINEBELOW", (0, 0), (-1, -1), 0.4, LINE),
        ("TEXTCOLOR", (0, 0), (0, -1), MUTED),
        ("TEXTCOLOR", (2, 0), (2, -1), MUTED),
        ("TOPPADDING", (0, 0), (-1, -1), 3),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
    ]))
    out.append(ft)

    if req.get("summary"):
        out.append(Spacer(1, 6))
        out.append(Paragraph("<b>Summary.</b> %s" % req["summary"], styles["CLSBody"]))

    out.append(Paragraph("Request details (line items)", styles["CLSSection"]))
    lines = req.get("lines") or []
    if lines:
        data = [[cell("Object", styles, True), cell("Spend category", styles, True),
                 cell("Amount", styles, True), cell("Justification", styles, True)]]
        for li in lines:
            data.append([cell(li.get("object_category"), styles), cell(li.get("spend_category"), styles),
                         cell(money(li.get("amount")), styles), cell(li.get("justification"), styles)])
        out.append(styled_table(data, [1.55 * inch, 1.6 * inch, 1.0 * inch, 2.45 * inch], styles))
    else:
        out.append(Paragraph("No line items.", styles["CLSService"]))

    out.append(Paragraph("Position requests", styles["CLSSection"]))
    positions = req.get("positions") or []
    if positions:
        data = [[cell("Classification", styles, True), cell("Positions", styles, True), cell("Est. salary", styles, True), cell("Justification", styles, True), cell("Explanation", styles, True)]]
        for po in positions:
            data.append([
                cell(po.get("classification"), styles),
                cell(po.get("position_count"), styles),
                cell(money(po.get("estimated_salary")), styles),
                cell(po.get("justification"), styles),
                cell(po.get("explanation"), styles),
            ])
        out.append(styled_table(data, [1.5 * inch, 0.7 * inch, 1.0 * inch, 1.7 * inch, 1.7 * inch], styles))
    else:
        out.append(Paragraph("No position requests.", styles["CLSService"]))

    out.append(Spacer(1, 6))
    out.append(HRFlowable(width="100%", thickness=1, color=ACCENT))
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    with open(args.input, "r", encoding="utf-8") as handle:
        payload = json.load(handle)

    styles = build_styles()
    story = [
        Paragraph("CLS Requests", styles["CLSTitle"]),
        Paragraph("%s &nbsp;&bull;&nbsp; Generated %s" % (payload.get("agency") or "Agency", payload.get("generated") or ""), styles["CLSsub"]),
        HRFlowable(width="100%", thickness=2, color=BRAND),
    ]

    requests = payload.get("requests") or []
    if not requests:
        story.append(Spacer(1, 12))
        story.append(Paragraph("No CLS requests have been created for this agency yet.", styles["CLSBody"]))
    else:
        for req in requests:
            story.extend(request_flowables(req, styles))

    doc = SimpleDocTemplate(
        args.output, pagesize=letter,
        leftMargin=0.75 * inch, rightMargin=0.75 * inch, topMargin=0.75 * inch, bottomMargin=0.75 * inch,
        title="CLS Requests",
    )
    doc.build(story)


if __name__ == "__main__":
    main()
