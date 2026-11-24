-- Trusted Owner/System Owner, read-only integrity scan.
-- Usage:
--   psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 \
--     -v project_id="$SUPABASE_PROJECT_ID" \
--     -f scripts/check-task-integrity.sql

\set ON_ERROR_STOP on
\if :{?project_id}
\else
  \echo 'ERROR: pass -v project_id=<public.projects.id UUID>'
  \quit 2
\endif

BEGIN;
SELECT private.begin_rae_system_context(:'project_id'::uuid);
SELECT *
FROM private.task_integrity_findings(:'project_id'::uuid)
ORDER BY source_relation, row_id, reference_name;
ROLLBACK;
