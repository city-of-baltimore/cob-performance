-- Generated from CivicAlign_DummyData.xlsx for the target namespaced schema.
-- Run database/schema/target_schema.sql before this file.
BEGIN;

-- PILLAR -> reference.pillar
INSERT INTO reference.pillar ("pillar_id", "pillar_name", "pillar_lead", "sort_order", "updated_at")
VALUES
    (1, 'Enhancing Public Safety', 'VACANT — Deputy Mayor, Public Safety', 1, '2026-01-01'),
    (2, 'Prioritizing Youth, Older Adults, and Vulnerable Communities', 'Dr. Letitia Dzirasa — Deputy Mayor, Health & Human Services', 2, '2026-01-01'),
    (3, 'Clean, Healthy, and Sustainable Communities', 'Khalil Zaied — Deputy Mayor, Operations', 3, '2026-01-01'),
    (4, 'Equitable Economic Development', 'Calvin Young — Deputy Mayor, Community & Economic Development', 4, '2026-01-01'),
    (5, 'Responsible Stewardship of City Resources', 'Faith Leach — City Administrator', 5, '2026-01-01'),
    (6, 'Modernizing Public Infrastructure', 'Khalil Zaied — Deputy Mayor, Operations', 6, '2026-01-01')
ON CONFLICT ("pillar_id") DO UPDATE SET
    "pillar_name" = EXCLUDED."pillar_name", "pillar_lead" = EXCLUDED."pillar_lead", "sort_order" = EXCLUDED."sort_order", "updated_at" = EXCLUDED."updated_at";
SELECT setval(
    pg_get_serial_sequence('reference.pillar', 'pillar_id'),
    COALESCE((SELECT MAX("pillar_id") FROM reference.pillar), 1),
    (SELECT COUNT(*) > 0 FROM reference.pillar)
);

-- PILLAR_GOAL -> reference.pillar_goal
INSERT INTO reference.pillar_goal ("pillar_goal_id", "pillar_id", "goal_code", "goal_title", "goal_lead", "sort_order")
VALUES
    (2, 1, '1.2', 'Disrupt Violent Networks and Reduce Access to Illegal Firearms', 'Samuel Johnson', 1),
    (3, 1, '1.3', 'Build a Culture of Accountability and Deliver Effective, Equitable Public Safety', 'Samuel Johnson', 2),
    (8, 3, '3.2', 'Improve Resident Health', 'Dr. Letitia Dzirasa', 1),
    (9, 3, '3.3', 'Improve Neighborhood Livability Through Clean Streets & Green Spaces', 'Khalil Zaied', 2),
    (10, 3, '3.4', 'Accelerate Transition to Sustainability and Zero Waste', 'Khalil Zaied', 3),
    (13, 4, '4.3', 'Build Workforce Development Systems That Connect Residents to Quality Jobs', 'Calvin Young', 1),
    (14, 5, '5.1', 'Maintain Strong Fiscal Health Through Disciplined Budget Management', 'Faith Leach', 1),
    (15, 5, '5.2', 'Make the City of Baltimore an Employer of Choice', 'Faith Leach', 2),
    (19, 6, '6.1', 'Maintain Safe, Functional, and Efficient City Facilities', 'Khalil Zaied', 1),
    (20, 6, '6.2', 'Expand and Modernize Transportation Infrastructure', 'Khalil Zaied', 2)
ON CONFLICT ("pillar_goal_id") DO UPDATE SET
    "pillar_id" = EXCLUDED."pillar_id", "goal_code" = EXCLUDED."goal_code", "goal_title" = EXCLUDED."goal_title", "goal_lead" = EXCLUDED."goal_lead", "sort_order" = EXCLUDED."sort_order";
SELECT setval(
    pg_get_serial_sequence('reference.pillar_goal', 'pillar_goal_id'),
    COALESCE((SELECT MAX("pillar_goal_id") FROM reference.pillar_goal), 1),
    (SELECT COUNT(*) > 0 FROM reference.pillar_goal)
);

-- AGENCY -> reference.agency
INSERT INTO reference.agency ("agency_id", "agency_name", "public_name", "deputy_mayor_pillar", "is_quasi", "active")
VALUES
    ('AGC2600', 'Department of General Services', NULL, 'Faith Leach — City Administrator', false, true),
    ('AGC4346', 'Mayor''s Office of Neighborhood Safety and Engagement', NULL, 'VACANT — Deputy Mayor, Public Safety', false, true),
    ('AGC2700', 'Baltimore City Health Department', NULL, 'Dr. Letitia Dzirasa — Deputy Mayor, Health & Human Services', false, true),
    ('AGC7000', 'Department of Transportation', NULL, 'Khalil Zaied — Deputy Mayor, Operations', false, true),
    ('AGC5900', 'Baltimore Police Department', NULL, 'VACANT — Deputy Mayor, Public Safety', false, true),
    ('AGC2500', 'Baltimore City Fire Department', NULL, 'VACANT — Deputy Mayor, Public Safety', false, true),
    ('AGC3100', 'Housing and Community Development', NULL, 'Calvin Young — Deputy Mayor, Community & Economic Development', false, true),
    ('AGC5700', 'Department of Planning', NULL, 'Calvin Young — Deputy Mayor, Community & Economic Development', false, true),
    ('AGC4301', 'Mayoralty', NULL, 'Mayor''s Office — multiple portfolios', false, true),
    ('AGC4361', 'Convention Complex', 'Baltimore Development Corporation / Baltimore Convention Center', 'Calvin Young — Deputy Mayor, Community & Economic Development', true, true),
    ('AGC1200', 'Comptroller', NULL, 'Independent — Elected Comptroller', false, true)
ON CONFLICT ("agency_id") DO UPDATE SET
    "agency_name" = EXCLUDED."agency_name", "public_name" = EXCLUDED."public_name", "deputy_mayor_pillar" = EXCLUDED."deputy_mayor_pillar", "is_quasi" = EXCLUDED."is_quasi", "active" = EXCLUDED."active";
-- reference.agency.agency_id is text; no identity sequence to reset.

-- SERVICE -> reference.service
INSERT INTO reference.service ("service_id", "service_name", "agency_id", "service_type", "service_description", "active")
VALUES
    ('SRV0189', 'Fleet Management', 'AGC2600', 'Performance', 'Acquisition, maintenance, and disposal of the City''s vehicle fleet.', true),
    ('SRV0731', 'Facilities Management', 'AGC2600', 'Performance', 'Maintenance and operations of City-owned buildings and facilities.', true),
    ('SRV0924', 'Violence Prevention', 'AGC4346', 'Performance', 'Group Violence Reduction Strategy, Safe Streets, and community violence intervention.', true),
    ('SRV0925', 'Victim Services', 'AGC4346', 'Performance', 'Direct support and advocacy for victims of violence and crime.', true),
    ('SRV0300', 'Communicable Disease Prevention and Control', 'AGC2700', 'Performance', 'Testing, treatment, and outbreak response for communicable diseases.', true),
    ('SRV0670', 'Traffic Signal and Streetlight Maintenance', 'AGC7000', 'Performance', 'Installation and maintenance of traffic signals and streetlights.', true),
    ('SRV0600', 'Administration - Fire', 'AGC2500', 'Administrative', 'Administrative and executive direction for the Fire Department.', true),
    ('SRV0749', 'Property Acquisition, Disposition and Asset Management', 'AGC3100', 'Performance', 'Acquisition and disposition of vacant and city-owned property.', true),
    ('SRV0570', 'Comprehensive Planning', 'AGC5700', 'Performance', 'Citywide land use and comprehensive planning services.', true),
    ('SRV0855', 'Convention Center', 'AGC4361', 'Performance', 'Operations of the Baltimore Convention Center.', true),
    ('SRV0750', 'Housing Rehabilitation Services', 'AGC3100', 'Performance', 'Rehabilitation and lead hazard reduction for City housing stock.', true),
    ('SRV0810', 'Real Estate Development', 'AGC3100', 'Performance', 'Strategic redevelopment of vacant and underutilized properties.', true),
    ('SRV0903', 'Office of Performance and Innovation', 'AGC4301', 'Performance', 'Citywide performance management, budget analysis, and data infrastructure.', true),
    ('SRV0904', 'Office of Immigrant and Multicultural Affairs', 'AGC4301', 'Performance', 'Services and advocacy for Baltimore''s immigrant communities.', true),
    ('SRV0500', 'Patrol Operations', 'AGC5900', 'Performance', 'Community patrol and emergency response operations.', true),
    ('SRV0610', 'Fire Suppression and Emergency Response', 'AGC2500', 'Performance', 'Fire suppression, rescue, and emergency medical response.', true),
    ('SRV0815', 'Live Baltimore', 'AGC3100', 'Performance', 'Marketing and resident attraction/retention programming for Baltimore neighborhoods.', true),
    ('SRV0130', 'Executive Direction and Control - Comptroller', 'AGC1200', 'Administrative', 'Administrative oversight for the Office of the Comptroller.', true)
ON CONFLICT ("service_id") DO UPDATE SET
    "service_name" = EXCLUDED."service_name", "agency_id" = EXCLUDED."agency_id", "service_type" = EXCLUDED."service_type", "service_description" = EXCLUDED."service_description", "active" = EXCLUDED."active";
-- reference.service.service_id is text; no identity sequence to reset.

-- COST_CENTER -> reference.cost_center
INSERT INTO reference.cost_center ("cost_center_id", "cost_center_name", "service_id", "agency_id", "active")
VALUES
    ('CCA000189', 'Fleet Management - Central Garage', 'SRV0189', 'AGC2600', true),
    ('CCA000731', 'Facilities Management - Downtown Campus', 'SRV0731', 'AGC2600', true),
    ('CCA000924', 'Violence Prevention - GVRS Operations', 'SRV0924', 'AGC4346', true),
    ('CCA000925', 'Victim Services - Visitation Center', 'SRV0925', 'AGC4346', true),
    ('CCA000300', 'Communicable Disease - Clinical Services', 'SRV0300', 'AGC2700', true),
    ('CCA000670', 'Traffic Signals - Field Operations', 'SRV0670', 'AGC7000', true),
    ('CCA000600', 'Fire Administration - HQ', 'SRV0600', 'AGC2500', true),
    ('CCA000749', 'Property Acquisition - Real Property Division', 'SRV0749', 'AGC3100', true),
    ('CCA000570', 'Comprehensive Planning - Land Use Division', 'SRV0570', 'AGC5700', true),
    ('CCA000855', 'Convention Center - Operations', 'SRV0855', 'AGC4361', true)
ON CONFLICT ("cost_center_id") DO UPDATE SET
    "cost_center_name" = EXCLUDED."cost_center_name", "service_id" = EXCLUDED."service_id", "agency_id" = EXCLUDED."agency_id", "active" = EXCLUDED."active";
-- reference.cost_center.cost_center_id is text; no identity sequence to reset.

-- PLAN_ENTITY -> reference.plan_entity
INSERT INTO reference.plan_entity ("entity_id", "parent_agency_id", "public_name", "entity_type", "has_own_plan", "active")
VALUES
    (1, 'AGC3100', 'Baltimore Development Corporation', 'QuasiAgency', true, true),
    (2, 'AGC4361', 'Baltimore Convention Center', 'QuasiAgency', true, true),
    (3, 'AGC4301', 'Mayor''s Office of Performance and Innovation', 'MayoraltyOffice', true, true),
    (4, 'AGC4301', 'Mayor''s Office of Immigrant and Multicultural Affairs', 'MayoraltyOffice', true, true),
    (5, 'AGC4301', 'Mayor''s Office of LGBTQ Affairs', 'MayoraltyOffice', true, true),
    (6, 'AGC4301', 'Mayor''s Office of Older Adult Affairs and Advocacy', 'MayoraltyOffice', true, true),
    (7, 'AGC4301', 'Mayor''s Office of African American Male Engagement', 'MayoraltyOffice', true, true),
    (8, 'AGC4301', 'Mayor''s Office of Infrastructure Development', 'MayoraltyOffice', true, true),
    (9, 'AGC3100', 'Live Baltimore', 'QuasiAgency', true, true),
    (10, 'AGC4301', 'Mayor''s Office of Art, Culture, and Entertainment', 'MayoraltyOffice', true, true)
ON CONFLICT ("entity_id") DO UPDATE SET
    "parent_agency_id" = EXCLUDED."parent_agency_id", "public_name" = EXCLUDED."public_name", "entity_type" = EXCLUDED."entity_type", "has_own_plan" = EXCLUDED."has_own_plan", "active" = EXCLUDED."active";
SELECT setval(
    pg_get_serial_sequence('reference.plan_entity', 'entity_id'),
    COALESCE((SELECT MAX("entity_id") FROM reference.plan_entity), 1),
    (SELECT COUNT(*) > 0 FROM reference.plan_entity)
);

-- PLAN_ENTITY_SERVICE -> reference.plan_entity_service
INSERT INTO reference.plan_entity_service ("pes_id", "entity_id", "service_id", "is_primary")
VALUES
    (1, 1, 'SRV0749', true),
    (2, 1, 'SRV0750', false),
    (3, 1, 'SRV0810', false),
    (4, 2, 'SRV0855', true),
    (5, 3, 'SRV0903', true),
    (6, 4, 'SRV0904', true),
    (7, 9, 'SRV0815', true),
    (8, 5, 'SRV0904', false),
    (9, 6, 'SRV0903', false),
    (10, 10, 'SRV0815', false)
ON CONFLICT ("pes_id") DO UPDATE SET
    "entity_id" = EXCLUDED."entity_id", "service_id" = EXCLUDED."service_id", "is_primary" = EXCLUDED."is_primary";
SELECT setval(
    pg_get_serial_sequence('reference.plan_entity_service', 'pes_id'),
    COALESCE((SELECT MAX("pes_id") FROM reference.plan_entity_service), 1),
    (SELECT COUNT(*) > 0 FROM reference.plan_entity_service)
);

-- USER -> access."user"
INSERT INTO access."user" ("user_id", "email", "full_name", "phone", "auth_type", "password_hash", "active", "created_at")
VALUES
    (1, 'babila.lima@baltimorecity.gov', 'Babila Lima', '410-555-0101', 'Email', NULL, true, '2025-09-01'),
    (2, 'james.trimarco@baltimorecity.gov', 'James Trimarco', '410-555-0102', 'MicrosoftAD', NULL, true, '2025-09-01'),
    (3, 'happy.iguare@baltimorecity.gov', 'Happy Iguare', '410-555-0103', 'MicrosoftAD', NULL, true, '2025-09-01'),
    (4, 'stefanie.mavronis@baltimorecity.gov', 'Stefanie Mavronis', '410-555-0104', 'MicrosoftAD', NULL, true, '2025-09-01'),
    (5, 'joseph.muhlhausen@baltimorecity.gov', 'Joseph Muhlhausen', '410-555-0105', 'MicrosoftAD', NULL, true, '2025-09-01'),
    (6, 'maria.chen@baltimorecity.gov', 'Maria Chen', '410-555-0106', 'MicrosoftAD', NULL, true, '2025-09-01'),
    (7, 'letitia.dzirasa@baltimorecity.gov', 'Dr. Letitia Dzirasa', '410-555-0107', 'MicrosoftAD', NULL, true, '2025-09-01'),
    (8, 'khalil.zaied@baltimorecity.gov', 'Khalil Zaied', '410-555-0108', 'MicrosoftAD', NULL, true, '2025-09-01'),
    (9, 'faith.leach@baltimorecity.gov', 'Faith Leach', '410-555-0109', 'MicrosoftAD', NULL, true, '2025-09-01'),
    (10, 'sam.okafor@baltimorecity.gov', 'Sam Okafor', '410-555-0110', 'Email', NULL, true, '2025-09-01')
ON CONFLICT ("user_id") DO UPDATE SET
    "email" = EXCLUDED."email", "full_name" = EXCLUDED."full_name", "phone" = EXCLUDED."phone", "auth_type" = EXCLUDED."auth_type", "password_hash" = EXCLUDED."password_hash", "active" = EXCLUDED."active", "created_at" = EXCLUDED."created_at";
SELECT setval(
    pg_get_serial_sequence('access."user"', 'user_id'),
    COALESCE((SELECT MAX("user_id") FROM access."user"), 1),
    (SELECT COUNT(*) > 0 FROM access."user")
);

-- USER_ROLE -> access.user_role
INSERT INTO access.user_role ("user_role_id", "user_id", "app_role", "agency_id", "pillar_id", "granted_at", "budget_access", "adaptive_planning", "performance_plan_access", "quasi")
VALUES
    (1, 1, 'AgencySubmitter', 'AGC2600', NULL, '2025-09-01', true, true, true, false),
    (2, 2, 'AgencySubmitter', 'AGC2600', NULL, '2025-09-01', true, true, true, false),
    (3, 3, 'AgencyApprover', 'AGC2600', NULL, '2025-09-01', true, true, true, false),
    (4, 4, 'AgencyApprover', 'AGC4346', NULL, '2025-09-01', true, true, true, false),
    (5, 5, 'AgencySubmitter', 'AGC4346', NULL, '2025-09-01', true, false, true, false),
    (6, 6, 'OPIReviewer', NULL, NULL, '2025-09-01', true, true, true, false),
    (7, 7, 'DeputyMayor', NULL, 2, '2025-09-01', true, true, true, false),
    (8, 8, 'DeputyMayor', NULL, 6, '2025-09-01', true, true, true, false),
    (9, 9, 'CAOffice', NULL, NULL, '2025-09-01', true, true, true, false),
    (10, 10, 'BBMRReviewer', NULL, NULL, '2025-09-01', true, true, true, false)
ON CONFLICT ("user_role_id") DO UPDATE SET
    "user_id" = EXCLUDED."user_id", "app_role" = EXCLUDED."app_role", "agency_id" = EXCLUDED."agency_id", "pillar_id" = EXCLUDED."pillar_id", "granted_at" = EXCLUDED."granted_at", "budget_access" = EXCLUDED."budget_access", "adaptive_planning" = EXCLUDED."adaptive_planning", "performance_plan_access" = EXCLUDED."performance_plan_access", "quasi" = EXCLUDED."quasi";
SELECT setval(
    pg_get_serial_sequence('access.user_role', 'user_role_id'),
    COALESCE((SELECT MAX("user_role_id") FROM access.user_role), 1),
    (SELECT COUNT(*) > 0 FROM access.user_role)
);

-- USER_FUNCTIONS -> access.user_agency_access
INSERT INTO access.user_agency_access ("access_id", "user_id", "agency_id", "service_id", "agency_role")
VALUES
    (1, 1, 'AGC2600', 'SRV0189', 'Performance Lead'),
    (2, 1, 'AGC2600', NULL, 'Performance Lead'),
    (3, 2, 'AGC2600', 'SRV0189', 'Fiscal Officer'),
    (4, 3, 'AGC2600', 'SRV0731', 'Agency Staff'),
    (5, 4, 'AGC4346', NULL, 'Agency Director'),
    (6, 5, 'AGC4346', 'SRV0924', 'Performance Lead'),
    (7, 6, 'AGC2600', NULL, 'Admin'),
    (8, 6, 'AGC4346', NULL, 'Admin'),
    (9, 9, 'AGC2600', NULL, 'Admin'),
    (10, 10, 'AGC4346', NULL, 'Admin')
ON CONFLICT ("access_id") DO UPDATE SET
    "user_id" = EXCLUDED."user_id", "agency_id" = EXCLUDED."agency_id", "service_id" = EXCLUDED."service_id", "agency_role" = EXCLUDED."agency_role";
SELECT setval(
    pg_get_serial_sequence('access.user_agency_access', 'access_id'),
    COALESCE((SELECT MAX("access_id") FROM access.user_agency_access), 1),
    (SELECT COUNT(*) > 0 FROM access.user_agency_access)
);

-- PLAN_CYCLE -> planning.plan_cycle
INSERT INTO planning.plan_cycle ("cycle_id", "fiscal_year", "summer_open", "summer_close", "fall_open", "fall_close", "cycle_status", "created_by")
VALUES
    (1, 2024, '2023-06-01', '2023-08-31', '2023-09-15', '2023-11-15', 'Complete', 9),
    (2, 2025, '2024-06-01', '2024-08-31', '2024-09-15', '2024-11-15', 'Complete', 9),
    (3, 2026, '2025-06-01', '2025-08-31', '2025-09-15', '2025-11-15', 'Complete', 9),
    (4, 2027, '2026-06-01', '2026-08-31', '2026-09-15', '2026-11-15', 'FallOpen', 9),
    (5, 2028, '2027-06-01', '2027-08-31', NULL, NULL, 'Upcoming', 9),
    (6, 2029, '2028-06-01', '2028-08-31', NULL, NULL, 'Upcoming', 9)
ON CONFLICT ("cycle_id") DO UPDATE SET
    "fiscal_year" = EXCLUDED."fiscal_year", "summer_open" = EXCLUDED."summer_open", "summer_close" = EXCLUDED."summer_close", "fall_open" = EXCLUDED."fall_open", "fall_close" = EXCLUDED."fall_close", "cycle_status" = EXCLUDED."cycle_status", "created_by" = EXCLUDED."created_by";
SELECT setval(
    pg_get_serial_sequence('planning.plan_cycle', 'cycle_id'),
    COALESCE((SELECT MAX("cycle_id") FROM planning.plan_cycle), 1),
    (SELECT COUNT(*) > 0 FROM planning.plan_cycle)
);

-- AGENCY_PLAN -> planning.agency_plan
INSERT INTO planning.agency_plan ("plan_id", "agency_id", "entity_id", "cycle_id", "plan_status", "budget_status", "version", "assigned_reviewer", "submitted_at", "approved_at", "created_at", "updated_at")
VALUES
    (1, 'AGC2600', NULL, 4, 'UnderReview', 'Draft', 2, 6, '2026-06-05', NULL, '2026-06-01', '2026-06-16'),
    (2, 'AGC4346', NULL, 4, 'Approved', 'Submitted', 3, 6, '2026-06-08', '2026-06-22', '2026-06-01', '2026-06-22'),
    (3, 'AGC2700', NULL, 4, 'Draft', 'Locked', 1, NULL, NULL, NULL, '2026-06-01', '2026-06-01'),
    (4, 'AGC7000', NULL, 4, 'Returned', 'Locked', 2, 6, '2026-06-12', '2026-06-12', '2026-06-01', '2026-06-25'),
    (5, 'AGC2600', NULL, 3, 'Published', 'Approved', 5, 6, '2025-06-04', '2025-06-28', '2025-06-01', '2025-07-10'),
    (6, NULL, 1, 4, 'Submitted', 'Locked', 1, 10, '2026-06-12', NULL, '2026-06-01', '2026-06-15'),
    (7, NULL, 3, 4, 'DirectorSignOff', 'Locked', 1, NULL, NULL, NULL, '2026-06-01', '2026-06-14'),
    (8, 'AGC5900', NULL, 4, 'DeputyMayorReview', 'Locked', 2, 6, '2026-06-14', NULL, '2026-06-01', '2026-06-17'),
    (9, 'AGC3100', NULL, 4, 'CAReview', 'Draft', 3, 6, '2026-06-09', '2026-06-26', '2026-06-01', '2026-06-26'),
    (10, 'AGC2500', NULL, 2, 'Published', 'Approved', 4, 6, '2025-05-01', '2025-05-15', '2025-05-01', '2025-05-15')
ON CONFLICT ("plan_id") DO UPDATE SET
    "agency_id" = EXCLUDED."agency_id", "entity_id" = EXCLUDED."entity_id", "cycle_id" = EXCLUDED."cycle_id", "plan_status" = EXCLUDED."plan_status", "budget_status" = EXCLUDED."budget_status", "version" = EXCLUDED."version", "assigned_reviewer" = EXCLUDED."assigned_reviewer", "submitted_at" = EXCLUDED."submitted_at", "approved_at" = EXCLUDED."approved_at", "created_at" = EXCLUDED."created_at", "updated_at" = EXCLUDED."updated_at";
SELECT setval(
    pg_get_serial_sequence('planning.agency_plan', 'plan_id'),
    COALESCE((SELECT MAX("plan_id") FROM planning.agency_plan), 1),
    (SELECT COUNT(*) > 0 FROM planning.agency_plan)
);

-- PLAN_HEADER -> performance.plan_header
INSERT INTO performance.plan_header ("header_id", "plan_id", "primary_contact_name", "primary_contact_email", "plan_date", "version_label")
VALUES
    (1, 1, 'Babila Lima', 'babila.lima@baltimorecity.gov', '2026-06-01', 'v1.0'),
    (2, 2, 'Stefanie Mavronis', 'stefanie.mavronis@baltimorecity.gov', '2026-06-08', 'v1.3'),
    (3, 3, 'Maria Chen', 'maria.chen@baltimorecity.gov', '2026-06-01', 'v1.0'),
    (4, 4, 'James Trimarco', 'james.trimarco@baltimorecity.gov', '2026-06-12', 'v1.1'),
    (5, 5, 'Happy Iguare', 'happy.iguare@baltimorecity.gov', '2025-06-04', 'v2.0'),
    (6, 6, 'Sam Okafor', 'sam.okafor@baltimorecity.gov', '2026-06-12', 'v1.0'),
    (7, 7, 'Maria Chen', 'maria.chen@baltimorecity.gov', '2026-06-01', 'v1.0'),
    (8, 8, 'Joseph Muhlhausen', 'joseph.muhlhausen@baltimorecity.gov', '2026-06-14', 'v1.1'),
    (9, 9, 'Happy Iguare', 'happy.iguare@baltimorecity.gov', '2026-06-09', 'v1.2'),
    (10, 10, 'James Trimarco', 'james.trimarco@baltimorecity.gov', '2025-05-01', 'v1.4')
ON CONFLICT ("header_id") DO UPDATE SET
    "plan_id" = EXCLUDED."plan_id", "primary_contact_name" = EXCLUDED."primary_contact_name", "primary_contact_email" = EXCLUDED."primary_contact_email", "plan_date" = EXCLUDED."plan_date", "version_label" = EXCLUDED."version_label";
SELECT setval(
    pg_get_serial_sequence('performance.plan_header', 'header_id'),
    COALESCE((SELECT MAX("header_id") FROM performance.plan_header), 1),
    (SELECT COUNT(*) > 0 FROM performance.plan_header)
);

-- OVERVIEW_VISION -> performance.overview_vision
INSERT INTO performance.overview_vision ("mv_id", "plan_id", "overview", "vision", "web_address")
VALUES
    (1, 1, 'To deliver results for City partners through services and solutions that are timely, cost-effective, and sustainable.', 'To be a leader in delivering expertise, efficiency, and service excellence.', 'https://generalservices.baltimorecity.gov'),
    (2, 2, 'To implement Baltimore''s public health approach to violence through prevention, intervention, and victim support.', 'A Baltimore where every neighborhood is safe from violence and every resident has access to support and opportunity.', 'https://monse.baltimorecity.gov'),
    (3, 3, 'To protect and promote the health of all Baltimore City residents.', 'A healthy Baltimore where every resident can thrive regardless of zip code or income.', 'https://health.baltimorecity.gov'),
    (4, 4, 'To plan, build, and maintain a safe, accessible, and sustainable transportation network.', 'A connected Baltimore where every resident can move safely and efficiently.', 'https://transportation.baltimorecity.gov'),
    (5, 5, 'To deliver results for City partners through services and solutions that are timely, cost-effective, and sustainable.', 'To be a leader in delivering expertise, efficiency, and service excellence.', 'https://generalservices.baltimorecity.gov'),
    (6, 6, 'To redevelop vacant and underutilized properties into thriving community assets.', 'A Baltimore where every neighborhood has the investment it needs to grow.', 'https://www.baltimoredevelopment.com'),
    (7, 7, 'To strengthen citywide performance management, budget transparency, and data-informed decision-making.', 'A city government that uses data and evidence to deliver better outcomes for every resident.', 'https://mayor.baltimorecity.gov/bcstat'),
    (8, 8, 'To protect the lives and property of Baltimore City residents through community-centered policing.', 'A Baltimore where every neighborhood is safe and every resident trusts their police department.', 'https://www.baltimorepolice.org'),
    (9, 9, 'To expand access to safe, affordable housing for all Baltimore City residents.', 'A Baltimore where every resident has a safe, stable, and affordable place to call home.', 'https://dhcd.baltimorecity.gov'),
    (10, 10, 'To protect lives and property through rapid, professional emergency response.', 'A Baltimore where every resident is protected by a modern, well-equipped Fire Department.', 'https://fire.baltimorecity.gov')
ON CONFLICT ("mv_id") DO UPDATE SET
    "plan_id" = EXCLUDED."plan_id", "overview" = EXCLUDED."overview", "vision" = EXCLUDED."vision", "web_address" = EXCLUDED."web_address";
SELECT setval(
    pg_get_serial_sequence('performance.overview_vision', 'mv_id'),
    COALESCE((SELECT MAX("mv_id") FROM performance.overview_vision), 1),
    (SELECT COUNT(*) > 0 FROM performance.overview_vision)
);

-- PLAN_PILLAR_ALIGNMENT -> performance.plan_pillar_alignment
INSERT INTO performance.plan_pillar_alignment ("alignment_id", "plan_id", "pillar_id")
VALUES
    (1, 1, 5),
    (2, 1, 6),
    (3, 2, 1),
    (4, 2, 3),
    (5, 3, 3),
    (6, 4, 6),
    (7, 6, 4),
    (8, 7, 5),
    (9, 8, 1),
    (10, 9, 4)
ON CONFLICT ("alignment_id") DO UPDATE SET
    "plan_id" = EXCLUDED."plan_id", "pillar_id" = EXCLUDED."pillar_id";
SELECT setval(
    pg_get_serial_sequence('performance.plan_pillar_alignment', 'alignment_id'),
    COALESCE((SELECT MAX("alignment_id") FROM performance.plan_pillar_alignment), 1),
    (SELECT COUNT(*) > 0 FROM performance.plan_pillar_alignment)
);

-- AGENCY_GOAL -> performance.agency_goal
INSERT INTO performance.agency_goal ("agency_goal_id", "plan_id", "title", "description", "sort_order", "created_at")
VALUES
    (1, 1, 'Continue effective long-term asset management by rightsizing our vehicle fleet and building portfolio, reducing avoidable costs.', 'Asset management goal covering Fleet, Facilities, Energy, and Capital Projects.', 1, '2026-06-01'),
    (2, 2, 'Sustain Effectiveness of Violence Intervention Models: Sustain a 15% reduction in Homicides and Shootings Year Over Year.', 'Citywide violence reduction through GVRS and Safe Streets.', 1, '2026-06-08'),
    (3, 3, 'Reduce communicable disease transmission through expanded testing and vaccination access.', 'Increase resident access to testing, treatment, and vaccination services.', 1, '2026-06-01'),
    (4, 4, 'Improve traffic signal reliability and reduce response time to outages.', 'Modernize and maintain the City''s traffic signal network.', 1, '2026-06-12'),
    (5, 5, 'Reduce fleet downtime through preventive maintenance.', 'FY26 fleet asset management goal — approved baseline year.', 1, '2025-06-04'),
    (6, 6, 'Accelerate redevelopment of vacant and abandoned properties.', 'BDC''s core redevelopment pipeline goal.', 1, '2026-06-12'),
    (7, 7, 'Strengthen citywide performance management and data-informed decision-making.', 'OPI''s flagship goal for the FY27 cycle.', 1, '2026-06-01'),
    (8, 8, 'Reduce violent crime through community policing strategies.', 'Expand foot patrol and community trust-building citywide.', 1, '2026-06-14'),
    (9, 9, 'Expand affordable housing production and preservation.', 'Increase the supply of affordable and preserved housing units.', 1, '2026-06-09'),
    (10, 10, 'Improve emergency response times across all districts.', 'FY25 historical goal, later amended to add a new KPI.', 1, '2025-05-01'),
    (11, 1, 'Reduce preventable facility downtime by 15% by June 2027.', 'Improve the reliability and availability of facilities used by City agencies and residents.', 2, '2026-06-01'),
    (12, 1, 'Reduce energy use in City-owned facilities by 10% from the FY2025 baseline by June 2027.', 'Lower operating costs and emissions through targeted efficiency improvements.', 3, '2026-06-01')
ON CONFLICT ("agency_goal_id") DO UPDATE SET
    "plan_id" = EXCLUDED."plan_id", "title" = EXCLUDED."title", "description" = EXCLUDED."description", "sort_order" = EXCLUDED."sort_order", "created_at" = EXCLUDED."created_at";
SELECT setval(
    pg_get_serial_sequence('performance.agency_goal', 'agency_goal_id'),
    COALESCE((SELECT MAX("agency_goal_id") FROM performance.agency_goal), 1),
    (SELECT COUNT(*) > 0 FROM performance.agency_goal)
);

-- AGENCY_GOAL_PILLAR_LINK -> performance.agency_goal_pillar_link
INSERT INTO performance.agency_goal_pillar_link ("link_id", "agency_goal_id", "pillar_goal_id", "link_type", "alignment_narrative", "created_date")
VALUES
    (1, 1, 19, 'Primary', NULL, '2026-06-01'),
    (2, 2, 2, 'Primary', NULL, '2026-06-08'),
    (3, 3, 8, 'Primary', NULL, '2026-06-01'),
    (4, 4, 20, 'Primary', NULL, '2026-06-12'),
    (5, 5, 14, 'Primary', NULL, '2025-06-04'),
    (6, 6, 13, 'Primary', NULL, '2026-06-12'),
    (7, 7, 14, 'Secondary', NULL, '2026-06-01'),
    (8, 8, 3, 'Primary', NULL, '2026-06-14'),
    (9, 9, 13, 'Primary', NULL, '2026-06-09'),
    (10, 10, 19, 'Primary', NULL, '2025-05-01'),
    (11, 11, 19, 'Primary', 'Reliable facilities directly support safe, functional, and efficient City operations.', '2026-06-01')
ON CONFLICT ("link_id") DO UPDATE SET
    "agency_goal_id" = EXCLUDED."agency_goal_id", "pillar_goal_id" = EXCLUDED."pillar_goal_id", "link_type" = EXCLUDED."link_type", "alignment_narrative" = EXCLUDED."alignment_narrative", "created_date" = EXCLUDED."created_date";
SELECT setval(
    pg_get_serial_sequence('performance.agency_goal_pillar_link', 'link_id'),
    COALESCE((SELECT MAX("link_id") FROM performance.agency_goal_pillar_link), 1),
    (SELECT COUNT(*) > 0 FROM performance.agency_goal_pillar_link)
);

-- INITIATIVE -> performance.initiative
INSERT INTO performance.initiative ("initiative_id", "title", "description", "start_date", "end_date", "status", "created_date", "last_updated")
VALUES
    (1, 'Expand preventative maintenance program', 'Expand the preventative maintenance program across all building systems.', '2026-07-01', '2027-06-30', 'Planned', '2026-06-01', '2026-06-01'),
    (2, 'Scale GVRS to additional districts', 'Scale the Group Violence Reduction Strategy to at least two more districts.', '2026-07-01', '2027-06-30', 'Planned', '2026-06-08', '2026-06-08'),
    (3, 'Expand mobile vaccination clinics', 'Increase the number of mobile vaccination and testing sites citywide.', '2026-07-01', '2027-06-30', 'Planned', '2026-06-01', '2026-06-01'),
    (4, 'Replace aging traffic signal controllers', 'Replace end-of-life signal controllers at high-priority intersections.', '2026-07-01', '2027-06-30', 'Planned', '2026-06-12', '2026-06-12'),
    (5, 'Implement telematics fleet tracking', 'Deploy telematics across the remaining fleet vehicles.', '2025-07-01', '2026-06-30', 'Completed', '2025-06-04', '2026-06-01'),
    (6, 'Redevelop Poppleton Phase 3', 'Continue strategic redevelopment of the Poppleton corridor.', '2026-07-01', '2028-06-30', 'InProgress', '2026-06-12', '2026-06-12'),
    (7, 'Launch citywide KPI dashboard', 'Build and launch a public-facing citywide performance dashboard.', '2026-07-01', '2027-06-30', 'Planned', '2026-06-01', '2026-06-01'),
    (8, 'Expand community policing foot patrols', 'Add foot patrol coverage in three additional neighborhoods.', '2026-07-01', '2027-06-30', 'Planned', '2026-06-14', '2026-06-14'),
    (9, 'Increase Housing Trust Fund allocations', 'Increase annual allocations to the Affordable Housing Trust Fund.', '2026-07-01', '2027-06-30', 'Planned', '2026-06-09', '2026-06-09'),
    (10, 'Modernize fire station dispatch system', 'Replace the legacy CAD dispatch system citywide.', '2025-01-01', '2026-12-31', 'InProgress', '2025-05-01', '2025-05-12'),
    (11, 'Launch condition-based facility maintenance schedules', 'Implement condition-based maintenance schedules for the twenty highest-use City facilities.', '2026-07-01', '2027-06-30', 'Planned', '2026-06-01', '2026-06-01'),
    (12, 'Complete priority facility energy upgrades', 'Complete energy audits and implement priority efficiency upgrades in City-owned facilities.', '2026-07-01', '2027-06-30', 'Planned', '2026-06-01', '2026-06-01')
ON CONFLICT ("initiative_id") DO UPDATE SET
    "title" = EXCLUDED."title", "description" = EXCLUDED."description", "start_date" = EXCLUDED."start_date", "end_date" = EXCLUDED."end_date", "status" = EXCLUDED."status", "created_date" = EXCLUDED."created_date", "last_updated" = EXCLUDED."last_updated";
SELECT setval(
    pg_get_serial_sequence('performance.initiative', 'initiative_id'),
    COALESCE((SELECT MAX("initiative_id") FROM performance.initiative), 1),
    (SELECT COUNT(*) > 0 FROM performance.initiative)
);

-- AGENCY_GOAL_INITIATIVE_LINK -> performance.agency_goal_initiative_link
INSERT INTO performance.agency_goal_initiative_link ("link_id", "agency_goal_id", "initiative_id", "link_type", "created_date")
VALUES
    (1, 1, 1, 'Primary', '2026-06-01'),
    (2, 2, 2, 'Primary', '2026-06-01'),
    (3, 3, 3, 'Primary', '2026-06-01'),
    (4, 4, 4, 'Primary', '2026-06-01'),
    (5, 5, 5, 'Primary', '2026-06-01'),
    (6, 6, 6, 'Primary', '2026-06-01'),
    (7, 7, 7, 'Primary', '2026-06-01'),
    (8, 8, 8, 'Primary', '2026-06-01'),
    (9, 9, 9, 'Primary', '2026-06-01'),
    (10, 10, 10, 'Primary', '2026-06-01'),
    (11, 11, 11, 'Primary', '2026-06-01'),
    (12, 12, 12, 'Primary', '2026-06-01')
ON CONFLICT ("link_id") DO UPDATE SET
    "agency_goal_id" = EXCLUDED."agency_goal_id", "initiative_id" = EXCLUDED."initiative_id", "link_type" = EXCLUDED."link_type", "created_date" = EXCLUDED."created_date";
SELECT setval(
    pg_get_serial_sequence('performance.agency_goal_initiative_link', 'link_id'),
    COALESCE((SELECT MAX("link_id") FROM performance.agency_goal_initiative_link), 1),
    (SELECT COUNT(*) > 0 FROM performance.agency_goal_initiative_link)
);

-- PERFORMANCE_MEASURE -> performance.performance_measure
INSERT INTO performance.performance_measure ("measure_id", "agency_id", "initial_cycle", "title", "measure_type", "description", "data_source", "data_owner", "data_owner_role", "update_frequency", "formula", "desired_direction", "baseline_value", "baseline_fy", "format_type", "display_unit", "context_required", "replicability", "disaggregation", "data_location", "collection_method", "how_data_used", "why_meaningful", "proxy_measure", "improvement_notes", "change_mapping", "pillar_id", "pillar_goal_id", "is_city", "is_agency", "is_service", "validated", "created_date", "last_updated")
VALUES
    (1, 'AGC2600', 4, 'Average Age of Fleet', 'Outcome', 'Tracks the average age of vehicles in DGS''s Fleet at the beginning of each fiscal quarter.', 'FasterWeb', 'James Trimarco', 'Analyst', 'Daily', 'SUM(Age of Fleet Vehicles)/COUNT(Fleet Vehicles)', 'Decrease', 6.7, 2025, 'Decimal', 'years', NULL, true, 'By vehicle type', 'FasterWeb', 'Fleet availability viewed on FasterWeb.', 'Tracks fleet asset health.', 'Vehicle age impacts availability and maintenance cost.', NULL, NULL, 'Unchanged', 5, NULL, false, true, false, true, '2026-06-01', '2026-06-01'),
    (2, 'AGC4346', 4, 'Citywide Violence Reduction', 'Outcome', 'Sustain a 15% reduction in Homicides and Shootings Year Over Year.', 'Citistat - BPD', 'Joseph Muhlhausen', 'Chief of Data Analytics', 'Daily', '(Current Year - Previous Year)/Previous Year * 100', 'Decrease', -13.13, 2025, 'Percent', NULL, NULL, true, 'By district', 'Citistat', 'SQL query against GroupA_Crime table.', 'Tracks citywide violence trend.', 'Core outcome measure for violence prevention strategy.', NULL, NULL, 'Unchanged', 1, 2, true, true, false, true, '2026-06-08', '2026-06-08'),
    (3, 'AGC2700', 4, '% of Residents Tested for Communicable Disease Within 48 Hours of Exposure', 'Effectiveness', 'Tracks how quickly exposed residents are tested following a known exposure event.', 'Health Dept Case Management System', 'Dr. Anita Roy', 'Epidemiology Program Manager', 'Monthly', '(Tested Within 48 Hrs / Total Exposures) * 100', 'Increase', 62, 2025, 'Percent', NULL, NULL, true, 'By zip code', 'CHESS', 'Case investigators log exposure and test dates.', 'Tracks outbreak response speed.', 'Faster testing limits disease spread.', NULL, NULL, 'New', 3, 8, false, true, false, false, '2026-06-01', '2026-06-01'),
    (4, 'AGC7000', 4, 'Average Traffic Signal Outage Response Time', 'Efficiency', 'Tracks the average number of days to resolve a reported traffic signal outage.', 'Maximo Work Order System', 'Carlos Reyes', 'Signals Division Manager', 'Monthly', 'AVG(Resolution Date - Report Date)', 'Decrease', 5, 2025, 'Days', NULL, NULL, true, 'By district', 'Maximo', 'Work orders logged and closed in Maximo.', 'Tracks signal maintenance responsiveness.', 'Faster repairs reduce intersection safety risk.', NULL, NULL, 'New', 6, 20, false, true, false, false, '2026-06-12', '2026-06-12'),
    (5, 'AGC2600', 4, '% of Preventive Maintenance Completed On Time', 'Effectiveness', 'Tracks the percentage of preventive maintenance work orders completed on time.', 'Archibus', 'Happy Iguare', 'Operations Research Analyst', 'Daily', '(PMs Completed On Time / All PMs) * 100', 'Increase', 88, 2025, 'Percent', NULL, NULL, true, 'By building', 'Archibus', 'Maintenance requests viewable in Archibus.', 'Tracks facilities upkeep performance.', 'Reduces emergency repair costs.', NULL, NULL, 'Unchanged', 6, 19, false, false, true, true, '2026-06-01', '2026-06-01'),
    (6, 'AGC3100', 4, '# of Vacant Properties Redeveloped', 'Output', 'Cumulative number of vacant properties redeveloped through BDC and Housing partnerships.', 'Real Property Database', 'Devon Carter', 'Redevelopment Program Manager', 'Quarterly', 'Cumulative count of redeveloped parcels', 'Increase', 42, 2025, 'Count', NULL, NULL, true, 'By neighborhood', 'Real Property DB', 'Redevelopment closings logged manually.', 'Tracks redevelopment pipeline progress.', 'Each property returned to productive use strengthens neighborhoods.', NULL, NULL, 'Unchanged', 4, 13, false, true, false, true, '2026-06-12', '2026-06-12'),
    (7, 'AGC4301', 4, 'Citizen Engagement Score for OPI Dashboards', 'Outcome', 'Composite resident engagement score based on dashboard usage and feedback surveys.', 'Google Analytics / MS Forms', 'Maria Chen', 'OPI Reviewer', 'Quarterly', 'Composite Score', 'Increase', 7.8, 2025, 'Score', 'out of 10', NULL, true, NULL, 'Google Analytics', 'Dashboard usage and survey data combined.', 'Tracks public engagement with performance data.', 'Higher engagement reflects greater transparency impact.', NULL, NULL, 'New', 5, 14, true, true, false, false, '2026-06-01', '2026-06-01'),
    (8, 'AGC5900', 4, 'Violent Crime Rate per 1,000 Residents', 'Outcome', 'Tracks the citywide violent crime rate normalized per 1,000 residents.', 'Citistat - BPD', 'Capt. Diane Foster', 'Crime Analysis Unit', 'Monthly', '(Violent Crimes / Population) * 1000', 'Decrease', 38.4, 2025, 'Rate', 'per 1,000 residents', NULL, true, 'By district', 'Citistat', 'Incident reports aggregated monthly.', 'Tracks overall public safety trend.', 'Normalizes crime trend against population change.', NULL, NULL, 'Unchanged', 1, 2, true, true, false, true, '2026-06-14', '2026-06-14'),
    (9, 'AGC3100', 4, '% of Affordable Housing Units Preserved', 'Outcome', 'Tracks the percentage of at-risk affordable units preserved through City intervention.', 'Housing Preservation Database', 'Devon Carter', 'Redevelopment Program Manager', 'Quarterly', '(Units Preserved / Units At Risk) * 100', 'Increase', 91, 2025, 'Percent', NULL, NULL, true, 'By council district', 'Housing Preservation DB', 'Preservation actions logged by case managers.', 'Tracks housing stability outcomes.', 'Preservation is more cost-effective than new construction.', NULL, NULL, 'Unchanged', 4, 13, false, true, false, true, '2026-06-09', '2026-06-09'),
    (10, 'AGC2500', 4, 'Average Emergency Response Time (Minutes)', 'Efficiency', 'Tracks the average response time from dispatch to arrival on scene.', 'CAD Dispatch System', 'Chief Robert Hale', 'Operations Chief', 'Daily', 'AVG(Arrival Time - Dispatch Time)', 'Decrease', 6.2, 2025, 'Decimal', 'minutes', NULL, true, 'By station', 'CAD System', 'Dispatch and arrival timestamps logged automatically.', 'Tracks emergency response performance.', 'Faster response improves survival and outcome rates.', NULL, NULL, 'Unchanged', 1, 3, false, true, false, true, '2025-05-01', '2025-05-12')
ON CONFLICT ("measure_id") DO UPDATE SET
    "agency_id" = EXCLUDED."agency_id", "initial_cycle" = EXCLUDED."initial_cycle", "title" = EXCLUDED."title", "measure_type" = EXCLUDED."measure_type", "description" = EXCLUDED."description", "data_source" = EXCLUDED."data_source", "data_owner" = EXCLUDED."data_owner", "data_owner_role" = EXCLUDED."data_owner_role", "update_frequency" = EXCLUDED."update_frequency", "formula" = EXCLUDED."formula", "desired_direction" = EXCLUDED."desired_direction", "baseline_value" = EXCLUDED."baseline_value", "baseline_fy" = EXCLUDED."baseline_fy", "format_type" = EXCLUDED."format_type", "display_unit" = EXCLUDED."display_unit", "context_required" = EXCLUDED."context_required", "replicability" = EXCLUDED."replicability", "disaggregation" = EXCLUDED."disaggregation", "data_location" = EXCLUDED."data_location", "collection_method" = EXCLUDED."collection_method", "how_data_used" = EXCLUDED."how_data_used", "why_meaningful" = EXCLUDED."why_meaningful", "proxy_measure" = EXCLUDED."proxy_measure", "improvement_notes" = EXCLUDED."improvement_notes", "change_mapping" = EXCLUDED."change_mapping", "pillar_id" = EXCLUDED."pillar_id", "pillar_goal_id" = EXCLUDED."pillar_goal_id", "is_city" = EXCLUDED."is_city", "is_agency" = EXCLUDED."is_agency", "is_service" = EXCLUDED."is_service", "validated" = EXCLUDED."validated", "created_date" = EXCLUDED."created_date", "last_updated" = EXCLUDED."last_updated";
SELECT setval(
    pg_get_serial_sequence('performance.performance_measure', 'measure_id'),
    COALESCE((SELECT MAX("measure_id") FROM performance.performance_measure), 1),
    (SELECT COUNT(*) > 0 FROM performance.performance_measure)
);

-- MEASURE_ACTUALS -> performance.measure_actuals
INSERT INTO performance.measure_actuals ("actual_id", "measure_id", "fiscal_year", "q1_value", "q1_notes", "q2_value", "q2_notes", "q3_value", "q3_notes", "q4_value", "q4_notes", "annual_actual", "annual_actual_notes", "target_value", "target_value_notes", "reported_by", "created_at", "updated_at")
VALUES
    (1, 1, 2026, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 6.9, NULL, 6.5, NULL, 2, '2026-06-15', '2026-06-15'),
    (2, 2, 2026, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, -10.2, NULL, -15, NULL, 6, '2026-06-15', '2026-06-15'),
    (3, 3, 2026, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 62, NULL, 75, NULL, 6, '2026-06-15', '2026-06-15'),
    (4, 4, 2026, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 5, NULL, 3, NULL, 6, '2026-06-15', '2026-06-15'),
    (5, 5, 2026, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 88, NULL, 95, NULL, 3, '2026-06-15', '2026-06-15'),
    (6, 6, 2026, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 42, NULL, 60, NULL, 6, '2026-06-15', '2026-06-15'),
    (7, 7, 2026, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 7.8, NULL, 8.5, NULL, 6, '2026-06-15', '2026-06-15'),
    (8, 8, 2026, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 38.4, NULL, 32, NULL, 6, '2026-06-15', '2026-06-15'),
    (9, 9, 2026, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 91, NULL, 95, NULL, 6, '2026-06-15', '2026-06-15'),
    (10, 10, 2026, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 6.2, NULL, 5.5, NULL, 3, '2025-06-15', '2025-06-15'),
    (11, 1, 2022, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 7.8, NULL, 7.6, NULL, 2, '2022-06-30', '2022-06-30'),
    (12, 1, 2023, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 7.5, NULL, 7.3, NULL, 2, '2023-06-30', '2023-06-30'),
    (13, 1, 2024, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 7.3, NULL, 7.0, NULL, 2, '2024-06-30', '2024-06-30'),
    (14, 1, 2025, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 7.1, NULL, 6.8, NULL, 2, '2025-06-30', '2025-06-30'),
    (15, 5, 2022, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 72, NULL, 75, NULL, 3, '2022-06-30', '2022-06-30'),
    (16, 5, 2023, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 77, NULL, 80, NULL, 3, '2023-06-30', '2023-06-30'),
    (17, 5, 2024, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 81, NULL, 85, NULL, 3, '2024-06-30', '2024-06-30'),
    (18, 5, 2025, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 85, NULL, 90, NULL, 3, '2025-06-30', '2025-06-30')
ON CONFLICT ("actual_id") DO UPDATE SET
    "measure_id" = EXCLUDED."measure_id", "fiscal_year" = EXCLUDED."fiscal_year", "q1_value" = EXCLUDED."q1_value", "q1_notes" = EXCLUDED."q1_notes", "q2_value" = EXCLUDED."q2_value", "q2_notes" = EXCLUDED."q2_notes", "q3_value" = EXCLUDED."q3_value", "q3_notes" = EXCLUDED."q3_notes", "q4_value" = EXCLUDED."q4_value", "q4_notes" = EXCLUDED."q4_notes", "annual_actual" = EXCLUDED."annual_actual", "annual_actual_notes" = EXCLUDED."annual_actual_notes", "target_value" = EXCLUDED."target_value", "target_value_notes" = EXCLUDED."target_value_notes", "reported_by" = EXCLUDED."reported_by", "created_at" = EXCLUDED."created_at", "updated_at" = EXCLUDED."updated_at";
SELECT setval(
    pg_get_serial_sequence('performance.measure_actuals', 'actual_id'),
    COALESCE((SELECT MAX("actual_id") FROM performance.measure_actuals), 1),
    (SELECT COUNT(*) > 0 FROM performance.measure_actuals)
);

-- PM_GOAL_LINK -> performance.pm_goal_link
INSERT INTO performance.pm_goal_link ("link_id", "measure_id", "agency_goal_id")
VALUES
    (1, 1, 1),
    (2, 2, 2),
    (3, 3, 3),
    (4, 4, 4),
    (5, 6, 6),
    (6, 6, 9),
    (7, 7, 7),
    (8, 8, 8),
    (9, 9, 9),
    (10, 10, 10),
    (11, 5, 11),
    (12, 1, 12)
ON CONFLICT ("link_id") DO UPDATE SET
    "measure_id" = EXCLUDED."measure_id", "agency_goal_id" = EXCLUDED."agency_goal_id";
SELECT setval(
    pg_get_serial_sequence('performance.pm_goal_link', 'link_id'),
    COALESCE((SELECT MAX("link_id") FROM performance.pm_goal_link), 1),
    (SELECT COUNT(*) > 0 FROM performance.pm_goal_link)
);

-- PM_SERVICE_LINK -> performance.pm_service_link
INSERT INTO performance.pm_service_link ("link_id", "measure_id", "service_id")
VALUES
    (1, 1, 'SRV0189'),
    (2, 2, 'SRV0924'),
    (3, 3, 'SRV0300'),
    (4, 4, 'SRV0670'),
    (5, 5, 'SRV0731'),
    (6, 6, 'SRV0749'),
    (7, 7, 'SRV0903'),
    (8, 8, 'SRV0500'),
    (9, 9, 'SRV0750'),
    (10, 10, 'SRV0610')
ON CONFLICT ("link_id") DO UPDATE SET
    "measure_id" = EXCLUDED."measure_id", "service_id" = EXCLUDED."service_id";
SELECT setval(
    pg_get_serial_sequence('performance.pm_service_link', 'link_id'),
    COALESCE((SELECT MAX("link_id") FROM performance.pm_service_link), 1),
    (SELECT COUNT(*) > 0 FROM performance.pm_service_link)
);

-- PM_SERVICE_REASSIGNMENT -> performance.pm_service_reassignment
INSERT INTO performance.pm_service_reassignment ("reassignment_id", "measure_id", "old_service_id", "new_service_id", "cycle_id", "reason", "changed_date", "changed_by")
VALUES
    (1, 5, 'SRV0731', 'SRV0189', 4, 'Measure reclassified from Facilities to Fleet Management after governance review.', '2026-05-01', 6),
    (2, 6, NULL, 'SRV0749', 4, 'New measure — no prior service assignment.', '2026-04-01', 6),
    (3, 9, 'SRV0749', 'SRV0750', 4, 'Moved to Housing Rehabilitation Services to better reflect preservation activities.', '2026-04-15', 6),
    (4, 3, NULL, 'SRV0300', 4, 'New measure — no prior service assignment.', '2026-03-20', 6),
    (5, 1, NULL, 'SRV0189', 3, 'Initial assignment.', '2025-05-01', 2),
    (6, 8, NULL, 'SRV0500', 4, 'New measure — no prior service assignment.', '2026-04-10', 6),
    (7, 4, 'SRV0570', 'SRV0670', 4, 'Corrected service assignment — originally miscoded under Planning.', '2026-04-22', 6),
    (8, 10, 'SRV0600', 'SRV0610', 4, 'Reassigned from administrative service to the operational Fire Suppression service for accurate reporting.', '2026-05-05', 3)
ON CONFLICT ("reassignment_id") DO UPDATE SET
    "measure_id" = EXCLUDED."measure_id", "old_service_id" = EXCLUDED."old_service_id", "new_service_id" = EXCLUDED."new_service_id", "cycle_id" = EXCLUDED."cycle_id", "reason" = EXCLUDED."reason", "changed_date" = EXCLUDED."changed_date", "changed_by" = EXCLUDED."changed_by";
SELECT setval(
    pg_get_serial_sequence('performance.pm_service_reassignment', 'reassignment_id'),
    COALESCE((SELECT MAX("reassignment_id") FROM performance.pm_service_reassignment), 1),
    (SELECT COUNT(*) > 0 FROM performance.pm_service_reassignment)
);

-- PLAN_SERVICE -> performance.plan_service
INSERT INTO performance.plan_service ("plan_service_id", "plan_id", "service_id", "sort_order")
VALUES
    (1, 1, 'SRV0189', 1),
    (2, 1, 'SRV0731', 2),
    (3, 2, 'SRV0924', 1),
    (4, 2, 'SRV0925', 2),
    (5, 3, 'SRV0300', 1),
    (6, 4, 'SRV0670', 1),
    (7, 6, 'SRV0749', 1),
    (8, 6, 'SRV0750', 2),
    (9, 8, 'SRV0500', 1),
    (10, 10, 'SRV0610', 1)
ON CONFLICT ("plan_service_id") DO UPDATE SET
    "plan_id" = EXCLUDED."plan_id", "service_id" = EXCLUDED."service_id", "sort_order" = EXCLUDED."sort_order";
SELECT setval(
    pg_get_serial_sequence('performance.plan_service', 'plan_service_id'),
    COALESCE((SELECT MAX("plan_service_id") FROM performance.plan_service), 1),
    (SELECT COUNT(*) > 0 FROM performance.plan_service)
);

-- SERVICE_GOAL_LINK -> performance.service_goal_link
INSERT INTO performance.service_goal_link ("sgl_id", "plan_service_id", "agency_goal_id", "initiative_id")
VALUES
    (1, 1, 1, 1),
    (2, 2, 1, 1),
    (3, 3, 2, 2),
    (4, 4, 2, NULL),
    (5, 5, 3, 3),
    (6, 6, 4, 4),
    (7, 7, 6, 6),
    (8, 8, 6, NULL),
    (9, 9, 8, 8),
    (10, 10, 10, 10)
ON CONFLICT ("sgl_id") DO UPDATE SET
    "plan_service_id" = EXCLUDED."plan_service_id", "agency_goal_id" = EXCLUDED."agency_goal_id", "initiative_id" = EXCLUDED."initiative_id";
SELECT setval(
    pg_get_serial_sequence('performance.service_goal_link', 'sgl_id'),
    COALESCE((SELECT MAX("sgl_id") FROM performance.service_goal_link), 1),
    (SELECT COUNT(*) > 0 FROM performance.service_goal_link)
);

-- PLAN_RISK -> performance.service_risk
INSERT INTO performance.service_risk ("risk_id", "plan_id", "description")
VALUES
    (1, 1, 'Supply chain delays for replacement vehicle parts could extend fleet downtime beyond targets.'),
    (2, 2, 'GVRS expansion to new districts depends on continued coordination with BPD and the State''s Attorney''s Office.'),
    (3, 3, 'Federal funding uncertainty for communicable disease programs could affect testing capacity.'),
    (4, 4, 'Aging traffic signal infrastructure increases risk of cascading outages during peak summer heat.'),
    (5, 5, 'Vehicle replacement schedule was delayed due to FY26 supply chain disruptions.'),
    (6, 6, 'Redevelopment timelines are sensitive to private capital market conditions and interest rates.'),
    (7, 7, 'Dashboard adoption depends on agency data quality and timely reporting across all departments.'),
    (8, 8, 'Staffing shortages may limit the pace of community policing foot patrol expansion.'),
    (9, 9, 'Rising construction costs could reduce the number of affordable units financed within budget.'),
    (10, 10, 'Dispatch system modernization is contingent on a multi-year IT procurement and integration timeline.')
ON CONFLICT ("risk_id") DO UPDATE SET
    "plan_id" = EXCLUDED."plan_id", "description" = EXCLUDED."description";
SELECT setval(
    pg_get_serial_sequence('performance.service_risk', 'risk_id'),
    COALESCE((SELECT MAX("risk_id") FROM performance.service_risk), 1),
    (SELECT COUNT(*) > 0 FROM performance.service_risk)
);

-- SERVICE_FUND_AMOUNT -> budget.service_fund_amount
INSERT INTO budget.service_fund_amount ("sfa_id", "plan_service_id", "fund_id", "fy_adopted", "cls_amount", "request_amount", "positions_adopted", "positions_cls", "positions_request", "fy25_actuals", "fy26_actuals")
VALUES
    (1, 1, '1001', 1200000, 1250000, 1300000, 10, 10, 11, 1180000, 1220000),
    (2, 2, '1001', 900000, 920000, 950000, 8, 8, 8, 880000, 905000),
    (3, 3, '1001', 2500000, 2600000, 2750000, 22, 22, 24, 2450000, 2580000),
    (4, 4, 'Federal', 600000, 620000, 640000, 6, 6, 6, 590000, 615000),
    (5, 5, 'State', 1800000, 1850000, 1900000, 14, 14, 15, 1770000, 1830000),
    (6, 6, '1001', 3200000, 3300000, 3450000, 28, 28, 30, 3150000, 3260000),
    (7, 7, 'Special Revenue', 5000000, 5200000, 5500000, 12, 12, 13, 4900000, 5100000),
    (8, 8, '1001', 1400000, 1450000, 1500000, 9, 9, 10, 1380000, 1430000),
    (9, 9, '1001', 8500000, 8700000, 9000000, 65, 65, 68, 8400000, 8650000),
    (10, 10, '1001', 4100000, 4200000, 4350000, 32, 32, 34, 4050000, 4150000)
ON CONFLICT ("sfa_id") DO UPDATE SET
    "plan_service_id" = EXCLUDED."plan_service_id", "fund_id" = EXCLUDED."fund_id", "fy_adopted" = EXCLUDED."fy_adopted", "cls_amount" = EXCLUDED."cls_amount", "request_amount" = EXCLUDED."request_amount", "positions_adopted" = EXCLUDED."positions_adopted", "positions_cls" = EXCLUDED."positions_cls", "positions_request" = EXCLUDED."positions_request", "fy25_actuals" = EXCLUDED."fy25_actuals", "fy26_actuals" = EXCLUDED."fy26_actuals";
SELECT setval(
    pg_get_serial_sequence('budget.service_fund_amount', 'sfa_id'),
    COALESCE((SELECT MAX("sfa_id") FROM budget.service_fund_amount), 1),
    (SELECT COUNT(*) > 0 FROM budget.service_fund_amount)
);

-- GENERAL_FUND_CHANGE -> budget.general_fund_change
INSERT INTO budget.general_fund_change ("change_id", "plan_service_id", "object_type", "description", "dollar_change", "position_change", "service_impact", "sort_order")
VALUES
    (1, 1, 'Service Level Change', 'Add 1 mechanic position to address repair backlog.', 65000, 1, true, 1),
    (2, 2, 'Prior Year Spending', 'Annualize FY26 mid-year HVAC contract increase.', 30000, 0, false, 1),
    (3, 3, 'Transfer Positions', 'Transfer 2 outreach coordinators from grant fund to general fund.', 180000, 2, true, 1),
    (4, 4, 'Service Realignment', 'Consolidate victim services intake under a single supervisor.', -20000, -1, false, 1),
    (5, 5, 'Service Level Change', 'Expand mobile testing van operating hours.', 75000, 0, true, 1),
    (6, 6, 'Prior Year Spending', 'Annualize FY26 signal controller maintenance contract.', 100000, 0, false, 1),
    (7, 7, 'Service Level Change', 'Increase property acquisition legal services budget.', 150000, 0, true, 1),
    (8, 8, 'Transfer Positions', 'Transfer 1 rehab specialist from CDBG fund.', 85000, 1, true, 1),
    (9, 9, 'Service Level Change', 'Add 3 patrol officers for foot patrol expansion.', 270000, 3, true, 1),
    (10, 10, 'Prior Year Spending', 'Annualize FY26 dispatch software licensing increase.', 45000, 0, false, 1)
ON CONFLICT ("change_id") DO UPDATE SET
    "plan_service_id" = EXCLUDED."plan_service_id", "object_type" = EXCLUDED."object_type", "description" = EXCLUDED."description", "dollar_change" = EXCLUDED."dollar_change", "position_change" = EXCLUDED."position_change", "service_impact" = EXCLUDED."service_impact", "sort_order" = EXCLUDED."sort_order";
SELECT setval(
    pg_get_serial_sequence('budget.general_fund_change', 'change_id'),
    COALESCE((SELECT MAX("change_id") FROM budget.general_fund_change), 1),
    (SELECT COUNT(*) > 0 FROM budget.general_fund_change)
);

-- KEY_SPEND_CATEGORY -> budget.key_spend_category
INSERT INTO budget.key_spend_category ("ksc_id", "plan_service_id", "category", "amount", "description")
VALUES
    (1, 1, 'ProfessionalServices', 45000, 'Fleet telematics consulting.'),
    (2, 2, 'Consultants', 60000, 'HVAC system assessment.'),
    (3, 3, 'NOC', 25000, 'Community violence intervention partner contracts.'),
    (4, 4, 'Subcontractors', 40000, 'Victim services case management software support.'),
    (5, 5, 'ProfessionalServices', 90000, 'Mobile testing van staffing contract.'),
    (6, 6, 'Consultants', 55000, 'Traffic signal timing study.'),
    (7, 7, 'NOC', 200000, 'Environmental remediation contractors.'),
    (8, 8, 'Subcontractors', 70000, 'Lead paint abatement contractors.'),
    (9, 9, 'ProfessionalServices', 30000, 'Community policing training consultants.'),
    (10, 10, 'Consultants', 50000, 'Dispatch system integration consultant.')
ON CONFLICT ("ksc_id") DO UPDATE SET
    "plan_service_id" = EXCLUDED."plan_service_id", "category" = EXCLUDED."category", "amount" = EXCLUDED."amount", "description" = EXCLUDED."description";
SELECT setval(
    pg_get_serial_sequence('budget.key_spend_category', 'ksc_id'),
    COALESCE((SELECT MAX("ksc_id") FROM budget.key_spend_category), 1),
    (SELECT COUNT(*) > 0 FROM budget.key_spend_category)
);

-- PROPOSAL_NARRATIVE -> budget.proposal_narrative
INSERT INTO budget.proposal_narrative ("narrative_id", "plan_service_id", "major_changes", "service_impact", "position_impact", "equity_narrative", "assumed_rates_desc", "grant_award_desc")
VALUES
    (1, 1, 'Adding one mechanic position to reduce repair backlog.', false, 'Net +1 FTE.', 'No disproportionate impact identified.', '3% wage adjustment per citywide guidance.', 'N/A'),
    (2, 2, 'Annualizing a mid-year HVAC contract increase.', false, 'No position impact.', 'No disproportionate impact identified.', 'Contractor rate increase of 4%.', 'N/A'),
    (3, 3, 'Transferring 2 outreach coordinators onto general fund.', false, 'Net +1 FTE after transfer.', 'Directly supports historically disinvested districts.', 'N/A', 'N/A'),
    (4, 4, 'Consolidating victim services intake supervision.', false, 'Net -1 FTE (supervisory layer only).', 'No disproportionate impact identified.', 'N/A', 'N/A'),
    (5, 5, 'Expanding mobile testing van operating hours.', false, 'No position impact.', 'Targets historically underserved zip codes.', 'N/A', 'CDC testing grant renewal pending.'),
    (6, 6, 'Annualizing the signal controller maintenance contract.', false, 'No position impact.', 'No disproportionate impact identified.', 'Contractor rate increase of 5%.', 'N/A'),
    (7, 7, 'Increasing legal services budget for property acquisition.', false, 'No position impact.', 'Targets historically disinvested corridors.', 'Outside counsel rate increase.', 'N/A'),
    (8, 8, 'Transferring 1 rehab specialist from CDBG fund.', false, 'Net +1 FTE after transfer.', 'Directly supports lead-burdened households.', 'N/A', 'CDBG allocation confirmed.'),
    (9, 9, 'Adding 3 patrol officers for foot patrol expansion.', false, 'Net +3 FTE.', 'Targets historically over-policed and under-resourced areas.', 'N/A', 'N/A'),
    (10, 10, 'Annualizing dispatch software licensing increase.', false, 'No position impact.', 'No disproportionate impact identified.', 'Vendor licensing increase of 6%.', 'N/A')
ON CONFLICT ("narrative_id") DO UPDATE SET
    "plan_service_id" = EXCLUDED."plan_service_id", "major_changes" = EXCLUDED."major_changes", "service_impact" = EXCLUDED."service_impact", "position_impact" = EXCLUDED."position_impact", "equity_narrative" = EXCLUDED."equity_narrative", "assumed_rates_desc" = EXCLUDED."assumed_rates_desc", "grant_award_desc" = EXCLUDED."grant_award_desc";
SELECT setval(
    pg_get_serial_sequence('budget.proposal_narrative', 'narrative_id'),
    COALESCE((SELECT MAX("narrative_id") FROM budget.proposal_narrative), 1),
    (SELECT COUNT(*) > 0 FROM budget.proposal_narrative)
);

-- CLS_REQUEST -> budget.cls_request
INSERT INTO budget.cls_request ("cls_id", "plan_service_id", "request_name", "request_type", "request_amount", "one_time", "overall_summary", "justified", "completed", "amount_next_fy", "amount_2next_fy")
VALUES
    (1, 1, 'Fleet Parts Cost Increase', 'Extraordinary Inflation', 65000, false, 'Vehicle parts costs increased 8% year over year.', 'Yes', false, 67000, 69000),
    (2, 2, 'HVAC Contract Annualization', 'Cyclical', 30000, false, 'Mid-year contract signed in FY26.', 'Yes', true, 31000, 32000),
    (3, 3, 'Outreach Coordinator Fund Transfer', 'Mandated Cost', 180000, false, 'Grant funding for these positions expires at end of FY26.', 'Yes', false, 185000, 190000),
    (4, 4, 'Victim Services Software Renewal', 'Cyclical', 40000, false, 'Annual case management software renewal.', 'Yes', true, 41000, 42000),
    (5, 5, 'Mobile Testing Van Lease Increase', 'Extraordinary Inflation', 25000, false, 'Vehicle lease costs increased due to market conditions.', 'Yes', false, 26000, 27000),
    (6, 6, 'Signal Controller Maintenance Contract', 'Cyclical', 100000, false, 'Multi-year maintenance contract renewal.', 'Yes', true, 103000, 106000),
    (7, 7, 'Legal Services Rate Increase', 'Extraordinary Inflation', 50000, false, 'Outside counsel rates increased citywide.', 'Yes', false, 52000, 54000),
    (8, 8, 'Lead Abatement Contractor Increase', 'Mandated Cost', 35000, false, 'State lead abatement requirements expanded scope.', 'Yes', false, 36000, 37000),
    (9, 9, 'Patrol Equipment Replacement', 'Cyclical', 90000, true, 'Scheduled replacement of body cameras and radios.', 'Yes', true, 0, 0),
    (10, 10, 'Dispatch Software License Renewal', 'Cyclical', 45000, false, 'Annual CAD system licensing renewal.', 'Yes', true, 46000, 47000)
ON CONFLICT ("cls_id") DO UPDATE SET
    "plan_service_id" = EXCLUDED."plan_service_id", "request_name" = EXCLUDED."request_name", "request_type" = EXCLUDED."request_type", "request_amount" = EXCLUDED."request_amount", "one_time" = EXCLUDED."one_time", "overall_summary" = EXCLUDED."overall_summary", "justified" = EXCLUDED."justified", "completed" = EXCLUDED."completed", "amount_next_fy" = EXCLUDED."amount_next_fy", "amount_2next_fy" = EXCLUDED."amount_2next_fy";
SELECT setval(
    pg_get_serial_sequence('budget.cls_request', 'cls_id'),
    COALESCE((SELECT MAX("cls_id") FROM budget.cls_request), 1),
    (SELECT COUNT(*) > 0 FROM budget.cls_request)
);

-- CLS_REQUEST_LINE -> budget.cls_request_line
INSERT INTO budget.cls_request_line ("line_id", "cls_id", "object_category", "amount", "justification", "sort_order")
VALUES
    (1, 1, 'Repair Parts & Supplies', 65000, 'Based on FY26 actual parts cost trend.', 1),
    (2, 2, 'Contracted Services', 30000, 'HVAC contractor mid-year increase.', 1),
    (3, 3, 'Grants & Subsidies', 180000, 'CVI partner agency contracts.', 1),
    (4, 4, 'Software Licensing', 40000, 'Case management system renewal.', 1),
    (5, 5, 'Equipment Lease', 25000, 'Mobile van lease cost increase.', 1),
    (6, 6, 'Contracted Services', 100000, 'Signal maintenance vendor.', 1),
    (7, 7, 'Professional Services', 50000, 'Outside legal counsel.', 1),
    (8, 8, 'Contracted Services', 35000, 'Abatement contractor rate increase.', 1),
    (9, 9, 'Major Equipment', 90000, 'Patrol vehicle equipment.', 1),
    (10, 10, 'Software Licensing', 45000, 'Dispatch CAD system.', 1)
ON CONFLICT ("line_id") DO UPDATE SET
    "cls_id" = EXCLUDED."cls_id", "object_category" = EXCLUDED."object_category", "amount" = EXCLUDED."amount", "justification" = EXCLUDED."justification", "sort_order" = EXCLUDED."sort_order";
SELECT setval(
    pg_get_serial_sequence('budget.cls_request_line', 'line_id'),
    COALESCE((SELECT MAX("line_id") FROM budget.cls_request_line), 1),
    (SELECT COUNT(*) > 0 FROM budget.cls_request_line)
);

-- CLS_REQUEST_POSITION -> budget.cls_request_position
INSERT INTO budget.cls_request_position ("pos_id", "cls_id", "classification", "position_count", "estimated_salary", "justification", "explanation")
VALUES
    (1, 3, 'Community Outreach Coordinator', 2, 65000, 'Needed to support GVRS district expansion.', 'Existing vacancy backfill plus 1 new.'),
    (2, 8, 'Lead Abatement Specialist', 1, 58000, 'Needed to meet inspection volume.', 'New position.'),
    (3, 9, 'Patrol Officer', 3, 72000, 'Supports foot patrol expansion goal.', 'New positions aligned to Goal 8.'),
    (4, 1, 'Fleet Mechanic', 1, 60000, 'Reduces repair backlog.', 'New position.'),
    (5, 4, 'Victim Services Case Manager', 1, 55000, 'Supports 48-hour intake SLA.', 'New position.'),
    (6, 9, 'Patrol Equipment Technician', 1, 50000, 'Supports new patrol vehicle equipment.', 'New position.'),
    (7, 6, 'Signal Technician', 1, 62000, 'Supports increased maintenance contract oversight.', 'New position.'),
    (8, 5, 'Community Health Outreach Worker', 2, 48000, 'Supports mobile testing van expansion.', 'New positions.'),
    (9, 10, 'Dispatch System Administrator', 1, 68000, 'Supports new CAD system.', 'New position.'),
    (10, 7, 'Real Estate Paralegal', 1, 52000, 'Supports increased legal services demand.', 'New position.')
ON CONFLICT ("pos_id") DO UPDATE SET
    "cls_id" = EXCLUDED."cls_id", "classification" = EXCLUDED."classification", "position_count" = EXCLUDED."position_count", "estimated_salary" = EXCLUDED."estimated_salary", "justification" = EXCLUDED."justification", "explanation" = EXCLUDED."explanation";
SELECT setval(
    pg_get_serial_sequence('budget.cls_request_position', 'pos_id'),
    COALESCE((SELECT MAX("pos_id") FROM budget.cls_request_position), 1),
    (SELECT COUNT(*) > 0 FROM budget.cls_request_position)
);

-- ENHANCEMENT -> budget.enhancement
INSERT INTO budget.enhancement ("enhancement_id", "plan_service_id", "name", "description", "total_cost", "position_cost", "position_count", "position_classification", "q1_service_delivery", "q2_revenue", "q3_cost_savings", "q4_future_savings", "external_funds", "arpa_funded", "completed")
VALUES
    (1, 1, 'Fleet Telematics Expansion', 'Install telematics on the remaining 40% of fleet vehicles.', 250000, 0, 0, NULL, 'Enables real-time vehicle tracking and predictive maintenance.', 'N/A', 'Reduces fuel waste through route optimization.', 'Extends vehicle lifespan via early issue detection.', false, false, false),
    (2, 3, 'GVRS District Expansion', 'Add violence intervention coverage in 2 additional districts.', 450000, 380000, 4, 'Outreach Worker', 'Directly expands core violence prevention coverage.', 'N/A', 'N/A', 'Long-term reduction in violence-related city costs.', false, false, false),
    (3, 5, 'Mobile Vaccination Unit', 'Purchase a second mobile health unit.', 320000, 0, 0, NULL, 'Expands testing and vaccination access.', 'N/A', 'N/A', 'N/A', true, false, false),
    (4, 6, 'Adaptive Signal Control Pilot', 'Pilot AI-based adaptive signal timing on 10 corridors.', 500000, 0, 0, NULL, 'Improves traffic flow and safety.', 'N/A', 'Reduces fuel consumption citywide.', 'Data informs future signal investments.', true, false, false),
    (5, 7, 'Property Acquisition Fund Increase', 'Increase the acquisition fund for strategic vacant lots.', 1000000, 0, 0, NULL, 'Accelerates the redevelopment pipeline.', 'Future tax revenue from redeveloped sites.', 'N/A', 'N/A', false, false, false),
    (6, 9, 'Foot Patrol Expansion Phase 2', 'Expand foot patrol to 3 additional neighborhoods.', 810000, 720000, 9, 'Patrol Officer', 'Directly expands community policing coverage.', 'N/A', 'N/A', 'Long-term crime reduction.', false, false, false),
    (7, 10, 'Dispatch System Modernization', 'Replace the legacy CAD system citywide.', 1200000, 0, 0, NULL, 'Improves emergency response coordination.', 'N/A', 'N/A', 'Reduces system downtime risk.', false, true, false),
    (8, 2, 'Facilities Preventive Maintenance Software', 'Implement CMMS software for predictive maintenance.', 180000, 0, 0, NULL, 'Improves maintenance completion rates.', 'N/A', 'Reduces emergency repair costs.', 'Extends building system lifespan.', false, false, false),
    (9, 4, 'Victim Services Expansion - Evening Hours', 'Extend victim services intake to evening hours.', 220000, 190000, 2, 'Case Manager', 'Improves access for victims unable to attend daytime hours.', 'N/A', 'N/A', 'N/A', false, false, false),
    (10, 8, 'Lead Hazard Reduction Expansion', 'Expand lead abatement to additional housing units.', 650000, 0, 0, NULL, 'Directly supports the housing rehabilitation goal.', 'N/A', 'Avoided future health costs.', 'N/A', true, false, false)
ON CONFLICT ("enhancement_id") DO UPDATE SET
    "plan_service_id" = EXCLUDED."plan_service_id", "name" = EXCLUDED."name", "description" = EXCLUDED."description", "total_cost" = EXCLUDED."total_cost", "position_cost" = EXCLUDED."position_cost", "position_count" = EXCLUDED."position_count", "position_classification" = EXCLUDED."position_classification", "q1_service_delivery" = EXCLUDED."q1_service_delivery", "q2_revenue" = EXCLUDED."q2_revenue", "q3_cost_savings" = EXCLUDED."q3_cost_savings", "q4_future_savings" = EXCLUDED."q4_future_savings", "external_funds" = EXCLUDED."external_funds", "arpa_funded" = EXCLUDED."arpa_funded", "completed" = EXCLUDED."completed";
SELECT setval(
    pg_get_serial_sequence('budget.enhancement', 'enhancement_id'),
    COALESCE((SELECT MAX("enhancement_id") FROM budget.enhancement), 1),
    (SELECT COUNT(*) > 0 FROM budget.enhancement)
);

-- ENHANCEMENT_MEASURE -> budget.enhancement_measure
INSERT INTO budget.enhancement_measure ("em_id", "enhancement_id", "measure_title", "measure_type", "baseline_value", "target_value", "data_type", "sort_order")
VALUES
    (1, 1, 'Fleet Vehicles with Telematics Installed', 'Output', 60, 100, 'Percentage', 1),
    (2, 2, 'Districts with Active GVRS Coverage', 'Output', 4, 6, 'Count', 1),
    (3, 3, 'Residents Served by Mobile Units', 'Output', 8000, 14000, 'Count', 1),
    (4, 4, 'Average Corridor Travel Time', 'Efficiency', 12, 9, 'Number', 1),
    (5, 5, 'Vacant Lots Acquired Annually', 'Output', 18, 35, 'Count', 1),
    (6, 6, 'Neighborhoods with Foot Patrol Coverage', 'Output', 5, 8, 'Count', 1),
    (7, 7, 'Average Dispatch Processing Time', 'Efficiency', 90, 45, 'Number', 1),
    (8, 8, '% Preventive Maintenance Completed On Time', 'Effectiveness', 65.3, 85, 'Percentage', 1),
    (9, 9, 'Evening Intake Sessions Completed Monthly', 'Output', 0, 40, 'Count', 1),
    (10, 10, 'Housing Units Receiving Lead Abatement', 'Output', 120, 220, 'Count', 1)
ON CONFLICT ("em_id") DO UPDATE SET
    "enhancement_id" = EXCLUDED."enhancement_id", "measure_title" = EXCLUDED."measure_title", "measure_type" = EXCLUDED."measure_type", "baseline_value" = EXCLUDED."baseline_value", "target_value" = EXCLUDED."target_value", "data_type" = EXCLUDED."data_type", "sort_order" = EXCLUDED."sort_order";
SELECT setval(
    pg_get_serial_sequence('budget.enhancement_measure', 'em_id'),
    COALESCE((SELECT MAX("em_id") FROM budget.enhancement_measure), 1),
    (SELECT COUNT(*) > 0 FROM budget.enhancement_measure)
);

-- COA_REQUEST -> budget.coa_request
INSERT INTO budget.coa_request ("coa_id", "plan_service_id", "request_type", "new_cost_center_name", "justification", "criteria_met", "approval_status", "reviewed_by")
VALUES
    (1, 1, 'New Cost Center', 'Fleet Telematics Unit', 'Supports dedicated tracking of telematics program costs.', '["Distinct funding source","Separate program reporting need"]', 'Pending', NULL),
    (2, 3, 'New Cost Center', 'GVRS District 5 Operations', 'New district expansion requires separate cost tracking.', '["New program activity","Geographic expansion"]', 'Approved', 6),
    (3, 5, 'Rename', NULL, 'Rename cost center to reflect expanded mobile health scope.', '["Scope change"]', 'Approved', 6),
    (4, 6, 'New Cost Center', 'Adaptive Signal Pilot', 'Pilot program requires isolated cost tracking for evaluation.', '["Pilot program","Time-limited funding"]', 'Pending', NULL),
    (5, 7, 'Move Service', NULL, 'Move property acquisition accounting under Real Estate Development.', '["Organizational realignment"]', 'Denied', 6),
    (6, 9, 'New Cost Center', 'Foot Patrol Expansion Phase 2', 'Tracks dedicated foot patrol expansion spending separately.', '["New program activity"]', 'Pending', NULL),
    (7, 10, 'New Cost Center', 'Dispatch Modernization Project', 'Multi-year capital project requires dedicated cost center.', '["Capital project","Multi-year tracking need"]', 'Approved', 6),
    (8, 2, 'Rename', NULL, 'Rename cost center to reflect CMMS software implementation scope.', '["Scope change"]', 'Pending', NULL),
    (9, 4, 'New Cost Center', 'Victim Services Evening Program', 'Tracks evening hours staffing and operations separately.', '["New program activity"]', 'Approved', 6),
    (10, 8, 'New Cost Center', 'Lead Hazard Reduction Expansion', 'Tracks expanded lead abatement funding separately.', '["New program activity","Distinct funding source"]', 'Pending', NULL)
ON CONFLICT ("coa_id") DO UPDATE SET
    "plan_service_id" = EXCLUDED."plan_service_id", "request_type" = EXCLUDED."request_type", "new_cost_center_name" = EXCLUDED."new_cost_center_name", "justification" = EXCLUDED."justification", "criteria_met" = EXCLUDED."criteria_met", "approval_status" = EXCLUDED."approval_status", "reviewed_by" = EXCLUDED."reviewed_by";
SELECT setval(
    pg_get_serial_sequence('budget.coa_request', 'coa_id'),
    COALESCE((SELECT MAX("coa_id") FROM budget.coa_request), 1),
    (SELECT COUNT(*) > 0 FROM budget.coa_request)
);

-- PLAN_REVIEW -> review.plan_review
INSERT INTO review.plan_review ("review_id", "plan_id", "reviewer_id", "review_started_at", "feedback_released_at", "overall_score", "internal_notes", "review_complete")
VALUES
    (1, 1, 6, '2026-06-15', NULL, NULL, 'In progress.', false),
    (2, 2, 6, '2026-06-10', '2026-06-20', 3.6, 'Strong plan overall.', true),
    (3, 3, 6, NULL, NULL, NULL, NULL, false),
    (4, 4, 6, '2026-06-18', '2026-06-25', 2.9, 'Needs revision on goals section.', true),
    (5, 5, 6, '2025-06-10', '2025-06-20', 3.8, 'Approved without changes.', true),
    (6, 6, 10, '2026-06-12', NULL, NULL, 'Awaiting BBMR review.', false),
    (7, 7, 6, '2026-06-14', '2026-06-22', 3.2, NULL, true),
    (8, 8, 6, '2026-06-16', NULL, NULL, NULL, false),
    (9, 9, 6, '2026-06-11', '2026-06-19', 3.4, NULL, true),
    (10, 10, 6, '2025-05-01', '2025-05-10', 3, 'Reviewed post-amendment.', true)
ON CONFLICT ("review_id") DO UPDATE SET
    "plan_id" = EXCLUDED."plan_id", "reviewer_id" = EXCLUDED."reviewer_id", "review_started_at" = EXCLUDED."review_started_at", "feedback_released_at" = EXCLUDED."feedback_released_at", "overall_score" = EXCLUDED."overall_score", "internal_notes" = EXCLUDED."internal_notes", "review_complete" = EXCLUDED."review_complete";
SELECT setval(
    pg_get_serial_sequence('review.plan_review', 'review_id'),
    COALESCE((SELECT MAX("review_id") FROM review.plan_review), 1),
    (SELECT COUNT(*) > 0 FROM review.plan_review)
);

-- SECTION_SCORE -> review.section_score
INSERT INTO review.section_score ("score_id", "review_id", "section_code", "criterion_code", "score", "weight", "weighted_score", "justification")
VALUES
    (1, 2, 'S1', '1.1', 4, 5, 5, 'Header complete and accurate.'),
    (2, 2, 'S4_KPI', '4.1', 3, 12.5, 9.375, 'KPIs are well-defined but baselines incomplete for one measure.'),
    (3, 4, 'S1', '1.1', 3, 5, 3.75, 'Header mostly complete.'),
    (4, 4, 'S4_KPI', '4.1', 2, 12.5, 6.25, 'Several KPIs missing clear targets.'),
    (5, 5, 'S1', '1.1', 4, 5, 5, 'Fully complete.'),
    (6, 5, 'S5', '5.1', 4, 10, 10, 'Excellent budget narrative detail.'),
    (7, 7, 'S2', '2.1', 3, 8, 6, 'Vision statement clear, minor polish needed.'),
    (8, 7, 'S4_Metric', '4.2', 4, 12.5, 12.5, 'Service metrics fully validated.'),
    (9, 9, 'S3', '3.1', 4, 10, 10, 'Strong goal-to-pillar alignment.'),
    (10, 9, 'S6', '6.1', 3, 8, 6, 'Risk section could be more specific.')
ON CONFLICT ("score_id") DO UPDATE SET
    "review_id" = EXCLUDED."review_id", "section_code" = EXCLUDED."section_code", "criterion_code" = EXCLUDED."criterion_code", "score" = EXCLUDED."score", "weight" = EXCLUDED."weight", "weighted_score" = EXCLUDED."weighted_score", "justification" = EXCLUDED."justification";
SELECT setval(
    pg_get_serial_sequence('review.section_score', 'score_id'),
    COALESCE((SELECT MAX("score_id") FROM review.section_score), 1),
    (SELECT COUNT(*) > 0 FROM review.section_score)
);

-- SECTION_FEEDBACK -> review.section_feedback
INSERT INTO review.section_feedback ("feedback_id", "review_id", "section_code", "feedback_text", "return_required", "resolved_at")
VALUES
    (1, 2, 'OverviewVision', 'Vision statement is clear and well-aligned with citywide priorities.', false, NULL),
    (2, 2, 'Goals', 'Consider adding a secondary pillar alignment for Goal 4.', true, '2026-06-25'),
    (3, 4, 'Goals', 'Goal 4 needs a clearer SMART structure — revise target language.', true, NULL),
    (4, 4, 'Services', 'Service descriptions are thorough.', false, NULL),
    (5, 5, 'DataReporting', 'Data sources are well documented.', false, NULL),
    (6, 7, 'Header', 'Contact information is complete.', false, NULL),
    (7, 7, 'Services', 'Add baseline values for two metrics missing them.', true, '2026-06-24'),
    (8, 9, 'Goals', 'Strong alignment to Pillar 4 goals.', false, NULL),
    (9, 9, 'DataReporting', 'Clarify data collection method for the housing preservation metric.', true, '2026-06-21'),
    (10, 10, 'OverviewVision', 'Overview statement updated appropriately post-amendment.', false, NULL)
ON CONFLICT ("feedback_id") DO UPDATE SET
    "review_id" = EXCLUDED."review_id", "section_code" = EXCLUDED."section_code", "feedback_text" = EXCLUDED."feedback_text", "return_required" = EXCLUDED."return_required", "resolved_at" = EXCLUDED."resolved_at";
SELECT setval(
    pg_get_serial_sequence('review.section_feedback', 'feedback_id'),
    COALESCE((SELECT MAX("feedback_id") FROM review.section_feedback), 1),
    (SELECT COUNT(*) > 0 FROM review.section_feedback)
);

-- APPROVAL_RECORD -> workflow.approval_record
INSERT INTO workflow.approval_record ("approval_id", "plan_id", "approver_id", "approver_role", "action", "notes", "return_target", "action_at")
VALUES
    (1, 2, 4, 'AgencyDirector', 'Approved', 'Plan looks complete and ready for review.', NULL, '2026-06-09'),
    (2, 2, 7, 'DeputyMayor', 'Approved', 'Strong alignment with HHS pillar priorities.', NULL, '2026-06-21'),
    (3, 4, 8, 'DeputyMayor', 'Returned', 'Needs clearer goal targets before proceeding.', 'Agency', '2026-06-26'),
    (4, 5, 3, 'AgencyDirector', 'Approved', NULL, NULL, '2025-06-05'),
    (5, 5, 9, 'CAOffice', 'Approved', 'Final sign-off granted.', NULL, '2025-06-28'),
    (6, 7, 9, 'CAOffice', 'Approved', 'Approved citywide dashboard initiative.', NULL, '2026-06-23'),
    (7, 9, 8, 'DeputyMayor', 'Approved', 'Aligns well with economic development goals.', NULL, '2026-06-20'),
    (8, 9, 9, 'CAOffice', 'Approved', 'Final approval granted.', NULL, '2026-06-26'),
    (9, 10, 9, 'CAOffice', 'Approved', 'Approved following amendment review.', NULL, '2025-05-15'),
    (10, 6, 10, 'BBMRReviewer', 'Returned', 'Budget detail needs additional justification.', 'Agency', '2026-06-18')
ON CONFLICT ("approval_id") DO UPDATE SET
    "plan_id" = EXCLUDED."plan_id", "approver_id" = EXCLUDED."approver_id", "approver_role" = EXCLUDED."approver_role", "action" = EXCLUDED."action", "notes" = EXCLUDED."notes", "return_target" = EXCLUDED."return_target", "action_at" = EXCLUDED."action_at";
SELECT setval(
    pg_get_serial_sequence('workflow.approval_record', 'approval_id'),
    COALESCE((SELECT MAX("approval_id") FROM workflow.approval_record), 1),
    (SELECT COUNT(*) > 0 FROM workflow.approval_record)
);

-- PLAN_STATUS_HISTORY -> workflow.plan_status_history
INSERT INTO workflow.plan_status_history ("history_id", "plan_id", "changed_by", "from_status", "to_status", "plan_phase", "changed_at", "notes")
VALUES
    (1, 2, 5, 'Draft', 'Submitted', 'PerformancePlan', '2026-06-08', NULL),
    (2, 2, 6, 'Submitted', 'UnderReview', 'PerformancePlan', '2026-06-10', NULL),
    (3, 2, 6, 'UnderReview', 'DirectorSignOff', 'PerformancePlan', '2026-06-20', NULL),
    (4, 2, 4, 'DirectorSignOff', 'DeputyMayorReview', 'PerformancePlan', '2026-06-21', NULL),
    (5, 2, 7, 'DeputyMayorReview', 'Approved', 'PerformancePlan', '2026-06-22', NULL),
    (6, 4, 6, 'UnderReview', 'FeedbackReturned', 'PerformancePlan', '2026-06-25', 'Returned for goal revisions.'),
    (7, 6, 10, 'Submitted', 'UnderReview', 'BudgetProposal', '2026-06-15', NULL),
    (8, 9, 8, 'CAReview', 'Approved', 'PerformancePlan', '2026-06-26', NULL),
    (9, 10, 9, 'Approved', 'Amended', 'PerformancePlan', '2025-05-12', 'Mayoral priority change.'),
    (10, 1, 1, 'Draft', 'Submitted', 'PerformancePlan', '2026-06-05', NULL)
ON CONFLICT ("history_id") DO UPDATE SET
    "plan_id" = EXCLUDED."plan_id", "changed_by" = EXCLUDED."changed_by", "from_status" = EXCLUDED."from_status", "to_status" = EXCLUDED."to_status", "plan_phase" = EXCLUDED."plan_phase", "changed_at" = EXCLUDED."changed_at", "notes" = EXCLUDED."notes";
SELECT setval(
    pg_get_serial_sequence('workflow.plan_status_history', 'history_id'),
    COALESCE((SELECT MAX("history_id") FROM workflow.plan_status_history), 1),
    (SELECT COUNT(*) > 0 FROM workflow.plan_status_history)
);

-- PLAN_AMENDMENT -> amendment.plan_amendment
INSERT INTO amendment.plan_amendment ("amendment_id", "plan_id", "initiated_by", "reason", "amendment_status", "initiated_at", "reapproved_at", "version_before", "version_after")
VALUES
    (1, 10, 9, 'New mayoral priority — added emergency response time KPI.', 'Reapproved', '2025-05-08', '2025-05-15', 3, 4),
    (2, 5, 6, 'Mid-cycle correction to baseline fleet age value.', 'Reapproved', '2025-07-01', '2025-07-10', 4, 5),
    (3, 2, 6, 'OPI requested update to victim services target following data correction.', 'AgencyEditing', '2026-06-28', NULL, 3, NULL),
    (4, 9, 6, 'Add new affordable housing preservation initiative mid-cycle.', 'Open', '2026-06-27', NULL, 3, NULL),
    (5, 7, 9, 'City Council requested an additional transparency metric.', 'Resubmitted', '2026-06-24', NULL, 1, NULL),
    (6, 1, 6, 'Correction to FY27 cycle alignment after schema update.', 'Open', '2026-06-16', NULL, 2, NULL),
    (7, 4, 6, 'Add missing pillar goal alignment per rubric requirement.', 'AgencyEditing', '2026-06-26', NULL, 2, NULL),
    (8, 8, 9, 'Mayoral directive to add a community trust metric.', 'Open', '2026-06-17', NULL, 2, NULL)
ON CONFLICT ("amendment_id") DO UPDATE SET
    "plan_id" = EXCLUDED."plan_id", "initiated_by" = EXCLUDED."initiated_by", "reason" = EXCLUDED."reason", "amendment_status" = EXCLUDED."amendment_status", "initiated_at" = EXCLUDED."initiated_at", "reapproved_at" = EXCLUDED."reapproved_at", "version_before" = EXCLUDED."version_before", "version_after" = EXCLUDED."version_after";
SELECT setval(
    pg_get_serial_sequence('amendment.plan_amendment', 'amendment_id'),
    COALESCE((SELECT MAX("amendment_id") FROM amendment.plan_amendment), 1),
    (SELECT COUNT(*) > 0 FROM amendment.plan_amendment)
);

-- AMENDMENT_UNLOCK -> amendment.amendment_unlock
INSERT INTO amendment.amendment_unlock ("unlock_id", "amendment_id", "section_code", "unlock_reason", "relocked_at")
VALUES
    (1, 1, 'Goals', 'Add new KPI for emergency response time.', '2025-05-14'),
    (2, 2, 'Services', 'Correct baseline value.', '2025-07-08'),
    (3, 3, 'Services', 'Update victim services target.', NULL),
    (4, 4, 'Goals', 'Add new initiative for housing preservation.', NULL),
    (5, 5, 'Header', 'Add transparency metric reference.', NULL),
    (6, 6, 'PlanPillarAlignment', 'Re-confirm pillar alignment for FY27 cycle.', NULL),
    (7, 7, 'Goals', 'Add missing pillar goal link.', NULL),
    (8, 8, 'Goals', 'Add community trust KPI.', NULL),
    (9, 3, 'DataReporting', 'Update data source documentation.', NULL),
    (10, 1, 'Header', 'Update primary contact for amended plan.', '2025-05-13')
ON CONFLICT ("unlock_id") DO UPDATE SET
    "amendment_id" = EXCLUDED."amendment_id", "section_code" = EXCLUDED."section_code", "unlock_reason" = EXCLUDED."unlock_reason", "relocked_at" = EXCLUDED."relocked_at";
SELECT setval(
    pg_get_serial_sequence('amendment.amendment_unlock', 'unlock_id'),
    COALESCE((SELECT MAX("unlock_id") FROM amendment.amendment_unlock), 1),
    (SELECT COUNT(*) > 0 FROM amendment.amendment_unlock)
);

-- SLIDE_DECK_EXPORT -> output.slide_deck_export
INSERT INTO output.slide_deck_export ("export_id", "plan_id", "generated_by", "generated_at", "plan_version", "file_path", "trigger")
VALUES
    (1, 2, 6, '2026-06-20', 3, '/exports/plan2_v3.pptx', 'Auto'),
    (2, 4, 6, '2026-06-25', 2, '/exports/plan4_v2.pptx', 'Auto'),
    (3, 5, 1, '2025-06-20', 5, '/exports/plan5_v5.pptx', 'Manual'),
    (4, 7, 9, '2026-06-22', 1, '/exports/plan7_v1.pptx', 'Auto'),
    (5, 9, 6, '2026-06-19', 3, '/exports/plan9_v3.pptx', 'Auto'),
    (6, 10, 9, '2025-05-10', 4, '/exports/plan10_v4.pptx', 'Manual'),
    (7, 2, 4, '2026-06-08', 2, '/exports/plan2_v2.pptx', 'Manual'),
    (8, 6, 10, '2026-06-15', 1, '/exports/plan6_v1.pptx', 'Auto'),
    (9, 1, 1, '2026-06-05', 1, '/exports/plan1_v1.pptx', 'Manual'),
    (10, 8, 6, '2026-06-16', 2, '/exports/plan8_v2.pptx', 'Auto')
ON CONFLICT ("export_id") DO UPDATE SET
    "plan_id" = EXCLUDED."plan_id", "generated_by" = EXCLUDED."generated_by", "generated_at" = EXCLUDED."generated_at", "plan_version" = EXCLUDED."plan_version", "file_path" = EXCLUDED."file_path", "trigger" = EXCLUDED."trigger";
SELECT setval(
    pg_get_serial_sequence('output.slide_deck_export', 'export_id'),
    COALESCE((SELECT MAX("export_id") FROM output.slide_deck_export), 1),
    (SELECT COUNT(*) > 0 FROM output.slide_deck_export)
);

-- NOTIFICATION -> output.notification
INSERT INTO output.notification ("notification_id", "plan_id", "recipient_id", "notification_type", "sent_at", "read_at", "channel")
VALUES
    (1, 2, 4, 'PlanSubmitted', '2026-06-08', '2026-06-08', 'Email'),
    (2, 2, 6, 'PlanSubmitted', '2026-06-08', '2026-06-09', 'InApp'),
    (3, 4, 6, 'FeedbackReturned', '2026-06-25', NULL, 'Email'),
    (4, 6, 10, 'ApprovalNeeded', '2026-06-15', '2026-06-16', 'InApp'),
    (5, 7, 9, 'ApprovalNeeded', '2026-06-22', '2026-06-22', 'Email'),
    (6, 9, 8, 'ApprovalNeeded', '2026-06-19', '2026-06-20', 'Email'),
    (7, 9, 9, 'ApprovalNeeded', '2026-06-25', NULL, 'InApp'),
    (8, 10, 9, 'AmendmentOpened', '2025-05-08', '2025-05-09', 'Email'),
    (9, 1, 1, 'DirectorSignOffNeeded', '2026-06-16', NULL, 'InApp'),
    (10, 7, 6, 'PlanApproved', '2026-06-23', '2026-06-23', 'Email')
ON CONFLICT ("notification_id") DO UPDATE SET
    "plan_id" = EXCLUDED."plan_id", "recipient_id" = EXCLUDED."recipient_id", "notification_type" = EXCLUDED."notification_type", "sent_at" = EXCLUDED."sent_at", "read_at" = EXCLUDED."read_at", "channel" = EXCLUDED."channel";
SELECT setval(
    pg_get_serial_sequence('output.notification', 'notification_id'),
    COALESCE((SELECT MAX("notification_id") FROM output.notification), 1),
    (SELECT COUNT(*) > 0 FROM output.notification)
);

\ir city_reference_seed.sql
\ir action_plan_seed.sql

COMMIT;
