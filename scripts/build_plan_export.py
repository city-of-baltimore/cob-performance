import argparse
import json
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import (
    PageBreak,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)

from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import PP_ALIGN
from pptx.util import Inches, Pt


PURPLE = colors.HexColor("#2f1c3d")
GOLD = colors.HexColor("#fabe21")
BLUE = colors.HexColor("#88c7d5")
DARK_GRAY = colors.HexColor("#3f454a")
LIGHT_BG = colors.HexColor("#f7fbfc")
SOFT_BG = colors.HexColor("#fbf8fd")


def clean(value):
    if value is None:
        return ""
    return str(value)


def add_pdf_header(canvas, doc):
    canvas.saveState()
    canvas.setFillColor(PURPLE)
    canvas.rect(0, letter[1] - 0.42 * inch, letter[0], 0.42 * inch, stroke=0, fill=1)
    canvas.setFillColor(GOLD)
    canvas.rect(0, letter[1] - 0.48 * inch, letter[0], 0.06 * inch, stroke=0, fill=1)
    canvas.setFont("Helvetica", 8)
    canvas.setFillColor(colors.white)
    canvas.drawString(0.6 * inch, letter[1] - 0.27 * inch, "Beacon: Baltimore Outcome Budgeting")
    canvas.setFillColor(DARK_GRAY)
    canvas.drawRightString(letter[0] - 0.6 * inch, 0.35 * inch, f"Page {doc.page}")
    canvas.restoreState()


def pdf_measure_table(measure, styles):
    data = [[Paragraph(clean(col), styles["TableHeader"]) for col in measure["columns"]]]
    data.append([Paragraph(clean(value), styles["TableCell"]) for value in measure["values"]])
    table = Table(data, repeatRows=1, hAlign="LEFT")
    table.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, 0), SOFT_BG),
                ("TEXTCOLOR", (0, 0), (-1, 0), DARK_GRAY),
                ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
                ("FONTSIZE", (0, 0), (-1, -1), 6.5),
                ("GRID", (0, 0), (-1, -1), 0.35, colors.HexColor("#d8e2e8")),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 4),
                ("RIGHTPADDING", (0, 0), (-1, -1), 4),
                ("TOPPADDING", (0, 0), (-1, -1), 4),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
            ]
        )
    )
    return table


def build_pdf(payload, output):
    doc = SimpleDocTemplate(
        output,
        pagesize=letter,
        rightMargin=0.55 * inch,
        leftMargin=0.55 * inch,
        topMargin=0.78 * inch,
        bottomMargin=0.65 * inch,
    )
    base = getSampleStyleSheet()
    styles = {
        "Title": ParagraphStyle("Title", parent=base["Title"], textColor=PURPLE, fontSize=24, leading=28, spaceAfter=8),
        "Subtitle": ParagraphStyle("Subtitle", parent=base["Normal"], textColor=DARK_GRAY, fontSize=9, leading=12, spaceAfter=12),
        "H1": ParagraphStyle("H1", parent=base["Heading1"], textColor=PURPLE, fontSize=16, leading=20, spaceBefore=12, spaceAfter=8),
        "H2": ParagraphStyle("H2", parent=base["Heading2"], textColor=PURPLE, fontSize=12, leading=15, spaceBefore=8, spaceAfter=5),
        "Body": ParagraphStyle("Body", parent=base["BodyText"], fontSize=9.5, leading=13, spaceAfter=6),
        "Small": ParagraphStyle("Small", parent=base["BodyText"], textColor=DARK_GRAY, fontSize=8, leading=11, spaceAfter=4),
        "TableHeader": ParagraphStyle("TableHeader", parent=base["BodyText"], textColor=DARK_GRAY, fontSize=6.5, leading=8),
        "TableCell": ParagraphStyle("TableCell", parent=base["BodyText"], fontSize=6.5, leading=8),
    }
    story = []
    story.append(Paragraph(f"FY{payload['fiscal_year']} Performance Plan", styles["Title"]))
    story.append(Paragraph(f"{payload['agency_name']} | {payload['status']} | Version {payload['version']}", styles["Subtitle"]))
    story.append(Paragraph(f"Agency contact: {payload['agency_contact']}", styles["Small"]))

    story.append(Paragraph("Overview & Vision", styles["H1"]))
    story.append(Paragraph(f"<b>Overview:</b> {clean(payload['overview'].get('overview'))}", styles["Body"]))
    story.append(Paragraph(f"<b>Vision:</b> {clean(payload['overview'].get('vision'))}", styles["Body"]))
    if payload["overview"].get("web_address"):
        story.append(Paragraph(f"<b>Web address:</b> {payload['overview']['web_address']}", styles["Body"]))

    story.append(Paragraph("Reviewer Feedback", styles["H1"]))
    story.append(Paragraph(f"<b>Reviewer:</b> {clean(payload['review'].get('reviewer'))}", styles["Body"]))
    story.append(Paragraph(f"<b>Overall score:</b> {clean(payload['review'].get('score'))}", styles["Body"]))
    for note in payload["review"].get("notes", []):
        story.append(Paragraph(f"- {clean(note)}", styles["Body"]))

    story.append(Paragraph("Agency Goals", styles["H1"]))
    for goal in payload["goals"]:
        story.append(Paragraph(clean(goal["title"]), styles["H2"]))
        if goal.get("initiatives"):
            story.append(Paragraph("<b>Initiatives</b>", styles["Small"]))
            for initiative in goal["initiatives"]:
                story.append(Paragraph(f"- {clean(initiative)}", styles["Body"]))
        if goal.get("kpis"):
            story.append(Paragraph("<b>Key Performance Indicators</b>", styles["Small"]))
            for measure in goal["kpis"]:
                story.append(Paragraph(clean(measure["title"]), styles["Body"]))
                story.append(Paragraph(f"{measure['type']} | {measure['direction']}", styles["Small"]))
                story.append(pdf_measure_table(measure, styles))
                story.append(Spacer(1, 0.08 * inch))
        if goal.get("alignment"):
            story.append(Paragraph(f"<b>Action Plan alignment:</b> {clean(goal['alignment'])}", styles["Small"]))

    story.append(Paragraph("Services", styles["H1"]))
    for service in payload["services"]:
        story.append(Paragraph(clean(service["name"]), styles["H2"]))
        story.append(Paragraph(clean(service["description"]), styles["Body"]))
        if service.get("metrics"):
            story.append(Paragraph("<b>Performance Metrics</b>", styles["Small"]))
            for measure in service["metrics"]:
                story.append(Paragraph(clean(measure["title"]), styles["Body"]))
                story.append(Paragraph(f"{measure['type']} | {measure['direction']}", styles["Small"]))
                story.append(pdf_measure_table(measure, styles))
                story.append(Spacer(1, 0.08 * inch))

    story.append(Paragraph("Risks", styles["H1"]))
    for risk in payload["risks"] or ["No risks available."]:
        story.append(Paragraph(f"- {clean(risk)}", styles["Body"]))

    doc.build(story, onFirstPage=add_pdf_header, onLaterPages=add_pdf_header)


def set_run(run, size=18, bold=False, color=PURPLE):
    run.font.size = Pt(size)
    run.font.bold = bold
    run.font.color.rgb = RGBColor(color.red if hasattr(color, "red") else 47, color.green if hasattr(color, "green") else 28, color.blue if hasattr(color, "blue") else 61)


def add_textbox(slide, text, left, top, width, height, size=18, bold=False, color=(47, 28, 61)):
    box = slide.shapes.add_textbox(left, top, width, height)
    frame = box.text_frame
    frame.clear()
    p = frame.paragraphs[0]
    p.text = text
    p.font.size = Pt(size)
    p.font.bold = bold
    p.font.color.rgb = RGBColor(*color)
    return box


def blank_layout(prs):
    return prs.slide_layouts[6] if len(prs.slide_layouts) > 6 else prs.slide_layouts[0]


def add_slide_title(slide, title, subtitle=None):
    add_textbox(slide, title, Inches(0.55), Inches(0.35), Inches(8.8), Inches(0.45), 24, True)
    if subtitle:
        add_textbox(slide, subtitle, Inches(0.55), Inches(0.82), Inches(8.8), Inches(0.35), 10, False, (63, 69, 74))
    shape = slide.shapes.add_shape(MSO_SHAPE.RECTANGLE, Inches(0), Inches(0), Inches(10), Inches(0.12))
    shape.fill.solid()
    shape.fill.fore_color.rgb = RGBColor(250, 190, 33)
    shape.line.fill.background()


def add_metric_table_to_slide(slide, measure, y):
    add_textbox(slide, measure["title"], Inches(0.7), y, Inches(8.6), Inches(0.28), 10, True, (22, 22, 22))
    add_textbox(slide, f"{measure['type']} | {measure['direction']}", Inches(0.7), y + Inches(0.25), Inches(8.6), Inches(0.25), 8, False, (63, 69, 74))
    rows, cols = 2, len(measure["columns"])
    table_shape = slide.shapes.add_table(rows, cols, Inches(0.7), y + Inches(0.58), Inches(8.6), Inches(0.72))
    table = table_shape.table
    for idx, col in enumerate(measure["columns"]):
        table.cell(0, idx).text = col
        table.cell(1, idx).text = clean(measure["values"][idx])
    for row in table.rows:
        for cell in row.cells:
            cell.text_frame.paragraphs[0].font.size = Pt(6.5)
            cell.margin_left = Inches(0.03)
            cell.margin_right = Inches(0.03)
            cell.margin_top = Inches(0.02)
            cell.margin_bottom = Inches(0.02)
    return y + Inches(1.42)


def build_pptx(payload, output, template=None):
    prs = Presentation(template) if template and Path(template).exists() else Presentation()
    layout = blank_layout(prs)

    slide = prs.slides.add_slide(layout)
    add_slide_title(slide, f"FY{payload['fiscal_year']} Performance Plan", payload["agency_name"])
    add_textbox(slide, "Beacon: Baltimore Outcome Budgeting", Inches(0.65), Inches(1.6), Inches(8.5), Inches(0.5), 28, True)
    add_textbox(slide, f"{payload['status']} | Version {payload['version']} | {payload['agency_contact']}", Inches(0.68), Inches(2.2), Inches(8.4), Inches(0.45), 13, False, (63, 69, 74))

    slide = prs.slides.add_slide(layout)
    add_slide_title(slide, "Overview & Reviewer Feedback", f"Overall score: {payload['review'].get('score', 'Not scored')}")
    add_textbox(slide, "Overview", Inches(0.65), Inches(1.25), Inches(4.1), Inches(0.3), 15, True)
    add_textbox(slide, clean(payload["overview"].get("overview")), Inches(0.65), Inches(1.65), Inches(4.1), Inches(1.8), 12, False, (22, 22, 22))
    add_textbox(slide, "Top improvement areas", Inches(5.1), Inches(1.25), Inches(4.1), Inches(0.3), 15, True)
    add_textbox(slide, "\n".join(f"- {clean(note)}" for note in payload["review"].get("notes", [])), Inches(5.1), Inches(1.65), Inches(4.2), Inches(2.1), 11, False, (22, 22, 22))

    for goal in payload["goals"]:
        slide = prs.slides.add_slide(layout)
        add_slide_title(slide, "Agency Goal", clean(goal["title"])[:95])
        y = Inches(1.25)
        if goal.get("initiatives"):
            add_textbox(slide, "Initiatives", Inches(0.65), y, Inches(8.8), Inches(0.25), 12, True, (63, 69, 74))
            add_textbox(slide, "\n".join(f"- {clean(i)}" for i in goal["initiatives"]), Inches(0.75), y + Inches(0.32), Inches(8.6), Inches(0.55), 10, False, (22, 22, 22))
            y += Inches(1.05)
        for measure in goal.get("kpis", [])[:2]:
            y = add_metric_table_to_slide(slide, measure, y)

    slide = prs.slides.add_slide(layout)
    add_slide_title(slide, "Services & Performance Metrics", f"{len(payload['services'])} services")
    y = Inches(1.2)
    for service in payload["services"][:3]:
        add_textbox(slide, service["name"], Inches(0.65), y, Inches(8.8), Inches(0.25), 12, True)
        y += Inches(0.33)
        for measure in service.get("metrics", [])[:1]:
            y = add_metric_table_to_slide(slide, measure, y)
        y += Inches(0.12)
        if y > Inches(6.0):
            break

    slide = prs.slides.add_slide(layout)
    add_slide_title(slide, "Risks", f"{len(payload['risks'])} risks identified")
    add_textbox(slide, "\n".join(f"- {clean(risk)}" for risk in payload["risks"]) or "No risks available.", Inches(0.75), Inches(1.3), Inches(8.5), Inches(4.8), 14, False, (22, 22, 22))

    prs.save(output)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--type", choices=["pdf", "pptx"], required=True)
    parser.add_argument("--template")
    args = parser.parse_args()
    with open(args.input, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if args.type == "pdf":
        build_pdf(payload, args.output)
    else:
        build_pptx(payload, args.output, args.template)


if __name__ == "__main__":
    main()
