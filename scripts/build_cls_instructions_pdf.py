#!/usr/bin/env python3
"""Generate the 'How to complete a CLS request' instructions PDF.

Uses reportlab (already in the app's export venv). Figures are schematic
representations of the two screens with numbered callouts; drop in live
screenshots to replace them if desired.
"""
import argparse

from reportlab.lib import colors
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import inch
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, HRFlowable, ListFlowable, ListItem,
)

BRAND = colors.HexColor("#2f1c3d")
ACCENT = colors.HexColor("#fabe21")
ORANGE = colors.HexColor("#e8730c")
MUTED = colors.HexColor("#526270")
LINE = colors.HexColor("#c4d1d9")
SUBTLE = colors.HexColor("#f3eef9")
CANVAS = colors.HexColor("#e7edf2")


def S():
    s = getSampleStyleSheet()
    s.add(ParagraphStyle("T", parent=s["Title"], textColor=BRAND, fontSize=20, spaceAfter=2))
    s.add(ParagraphStyle("Sub", parent=s["Normal"], textColor=MUTED, fontSize=10, spaceAfter=12))
    s.add(ParagraphStyle("H", parent=s["Heading2"], textColor=BRAND, fontSize=13, spaceBefore=12, spaceAfter=4))
    s.add(ParagraphStyle("B", parent=s["Normal"], fontSize=10, leading=14, spaceAfter=5))
    s.add(ParagraphStyle("Cap", parent=s["Normal"], fontSize=8.5, textColor=MUTED, alignment=1, spaceBefore=3, spaceAfter=10))
    s.add(ParagraphStyle("Fig", parent=s["Normal"], fontSize=9, leading=13, textColor=BRAND))
    s.add(ParagraphStyle("FigMuted", parent=s["Normal"], fontSize=8.5, leading=12, textColor=MUTED))
    s.add(ParagraphStyle("Pill", parent=s["Normal"], fontSize=8.5, textColor=colors.white, alignment=1))
    return s


def pill(text, styles, bg):
    t = Table([[Paragraph("<b>%s</b>" % text, styles["Pill"])]], colWidths=[1.5 * inch])
    t.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, -1), bg), ("TOPPADDING", (0, 0), (-1, -1), 3), ("BOTTOMPADDING", (0, 0), (-1, -1), 3), ("ROUNDEDCORNERS", [4, 4, 4, 4])]))
    return t


def screen_frame(title, inner_rows, styles, widths):
    """A framed box that reads like a screenshot: title bar + content rows."""
    header = [[Paragraph("<b>%s</b>" % title, styles["Fig"])]]
    ht = Table(header, colWidths=[sum(widths)])
    ht.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, -1), BRAND), ("TEXTCOLOR", (0, 0), (-1, -1), colors.white), ("LEFTPADDING", (0, 0), (-1, -1), 8), ("TOPPADDING", (0, 0), (-1, -1), 5), ("BOTTOMPADDING", (0, 0), (-1, -1), 5)]))
    body = Table(inner_rows, colWidths=widths)
    body.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), colors.white),
        ("BOX", (0, 0), (-1, -1), 0.5, LINE),
        ("INNERGRID", (0, 0), (-1, -1), 0.5, LINE),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 6),
        ("RIGHTPADDING", (0, 0), (-1, -1), 6),
        ("TOPPADDING", (0, 0), (-1, -1), 5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
    ]))
    wrap = Table([[ht], [body]], colWidths=[sum(widths)])
    wrap.setStyle(TableStyle([("BOX", (0, 0), (-1, -1), 1, BRAND), ("BACKGROUND", (0, 0), (-1, -1), CANVAS), ("LEFTPADDING", (0, 0), (-1, -1), 0), ("RIGHTPADDING", (0, 0), (-1, -1), 0), ("TOPPADDING", (0, 0), (-1, -1), 0), ("BOTTOMPADDING", (0, 0), (-1, -1), 0)]))
    return wrap


def callout(n, text, styles):
    return [Paragraph("<b>%d</b>" % n, styles["Fig"]), Paragraph(text, styles["FigMuted"])]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    st = S()
    W = 6.9 * inch

    story = []
    story.append(Paragraph("Completing a CLS Request", st["T"]))
    story.append(Paragraph("A step-by-step guide for agency writers and approvers &bull; Beacon Performance &amp; Budgeting", st["Sub"]))
    story.append(HRFlowable(width="100%", thickness=2, color=BRAND))
    story.append(Spacer(1, 8))

    story.append(Paragraph("What is a CLS request?", st["H"]))
    story.append(Paragraph(
        "A Current Level of Service (CLS) request asks BBMR to fund the cost of maintaining your agency's current level of service "
        "in the coming fiscal year &mdash; for example mandated cost increases, cyclical costs, or extraordinary inflation. "
        "Each request is summarized by initiative/project, given a total amount, and then broken out by expenditure object.",
        st["B"]))

    # Figure 1 — list page
    story.append(Paragraph("The CLS Requests page", st["H"]))
    fig1 = screen_frame(
        "[Agency name] Requests",
        [
            [Paragraph("<b>Request name</b> &nbsp; | &nbsp; Service &nbsp; | &nbsp; Amount", st["FigMuted"]),
             Paragraph('<font color="#e8730c"><b>&#9992; Submit for approval</b></font> &nbsp; <font color="#2f1c3d"><b>+ Add CLS Request</b></font>', st["Fig"])],
            [Paragraph("Mandated fleet fuel increase &nbsp; | &nbsp; Fleet Management &nbsp; | &nbsp; $412.0K", st["FigMuted"]),
             Paragraph("Delete &nbsp; <b>Modify &#8594;</b>", st["FigMuted"])],
            [Paragraph("Export request(s): Excel &nbsp; PDF", st["FigMuted"]), Paragraph("", st["FigMuted"])],
        ],
        st, [4.3 * inch, 2.6 * inch])
    story.append(fig1)
    story.append(Paragraph("Figure 1. The list page: one card per agency. Add a request, sort by service or amount, submit for approval, or export.", st["Cap"]))

    story.append(Paragraph("Step by step", st["H"]))
    steps = [
        "<b>Open the page.</b> In the left navigation under <b>Budget Planning</b>, choose <b>CLS Requests</b>.",
        "<b>Add a request.</b> Click <b>Add CLS Request</b> to open the request page.",
        "<b>Fill in the summary.</b> Give the request a name, pick the service it supports, choose the request type (use the info icon if unsure), and enter the request amount. Add FY29/FY30 amounts, or check <b>One-time request</b> to hide them.",
        "<b>Summarize the request.</b> Write a 3&ndash;4 sentence explanation (required, 300-word limit).",
        "<b>Break it out.</b> Under <b>Request details</b>, use <b>Add Details</b> to add one line per expenditure object until the line totals equal the request amount (watch the remaining-$ note).",
        "<b>Add positions (if needed).</b> Check <b>Add positions to this request</b> and complete the position fields.",
        "<b>Submit.</b> Back on the CLS Requests page, click <b>Submit for approval</b> to send it to your Agency Approver.",
    ]
    story.append(ListFlowable([ListItem(Paragraph(s, st["B"]), value=i + 1) for i, s in enumerate(steps)], bulletType="1", leftIndent=16))

    # Figure 2 — request page
    story.append(Spacer(1, 4))
    story.append(Paragraph("The request page", st["H"]))
    fig2 = screen_frame(
        "Mandated fleet fuel increase",
        [
            [Paragraph("<b>&#8592; Back to CLS requests</b> &nbsp;&nbsp; <font color='#526270'>(reminder: send to your Agency Approver before the deadline)</font>", st["FigMuted"])],
            [Paragraph("<b>Summary:</b> Request name &bull; Service &bull; Request type (&#9432; info) &bull; Request / FY29 / FY30 amounts &bull; One-time &bull; Summarize (300 words)", st["FigMuted"])],
            [Paragraph("<b>Request details:</b> remaining-$ note, Add Details, one line per expenditure object", st["FigMuted"])],
            [Paragraph("<b>Position requests:</b> shown after you check &lsquo;Add positions to this request&rsquo;", st["FigMuted"])],
        ],
        st, [6.9 * inch])
    story.append(fig2)
    story.append(Paragraph("Figure 2. The request page: the summary box, the expenditure-object breakdown, and the optional positions section.", st["Cap"]))

    story.append(Paragraph("How you'll know it's complete", st["H"]))
    story.append(Paragraph(
        "Required fields turn <font color='#b64454'><b>red</b></font> when left blank, and the summary word counter turns red if you go over 300 words. "
        "The remaining-$ note confirms when your line items match the request amount. When everything is filled in and fully broken out, returning to the "
        "CLS Requests page shows a confirmation that the request has been justified. Only requests approved by your Agency Approver are reviewed by BBMR.",
        st["B"]))

    doc = SimpleDocTemplate(args.output, pagesize=letter, leftMargin=0.75 * inch, rightMargin=0.75 * inch, topMargin=0.7 * inch, bottomMargin=0.7 * inch, title="Completing a CLS Request")
    doc.build(story)


if __name__ == "__main__":
    main()
