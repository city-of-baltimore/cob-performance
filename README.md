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

## Testing

```powershell
docker compose up -d db
$env:DATABASE_URL = "postgresql://postgres:postgres@localhost:5433/cob_performance"
Rscript tests/testthat.R
```

Tests live in `tests/testthat/`. Pure logic tests (display-name resolution,
CSV export shape) run with or without a database; database-backed tests
(team role save, seed idempotency) skip automatically if `DATABASE_URL` isn't
set. CI (`.github/workflows/ci.yml`) runs the full suite against a fresh
Postgres service container on every push/PR.

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

## Performance & Scaling Notes (2026-08-07)

Beacon hit real capacity problems at scale this week — OOM crashes, a
concurrent-login freeze, and slow Services/Measures navigation for large
agencies. Below is what actually fixed each one, what's still open, and
where the remaining slow paths are, so the next person doesn't have to
re-derive this from scratch.

### Running on multiple machines

The app now runs on **3 Fly machines** (`fly.toml`'s `min_machines_running`),
not the single machine the app was originally built assuming. This was
the fix for concurrent logins blocking every other connected session
(see "Concurrent-login freeze" below) — confirmed via a local load test
(shinyloadtest/shinycannon against 3 app instances behind an nginx proxy
with **no sticky sessions**, matching Fly's real default routing) that
this cuts worst-case login latency from ~12.4s to ~5.1s at 50 concurrent
logins.

This works *without* session affinity because of two things already true
about the app, verified before scaling out:
- Login/session tokens are Postgres + browser-`localStorage`-backed
  (`access.user_login_session`, `R/auth.R`), not in-process memory — a
  session landing on a different machine after a dropped WebSocket just
  pays a normal fresh-login cost, not a lost session.
- Per-session caches (`section_draft_cache`, `service_open_flags`, etc.)
  are declared inside `server()`, not at the top level of `app.R` — they
  were never shared across sessions on one process in the first place,
  so running N processes doesn't change anything about their behavior.

The one thing that *did* need fixing before scaling out: the failed-login
lockout (`auth_attempt_blocked`/`auth_note_failure`/`auth_clear_failures`,
`R/auth.R`) used to live in a plain in-process R environment
(`auth_throttle`) — across multiple machines, a locked-out user could
reset their attempt count just by reconnecting onto a different machine.
It's now backed by a Postgres table, `access.login_throttle`.

If you add new per-process state to `app.R` in the future, check whether
it's declared inside `server()` (safe, per-session, no multi-machine
concern) or at the top level (shared per-process — think carefully about
whether it needs to be Postgres-backed instead before relying on it).

### Full-database reloads are the main remaining cost driver

`refresh_app_data()` (`app.R`) is the one function behind almost every
save in the app. By default it reloads the *entire* database (~31
queries) into that session's own copy of `app_data()` — every session
holds its own full copy, there is no shared cache across sessions.
Confirmed live in production that **a full reload settles at ~2.6GB
resident per background worker** on real data (vs. ~150MB against the
local Docker dev-seed data, which is why local testing alone won't
reproduce this — the dev seed dataset is much smaller than production's).

This is why background worker count matters for memory: `future::plan()`
at the top of `app.R` currently runs **2 workers per machine** (dropped
from 3 same-day after this was found — 3 workers × ~2.6GB could exceed
an 8GB machine's ceiling on their own in steady state, no leak required,
just concurrent full reloads landing during a busy period). Tried
`gc(full = TRUE)` after each worker load to see if R was retaining
memory it could release — production data showed **zero measurable
effect** even at ~1.5GB, ruling that out cleanly. **Root cause of the
2.6GB figure is still open** — the next lead, not yet tried, is
periodically recycling the worker pool rather than trying to shrink a
long-lived worker's memory in place.

**The actual fix, in progress**: reduce how often a *full* reload
happens at all, by giving more save flows their own narrowly-scoped
reload instead of the default. CLS and Measures are done (see next
section); Goals/Services/Overview/Risks/Team-Roles/plan-approval saves
still trigger a full reload. If you're adding a new save flow, check
`refresh_app_data()`'s own comment block in `app.R` first — it explains
exactly when a domain-scoped reload is safe to add and when it isn't
(the rule of thumb: reloading too much is merely wasteful; reloading too
little silently shows some *other* page stale data, which is worse).

### Domain-scoped reloads: what's covered

`refresh_domain_loaders` (`app.R`) maps a domain name to a loader
function in `R/database.R`. Passing `domains = "<name>"` to
`refresh_app_data()` reloads only that domain's own queries instead of
everything.

| Domain | Loader | Save flows using it |
|---|---|---|
| `cls` | `load_cls_domain_data()` | All CLS/budget-request saves |
| `measures` | `load_measures_domain_data()` | Measure save/delete/review/deactivate/reactivate/revert-to-draft/owner-reassignment |

Everything else (Goals, Services, Overview, Risks, Team Roles, plan
submit/approve/publish/return, review scoring) still triggers a full,
unscoped reload — not yet migrated.

### Agency-scoped measures loading: where it applies and where it doesn't

Separately from domain scoping above, an ordinary single-agency
session's *initial* load (at sign-in) is scoped to just the agencies
that session actually needs, instead of every agency in the city —
`resolve_measures_scope_agency_ids()` in `R/database.R` resolves this
once at sign-in, stored in the session's `measures_scope_agency_ids`
reactiveVal, and reused by every later reload for that session (whether
full or `domains = "measures"`) so a save doesn't silently widen back to
citywide.

**Applies to** (agency-scoped, only loads relevant agencies):
- `performance.performance_measure`, `performance.measure_actuals`,
  `performance.pm_goal_link`, `performance.pm_service_link`,
  `performance.measure_entity_link`, `review.measure_review` — i.e.
  exactly the tables `load_measures_domain_data()` covers.

**Does NOT apply to** (still full citywide, for every session
regardless of role):
- `city_measures`/`strategic_plan` (Timeline and Action Plan pages) —
  deliberately never scoped; every signed-in user is meant to see the
  same citywide Action Plan dashboard.
- Review feedback (`review.section_feedback`, `review.plan_review`,
  `review.section_score`) — lives in the main `load_app_data()` query
  list, not the measures domain; untouched by this.
- CLS (`load_cls_domain_data()`) — a separate domain loader entirely;
  it accepts (and ignores) an `agency_ids` argument for calling-
  convention consistency with the other domain loaders, but its queries
  are not filtered by it.

**Who gets scoped**: everyone except `SystemAdmin`, `OPIReviewer`,
`BBMRReviewer`, `DeputyMayor`, and `CAOffice` (`CITYWIDE_MEASURES_APP_ROLES`,
`R/database.R`) — those roles review across agencies and always get the
full citywide set, unchanged. The resolved agency set for everyone else
is deliberately a *superset* at the agency level (every agency the
user's own grants and entity links touch, unioned together), not a
minimal entity-level slice — a shared-grant entity (e.g. an entity
entity-linked to a service/measure filed under a different agency than
its own parent) can legitimately need more than one agency's worth of
data, and under-fetching there is the failure mode that actually matters
(over-fetching an extra agency is harmless; the existing entity-level
display filtering elsewhere in the app already narrows it down to what
that entity actually shows).

If you extend this pattern to another domain, reuse
`resolve_measures_scope_agency_ids()`'s resolution logic rather than
re-deriving "which agencies does this user need" from scratch.

### Services/Measures page rendering

Independent of the loading-side fixes above, `page_services()` and
`page_metrics()` used to filter `performance_measure_actuals`/
`performance_measure_entity_link` *inside* a per-service/per-measure
loop — a full table scan per item, which is what made agencies with many
services (e.g. Transportation) feel slow to navigate even once the data
was already loaded. Both now build a `split()`-based index once per page
render instead. If you add a new per-item loop over services or
measures, index first — don't filter the same table inside the loop.

### Load-testing tooling

`docker-compose.scale-test.yml` + `docker/scale-test-nginx.conf` (repo
root/`docker/`, not part of the normal `docker compose up` flow) spin up
3 app instances behind a round-robin, no-sticky-sessions nginx proxy for
reproducing the concurrent-login load test locally:

```powershell
docker compose -f docker-compose.yml -f docker-compose.scale-test.yml up -d
```

Record a session with `shinyloadtest::record_session()` against the
proxy port (8080), then replay it with `shinycannon` (a separate Java
tool, not an R package — `https://github.com/rstudio/shinycannon`) at
whatever concurrency you want to test. Tear down with:

```powershell
docker compose -f docker-compose.yml -f docker-compose.scale-test.yml down
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

