import fs from "node:fs/promises";
import path from "node:path";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const outputDir = path.resolve("outputs/access_rules_v1");
const outputPath = path.join(outputDir, "BOB_Access_Rules_v1.xlsx");

function writeSheet(workbook, name, title, headers, rows, tableName) {
  const sheet = workbook.worksheets.add(name);
  sheet.showGridLines = false;
  const colCount = headers.length;
  const endCol = String.fromCharCode("A".charCodeAt(0) + colCount - 1);
  sheet.mergeCells(`A1:${endCol}1`);
  sheet.getRange("A1").values = [[title]];
  sheet.getRangeByIndexes(2, 0, rows.length + 1, colCount).values = [headers].concat(rows);
  sheet.getRange("A1").format = {
    fill: "#2D1B3D",
    font: { bold: true, color: "#FFFFFF", size: 15 },
    wrapText: true
  };
  sheet.getRangeByIndexes(2, 0, 1, colCount).format = {
    fill: "#4B2E83",
    font: { bold: true, color: "#FFFFFF" },
    wrapText: true
  };
  sheet.getRangeByIndexes(3, 0, Math.max(rows.length, 1), colCount).format = {
    wrapText: true,
    verticalAlignment: "top"
  };
  sheet.getRangeByIndexes(2, 0, rows.length + 1, colCount).format.borders = {
    preset: "all",
    style: "thin",
    color: "#D8D3E0"
  };
  sheet.freezePanes.freezeRows(3);
  sheet.tables.add(`A3:${endCol}${rows.length + 3}`, true, tableName);
  const used = sheet.getUsedRange();
  used.format.autofitColumns();
  used.format.autofitRows();
}

const decisions = [
  ["Agency Director does not imply AgencySubmitter", "Agency Director is a business/title role. Plan submission requires the AgencySubmitter app role."],
  ["Chief of Staff can edit all roles", "Chief of Staff can maintain full agency/entity role assignments."],
  ["AgencySubmitter assignment is restricted", "Only Agency Head, Agency Director, Chief of Staff, or admin roles can assign another AgencySubmitter."],
  ["Measure review authority", "Only SystemAdmin and OPIReviewer can approve/validate, return, and provide feedback on measures."],
  ["Plan finalization", "Only SystemAdmin can finalize a plan and promote payload data into database records."],
  ["Plan approval chain", "Deputy Mayor and CA Office approvals are required before final SystemAdmin approval, but SystemAdmin can override with a note."],
  ["Returned review notes", "Deputy Mayor or CA Office notes keep the plan in review rather than immediately returning it to the agency."],
  ["BBMR comments", "BBMRReviewer can view and comment only; comments are visible to all."],
  ["AgencyViewer access", "AgencyViewer can view reviewer notes, scores, feedback, and download/export content."],
  ["Entity access", "Mayoral and quasi agency access is assigned by parent agency plus entity link."]
];

const appRoleRules = [
  ["SystemAdmin", "all_data", "all", "all", "yes", "yes", "yes", "yes", "yes", "yes", "SystemAdmin can override missing Deputy Mayor/CA approvals with a required note."],
  ["OPIReviewer", "all_data", "performance reviewing; measures", "review notes; measure review", "no", "yes", "yes", "no", "no", "no", "Can approve/validate and return measures."],
  ["BBMRReviewer", "all_data", "plans; reviewer feedback", "comments only", "no", "no", "no", "no", "no", "no", "View/comment only; comments visible to all."],
  ["CAOffice", "all_plans", "all plans", "approval notes", "no", "no", "no", "yes", "no", "yes", "Approval interface should filter by agency, pillar, and status."],
  ["DeputyMayor", "portfolio", "plans aligned to portfolio", "approval notes", "no", "no", "no", "yes", "no", "yes", "Portfolio comes from agency.deputy_mayor_pillar. Independents sit with CA Office."],
  ["AgencySubmitter", "agency_or_entity", "assigned plan; notes; scores; downloads", "planning content; role edits", "yes", "yes", "no", "no", "no", "yes", "Cannot assign another AgencySubmitter unless paired with Agency Head, Agency Director, Chief of Staff, or admin."],
  ["AgencyWriter", "agency_or_entity", "assigned plan; notes; scores; downloads", "planning content; measures", "no", "yes", "no", "no", "no", "no", "Can submit measures."],
  ["AgencyApprover", "agency_or_entity", "assigned plan; notes; scores; downloads", "planning content", "policy TBD", "yes", "no", "no", "no", "no", "Kept as schema role; confirm whether still needed."],
  ["AgencyViewer", "agency_or_entity", "assigned plan; notes; scores; downloads", "none", "no", "no", "no", "no", "no", "no", "Read-only plus download/export."]
];

const agencyRoleRules = [
  ["Agency Head", "Can edit roles; can assign AgencySubmitter; can submit only if app_role includes AgencySubmitter."],
  ["Agency Director", "Can edit roles; can assign AgencySubmitter; does not automatically submit plans."],
  ["Chief of Staff", "Can edit all roles; can assign AgencySubmitter."],
  ["Performance Lead", "Can submit measures; no plan submit unless app_role includes AgencySubmitter."],
  ["Program Staff", "Can contribute when paired with write permissions; no plan submit by title alone."],
  ["Fiscal Officer", "Can contribute when paired with write permissions; no plan submit by title alone."],
  ["Fiscal Staff", "Can contribute when paired with write permissions; no plan submit by title alone."],
  ["Agency Staff", "Read-only by default unless paired with a write app role."],
  ["Admin", "Admin title can assign AgencySubmitter; exact scope should come from app_role and assignments."]
];

const scopeRules = [
  ["all_data", "All agencies, entities, services, plans, and measures.", "SystemAdmin, OPIReviewer, BBMRReviewer"],
  ["all_plans", "All plan submissions, filterable by agency, pillar, and status.", "CAOffice"],
  ["portfolio", "Plans aligned to assigned Deputy Mayor portfolio.", "DeputyMayor via reference.agency.deputy_mayor_pillar"],
  ["agency_or_entity", "Assigned parent agency and, where applicable, assigned entity link.", "Agency roles and reference.plan_entity/reference.plan_entity_service"],
  ["service", "Assigned service-level contribution scope.", "access.user_agency_access.service_id"]
];

const workflowRules = [
  ["Draft", "Submit plan", "AgencySubmitter", "Submitted", "Locks agency editing while in review."],
  ["Submitted/Under Review", "Deputy Mayor approval", "DeputyMayor", "Still in review", "Approval/note captured; does not finalize."],
  ["Submitted/Under Review", "CA Office approval", "CAOffice", "Still in review", "Approval/note captured; does not finalize."],
  ["Submitted/Under Review", "Return/comment", "DeputyMayor or CAOffice or BBMRReviewer", "Still in review", "Notes remain visible to agency and reviewers."],
  ["Ready for final approval", "Finalize plan", "SystemAdmin", "Approved/Published", "Promotes payload to database and clears payload."],
  ["Ready for final approval", "Override finalization", "SystemAdmin", "Approved/Published", "Allowed with required override note."],
  ["Measure pending approval", "Approve/validate measure", "SystemAdmin or OPIReviewer", "Validated", "Agency can see status and feedback."],
  ["Measure pending approval", "Return measure", "SystemAdmin or OPIReviewer", "Returned", "Feedback required and visible to agency."]
];

await fs.mkdir(outputDir, { recursive: true });
const workbook = Workbook.create();
writeSheet(workbook, "Decisions", "Access Decisions v1", ["decision", "rule"], decisions, "DecisionsTable");
writeSheet(workbook, "App Role Rules", "App Role Rules v1", ["app_role", "scope", "view", "write", "submit_plan", "submit_measure", "review_measure", "approve_plan_step", "finalize_plan", "edit_roles", "notes"], appRoleRules, "AppRoleRulesTable");
writeSheet(workbook, "Agency Role Rules", "Agency Role Rules v1", ["agency_role", "rule"], agencyRoleRules, "AgencyRoleRulesTable");
writeSheet(workbook, "Scope Rules", "Scope Rules v1", ["scope", "meaning", "source"], scopeRules, "ScopeRulesTable");
writeSheet(workbook, "Workflow Rules", "Workflow Rules v1", ["from_state", "action", "allowed_role", "to_state", "notes"], workflowRules, "WorkflowRulesTable");

const output = await SpreadsheetFile.exportXlsx(workbook);
await output.save(outputPath);
console.log(outputPath);
