#!/usr/bin/env bash
set -euo pipefail

: "${SUPABASE_DB_URL:?Set SUPABASE_DB_URL}"
: "${SUPABASE_OWNER_ID:?Set SUPABASE_OWNER_ID}"
: "${SUPABASE_PROJECT_ID:?Set SUPABASE_PROJECT_ID}"
: "${SHARED_WORKER_ID:?Set SHARED_WORKER_ID}"
: "${REVIEWER_WORKER_ID:?Set REVIEWER_WORKER_ID}"
: "${REVIEW_LIFECYCLE_TEST_ALLOW_MUTATIONS:?Set REVIEW_LIFECYCLE_TEST_ALLOW_MUTATIONS=YES}"
[[ "$REVIEW_LIFECYCLE_TEST_ALLOW_MUTATIONS" == "YES" ]] || {
  echo "Refusing to run: set REVIEW_LIFECYCLE_TEST_ALLOW_MUTATIONS=YES for isolated fixtures." >&2
  exit 2
}

uuid_re='^[0-9a-fA-F-]{36}$'
for value in "$SUPABASE_OWNER_ID" "$SUPABASE_PROJECT_ID" "$SHARED_WORKER_ID" "$REVIEWER_WORKER_ID"; do
  [[ "$value" =~ $uuid_re ]] || { echo "Expected UUID environment values" >&2; exit 2; }
done
command -v psql >/dev/null || { echo "psql is required" >&2; exit 2; }

psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 \
  -v owner_id="$SUPABASE_OWNER_ID" \
  -v project_id="$SUPABASE_PROJECT_ID" \
  -v worker_id="$SHARED_WORKER_ID" \
  -v reviewer_worker_id="$REVIEWER_WORKER_ID" \
  -f tests/review-tests.sql

bash scripts/test-review-create-concurrency.sh

echo "PASS: review lifecycle integration assertions completed; transactional fixtures rolled back and concurrency fixture accepted."
