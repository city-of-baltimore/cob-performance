-- Loads the canonical seed stack (reference data, user roles, performance plans)
-- into the freshly created database. Paths are relative to this file, which the
-- compose file mounts alongside a read-only copy of database/seed.
\ir seed/load_uploaded_seed.sql
