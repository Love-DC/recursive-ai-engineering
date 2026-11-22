#!/usr/bin/env bash
# Run failure/retry integration assertions against an isolated PostgreSQL database.
set -euo pipefail

: "${SUPABASE_DB_URL:?Set SUPABASE_DB_URL to an isolated PostgreSQL connection string}"
[[ "${FAILURE_RECOVERY_TEST_ALLOW_MUTATIONS:-}" == "YES" ]] || {
  echo "Refusing to run: set FAILURE_RECOVERY_TEST_ALLOW_MUTATIONS=YES for disposable test database writes." >&2
  exit 2
}
command -v psql >/dev/null || { echo "psql is required" >&2; exit 2; }

psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 -f tests/failure-recovery-integration.sql
echo "PASS: failure/retry integration assertions completed; transaction rolled back."
