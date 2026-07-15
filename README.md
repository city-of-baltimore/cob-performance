# Beacon

Beacon is the City of Baltimore performance and budgeting planning application.
It supports agency performance planning, measure management, plan review, approval
routing, and PDF export for performance plans.

The app is an R Shiny application backed by PostgreSQL, containerized with Docker,
and currently deployed to Fly.io for staging/demo use.

## Links

- Local app: `http://127.0.0.1:3838`
- Live staging app: `https://baltimore-city-beacon.fly.dev`
- Deployment notes: [`DEPLOY.md`](DEPLOY.md)
- Database notes: [`database/README.md`](database/README.md)
- Claude handoff notes: [`docs/claude_handoff.md`](docs/claude_handoff.md)

## Repository Layout

- `app.R` - main Shiny app.
- `R/` - database, auth, and helper code.
- `www/` - JavaScript, CSS, images, and client-side behavior.
- `database/schema/target_schema.sql` - target PostgreSQL schema.
- `database/seed/` - seed data loaders.
- `scripts/` - import, cleanup, and export scripts.
- `docs/` - supporting documentation.
- `Dockerfile` and `docker-compose.yml` - local/container setup.
- `fly.toml` - Fly.io deployment configuration.

## Local Development

Run the app locally with Docker Compose:

```powershell
docker compose up -d --build app
```

Open:

```text
http://127.0.0.1:3838
```

Local Postgres is exposed on host port `5433`.

Important: app source is copied into the Docker image. If you change `app.R`,
`R/`, `www/`, or app scripts, rebuild the app image. A plain restart will keep
serving the old copied files.

```powershell
docker compose up -d --build app
```

Use this only when no source files changed:

```powershell
docker compose restart app
```

Stop local containers:

```powershell
docker compose down
```

Do not run `docker compose down -v` unless you intentionally want to delete the
local Docker database volume and reseed from scratch.

## Configuration

The app expects `DATABASE_URL`.

Docker Compose sets:

```text
postgresql://postgres:postgres@db:5432/cob_performance
```

Email settings are read from environment variables. For local testing, put them
in a gitignored `.env` file. Do not commit credentials.

Supported email settings include:

- `SENDGRID_API_KEY`
- `DEFAULT_FROM_EMAIL`
- `SMTP_HOST`
- `SMTP_PORT`
- `SMTP_USER`
- `SMTP_PASSWORD`
- `SMTP_FROM`

## Database

The database is organized into namespaced schemas:

- `reference` - city reference data, agencies, services, entities, pillars.
- `access` - users, roles, and entity access.
- `planning` - plans, cycles, and shared section drafts.
- `performance` - goals, services, measures, risks, actuals, and targets.
- `review` - review scores and feedback.
- `workflow` - routing, approvals, status history, and entity assignments.

See [`database/README.md`](database/README.md) for schema and seed loading
details.

## Planning Drafts

Working drafts are stored in `planning.plan_section_draft`.

The browser keeps local storage only as a recovery copy for unsaved changes.
Goals and Services save whole-section draft payloads so the database has one
shared draft source per plan section.

## Deployment

Deploy to Fly.io:

```powershell
flyctl deploy
```

Verify the live app:

```powershell
Invoke-WebRequest -Uri "https://baltimore-city-beacon.fly.dev" -UseBasicParsing -TimeoutSec 30
```

See [`DEPLOY.md`](DEPLOY.md) for full deployment setup, including Fly Postgres
and secrets.

## Development Workflow

Recommended flow:

1. Create a branch for each change.
2. Rebuild local Docker after source edits.
3. Test locally.
4. Deploy to Fly when ready for staging.
5. Commit, push, and merge to `main`.

Before handing off or deploying, check:

```powershell
git status --short --branch
Rscript -e "invisible(parse('app.R')); cat('R parse ok\n')"
node --check www/app.js
```

## Notes For Future Maintainers

The most fragile areas are:

- user/entity/public-name mapping for quasis and mayoral services,
- role and access rules,
- plan routing and approval stamps,
- Services and Goals autosave behavior,
- PDF export behavior when draft payloads differ from published database rows.

Start with [`docs/claude_handoff.md`](docs/claude_handoff.md) for current
handoff context and known sharp edges.

