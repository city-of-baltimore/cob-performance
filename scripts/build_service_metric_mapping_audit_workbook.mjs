import fs from "node:fs/promises";
import path from "node:path";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const outputDir = "outputs/service_metric_mapping_audit";
const outputPath = path.join(outputDir, "service_metric_mapping_audit.xlsx");

function parseCsv(text) {
  const rows = [];
  let row = [];
  let field = "";
  let inQuotes = false;
  for (let i = 0; i < text.length; i += 1) {
    const char = text[i];
    const next = text[i + 1];
    if (inQuotes) {
      if (char === '"' && next === '"') {
        field += '"';
        i += 1;
      } else if (char === '"') {
        inQuotes = false;
      } else {
        field += char;
      }
    } else if (char === '"') {
      inQuotes = true;
    } else if (char === ",") {
      row.push(field);
      field = "";
    } else if (char === "\n") {
      row.push(field);
      rows.push(row);
      row = [];
      field = "";
    } else if (char !== "\r") {
      field += char;
    }
  }
  if (field.length || row.length) {
    row.push(field);
    rows.push(row);
  }
  return rows;
}

function colName(index) {
  let name = "";
  let n = index + 1;
  while (n > 0) {
    const rem = (n - 1) % 26;
    name = String.fromCharCode(65 + rem) + name;
    n = Math.floor((n - 1) / 26);
  }
  return name;
}

function addCsvSheet(workbook, sheetName, csvName, options = {}) {
  const csvPath = path.join(outputDir, csvName);
  return fs.readFile(csvPath, "utf8").then((text) => {
    const rows = parseCsv(text);
    const sheet = workbook.worksheets.add(sheetName);
    sheet.showGridLines = false;
    if (!rows.length) return sheet;
    const rowCount = rows.length;
    const colCount = rows[0].length;
    const range = sheet.getRangeByIndexes(0, 0, rowCount, colCount);
    range.values = rows;
    const header = sheet.getRangeByIndexes(0, 0, 1, colCount);
    header.format = {
      fill: options.headerFill || "#2F2140",
      font: { bold: true, color: "#FFFFFF" },
      wrapText: true,
    };
    range.format.borders = { preset: "all", style: "thin", color: "#D9D9D9" };
    range.format.wrapText = true;
    sheet.freezePanes.freezeRows(1);
    sheet.getRangeByIndexes(0, 0, rowCount, colCount).format.autofitColumns();
    sheet.getRangeByIndexes(0, 0, rowCount, colCount).format.autofitRows();
    const tableRange = `A1:${colName(colCount - 1)}${rowCount}`;
    sheet.tables.add(tableRange, true, sheetName.replace(/[^A-Za-z0-9]/g, "").slice(0, 24) + "Table");
    return sheet;
  });
}

const workbook = Workbook.create();

const readme = workbook.worksheets.add("README");
readme.showGridLines = false;
readme.getRange("A1:E1").merge();
readme.getRange("A1").values = [["Service Metric Mapping Audit"]];
readme.getRange("A1").format = {
  fill: "#2F2140",
  font: { bold: true, color: "#FFFFFF", size: 16 },
};
readme.getRange("A3:B10").values = [
  ["Purpose", "Analyst review file for identifying which public-facing plan entity and service should own each performance measure where current mapping is unclear."],
  ["Primary Tab", "Entity Measure Review"],
  ["How To Respond", "Fill analyst_recommended_entity_id, analyst_recommended_entity_name, analyst_recommended_service_id, analyst_action, and analyst_notes."],
  ["Suggested Actions", "Link to entity/service; Keep agency-level only; Split shared service; Needs follow-up; Retire/deprecate"],
  ["Naming Rule", "Use public-facing names for display. Keep IDs for import accuracy."],
  ["Generated From", "Current local database plus database/reference/Performance_Data.xlsx"],
  ["Round Trip", "Send this completed workbook back so mappings can be imported into pm_service_link and future entity mapping tables."],
  ["Do Not Edit", "Avoid changing measure_id, agency_id, entity_id, or service_id values except in the analyst response columns."],
];
readme.getRange("A3:A10").format = {
  fill: "#F3F0F7",
  font: { bold: true, color: "#2F2140" },
};
readme.getRange("A3:B10").format.borders = { preset: "all", style: "thin", color: "#D9D9D9" };
readme.getRange("A3:B10").format.wrapText = true;
readme.getRange("A:B").format.autofitColumns();

await addCsvSheet(workbook, "Entity Measure Review", "entity_measure_review.csv", { headerFill: "#2F2140" });
await addCsvSheet(workbook, "Entity Reference", "entity_reference.csv", { headerFill: "#3B4A54" });
await addCsvSheet(workbook, "Services No Metrics", "services_without_metrics.csv", { headerFill: "#6B2E2E" });
await addCsvSheet(workbook, "Unassigned Measures", "unassigned_measures.csv", { headerFill: "#6B2E2E" });
await addCsvSheet(workbook, "Shared Entity Services", "shared_entity_services.csv", { headerFill: "#6B4E16" });
await addCsvSheet(workbook, "Entity Services No Metrics", "entity_services_without_metrics.csv", { headerFill: "#6B4E16" });
await addCsvSheet(workbook, "Agency Summary", "summary.csv", { headerFill: "#2F2140" });

const review = workbook.worksheets.getItem("Entity Measure Review");
review.freezePanes.freezeRows(1);
review.freezePanes.freezeColumns(4);

await fs.mkdir(outputDir, { recursive: true });
const preview = await workbook.render({ sheetName: "README", autoCrop: "all", scale: 1, format: "png" });
await fs.writeFile(path.join(outputDir, "readme_preview.png"), new Uint8Array(await preview.arrayBuffer()));

const xlsx = await SpreadsheetFile.exportXlsx(workbook);
await xlsx.save(outputPath);
console.log(outputPath);
