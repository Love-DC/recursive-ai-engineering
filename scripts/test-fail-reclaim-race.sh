#!/usr/bin/env bash
# Two-session race: a late failure report must lose to lease-expiry reclaim.
set -euo pipefail

: "$SUPABASE_DB_URL"
: "$SUPABASE_OWNER_ID"
: "$SUPABASE_PROJECT_ID"
: "$SHARED_WORKER_ID"
command -v psql >/dev/null || { echo "psql is required" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 -At <<SQL >"$tmp_dir/task.json"
SELECT set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', false);
SELECT public.create_task(
  '$SUPABASE_PROJECT_ID','$SHARED_WORKER_ID','implementation',
  'Fail/reclaim race fixture','Disposable isolated PostgreSQL race fixture',
  '{"retry":{"max_attempts":3}}'::jsonb,-100,false,null,null,
  'fail-reclaim-create-' || md5(clock_timestamp()::text)
);
SQL
task_id="$(tail -n 1 "$tmp_dir/task.json" | jq -r '.data.id')"
[[ "$task_id" =~ ^[0-9a-fA-F-]{36}$ ]] || { echo "Could not create race fixture task" >&2; exit 1; }

psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 -At <<SQL >"$tmp_dir/claim.json"
SELECT set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', false);
SELECT public.claim_task(
  '$SUPABASE_PROJECT_ID','$SHARED_WORKER_ID',600,
  'fail-reclaim-initial-claim-' || md5(clock_timestamp()::text)
);
SQL
old_execution_id="$(tail -n 1 "$tmp_dir/claim.json" | jq -r '.data.execution_id')"
[[ "$old_execution_id" =~ ^[0-9a-fA-F-]{36}$ ]] || { echo "Could not claim race fixture task" >&2; exit 1; }

psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 -c \
  "UPDATE public.tasks SET lease_until=clock_timestamp()-interval '1 second' WHERE id='$task_id' AND current_execution_id='$old_execution_id'"

# Launch the late failure report and the reclaim claim in separate sessions.
psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 >"$tmp_dir/fail.log" 2>&1 <<SQL &
SELECT set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', false);
DO \$race\$
BEGIN
  PERFORM public.fail_execution(
    '$task_id','$old_execution_id','$SHARED_WORKER_ID',
    'LATE_FAILURE','report raced with lease reclaim',
    'fail-reclaim-late-report-' || md5(clock_timestamp()::text)
  );
  RAISE EXCEPTION 'FAIL: late failure report unexpectedly succeeded';
EXCEPTION WHEN SQLSTATE '55000' THEN
  IF SQLERRM NOT IN ('EXECUTION_EXPIRED','EXECUTION_SUPERSEDED') THEN RAISE; END IF;
  RAISE NOTICE 'PASS: stale failure report was fenced (%).', SQLERRM;
END
\$race\$;
SQL
fail_pid=$!

psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 -At >"$tmp_dir/reclaim.json" 2>"$tmp_dir/reclaim.log" <<SQL &
SELECT set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', false);
SELECT public.claim_task(
  '$SUPABASE_PROJECT_ID','$SHARED_WORKER_ID',600,
  'fail-reclaim-race-claim-' || md5(clock_timestamp()::text)
);
SQL
claim_pid=$!

wait "$fail_pid"
wait "$claim_pid"

new_execution_id="$(tail -n 1 "$tmp_dir/reclaim.json" | jq -r '.data.execution_id')"
attempt="$(tail -n 1 "$tmp_dir/reclaim.json" | jq -r '.data.attempt')"
[[ "$new_execution_id" =~ ^[0-9a-fA-F-]{36}$ && "$new_execution_id" != "$old_execution_id" && "$attempt" == "2" ]] || {
  cat "$tmp_dir/fail.log" "$tmp_dir/reclaim.log" >&2
  echo "FAIL: reclaim did not create exactly attempt 2" >&2
  exit 1
}

state="$(psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 -Atc \
  "SELECT jsonb_build_object(
    'task_status',t.status,
    'old_execution_status',old.status,
    'new_execution_status',new.status,
    'new_attempt',new.attempt,
    'current_execution_id',t.current_execution_id
  ) FROM public.tasks t
  JOIN public.executions old ON old.id='$old_execution_id'
  JOIN public.executions new ON new.id='$new_execution_id'
  WHERE t.id='$task_id'")"
echo "$state" | jq -e \
  --arg new_id "$new_execution_id" \
  '.task_status=="running" and .old_execution_status=="expired" and .new_execution_status=="running" and .new_attempt==2 and .current_execution_id==$new_id' >/dev/null

echo "PASS: concurrent fail/reclaim race produced one valid transition and a fenced stale failure."
