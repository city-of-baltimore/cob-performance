FROM rocker/r-ver:4.4.2

# System libraries for RPostgres (libpq) and the Python export toolchain
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    libpq-dev \
    pkg-config \
    zlib1g-dev \
    libsodium-dev \
    libcurl4-openssl-dev \
    libssl-dev \
    libuv1-dev \
    python3 \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

# City of Baltimore's network TLS-inspection root CA. Without this, builds
# on the city network fail SSL verification for external hosts (e.g. pypi.org)
# that get intercepted and re-signed with this cert -- the browser trusts it
# via Windows' certificate store, but a fresh container has no idea it exists.
COPY docker/certs/baltrootca.pem /usr/local/share/ca-certificates/baltrootca.crt
RUN update-ca-certificates
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ENV REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
ENV PIP_CERT=/etc/ssl/certs/ca-certificates.crt

# R package dependencies (sodium: password hashing; curl: SMTP for reset links;
# future/promises: run full database reloads off the main process so one
# user's save/submit/approve doesn't freeze every other connected session)
RUN R -q -e "options(repos = c(CRAN = 'https://cloud.r-project.org')); pkgs <- c('shiny', 'DBI', 'RPostgres', 'jsonlite', 'sodium', 'curl', 'future', 'promises'); for (pkg in pkgs) { if (!requireNamespace(pkg, quietly = TRUE)) install.packages(pkg); library(pkg, character.only = TRUE) }"

# Python environment for PDF/PowerPoint plan exports
COPY scripts/requirements.txt /opt/plan-export/requirements.txt
RUN python3 -m venv /opt/plan-export/venv \
    && /opt/plan-export/venv/bin/pip install --no-cache-dir -r /opt/plan-export/requirements.txt
ENV PLAN_EXPORT_PYTHON=/opt/plan-export/venv/bin/python

WORKDIR /app
COPY app.R ./
COPY R/ R/
COPY scripts/build_plan_export.py scripts/
COPY scripts/import_entity_role_assignments.R scripts/
COPY scripts/apply_user_entity_access_cleanup.R scripts/
COPY database/seed/entity_role_assignments.csv database/seed/entity_role_assignments.csv
COPY database/seed/reviewer_assignments.csv database/seed/reviewer_assignments.csv
COPY database/seed/user_entity_access_seed.csv database/seed/user_entity_access_seed.csv
COPY database/seed/agency_fiscal_analyst_seed.csv database/seed/agency_fiscal_analyst_seed.csv
COPY www/ www/

ENV PORT=3838
EXPOSE 3838

CMD ["R", "-e", "shiny::runApp('/app', host = '0.0.0.0', port = as.integer(Sys.getenv('PORT', '3838')))"]
