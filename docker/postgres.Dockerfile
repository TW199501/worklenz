# Worklenz PostgreSQL with the schema baked in.
#
# Purpose: let the whole stack run from PULLED images only — no source code and
# no bind mounts. This is required for deploy panels (e.g. Dockhand) that only
# take a compose file + .env and have no repo checkout on disk.
#
# Postgres runs everything in /docker-entrypoint-initdb.d on first start (empty
# data dir); db-init-wrapper.sh then imports the SQL from /database/sql.
FROM postgres:15.10-alpine

# Schema + migration SQL (the wrapper reads /database/sql)
COPY worklenz-backend/database /database

# First-run schema import (runs once, on an empty data directory)
COPY scripts/db-init-wrapper.sh /docker-entrypoint-initdb.d/00-init-wrapper.sh
RUN chmod +x /docker-entrypoint-initdb.d/00-init-wrapper.sh
