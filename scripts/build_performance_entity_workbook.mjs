import fs from "node:fs/promises";
import path from "node:path";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const outputDir = "outputs/performance_entity_table";
const outputPath = path.join(outputDir, "performance_entity_table.xlsx");

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
  return fs.readFile(path.join(outputDir, csvName), "utf8").then((text) => {
    const rows = parseCsv(text);
    const sheet = workbook.worksheets.add(sheetName);
    sheet.showGridLines = false;
    const rowCount = rows.length;
    const colCount = rows[0]?.length || 0;
    if (!rowCount || !colCount) return sheet;

    const range = sheet.getRangeByIndexes(0, 0, rowCount, colCount);
    range.values = rows;
    range.format.wrapText = true;
    range.format.borders = { preset: "inside", style: "thin", color: "#E5E1EB" };

    const header = sheet.getRangeByIndexes(0, 0, 1, colCount);
    header.format = {
      fill: options.headerFill || "#2F2140",
      font: { bold: true, color: "#FFFFFF" },
      wrapText: true,
    };

    sheet.freezePanes.freezeRows(1);
    if (options.freezeColumns) sheet.freezePanes.freezeColumns(options.freezeColumns);

    const tableRange = `A1:${colName(colCount - 1)}${rowCount}`;
    sheet.tables.add(tableRange, true, sheetName.replace(/[^A-Za-z0-9]/g, "").slice(0, 24) + "Table");

    sheet.getRangeByIndexes(0, 0, rowCount, colCount).format.autofitColumns();
    sheet.getRange("A:A").format.columnWidth = 18;
    sheet.getRange("B:B").format.columnWidth = 30;
    sheet.getRange("C:D").format.columnWidth = 32;
    sheet.getRange("E:E").format.columnWidth = 44;
    sheet.getRange("H:I").format.columnWidth = 42;
    sheet.getRangeByIndexes(1, 0, Math.max(rowCount - 1, 1), colCount).format.rowHeight = 36;
    return sheet;
  });
}

await fs.mkdir(outputDir, { recursive: true });
const workbook = Workbook.create();

const readme = workbook.worksheets.add("README");
readme.showGridLines = false;
readme.getRange("A1:F1").merge();
readme.getRange("A1").values = [["Performance Entity Alignment"]];
readme.getRange("A1").format = {
  fill: "#2F2140",
  font: { bold: true, color: "#FFFFFF", size: 16 },
};
readme.getRange("A3:B12").values = [
  ["Purpose", "FY27 reconciliation table for aligning performance metrics with the entity that should own them: service, mayoral service, or quasi agency."],
  ["Primary Tab", "Performance Entity Table"],
  ["Public Name Rule", "Uses public-facing names where the mapping clearly resolves. If the mapping is uncertain, public_name is left blank."],
  ["Entity ID Rule", "entity_id is only populated for plan entities. Service IDs stay in service_id."],
  ["Entity Type Values", "service; mayoral service; quasi agency"],
  ["Old Measure ID", "Measure ID from database/reference/Performance_Data.xlsx."],
  ["New Measure ID", "Seeded performance.performance_measure.measure_id matched by agency and measure name."],
  ["FY Filter", "Only rows where Performance_Data.xlsx Fiscal Year equals FY27 are included."],
  ["Analyst Use", "Review blank or questionable public_name/entity_type values, using candidate_entity_names and mapping_status for context."],
  ["Return Path", "Send the completed workbook back so the entity alignment can be imported into the database."],
];
readme.getRange("A3:A12").format = {
  fill: "#F3F0F7",
  font: { bold: true, color: "#2F2140" },
};
readme.getRange("A3:B12").format.borders = { preset: "all", style: "thin", color: "#D9D9D9" };
readme.getRange("A3:B12").format.wrapText = true;
readme.getRange("A:B").format.autofitColumns();
readme.getRange("B:B").format.columnWidth = 90;

await addCsvSheet(workbook, "Performance Entity Table", "performance_entity_table.csv", {
  headerFill: "#2F2140",
  freezeColumns: 5,
});

const tableSheet = workbook.worksheets.getItem("Performance Entity Table");
tableSheet.getRange("A2:A1000").dataValidation = {
  rule: { type: "list", values: ["service", "mayoral service", "quasi agency"] },
};

const preview = await workbook.render({ sheetName: "Performance Entity Table", range: "A1:I20", scale: 1, format: "png" });
await fs.writeFile(path.join(outputDir, "performance_entity_table_preview.png"), new Uint8Array(await preview.arrayBuffer()));

const xlsx = await SpreadsheetFile.exportXlsx(workbook);
try {
  await xlsx.save(outputPath);
  console.log(outputPath);
} catch (error) {
  if (error?.code !== "EBUSY") throw error;
  const fallbackPath = path.join(outputDir, "performance_entity_table_updated.xlsx");
  await xlsx.save(fallbackPath);
  console.log(fallbackPath);
}
