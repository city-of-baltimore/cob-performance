# Deploying Beacon

## Local (Docker Compose)

```bash
docker compose up -d --build
# App: http://localhost:3838
# Postgres: localhost:5433 (postgres/postgres), schema + seeds load on first start
```

You do not need to rebuild the Docker image every time you restart your
computer. After the first successful build, Docker keeps the app image and the
database volume. For normal local use, start the stack with:

```bash
docker compose up
```

Use `docker compose up --build` when the Dockerfile, R package dependencies,
Python requirements, or app code changes enough that you want the image
refreshed. To run it in the background:

```bash
docker compose up -d
```

Stop the local stack with:

```bash
docker compose down
```

`docker compose down` keeps the local database volume by default. Do not run
`docker compose down -v` unless you intentionally want to delete the local
Docker database and reseed from scratch.

`AUTH_DEV_LINKS=true` is set in the compose file, so password set/reset links
appear on screen instead of being emailed — local demo convenience only.

To sign in the first time: click **"First time here? Set your password"**, enter
a seeded user's email (see `database/seed/user_roles_seed.sql`), follow the
displayed link, choose a password, then sign in. Reviewer-type roles
(`OPIReviewer`, `BBMRReviewer`, `SystemAdmin`, `DeputyMayor`, `CAOffice`) land
on the reviewer workspace; agency roles land on their agency's cycle home.

## Fly.io

Prerequisites: [flyctl](https://fly.io/docs/flyctl/) installed and signed in.

### 1. Create the app

```bash
fly launch --no-deploy   # uses the committed fly.toml and Dockerfile
```

### 2. Create and attach Postgres

```bash
fly postgres create --name cob-performance-db --region iad
fly postgres attach cob-performance-db
```

`attach` sets the `DATABASE_URL` secret automatically. The app's URL parser
honors the `sslmode` query parameter Fly includes.

`fly postgres create`'s default size (`shared-cpu-1x:256MB`) is too small for
real concurrent use. On 2026-07-16 it caused a ~20-minute outage during a
live training session: the Postgres VM hit its memory/IO limits under
concurrent load, connections were dropped (`server closed the connection
unexpectedly` in the app logs), and the app appeared to hang for active
users. Size it up after creating it:

```bash
fly machine list -a cob-performance-db   # get the machine ID
fly machine update <machine-id> -a cob-performance-db --vm-memory 1024
```

Current production sizing is `shared-cpu-1x:1024MB`. Re-evaluate if the app
sees heavier concurrent use (e.g. many agencies working simultaneously
during a submission deadline).

### 3. Load the schema and seeds

```bash
fly proxy 15432:5432 -a cob-performance-db   # keep running in another terminal

psql "postgresql://postgres:<password>@localhost:15432/cob_performance" -v ON_ERROR_STOP=1 -f database/schema/target_schema.sql
psql "postgresql://postgres:<password>@localhost:15432/cob_performance" -v ON_ERROR_STOP=1 -f database/seed/load_uploaded_seed.sql
```

(The password is printed by `fly postgres create`; the database name comes from
the attach output.)

### 4. Configure secrets

```bash
# Required so emailed password links point at the public URL
fly secrets set APP_BASE_URL="https://cob-performance.fly.dev"

# Email for password set/reset links — either SendGrid:
fly secrets set SENDGRID_API_KEY=SG.... DEFAULT_FROM_EMAIL=performance@baltimorecity.gov

# ...or any generic SMTP relay (explicit SMTP_* settings win over SendGrid):
fly secrets set SMTP_HOST=smtp.example.com SMTP_PORT=587 \
  SMTP_USER=... SMTP_PASSWORD=... SMTP_FROM=performance@baltimorecity.gov
```

For local email testing, put `SENDGRID_API_KEY` and `DEFAULT_FROM_EMAIL` in the
gitignored `.env` at the repo root; `docker-compose.yml` passes them through.
The from address must be a verified sender identity in SendGrid.

Without SMTP configured, password set/reset requests succeed but no link is
delivered. Do **not** set `AUTH_DEV_LINKS` on Fly — it displays account-takeover
links on screen and exists only for local demos.

### 5. Deploy

```bash
fly deploy
fly scale count 1   # Shiny requires a single machine; see fly.toml
```

### Notes

- The app loads the full database into memory per session; `shared-cpu-2x` /
  2 GB in `fly.toml` is sized for the seeded prototype data.
- PDF/PowerPoint exports work out of the box (Python + reportlab/python-pptx
  are baked into the image). To brand the PPTX export, add a template at
  `templates/agency-performance-plan-template.pptx` or set
  `PLAN_EXPORT_PPTX_TEMPLATE`.
- Treat Fly as the staging/demo environment. Production hosting is expected to
  move to Azure (App Service + Entra ID); the auth code reads the user's email
  and looks up roles in `access.*`, so swapping password login for Entra later
  only changes how the email is learned.
