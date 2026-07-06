import fs from "node:fs/promises";
import path from "node:path";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const root = process.cwd();
const outputDir = path.join(root, "outputs", "entity_roles");
const csvPath = path.join(outputDir, "entity_role_roster.csv");
const outPath = path.join(outputDir, "entity_role_roster.xlsx");
const previewPath = path.join(outputDir, "entity_role_roster_preview.png");

const csvText = (await fs.readFile(csvPath, "utf8"))
  .replace(/\u2014/g, "-")
  .replace(/Family Leage/g, "Family League");
const workbook = await Workbook.fromCSV(csvText, { sheetName: "Entity Roles" });
const sheet = workbook.worksheets.getItem("Entity Roles");
sheet.name = "Entity Roles";
sheet.showGridLines = false;

const used = sheet.getUsedRange();
const rowCount = used.rowCount;
const colCount = used.columnCount;

sheet.getRange("A1:I1").format = {
  fill: "#2f1b45",
  font: { bold: true, color: "#FFFFFF" },
  wrapText: true,
};
sheet.getRangeByIndexes(1, 0, Math.max(rowCount - 1, 1), colCount).format = {
  wrapText: true,
  borders: {
    insideHorizontal: { style: "thin", color: "#E5E7EB" },
  },
};
sheet.freezePanes.freezeRows(1);
sheet.tables.add(`A1:I${rowCount}`, true, "EntityRoleRoster");

const widths = [18, 13, 28, 12, 34, 28, 24, 36, 28];
for (let i = 0; i < widths.length; i += 1) {
  sheet.getRangeByIndexes(0, i, rowCount, 1).format.columnWidth = widths[i];
}
sheet.getRange(`A1:I${rowCount}`).format.autofitRows();

const notes = workbook.worksheets.add("Notes");
notes.showGridLines = false;
notes.getRange("A1:D1").merge();
notes.getRange("A1").values = [["Entity role roster export"]];
notes.getRange("A1").format = {
  fill: "#2f1b45",
  font: { bold: true, color: "#FFFFFF", size: 14 },
};
notes.getRange("A3:D9").values = [
  ["Field", "How populated", "", ""],
  ["Entity rows", "Agencies where reference.agency.submit_plan is TRUE plus active reference.plan_entity rows where has_own_plan is TRUE.", "", ""],
  ["Submitter", "Users with app_role = AgencySubmitter for the agency/accounting agency.", "", ""],
  ["Reviewer", "Current plan assigned_reviewer_name when present, otherwise reviewer_assignments.csv matched by public name.", "", ""],
  ["Deputy Mayor", "reference.agency.deputy_mayor_pillar for the accounting agency.", "", ""],
  ["CA Office", "CAOffice user whose name is explicitly present in the Deputy Mayor / portfolio field; blank when no clear name match exists.", "", ""],
  ["Generated", new Date().toISOString(), "", ""],
];
notes.getRange("A3:D3").format = {
  fill: "#F3F4F6",
  font: { bold: true, color: "#111827" },
};
notes.getRange("A:D").format.wrapText = true;
notes.getRange("A:A").format.columnWidth = 20;
notes.getRange("B:B").format.columnWidth = 95;
notes.getRange("A3:D9").format.borders = { preset: "all", style: "thin", color: "#E5E7EB" };

const preview = await workbook.render({ sheetName: "Entity Roles", range: "A1:I20", scale: 1, format: "png" });
await fs.writeFile(previewPath, new Uint8Array(await preview.arrayBuffer()));

const xlsx = await SpreadsheetFile.exportXlsx(workbook);
await xlsx.save(outPath);
console.log(outPath);
