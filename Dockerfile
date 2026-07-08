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

# R package dependencies (sodium: password hashing; curl: SMTP for reset links)
RUN R -q -e "options(repos = c(CRAN = 'https://cloud.r-project.org')); pkgs <- c('shiny', 'DBI', 'RPostgres', 'jsonlite', 'sodium', 'curl'); for (pkg in pkgs) { if (!requireNamespace(pkg, quietly = TRUE)) install.packages(pkg); library(pkg, character.only = TRUE) }"

# Python environment for PDF/PowerPoint plan exports
COPY scripts/requirements.txt /opt/plan-export/requirements.txt
RUN python3 -m venv /opt/plan-export/venv \
    && /opt/plan-export/venv/bin/pip install --no-cache-dir -r /opt/plan-export/requirements.txt
ENV PLAN_EXPORT_PYTHON=/opt/plan-export/venv/bin/python

WORKDIR /app
COPY app.R ./
COPY R/ R/
COPY scripts/build_plan_export.py scripts/
COPY database/seed/entity_role_assignments.csv database/seed/entity_role_assignments.csv
COPY database/seed/reviewer_assignments.csv database/seed/reviewer_assignments.csv
COPY www/ www/

ENV PORT=3838
EXPOSE 3838

CMD ["R", "-e", "shiny::runApp('/app', host = '0.0.0.0', port = as.integer(Sys.getenv('PORT', '3838')))"]
