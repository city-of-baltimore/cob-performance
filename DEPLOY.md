# Deploying Beacon

## Local (Docker Compose)

```bash
docker compose up -d --build
# App: http://localhost:3838
# Postgres: localhost:5433 (postgres/postgres), schema + seeds load on first start
```

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
