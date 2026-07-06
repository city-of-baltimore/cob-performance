# Changelog

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
  loaded automatically on first start.
- **`docker/initdb/02_load_seed.sql`** — init wrapper that loads
  `database/seed/load_uploaded_seed.sql` inside the Postgres container.
- **`.dockerignore`** — keeps Terraform, database SQL, git metadata, and generator
  scripts out of the image.

### How to run

```bash
docker compose up --build
# app: http://localhost:3838  (db: localhost:5432, postgres/postgres)
```

Or against an existing database:

```bash
docker build -t cob-performance .
docker run -p 3838:3838 -e DATABASE_URL="postgresql://user:pass@host:5432/cob_performance?sslmode=require" cob-performance
```
