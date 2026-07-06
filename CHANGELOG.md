# Changelog

## Unreleased — merge of codex/username-password-login (branch `fix/containerize`)

- Merged the workflow build-out branch (plan review workflow, measure review,
  role preview/workspace model, entity links, richer seeds). Password
  authentication now fronts their email role-lookup sign-in; the demo
  role-bypass observers were removed, pages are gated server-side, and boot
  lands on the login page.
- `database/schema/target_schema.sql` was overwritten with a notes file on
  their branch (preserved as `NOTES.md`); kept our working schema and folded in
  the schema drift their code assumed but only created via one-off scripts or
  at runtime: `review.measure_review`, `performance.measure_entity_link`,
  `reference.agency.submit_plan`, `performance.service_risk.risk_type`,
  `access.user_agency_access.access_level/budget_access/performance_plan_access`,
  and the widened `approval_status` check.
- Verified from a completely fresh database: schema + seed init clean (62 plans,
  439 users), password sign-in routes through their role model to the Plan
  Review workspace, failed sign-in shows the notice, first-time/reset views
  intact, no console errors.
- **Deployed to Fly.io**: app `cob-performance` (https://cob-performance.fly.dev,
  single machine, iad) with attached Fly Postgres `cob-performance-db` loaded
  with the full schema + seed stack over `fly proxy`. Secrets set: DATABASE_URL
  (via attach), APP_BASE_URL, SENDGRID_API_KEY, DEFAULT_FROM_EMAIL. Verified
  from the deployed machine: session-start data load succeeds against the
  attached database.

## Unreleased — password authentication & Fly.io (branch `fix/containerize`)

### Added

- **Password sign-in against the `access` schema** (`R/auth.R`, `app.R`). The
  prototype login buttons are replaced with a real email + password form. Passwords
  are hashed with libsodium (`sodium::password_store`, scrypt) into the existing
  `access."user".password_hash` column. Sign-in routes by role: reviewer-type app
  roles (`OPIReviewer`, `BBMRReviewer`, `SystemAdmin`, `DeputyMayor`, `CAOffice`)
  land on the reviewer workspace; agency roles land on their agency's cycle home
  (pinned to the user's agency when it has a seeded FY2027 plan). Since users are
  provisioned by admins, password login is allowed for both `Email` and
  `MicrosoftAD` auth types until Entra sign-in exists.
- **First-time password setup and password reset** — both use the same one-time
  link flow ("First time here? Set your password" / "Forgot your password?").
  Tokens are 32 random bytes, stored only as a hash in the new
  `access.password_reset_token` table, expire after 60 minutes, and are single-use
  (all outstanding tokens for a user burn on success). The request form always
  responds identically whether or not the email exists.
- **Email delivery via SMTP or SendGrid** (`curl::send_mail`). Set
  `SENDGRID_API_KEY` + `DEFAULT_FROM_EMAIL` (SendGrid's SMTP relay with the
  literal `apikey` username), or explicit `SMTP_HOST`/`SMTP_PORT`/`SMTP_USER`/
  `SMTP_PASSWORD`/`SMTP_FROM` which take precedence; `APP_BASE_URL` controls link
  building. Display-name from addresses (`Name <user@host>`) are parsed to a bare
  address for the SMTP envelope, and the SMTP trace is disabled so credentials
  never reach container logs. Verified end to end against SendGrid (queued 250).
  `AUTH_DEV_LINKS=true` (local demos only, enabled in `docker-compose.yml`) shows
  links on screen and suppresses all outbound email so demos never mail the real
  employee addresses in the seed data; never set it on a shared host.
- **Server-side access gate** — every page render and navigation event checks the
  session's authenticated user; unauthenticated sessions always see the login page
  regardless of nav clicks.
- **Failed-attempt throttling** — 5 failures per email locks sign-in for
  15 minutes (in-process).
- **Fly.io deployment support** — `fly.toml` (port 3838, force-HTTPS, single-machine
  guidance, health check, 2 GB VM) and `DEPLOY.md` with the full walkthrough:
  `fly launch`, Fly Postgres create/attach, schema + seed loading over `fly proxy`,
  and required secrets.
- **`.claude/launch.json`** — dev-server config for launching the compose stack.

### Verified

End to end in the container stack: navigation gating while signed out, failed
sign-in notice, first-time setup link → password save → agency user landing on
their FY2027 plan, reviewer sign-in landing on the reviewer workspace, token
single-use and expiry checks, and case-insensitive email lookup.

## Unreleased — containerization (branch `fix/containerize`)

### Fixed

- **Removed hardcoded developer-machine Python path** (`app.R`, `plan_export_python()`).
  The plan export helper pointed at `C:/Users/melanie.lada/.cache/...` and only fell
  back to `python`. It now honors `PLAN_EXPORT_PYTHON`, then falls back to `python3`
  and `python` on `PATH`.
- **Removed hardcoded PPTX template path** (`app.R`, `build_plan_export_file()`).
  The PowerPoint export template was read from `C:/Users/melanie.lada/AppData/Local/Temp/`.
  The template location is now configurable via `PLAN_EXPORT_PPTX_TEMPLATE`, defaulting
  to `templates/agency-performance-plan-template.pptx` in the app directory. As before,
  the export runs without a template when the file is absent.
- **Schema file could not load on a fresh database**
  (`database/schema/target_schema.sql`). Constraint-widening `ALTER TABLE` patches
  for `performance.performance_measure` appeared ~115 lines before the table's
  `CREATE TABLE`, so `psql -v ON_ERROR_STOP=1` failed with
  `relation "performance.performance_measure" does not exist`. The patches now sit
  with the other `performance_measure` patches after the table definition.
- **Reference seed loader violated a foreign key on a fresh database**
  (`database/seed/load_reference_seed.sql`). `city_reference_seed.sql` inserts
  `reference.service` rows that reference `reference.pillar`, but pillars were
  loaded afterwards by `action_plan_seed.sql`. The load order is now reversed.
- **`sslmode` in `DATABASE_URL` is no longer silently dropped** (`R/database.R`,
  `connect_app_database()`). The URL parser discarded everything after `?`, so the
  `?sslmode=require` suffix in the Key Vault connection string never reached the
  driver. The parser now extracts `sslmode` from the query string and passes it to
  `dbConnect()` (defaulting to `prefer` when absent).

### Added

- **`Dockerfile`** — builds a runnable image from `rocker/r-ver:4.4.2` with the R
  dependencies (`shiny`, `DBI`, `RPostgres`, `jsonlite`), plus a Python virtualenv
  (`reportlab`, `python-pptx`) for the PDF/PowerPoint plan exports, wired up through
  `PLAN_EXPORT_PYTHON`. The app listens on `0.0.0.0:$PORT` (default 3838).
- **`scripts/requirements.txt`** — pinned Python dependencies for
  `scripts/build_plan_export.py`.
- **`docker-compose.yml`** — local stack: the app container plus Postgres 18 with the
  target schema and full seed stack (reference data, user roles, performance plans)
  loaded automatically on first start. The database is published on host port 5433
  to avoid clashing with a locally installed Postgres.
- **`docker/initdb/02_load_seed.sql`** — init wrapper that loads
  `database/seed/load_uploaded_seed.sql` inside the Postgres container.
- **`.dockerignore`** — keeps Terraform, database SQL, git metadata, and generator
  scripts out of the image.

### How to run

```bash
docker compose up --build
# app: http://localhost:3838  (db: localhost:5433, postgres/postgres)
```

Or against an existing database:

```bash
docker build -t cob-performance .
docker run -p 3838:3838 -e DATABASE_URL="postgresql://user:pass@host:5432/cob_performance?sslmode=require" cob-performance
```
