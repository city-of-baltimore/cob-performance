-- Canonical reference seed loader for Beacon / Baltimore Outcome Budgeting.
-- Run after database/schema/target_schema.sql.
--
-- This file loads real reference data only:
-- - City agency, service, and plan entity reference rows
-- - 2026 Mayor's Action Plan pillars, goals, strategies, and measures

BEGIN;

\ir city_reference_seed.sql
\ir action_plan_seed.sql

COMMIT;
