# Claude Handoff For Beacon

Last updated: 2026-07-15

This repo contains Beacon, the City of Baltimore performance and budgeting planning app.
It is an R Shiny application backed by PostgreSQL, containerized with Docker, and currently
deployed to Fly.io for demo/staging.

## Quick Start

- Local app: `http://127.0.0.1:3838`
- Live app: `https://baltimore-city-beacon.fly.dev`
- Main app file: `app.R`
- Database helpers: `R/database.R`
- Auth helpers: `R/auth.R`
- Client behavior: `www/app.js`
- Styling: `www/styles.css`
- Schema: `database/schema/target_schema.sql`
- Seed loaders: `database/seed/`
- Deployment notes: `DEPLOY.md`
- Database notes: `database/README.md`
- Workflow/access decisions: `docs/workflow_access_rules_questions.md`

## Local Development

Run the app through Docker:

```powershell
docker compose up -d --build app
```

Open:

```text
http://127.0.0.1:3838
```

Important: app source is copied into the Docker image. If `app.R`, `R/`, `www/`, or scripts
change, `docker compose restart app` is not enough. Rebuild the app image:

```powershell
docker compose up -d --build app
```

Use this only for a quick restart when no app source changed:

```powershell
docker compose restart app
```

Local Postgres is exposed on port `5433`. The app talks to the Docker database through:

```text
postgresql://postgres:postgres@db:5432/cob_performance
```

Do not run `docker compose down -v` unless you intentionally want to delete and reseed the
local database.

## Deploy Workflow

Current working rhythm:

1. Create a branch for meaningful work.
2. Test locally in Docker with a rebuilt app image.
3. Deploy to Fly:

```powershell
flyctl deploy
```

4. Verify the live app loads:

```powershell
Invoke-WebRequest -Uri "https://baltimore-city-beacon.fly.dev" -UseBasicParsing -TimeoutSec 30
```

5. Commit, push, merge to `main`.

Fly uses a single Shiny machine. `fly.toml` has notes about single-machine behavior and port
`3838`.

## Architecture In Plain English

The app has four main surfaces:

- Agency planning: timeline, team and roles, overview and vision, goals, services, measures, risks.
- Measure review: OPI/System Admin review and validation of submitted measures.
- Plan review and approval: reviewer, Deputy Mayor, CA Office, and System Admin publishing workflow.
- Application admin: role preview, bug/fix feedback, user/team management.

The database is namespaced:

- `reference`: agencies, services, entities, pillars, action plan reference data.
- `access`: users, roles, user/entity access.
- `planning`: cycles, agency/entity plans, shared section drafts.
- `performance`: goals, services, measures, risks, actuals/targets.
- `review`: review scores and feedback.
- `workflow`: routing, approvals, status history, entity role assignments.

`planning.plan_section_draft` is the key working-draft table. The app stores one shared draft
payload per plan and section. Browser storage is only recovery for unsaved local changes.

## Critical Data Model Concepts

### Entity / Agency / Service

The planning unit shown in the app selector should be a public-facing entity:

- regular agency,
- mayoral service,
- quasi agency.

The desired source of truth is a clean entity mapping where each planning entity has:

- public name,
- agency ID,
- service ID where relevant,
- entity ID,
- entity type.

Performance planning should key off the entity/public name layer. Budget work may later need
broader agency/service rollups.

### User / Entity Access

Users should map to the planning entities they can access. Some users can access multiple
entities. Those users should see the working-plan selector; single-entity users should not need
it.

Users should have only one performance role. If conflicting rows are imported, keep the higher
permission role and clean the source data.

Known sensitive area: user/entity mapping has historically been messy for quasis, mayoral
services, and shared-service public names. Watch for users appearing under related but wrong
entities, such as BDC users under Housing or BMA/Walters/Zoo-style quasi group bleed.

### Entity Role Assignments

`workflow.entity_role_assignment` is intended to replace ad hoc CSV assignment lookups. It stores
submitter, reviewer, Deputy Mayor, and CA Office assignments by entity.

Do not reintroduce spreadsheet-only logic if the data can live in the database.

## Auth And Email

Password sign-in uses the `access` schema. First-time account setup and password reset use email.

Local Docker has `AUTH_DEV_LINKS=true`, so password links can appear on screen for demo/local work.
Do not enable that on a shared or public environment.

Email can use SendGrid or generic SMTP. Secrets live outside git. Do not commit `.env` or copied
credentials.

If an unknown email tries to sign in, the user should see a soft access-request path and Melanie
should get an email including requested entity and agency role/title.

## Workflow And Permissions

See `docs/workflow_access_rules_questions.md` for the latest confirmed workflow rules.

Short version:

- Agency users can generally see their own assigned entity plan.
- AgencyViewer can view but should not edit.
- AgencyWriter / Performance Lead / AgencySubmitter and above can work on planning content as allowed.
- SystemAdmin and OPIReviewer can review/validate measures.
- Plan review has reviewer, Deputy Mayor, CA Office, and System Admin publishing stages.
- SystemAdmin can override stamps with a note.
- Final publish moves approved plan content from draft payload into database-backed plan records and clears payload.

Current/known approval nuance:

- Reviewer approval is required before normal downstream approval.
- Melanie Lada or Danny Heller also need an internal approval before routing to Deputy Mayor.
- Deputy Mayor and CA Office can approve/rescind their own stage.
- System Admin can add/remove approval stamps and route plans.

## Planning Draft Behavior

Goals and Services now intentionally use similar autosave patterns:

- Browser collects the whole section draft payload.
- App saves one payload to `planning.plan_section_draft`.
- The server updates the in-session cached draft row.

Services had a long-running bug where metric selections could return stale values after deletion.
The fix was to move services away from split partial saves and toward the same whole-section save
pattern used by goals. Service metric controls are browser-owned plain selects rather than Shiny
`selectInput()` controls.

Important Docker lesson from that bug: if code changes do not appear locally, rebuild the Docker
image. The app image copies `www/` and `app.R`; restart alone may serve stale JS.

## Known Fragile Areas

Treat these carefully:

- User/entity/public-name mapping for quasis and mayoral services.
- Role preview can be useful for demos, but it can also confuse testing because SystemAdmin rights
  can leak into preview expectations if not handled explicitly.
- Services autosave and goals autosave should be kept conceptually parallel.
- Published-site data and local Docker data can differ. Confirm which database you are testing.
- PDF export has its own Python path and can behave differently if draft payload vs database plan
  content differs.
- Measures can be selected by goals and services, but service-level metrics should not repeat across
  services in the same plan.
- Administration services are visible for context but are not currently scored and do not require
  metrics.

## Testing Checklist Before Demo Or Deploy

At minimum:

1. Sign in with a SystemAdmin and an agency user.
2. Confirm the working-plan selector only appears for users who need it.
3. On Goals:
   - add/remove initiatives,
   - add/remove KPIs,
   - navigate away and back,
   - confirm draft persisted.
4. On Services:
   - add a metric,
   - remove a middle metric from three,
   - navigate away and back,
   - confirm no stale metric returns.
5. Add/edit a service description and confirm it autosaves.
6. Add a measure, submit it, approve/return it, and confirm it appears where expected.
7. Submit a plan, route through reviewer/DM/CA/publishing as needed.
8. Export PDF for at least one agency and one mayoral service/quasi.
9. Submit feedback through the floating feedback button and verify it appears in Bug/Fix.
10. Check the live URL after deploy.

## Useful Commands

Parse checks:

```powershell
Rscript -e "invisible(parse('app.R')); cat('R parse ok\n')"
node --check www/app.js
```

Rebuild local app:

```powershell
docker compose up -d --build app
```

Check local app:

```powershell
Invoke-WebRequest -Uri "http://127.0.0.1:3838" -UseBasicParsing -TimeoutSec 30
```

Deploy:

```powershell
flyctl deploy
```

Git hygiene:

```powershell
git status --short --branch
git switch -c codex/short-branch-name
git add <files>
git commit -m "Clear concise message"
git push -u origin <branch>
```

## Handoff Guidance

When picking up work:

1. Start by checking `git status --short --branch`.
2. Confirm whether the user is testing local Docker or live Fly.
3. If testing local Docker after source edits, rebuild the app image.
4. Avoid quick one-off database mutations unless the user explicitly wants them; prefer scripts or
   seed/update files that can be reviewed and replayed.
5. Keep role/access logic centralized and explicit. Do not scatter one-off role checks throughout
   UI code unless there is no alternative.
6. When debugging stale UI behavior, first verify the app is serving the current JS bundle.

