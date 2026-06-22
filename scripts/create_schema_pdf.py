from __future__ import annotations

from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import (
    ListFlowable,
    ListItem,
    PageBreak,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)


OUTPUT = Path("docs/database_schema_so_far.pdf")


TABLES = {
    "PILLAR": [
        ("pillar_id", "int", "PK"),
        ("pillar_name", "text", ""),
        ("pillar_lead", "text", ""),
        ("sort_order", "int", ""),
        ("updated_at", "timestamptz", ""),
    ],
    "PILLAR_GOAL": [
        ("pillar_goal_id", "int", "PK"),
        ("pillar_id", "int", "FK -> PILLAR.pillar_id"),
        ("goal_code", "text", ""),
        ("goal_title", "text", ""),
        ("goal_lead", "text", ""),
        ("sort_order", "int", ""),
    ],
    "AGENCY": [
        ("agency_id", "text", "PK"),
        ("agency_name", "text", ""),
        ("public_name", "text", ""),
        ("deputy_mayor_pillar", "text", ""),
        ("is_quasi", "boolean", ""),
        ("active", "boolean", ""),
    ],
    "SERVICE": [
        ("service_id", "text", "PK"),
        ("service_name", "text", ""),
        ("agency_id", "text", "FK -> AGENCY.agency_id"),
        ("service_type", "text", ""),
        ("pillar_id", "int", "FK -> PILLAR.pillar_id"),
        ("pillar_name", "text", ""),
        ("active", "boolean", ""),
    ],
    "COST_CENTER": [
        ("cost_center_id", "text", "PK"),
        ("cost_center_name", "text", ""),
        ("service_id", "text", "FK -> SERVICE.service_id"),
        ("agency_id", "text", "FK -> AGENCY.agency_id"),
        ("active", "boolean", ""),
    ],
    "PLAN_ENTITY": [
        ("entity_id", "int", "PK"),
        ("parent_agency_id", "text", "FK -> AGENCY.agency_id"),
        ("public_name", "text", ""),
        ("entity_type", "text", ""),
        ("has_own_plan", "boolean", ""),
        ("active", "boolean", ""),
    ],
    "PLAN_ENTITY_SERVICE": [
        ("pes_id", "int", "PK"),
        ("entity_id", "int", "FK -> PLAN_ENTITY.entity_id"),
        ("service_id", "text", "FK -> SERVICE.service_id"),
        ("service_name", "text", ""),
        ("is_primary", "boolean", ""),
    ],
}


RELATIONSHIPS = [
    "PILLAR -> PILLAR_GOAL",
    "PILLAR -> SERVICE",
    "AGENCY -> SERVICE",
    "AGENCY -> COST_CENTER",
    "AGENCY -> PLAN_ENTITY",
    "SERVICE -> COST_CENTER",
    "SERVICE -> PLAN_ENTITY_SERVICE",
    "PLAN_ENTITY -> PLAN_ENTITY_SERVICE",
]


def add_footer(canvas, doc) -> None:
    canvas.saveState()
    canvas.setFont("Helvetica", 8)
    canvas.setFillColor(colors.HexColor("#666666"))
    canvas.drawRightString(7.5 * inch, 0.5 * inch, f"Page {doc.page}")
    canvas.restoreState()


def build_pdf() -> None:
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)

    doc = SimpleDocTemplate(
        str(OUTPUT),
        pagesize=letter,
        rightMargin=0.65 * inch,
        leftMargin=0.65 * inch,
        topMargin=0.65 * inch,
        bottomMargin=0.65 * inch,
        title="Database Schema So Far",
    )

    styles = getSampleStyleSheet()
    styles.add(
        ParagraphStyle(
            name="SchemaTitle",
            parent=styles["Title"],
            fontName="Helvetica-Bold",
            fontSize=20,
            leading=24,
            spaceAfter=10,
            textColor=colors.HexColor("#1f2937"),
        )
    )
    styles.add(
        ParagraphStyle(
            name="SchemaHeading",
            parent=styles["Heading2"],
            fontName="Helvetica-Bold",
            fontSize=13,
            leading=16,
            spaceBefore=12,
            spaceAfter=6,
            textColor=colors.HexColor("#1f2937"),
        )
    )
    styles.add(
        ParagraphStyle(
            name="SmallMono",
            parent=styles["BodyText"],
            fontName="Courier",
            fontSize=8.5,
            leading=11,
        )
    )

    story = [
        Paragraph("Database Schema So Far", styles["SchemaTitle"]),
        Paragraph(
            "Reference schema based on the current city reference table loader.",
            styles["BodyText"],
        ),
        Spacer(1, 8),
        Paragraph("Relationships", styles["SchemaHeading"]),
        ListFlowable(
            [ListItem(Paragraph(item, styles["SmallMono"])) for item in RELATIONSHIPS],
            bulletType="bullet",
            start="circle",
            leftIndent=16,
        ),
        Paragraph("Main Model", styles["SchemaHeading"]),
        Paragraph(
            "Pillar -> Goals; Pillar -> Services; Agency -> Services; Agency -> "
            "Cost Centers; Agency -> Plan Entities; Service -> Cost Centers; "
            "Plan Entity -> Plan Entity Service -> Service.",
            styles["BodyText"],
        ),
        PageBreak(),
        Paragraph("Tables", styles["SchemaHeading"]),
    ]

    for table_name, fields in TABLES.items():
        story.append(Paragraph(table_name, styles["SchemaHeading"]))
        table_data = [["Column", "Type", "Key / Relationship"], *fields]
        table = Table(table_data, colWidths=[2.15 * inch, 1.25 * inch, 3.4 * inch])
        table.setStyle(
            TableStyle(
                [
                    ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#e5e7eb")),
                    ("TEXTCOLOR", (0, 0), (-1, 0), colors.HexColor("#111827")),
                    ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
                    ("FONTNAME", (0, 1), (-1, -1), "Helvetica"),
                    ("FONTSIZE", (0, 0), (-1, -1), 8.5),
                    ("LEADING", (0, 0), (-1, -1), 10),
                    ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#d1d5db")),
                    ("VALIGN", (0, 0), (-1, -1), "TOP"),
                    ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#f9fafb")]),
                    ("LEFTPADDING", (0, 0), (-1, -1), 5),
                    ("RIGHTPADDING", (0, 0), (-1, -1), 5),
                    ("TOPPADDING", (0, 0), (-1, -1), 4),
                    ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
                ]
            )
        )
        story.append(table)
        story.append(Spacer(1, 4))

    doc.build(story, onFirstPage=add_footer, onLaterPages=add_footer)
    print(OUTPUT.resolve())


if __name__ == "__main__":
    build_pdf()
