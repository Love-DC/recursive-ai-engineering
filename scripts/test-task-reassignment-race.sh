#!/usr/bin/env bash
# Two-session race checks for pending-task reassignment versus claim_task.
# Required environment:
# SUPABASE_DB_URL, SUPABASE_OWNER_ID, SUPABASE_PROJECT_ID,
# SHARED_WORKER_ID, SECOND_WORKER_ID.
set -euo pipefail

: "${SUPABASE_DB_URL:?Set SUPABASE_DB_URL}"
: "${SUPABASE_OWNER_ID:?Set SUPABASE_OWNER_ID}"
: "${SUPABASE_PROJECT_ID:?Set SUPABASE_PROJECT_ID}"
: "${SHARED_WORKER_ID:?Set SHARED_WORKER_ID}"
: "${SECOND_WORKER_ID:?Set SECOND_WORKER_ID}"

command -v psql >/dev/null || { echo "psql is required" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

uuid_re='^[0-9a-fA-F-]{36}$'
for value in "$SUPABASE_OWNER_ID" "$SUPABASE_PROJECT_ID" "$SHARED_WORKER_ID" "$SECOND_WORKER_ID"; do
  [[ "$value" =~ $uuid_re ]] || { echo "Expected UUID environment values" >&2; exit 2; }
done
[[ "$SHARED_WORKER_ID" != "$SECOND_WORKER_ID" ]] || {
  echo "The two Worker IDs must be distinct" >&2
  exit 2
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
run_key="$(openssl rand -hex 16 2>/dev/null || printf '%s-%s' "$(date +%s)" "$$")"

claimable_count="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
select count(*)
from public.tasks
where project_id='$SUPABASE_PROJECT_ID'
  and (status='pending' or (status='running' and lease_until < clock_timestamp()));
SQL
)"
if [[ "$claimable_count" != "0" ]]; then
  echo "Refusing race probe: $claimable_count pending or expired task(s) could be claimed as collateral." >&2
  exit 2
fi

create_fixture() {
  local label="$1"
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
with auth as (
  select set_config('request.jwt.claim.sub','$SUPABASE_OWNER_ID',false)
)
select (public.create_task(
  '$SUPABASE_PROJECT_ID','$SHARED_WORKER_ID','implementation',
  'Reassignment race $run_key $label',
  'Disposable isolated PostgreSQL task for reassignment/claim row-lock ordering.',
  '{}'::jsonb,-1000,false,null,null,
  'reassignment-race-create-$run_key-$label'
)->'data'->>'id')
from auth;
SQL
}

wait_for_marker() {
  local marker="$1"
  for _ in $(seq 1 150); do
    local found
    found="$(psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 -c       "select count(*) from pg_stat_activity where pid <> pg_backend_pid() and state='active' and query like '%$marker%'")"
    [[ "$found" == "1" ]] && return 0
    sleep 0.04
  done
  echo "Timed out waiting for transaction marker: $marker" >&2
  return 1
}

# Race A: reassignment takes the row lock first. A concurrent claim must skip
# the locked row; after commit only the newly assigned Worker can claim it.
task_a="$(create_fixture first)"
[[ "$task_a" =~ $uuid_re ]] || { echo "Could not create race-A task: $task_a" >&2; exit 1; }

psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 >"$tmp/reassign-a.log" 2>&1 <<SQL &
BEGIN;
select set_config('request.jwt.claim.sub','$SUPABASE_OWNER_ID',true);
select public.reassign_pending_task(
  '$task_a',NULL::uuid,'$SECOND_WORKER_ID',
  'Concurrent reassignment-first fixture','reassignment-race-a-$run_key'
);
select pg_sleep(2) /* race_hold_reassign_$run_key */;
COMMIT;
SQL
reassign_pid=$!
wait_for_marker "race_hold_reassign_$run_key"

claim_during_reassign="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
select set_config('request.jwt.claim.sub','$SUPABASE_OWNER_ID',false);
select public.claim_task(
  '$SUPABASE_PROJECT_ID','$SECOND_WORKER_ID',600,
  'reassignment-race-a-claim-during-$run_key'
);
SQL
)"
claim_json="$(printf '%s\n' "$claim_during_reassign" | tail -n 1)"
if [[ "$(printf '%s' "$claim_json" | jq -r '.data.task_id // empty')" != "" ]]; then
  echo "FAIL: claim observed a task while reassignment held its row lock: $claim_json" >&2
  exit 1
fi
wait "$reassign_pid"

assigned_after_reassign="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 -c     "select assigned_worker_id from public.tasks where id='$task_a' and status='pending' and current_execution_id is null and lease_until is null"
)"
[[ "$assigned_after_reassign" == "$SECOND_WORKER_ID" ]] || {
  echo "FAIL: reassignment-first race persisted unexpected assignment '$assigned_after_reassign'" >&2
  exit 1
}

claim_after_reassign="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
select set_config('request.jwt.claim.sub','$SUPABASE_OWNER_ID',false);
select public.claim_task(
  '$SUPABASE_PROJECT_ID','$SECOND_WORKER_ID',600,
  'reassignment-race-a-claim-after-$run_key'
);
SQL
)"
claim_after_json="$(printf '%s\n' "$claim_after_reassign" | tail -n 1)"
claimed_task="$(printf '%s' "$claim_after_json" | jq -r '.data.task_id // empty')"
execution_a="$(printf '%s' "$claim_after_json" | jq -r '.data.execution_id // empty')"
if [[ "$claimed_task" != "$task_a" || ! "$execution_a" =~ $uuid_re ]]; then
  echo "FAIL: correctly routed Worker could not claim after reassignment committed: $claim_after_json" >&2
  exit 1
fi
psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 >/dev/null <<SQL
select set_config('request.jwt.claim.sub','$SUPABASE_OWNER_ID',false);
select public.complete_execution(
  '$task_a','$execution_a','$SECOND_WORKER_ID',
  '{"summary":"reassignment-first concurrency fixture completed"}'::jsonb,
  'reassignment-race-a-complete-$run_key'
);
SQL

# Race B: claim_task obtains the task lock first. Reassignment must wait, then
# reject the now-running task instead of replacing its live lease/Worker.
task_b="$(create_fixture second)"
[[ "$task_b" =~ $uuid_re ]] || { echo "Could not create race-B task: $task_b" >&2; exit 1; }
psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 >/dev/null <<SQL
update public.tasks set assigned_worker_id='$SHARED_WORKER_ID'
where id='$task_b' and project_id='$SUPABASE_PROJECT_ID' and status='pending';
SQL

psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 >"$tmp/claim-b.log" 2>&1 <<SQL &
BEGIN;
select set_config('request.jwt.claim.sub','$SUPABASE_OWNER_ID',true);
select public.claim_task(
  '$SUPABASE_PROJECT_ID','$SHARED_WORKER_ID',600,
  'reassignment-race-b-claim-$run_key'
);
select pg_sleep(2) /* race_hold_claim_$run_key */;
COMMIT;
SQL
claim_pid=$!
wait_for_marker "race_hold_claim_$run_key"

if psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 >"$tmp/reassign-b.log" 2>&1 <<SQL
select set_config('request.jwt.claim.sub','$SUPABASE_OWNER_ID',false);
select public.reassign_pending_task(
  '$task_b','$SHARED_WORKER_ID','$SECOND_WORKER_ID',
  'Must not replace a concurrent live claim','reassignment-race-b-reassign-$run_key'
);
SQL
then
  echo "FAIL: reassignment succeeded after claim_task acquired the task lock." >&2
  exit 1
fi
if ! grep -q "TASK_NOT_PENDING" "$tmp/reassign-b.log"; then
  cat "$tmp/reassign-b.log" >&2
  echo "FAIL: concurrent reassignment did not fail specifically with TASK_NOT_PENDING." >&2
  exit 1
fi
wait "$claim_pid"

state_b="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 -c     "select jsonb_build_object('status',status,'assigned_worker_id',assigned_worker_id,'execution_id',current_execution_id,'leased',lease_until > clock_timestamp()) from public.tasks where id='$task_b'"
)"
echo "$state_b" | jq -e --arg worker "$SHARED_WORKER_ID"   '.status=="running" and .assigned_worker_id==$worker and .execution_id!=null and .leased==true' >/dev/null || {
    echo "FAIL: claim-first race did not preserve the live Worker execution: $state_b" >&2
    exit 1
  }
execution_b="$(echo "$state_b" | jq -r '.execution_id')"
psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 >/dev/null <<SQL
select set_config('request.jwt.claim.sub','$SUPABASE_OWNER_ID',false);
select public.complete_execution(
  '$task_b','$execution_b','$SHARED_WORKER_ID',
  '{"summary":"claim-first concurrency fixture completed"}'::jsonb,
  'reassignment-race-b-complete-$run_key'
);
SQL

echo "PASS: reassignment-first claims skip the locked row; claim-first reassignment is fenced by TASK_NOT_PENDING."
