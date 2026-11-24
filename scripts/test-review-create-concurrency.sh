#!/usr/bin/env bash
# Two PostgreSQL sessions concurrently create a review for the same delivery execution.
# The original-task row lock must serialize them so exactly one review is created.
set -euo pipefail

: "${SUPABASE_DB_URL:?Set SUPABASE_DB_URL}"
: "${SUPABASE_OWNER_ID:?Set SUPABASE_OWNER_ID}"
: "${SUPABASE_PROJECT_ID:?Set SUPABASE_PROJECT_ID}"
: "${SHARED_WORKER_ID:?Set SHARED_WORKER_ID}"
: "${REVIEWER_WORKER_ID:?Set REVIEWER_WORKER_ID}"
[[ "${REVIEW_LIFECYCLE_TEST_ALLOW_MUTATIONS:-}" == "YES" ]] || {
  echo "Refusing to run: set REVIEW_LIFECYCLE_TEST_ALLOW_MUTATIONS=YES for disposable isolated fixtures." >&2
  exit 2
}
command -v psql >/dev/null || { echo "psql is required" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

uuid_re='^[0-9a-fA-F-]{36}$'
for value in "$SUPABASE_OWNER_ID" "$SUPABASE_PROJECT_ID" "$SHARED_WORKER_ID" "$REVIEWER_WORKER_ID"; do
  [[ "$value" =~ $uuid_re ]] || { echo "Expected UUID environment values" >&2; exit 2; }
done

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
run_key="$(openssl rand -hex 16 2>/dev/null || printf '%s-%s' "$(date +%s)" "$$")"

original_id="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
SET request.jwt.claim.sub = '$SUPABASE_OWNER_ID';
SELECT (public.create_task(
  '$SUPABASE_PROJECT_ID',
  '$SHARED_WORKER_ID',
  'implementation',
  'Concurrent review creation fixture $run_key',
  'Disposable fixture for two-session create_review_task serialization.',
  '{"test":"review-create-concurrency"}'::jsonb,
  -200,
  true,
  null,
  null,
  'review-create-concurrency-original-$run_key'
)->'data'->>'id');
SQL
)"
[[ "$original_id" =~ $uuid_re ]] || { echo "Could not create original task: $original_id" >&2; exit 1; }

implementation_claim="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
SET request.jwt.claim.sub = '$SUPABASE_OWNER_ID';
SELECT public.claim_task(w.project_id,w.id,600,'review-create-concurrency-implementation-$run_key')
FROM public.workers w
WHERE w.id='$SHARED_WORKER_ID' AND w.project_id='$SUPABASE_PROJECT_ID';
SQL
)"
implementation_execution="$(echo "$implementation_claim" | jq -r '.data.execution_id // empty')"
claimed_original="$(echo "$implementation_claim" | jq -r '.data.task_id // empty')"
[[ "$claimed_original" == "$original_id" && "$implementation_execution" =~ $uuid_re ]] || {
  echo "Could not claim concurrency fixture implementation task: $implementation_claim" >&2
  exit 1
}

submit_result="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
SET request.jwt.claim.sub = '$SUPABASE_OWNER_ID';
SELECT public.submit_result(
  '$original_id',
  '$implementation_execution',
  '$SHARED_WORKER_ID',
  '{"summary":"submitted for concurrent review-creation test"}'::jsonb,
  'review-create-concurrency-submit-$run_key'
);
SQL
)"
echo "$submit_result" | jq -e '.data.status == "submitted"' >/dev/null

# Session A owns the original task row before the competing function call begins.
# The explicit marker is emitted only after FOR UPDATE has acquired the row lock.
psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 >"$tmp/a.out" 2>"$tmp/a.err" <<SQL &
BEGIN;
SET LOCAL request.jwt.claim.sub = '$SUPABASE_OWNER_ID';
SELECT 1 FROM public.tasks WHERE id='$original_id' FOR UPDATE;
\echo REVIEW_ORIGINAL_LOCKED
SELECT pg_sleep(3);
SELECT public.create_review_task(
  '$original_id','$original_id','$implementation_execution','$REVIEWER_WORKER_ID',
  'review-create-concurrency-a-$run_key'
);
COMMIT;
SQL
pid_a=$!

for _ in $(seq 1 200); do
  if grep -q "REVIEW_ORIGINAL_LOCKED" "$tmp/a.out"; then break; fi
  if ! kill -0 "$pid_a" 2>/dev/null; then
    echo "Session A exited before acquiring the original-task lock" >&2
    cat "$tmp/a.out" "$tmp/a.err" >&2
    exit 1
  fi
  sleep 0.02
done
grep -q "REVIEW_ORIGINAL_LOCKED" "$tmp/a.out" || {
  echo "Session A did not acquire the original-task lock in time" >&2
  cat "$tmp/a.out" "$tmp/a.err" >&2
  exit 1
}

# Session B enters create_review_task while A holds the original task lock.
set +e
psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 >"$tmp/b.out" 2>"$tmp/b.err" <<SQL &
SET request.jwt.claim.sub = '$SUPABASE_OWNER_ID';
SELECT public.create_review_task(
  '$original_id','$original_id','$implementation_execution','$REVIEWER_WORKER_ID',
  'review-create-concurrency-b-$run_key'
);
SQL
pid_b=$!
set -e

blocked=false
for _ in $(seq 1 200); do
  waiting="$(
    psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 -c \
      "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' AND query ILIKE '%review-create-concurrency-b-$run_key%';"
  )"
  if [[ "$waiting" =~ ^[1-9][0-9]*$ ]]; then blocked=true; break; fi
  sleep 0.02
done
if [[ "$blocked" != "true" ]]; then
  echo "FAIL: second session was not observed waiting on the original-task lock" >&2
  cat "$tmp/a.out" "$tmp/a.err" "$tmp/b.out" "$tmp/b.err" >&2
  exit 1
fi

wait "$pid_a"
set +e
wait "$pid_b"
b_status=$?
set -e
if [[ "$b_status" -eq 0 ]]; then
  echo "FAIL: both concurrent review creation calls succeeded" >&2
  cat "$tmp/a.out" "$tmp/b.out" >&2
  exit 1
fi
grep -q "REVIEW_ALREADY_EXISTS" "$tmp/b.err" || {
  echo "FAIL: losing session did not receive REVIEW_ALREADY_EXISTS" >&2
  cat "$tmp/a.out" "$tmp/a.err" "$tmp/b.out" "$tmp/b.err" >&2
  exit 1
}

review_count="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 -c \
    "SELECT count(*) FROM public.tasks WHERE task_type='review' AND review_target_original_task_id='$original_id' AND review_target_delivery_task_id='$original_id' AND review_target_execution_id='$implementation_execution';"
)"
[[ "$review_count" == "1" ]] || {
  echo "FAIL: expected exactly one review row after concurrent create, got $review_count" >&2
  exit 1
}

review_id="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 -c \
    "SELECT id FROM public.tasks WHERE task_type='review' AND review_target_original_task_id='$original_id' AND review_target_delivery_task_id='$original_id' AND review_target_execution_id='$implementation_execution';"
)"
review_claim="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
SET request.jwt.claim.sub = '$SUPABASE_OWNER_ID';
SELECT public.claim_task(w.project_id,w.id,600,'review-create-concurrency-review-claim-$run_key')
FROM public.workers w
WHERE w.id='$REVIEWER_WORKER_ID' AND w.project_id='$SUPABASE_PROJECT_ID';
SQL
)"
review_execution="$(echo "$review_claim" | jq -r '.data.execution_id // empty')"
claimed_review="$(echo "$review_claim" | jq -r '.data.task_id // empty')"
[[ "$claimed_review" == "$review_id" && "$review_execution" =~ $uuid_re ]] || {
  echo "Could not claim sole review task: $review_claim" >&2
  exit 1
}

review_result="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
SET request.jwt.claim.sub = '$SUPABASE_OWNER_ID';
SELECT public.review_result(
  '$review_id','$review_execution','$REVIEWER_WORKER_ID','accepted',
  '{"summary":"concurrent creation produced exactly one review task"}'::jsonb,
  'review-create-concurrency-result-$run_key'
);
SQL
)"
echo "$review_result" | jq -e '.data.decision == "accepted"' >/dev/null

final_state="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 -c \
    "SELECT jsonb_build_object('original_status',(SELECT status FROM public.tasks WHERE id='$original_id'),'review_status',(SELECT status FROM public.tasks WHERE id='$review_id'),'review_count',(SELECT count(*) FROM public.tasks WHERE task_type='review' AND review_target_original_task_id='$original_id' AND review_target_delivery_task_id='$original_id' AND review_target_execution_id='$implementation_execution'));"
)"
echo "$final_state" | jq -e '.original_status == "accepted" and .review_status == "accepted" and .review_count == 1' >/dev/null

echo "PASS: concurrent review creation serialized; one task created and accepted; second session received REVIEW_ALREADY_EXISTS."
