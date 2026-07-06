import fs from "node:fs/promises";
import path from "node:path";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const outputDir = path.resolve("outputs/role_permission_matrix");
const outputPath = path.join(outputDir, "Beacon_Role_Permission_Matrix.xlsx");
const userEntityPath = path.resolve("tmp/user_entity_access.json");

const today = "2026-07-01";
const userEntityRows = JSON.parse(await fs.readFile(userEntityPath, "utf8"));

const permissions = [
  ["view.home", "Navigation", "View", "View agency home dashboard and plan status."],
  ["view.action_plan", "Navigation", "View", "View Mayor's Action Plan reference content."],
  ["view.team_roles", "Navigation", "View", "View team and role assignments."],
  ["manage.team_roles", "Administration", "Manage", "Change agency team role assignments."],
  ["view.history_status", "Planning", "View", "View plan history, status, exports, and review feedback."],
  ["submit.plan", "Planning", "Submit", "Submit the current agency/entity performance plan for review."],
  ["view.overview", "Planning", "View", "View agency overview and vision."],
  ["edit.overview", "Planning", "Write", "Edit agency overview, vision, and website."],
  ["view.goals", "Planning", "View", "View goals, initiatives, KPIs, and Action Plan alignment."],
  ["edit.goals", "Planning", "Write", "Edit goals, initiatives, KPIs, and Action Plan alignment."],
  ["view.services", "Planning", "View", "View services and service metrics."],
  ["edit.services", "Planning", "Write", "Edit service descriptions and service metric selections."],
  ["view.measures", "Performance Planning", "View", "View the measure library, including inactive/deprecated measures."],
  ["edit.measures", "Performance Planning", "Write", "Create or edit measures in draft."],
  ["submit.measures", "Performance Planning", "Submit", "Submit a measure for OPI/System Admin review."],
  ["view.risks", "Planning", "View", "View risk register."],
  ["edit.risks", "Planning", "Write", "Create and edit risk register entries."],
  ["review.plan", "Performance Reviewing", "Review", "Review submitted performance plans."],
  ["return.plan", "Performance Reviewing", "Return", "Return a plan to the agency with feedback."],
  ["approve.plan", "Performance Reviewing", "Approve", "Approve a reviewed performance plan."],
  ["publish.plan", "Performance Reviewing", "Publish", "Publish an approved performance plan."],
  ["review.measures", "Performance Reviewing", "Review", "Review submitted measures."],
  ["return.measures", "Performance Reviewing", "Return", "Return a measure to the agency with feedback."],
  ["approve.measures", "Performance Reviewing", "Approve", "Approve/validate a submitted measure."],
  ["manage.citywide_measure_scope", "System Admin", "Manage", "Set citywide/agency/service scope fields on measures."],
  ["manage.action_plan_measure_alignment", "System Admin", "Manage", "Assign Action Plan pillar/goal alignment on measures."],
  ["view.all_data", "Scope", "View", "Can see all agencies, entities, services, plans, and measures."],
  ["view.assigned_agency", "Scope", "View", "Can see assigned agency plans and records."],
  ["view.assigned_entity", "Scope", "View", "Can see assigned mayoral service or quasi-agency plan records."],
  ["view.assigned_service", "Scope", "View", "Can see assigned service records."],
  ["view.assigned_pillar", "Scope", "View", "Can see records aligned to assigned Action Plan pillar."]
];

const appRoleRows = [
  {
    role: "SystemAdmin",
    scopeType: "all_data",
    defaultScopeSource: "access.user_role.app_role",
    view: "all sections; all agencies; all entities",
    write: "all planning fields; all measure fields; seed/reference maintenance as needed",
    submit: "plans; measures",
    review: "plans; measures",
    returnAction: "plans; measures",
    approve: "plans; measures; citywide measure scope; Action Plan measure alignment",
    notes: "For app dev team and system administration.",
    keys: ["view.all_data", "manage.team_roles", "submit.plan", "review.plan", "return.plan", "approve.plan", "publish.plan", "review.measures", "return.measures", "approve.measures", "manage.citywide_measure_scope", "manage.action_plan_measure_alignment"]
  },
  {
    role: "OPIReviewer",
    scopeType: "all_data",
    defaultScopeSource: "access.user_role.app_role",
    view: "all sections; all agencies; all entities",
    write: "review notes; measure review fields",
    submit: "",
    review: "plans; measures",
    returnAction: "plans; measures",
    approve: "measures, if delegated by policy",
    notes: "Use for performance plan and measure review. Final approval authority should be confirmed.",
    keys: ["view.all_data", "review.plan", "return.plan", "review.measures", "return.measures", "approve.measures"]
  },
  {
    role: "BBMRReviewer",
    scopeType: "all_data",
    defaultScopeSource: "access.user_role.app_role",
    view: "all performance plans; all measures; budget proposal areas later",
    write: "review notes; budget proposal edits later",
    submit: "",
    review: "plans",
    returnAction: "plans",
    approve: "",
    notes: "For review and viewing performance plans; budget proposal workflow later.",
    keys: ["view.all_data", "review.plan", "return.plan"]
  },
  {
    role: "CAOffice",
    scopeType: "all_data",
    defaultScopeSource: "access.user_role.app_role",
    view: "all sections; all agencies; all entities",
    write: "review notes; review edits",
    submit: "",
    review: "plans",
    returnAction: "plans",
    approve: "plans",
    notes: "For Chief Administrative Officer review.",
    keys: ["view.all_data", "review.plan", "return.plan", "approve.plan"]
  },
  {
    role: "DeputyMayor",
    scopeType: "pillar",
    defaultScopeSource: "access.user_role.pillar_id",
    view: "assigned Action Plan pillar and related agency/entity submissions",
    write: "review notes; review edits for assigned pillar",
    submit: "",
    review: "plans",
    returnAction: "plans",
    approve: "plans for assigned pillar, if delegated by policy",
    notes: "Scope is assigned pillar rather than a single agency.",
    keys: ["view.assigned_pillar", "review.plan", "return.plan", "approve.plan"]
  },
  {
    role: "AgencySubmitter",
    scopeType: "agency or entity",
    defaultScopeSource: "access.user_role.agency_id plus access.user_agency_access.service_id/entity mapping",
    view: "assigned agency/entity planning workspace",
    write: "overview; goals; services where applicable; measures; risks",
    submit: "current plan; measures",
    review: "",
    returnAction: "",
    approve: "internal agency signoff only; not system approval",
    notes: "Leadership role. For mayoral services/quasi agencies, scope should resolve through plan entity/service mapping.",
    keys: ["view.assigned_agency", "view.assigned_entity", "view.history_status", "edit.overview", "edit.goals", "edit.services", "edit.measures", "submit.measures", "edit.risks", "submit.plan"]
  },
  {
    role: "AgencyWriter",
    scopeType: "agency or entity",
    defaultScopeSource: "access.user_role.agency_id plus access.user_agency_access.service_id/entity mapping",
    view: "assigned agency/entity planning workspace",
    write: "overview; goals; services where applicable; measures; risks",
    submit: "",
    review: "",
    returnAction: "",
    approve: "",
    notes: "Data entry role. Cannot submit the plan unless paired with AgencySubmitter.",
    keys: ["view.assigned_agency", "view.assigned_entity", "view.history_status", "edit.overview", "edit.goals", "edit.services", "edit.measures", "submit.measures", "edit.risks"]
  },
  {
    role: "AgencyApprover",
    scopeType: "agency or entity",
    defaultScopeSource: "access.user_role.agency_id plus access.user_agency_access.service_id/entity mapping",
    view: "assigned agency/entity planning workspace",
    write: "review/edit assigned agency plan before submission",
    submit: "current plan, if retained as an active role",
    review: "",
    returnAction: "",
    approve: "internal agency approval only",
    notes: "Currently present in schema; confirm whether to keep separate from AgencySubmitter.",
    keys: ["view.assigned_agency", "view.assigned_entity", "view.history_status", "edit.overview", "edit.goals", "edit.services", "edit.measures", "edit.risks", "submit.plan"]
  },
  {
    role: "AgencyViewer",
    scopeType: "agency or entity",
    defaultScopeSource: "access.user_role.agency_id plus access.user_agency_access.service_id/entity mapping",
    view: "assigned agency/entity planning workspace",
    write: "",
    submit: "",
    review: "",
    returnAction: "",
    approve: "",
    notes: "Read-only assigned agency/entity role.",
    keys: ["view.assigned_agency", "view.assigned_entity", "view.history_status", "view.overview", "view.goals", "view.services", "view.measures", "view.risks"]
  }
];

const agencyRoleRows = [
  ["Agency Head", "agency or entity", "Executive owner/final agency signoff.", "all assigned planning sections", "all assigned planning sections", "plan; measures", "agency team only", "Usually maps to AgencySubmitter."],
  ["Agency Director", "agency or entity", "Department/bureau leader; can manage agency team roles in prototype.", "all assigned planning sections", "all assigned planning sections", "policy decision", "agency team only", "Added as a distinct homepage path."],
  ["Chief of Staff", "agency or entity", "Coordination lead.", "all assigned planning sections", "all assigned planning sections", "", "", "Often paired with AgencyWriter."],
  ["Fiscal Officer", "agency or entity", "Budget/fiscal lead.", "plan status; services; measures; risks; budget areas later", "services; measures; risks; budget areas later", "", "", ""],
  ["Fiscal Staff", "agency or entity", "Budget/fiscal support.", "services; measures; risks; budget areas later", "services; measures; risks; budget areas later", "", "", ""],
  ["Performance Lead", "agency or entity", "Performance measure and reporting lead.", "overview; goals; services; measures; risks", "goals; services; measures; risks", "measures", "", "Map performance metric updates here."],
  ["Program Staff", "service", "Program/service subject matter contributor.", "assigned service and related measures", "assigned service descriptions; assigned measures; risks", "measures, if policy allows", "", ""],
  ["Agency Staff", "agency or service", "General read-only or limited contributor.", "assigned workspace", "none by default", "", "", "Defaults to ReadOnly unless paired with an app role."],
  ["Admin", "all_data or assigned agency", "Administrative support role.", "assigned admin scope", "assigned admin scope", "policy decision", "policy decision", "Clarify whether this is agency-local admin or system admin support."]
];

const scopeRows = [
  ["all_data", "No agency/entity/service restriction.", "access.user_role.app_role IN SystemAdmin, OPIReviewer, BBMRReviewer, CAOffice", "System/admin reviewing sections."],
  ["pillar", "Records aligned to one assigned Action Plan pillar.", "access.user_role.pillar_id", "Deputy Mayor review."],
  ["agency", "Records where planning.agency_plan.agency_id matches assignment.", "access.user_role.agency_id and access.user_agency_access.agency_id", "Regular agency planning."],
  ["service", "Records where service_id matches assignment.", "access.user_agency_access.service_id", "Program staff or service-level contributors."],
  ["entity", "Records where planning.agency_plan.entity_id matches resolved plan entity.", "reference.plan_entity + reference.plan_entity_service; future explicit access.entity_id recommended", "Mayoral services and quasi agencies with own plans."]
];

const programmaticRows = [
  ["SystemAdmin", "app_role", "all_data", "all", "all", "true", "true", "true", "true", "true", "true"],
  ["OPIReviewer", "app_role", "all_data", "performance_reviewing; performance_planning_read", "review_notes; measure_review", "false", "true", "true", "conditional", "false", "false"],
  ["BBMRReviewer", "app_role", "all_data", "performance_reviewing; performance_planning_read", "review_notes; budget_later", "false", "true", "true", "false", "false", "false"],
  ["CAOffice", "app_role", "all_data", "performance_reviewing; performance_planning_read", "review_notes", "false", "true", "true", "true", "false", "false"],
  ["DeputyMayor", "app_role", "pillar", "assigned_pillar_review; performance_planning_read", "review_notes", "false", "true", "true", "conditional", "false", "false"],
  ["AgencySubmitter", "app_role", "agency_or_entity", "assigned_workspace", "overview; goals; services_if_applicable; measures; risks", "true", "false", "false", "false", "false", "false"],
  ["AgencyWriter", "app_role", "agency_or_entity", "assigned_workspace", "overview; goals; services_if_applicable; measures; risks", "false", "false", "false", "false", "false", "false"],
  ["AgencyApprover", "app_role", "agency_or_entity", "assigned_workspace", "overview; goals; services_if_applicable; measures; risks", "conditional", "false", "false", "false", "false", "false"],
  ["AgencyViewer", "app_role", "agency_or_entity", "assigned_workspace", "none", "false", "false", "false", "false", "false", "false"]
];

function matrixFromObjects(rows, columns) {
  return [columns.map((c) => c.label)].concat(
    rows.map((row) => columns.map((c) => {
      const value = row[c.key];
      if (Array.isArray(value)) return value.join(", ");
      return value ?? "";
    }))
  );
}

function writeSheet(workbook, name, title, subtitle, headers, rows, tableName) {
  const sheet = workbook.worksheets.add(name);
  sheet.showGridLines = false;
  const colCount = headers.length;
  const endCol = String.fromCharCode("A".charCodeAt(0) + colCount - 1);
  sheet.mergeCells(`A1:${endCol}1`);
  sheet.mergeCells(`A2:${endCol}2`);
  sheet.getRange("A1").values = [[title]];
  sheet.getRange("A2").values = [[subtitle]];
  sheet.getRangeByIndexes(3, 0, rows.length + 1, colCount).values = [headers].concat(rows);
  sheet.getRangeByIndexes(0, 0, 1, colCount).format = {
    fill: "#2D1B3D",
    font: { bold: true, color: "#FFFFFF", size: 15 },
    wrapText: true
  };
  sheet.getRangeByIndexes(1, 0, 1, colCount).format = {
    fill: "#F3EEF7",
    font: { color: "#374151", size: 10 },
    wrapText: true
  };
  sheet.getRangeByIndexes(3, 0, 1, colCount).format = {
    fill: "#4B2E83",
    font: { bold: true, color: "#FFFFFF" },
    wrapText: true
  };
  sheet.getRangeByIndexes(4, 0, Math.max(rows.length, 1), colCount).format = {
    wrapText: true,
    verticalAlignment: "top"
  };
  sheet.getRangeByIndexes(3, 0, rows.length + 1, colCount).format.borders = {
    preset: "all",
    style: "thin",
    color: "#D8D3E0"
  };
  sheet.freezePanes.freezeRows(4);
  sheet.tables.add(`A4:${endCol}${rows.length + 4}`, true, tableName);
  const used = sheet.getUsedRange();
  used.format.autofitColumns();
  used.format.autofitRows();
  return sheet;
}

await fs.mkdir(outputDir, { recursive: true });

const workbook = Workbook.create();

writeSheet(
  workbook,
  "Read Me",
  "Beacon Role Permission Matrix",
  `Working policy matrix generated ${today}. This is intended to communicate access logic before the app fully enforces Entra-backed roles.`,
  ["Topic", "Detail"],
  [
    ["Important caveat", "I am treating this as a proposed working matrix based on the roles and schema currently in the app. Please verify policy choices before enforcement."],
    ["Programmatic model", "Use app_role for cross-agency capability, agency_role for agency business function, and scope_type/scope_id for the data boundary."],
    ["Entity support", "Entity access source rows are pulled from User_Roles (1).xlsx, tab DH_USERLIST With Entities. Use scope_type and scope_label to distinguish regular agency assignments from plan entities."],
    ["Multiselect convention", "Cells with multiple capabilities use semicolon-delimited values so they can be parsed into arrays later."],
    ["Recommended enforcement order", "1. Resolve user roles. 2. Resolve scope. 3. Compute section visibility. 4. Compute allowed actions. 5. Apply record-level filters."]
  ],
  "ReadMeTable"
);

writeSheet(
  workbook,
  "Permission Catalog",
  "Permission Catalog",
  "Stable permission keys that can become code constants or policy records.",
  ["permission_key", "section", "action", "description"],
  permissions,
  "PermissionCatalogTable"
);

writeSheet(
  workbook,
  "App Roles",
  "App Role Matrix",
  "App roles determine capability and broad workspace access. Scope columns determine which records the role can touch.",
  ["app_role", "scope_type", "default_scope_source", "view", "write", "submit", "review", "return", "approve", "notes", "permission_keys"],
  matrixFromObjects(appRoleRows, [
    { key: "role", label: "app_role" },
    { key: "scopeType", label: "scope_type" },
    { key: "defaultScopeSource", label: "default_scope_source" },
    { key: "view", label: "view" },
    { key: "write", label: "write" },
    { key: "submit", label: "submit" },
    { key: "review", label: "review" },
    { key: "returnAction", label: "return" },
    { key: "approve", label: "approve" },
    { key: "notes", label: "notes" },
    { key: "keys", label: "permission_keys" }
  ]).slice(1),
  "AppRolesTable"
);

writeSheet(
  workbook,
  "Agency Roles",
  "Agency Role Matrix",
  "Agency roles describe the person's business role within an agency/entity. They should be combined with app_role permissions.",
  ["agency_role", "scope_type", "purpose", "view", "write", "submit", "manage_roles", "notes"],
  agencyRoleRows,
  "AgencyRolesTable"
);

writeSheet(
  workbook,
  "Scope Rules",
  "Scope Rules",
  "Record-level access should be resolved separately from capability. This keeps regular agencies, mayoral services, and quasi agencies clean.",
  ["scope_type", "meaning", "likely_source", "use_case"],
  scopeRows,
  "ScopeRulesTable"
);

writeSheet(
  workbook,
  "Programmatic Rules",
  "Programmatic Rules",
  "Boolean and semicolon-delimited columns designed for direct translation into role policy code.",
  ["role", "role_source", "scope_type", "can_view_sections", "can_edit_sections", "can_submit_plan", "can_review", "can_return", "can_approve", "can_manage_team", "can_manage_admin_measure_fields"],
  programmaticRows,
  "ProgrammaticRulesTable"
);

writeSheet(
  workbook,
  "Entity Access Source",
  "Entity Access Source",
  "Rows extracted from User_Roles (1).xlsx / DH_USERLIST With Entities. This is the clearest current source for user-to-entity scope.",
  [
    "assignment_id",
    "user_email",
    "app_role",
    "agency_id",
    "agency_name",
    "entity_id",
    "entity_name",
    "scope_type",
    "scope_label",
    "budget_access",
    "adaptive_planning",
    "performance_plan_access",
    "assigned_by"
  ],
  userEntityRows.map((row) => [
    row.assignment_id,
    row.user_email,
    row.app_role,
    row.agency_id,
    row.agency_name,
    row.entity_id,
    row.entity_name,
    row.scope_type,
    row.scope_label,
    row.budget_access,
    row.adaptive_planning,
    row.performance_plan_access,
    row.assigned_by
  ]),
  "EntityAccessSourceTable"
);

const inspect = await workbook.inspect({
  kind: "sheet,table",
  maxChars: 4000,
  tableMaxRows: 4,
  tableMaxCols: 6
});
console.log(inspect.ndjson);

const output = await SpreadsheetFile.exportXlsx(workbook);
await output.save(outputPath);
console.log(outputPath);
