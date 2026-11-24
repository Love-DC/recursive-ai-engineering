#!/usr/bin/env bash
set -euo pipefail

: "${SUPABASE_DB_URL:?Set SUPABASE_DB_URL to the isolated PostgreSQL test database}"
command -v psql >/dev/null || { echo "psql is required" >&2; exit 2; }

psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 -f tests/ai-initiative-lifecycle.sql
echo "PASS: AI initiative lifecycle transactional integration tests completed."
