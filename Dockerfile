FROM rocker/r-ver:4.4.2

# System libraries for RPostgres (libpq) and the Python export toolchain
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    python3 \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

# R package dependencies
RUN install2.r --error --skipinstalled shiny DBI RPostgres jsonlite

# Python environment for PDF/PowerPoint plan exports
COPY scripts/requirements.txt /opt/plan-export/requirements.txt
RUN python3 -m venv /opt/plan-export/venv \
    && /opt/plan-export/venv/bin/pip install --no-cache-dir -r /opt/plan-export/requirements.txt
ENV PLAN_EXPORT_PYTHON=/opt/plan-export/venv/bin/python

WORKDIR /app
COPY app.R ./
COPY R/ R/
COPY scripts/build_plan_export.py scripts/
COPY www/ www/

ENV PORT=3838
EXPOSE 3838

CMD ["R", "-e", "shiny::runApp('/app', host = '0.0.0.0', port = as.integer(Sys.getenv('PORT', '3838')))"]
