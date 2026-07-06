import fs from "node:fs/promises";
import path from "node:path";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const outputDir = "outputs/service_descriptions_simple";
const outputPath = path.join(outputDir, "service_descriptions_simple.xlsx");

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

const csvPath = path.join(outputDir, "service_descriptions_simple.csv");
const rows = parseCsv(await fs.readFile(csvPath, "utf8"));
const workbook = Workbook.create();
const sheet = workbook.worksheets.add("Service Descriptions");
sheet.showGridLines = false;

const rowCount = rows.length;
const colCount = rows[0].length;
const range = sheet.getRangeByIndexes(0, 0, rowCount, colCount);
range.values = rows;
range.format.wrapText = true;
range.format.borders = { preset: "inside", style: "thin", color: "#E5E1EB" };

sheet.getRangeByIndexes(0, 0, 1, colCount).format = {
  fill: "#2F2140",
  font: { bold: true, color: "#FFFFFF" },
  wrapText: true,
};
sheet.freezePanes.freezeRows(1);
sheet.freezePanes.freezeColumns(4);
sheet.tables.add(`A1:${colName(colCount - 1)}${rowCount}`, true, "ServiceDescriptionsTable");

sheet.getRange("A:A").format.columnWidth = 14;
sheet.getRange("B:B").format.columnWidth = 36;
sheet.getRange("C:C").format.columnWidth = 14;
sheet.getRange("D:D").format.columnWidth = 36;
sheet.getRange("E:E").format.columnWidth = 100;
sheet.getRangeByIndexes(1, 0, Math.max(rowCount - 1, 1), colCount).format.rowHeight = 54;

const preview = await workbook.render({ sheetName: "Service Descriptions", range: "A1:E18", scale: 1, format: "png" });
await fs.writeFile(path.join(outputDir, "service_descriptions_simple_preview.png"), new Uint8Array(await preview.arrayBuffer()));

await fs.mkdir(outputDir, { recursive: true });
const xlsx = await SpreadsheetFile.exportXlsx(workbook);
await xlsx.save(outputPath);
console.log(outputPath);
