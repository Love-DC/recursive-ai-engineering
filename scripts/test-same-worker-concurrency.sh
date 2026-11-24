#!/usr/bin/env bash
# Prove that multiple independent GPT-like sessions can share one logical Worker route.
# Two sessions using the same Worker ID must claim different tasks when two are ready,
# and exactly one session may claim a single available task.
set -euo pipefail

: "${SUPABASE_DB_URL:?Set SUPABASE_DB_URL}"
: "${SUPABASE_OWNER_ID:?Set SUPABASE_OWNER_ID}"
: "${SUPABASE_PROJECT_ID:?Set SUPABASE_PROJECT_ID}"
: "${SHARED_WORKER_ID:?Set SHARED_WORKER_ID}"

command -v psql >/dev/null || { echo "psql is required" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

uuid_re='^[0-9a-fA-F-]{36}$'
for value in "$SUPABASE_OWNER_ID" "$SUPABASE_PROJECT_ID" "$SHARED_WORKER_ID"; do
  [[ "$value" =~ $uuid_re ]] || { echo "Expected UUID environment values" >&2; exit 2; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
run_key="$(openssl rand -hex 16 2>/dev/null || printf '%s-%s' "$(date +%s)" "$$")"

claimable_count="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
with auth as (
  select set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', true)
)
select count(*)
from public.tasks, auth
where project_id = '$SUPABASE_PROJECT_ID'
  and (status = 'pending' or (status = 'running' and lease_until < clock_timestamp()));
SQL
)"
if [[ "$claimable_count" != "0" ]]; then
  echo "Refusing same-Worker concurrency probe: $claimable_count pending or expired task(s) could be leased as collateral." >&2
  exit 2
fi

worker_key="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
with auth as (
  select set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', true)
)
select worker_key
from public.workers, auth
where id = '$SHARED_WORKER_ID'
  and project_id = '$SUPABASE_PROJECT_ID'
  and status = 'active';
SQL
)"
[[ -n "$worker_key" ]] || { echo "Shared Worker route is not active in the selected project" >&2; exit 2; }

create_task() {
  local label="$1"
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 -v worker_key="$worker_key" <<SQL
with auth as (
  select set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', true)
)
select (public.create_task(
  '$SUPABASE_PROJECT_ID',
  '$SHARED_WORKER_ID',
  'implementation',
  'Same-Worker concurrency $run_key $label',
  'Disposable isolated task for two GPT sessions sharing one project Worker route.',
  jsonb_build_object('required_worker_key', :'worker_key'),
  0,
  false,
  null,
  null,
  'same-worker-create-$run_key-$label'
)->'data'->>'id')
from auth;
SQL
}

claim_session() {
  local label="$1"
  local scenario="$2"
  : > "$tmp/ready-$label"
  while [[ ! -f "$tmp/go" ]]; do sleep 0.02; done
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL > "$tmp/$label.json"
with auth as (
  select set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', true)
)
select public.claim_task(
  '$SUPABASE_PROJECT_ID',
  '$SHARED_WORKER_ID',
  600,
  'same-worker-claim-$run_key-$scenario-$label'
)
from auth;
SQL
}

complete_claim() {
  local scenario="$1"
  local label="$2"
  local task_id="$3"
  local execution_id="$4"
  local response_file="$tmp/complete-$label.json"

  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL > "$response_file"
with auth as (
  select set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', true)
)
select public.complete_execution(
  '$task_id',
  '$execution_id',
  '$SHARED_WORKER_ID',
  jsonb_build_object(
    'summary', 'Independent sessions sharing one logical Worker route claimed isolated work.',
    'session_label', '$label',
    'test_run', '$run_key'
  ),
  'same-worker-complete-$run_key-$scenario-$label'
)
from auth;
SQL

  if [[ "$(jq -r '.success // false' "$response_file")" != "true" \
    || "$(jq -r '.data.status // empty' "$response_file")" != "accepted" \
    || "$(jq -r '.data.task_id // empty' "$response_file")" != "$task_id" ]]; then
    echo "FAIL: completion did not accept first-case fixture $task_id: $(cat "$response_file")" >&2
    return 1
  fi

  local persisted_status
  persisted_status="$(
    psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
select status
from public.tasks
where id = '$task_id'
  and project_id = '$SUPABASE_PROJECT_ID';
SQL
  )"
  if [[ "$persisted_status" != "accepted" ]]; then
    echo "FAIL: completed fixture $task_id persisted as '$persisted_status', expected accepted" >&2
    return 1
  fi
}

# Case 1: two sessions, two eligible tasks, one shared Worker UUID.
task_a="$(create_task a)"
task_b="$(create_task b)"
[[ "$task_a" =~ $uuid_re && "$task_b" =~ $uuid_re && "$task_a" != "$task_b" ]] || {
  echo "Could not create two distinct same-Worker fixtures" >&2
  exit 1
}

claim_session a two-task &
pid_a=$!
claim_session b two-task &
pid_b=$!
while [[ ! -f "$tmp/ready-a" || ! -f "$tmp/ready-b" ]]; do sleep 0.02; done
touch "$tmp/go"
wait "$pid_a"
wait "$pid_b"

id_a="$(jq -r '.data.task_id // empty' "$tmp/a.json")"
id_b="$(jq -r '.data.task_id // empty' "$tmp/b.json")"
exec_a="$(jq -r '.data.execution_id // empty' "$tmp/a.json")"
exec_b="$(jq -r '.data.execution_id // empty' "$tmp/b.json")"

if [[ -z "$id_a" || -z "$id_b" || "$id_a" == "$id_b" ]]; then
  echo "FAIL: two same-Worker sessions must claim two different tasks; a=$id_a b=$id_b" >&2
  echo "Responses: $(cat "$tmp/a.json") / $(cat "$tmp/b.json")" >&2
  exit 1
fi
[[ ( "$id_a" == "$task_a" || "$id_a" == "$task_b" ) && ( "$id_b" == "$task_a" || "$id_b" == "$task_b" ) ]] || {
  echo "FAIL: a session claimed work outside the two same-Worker fixtures" >&2
  exit 1
}
[[ "$exec_a" =~ $uuid_re && "$exec_b" =~ $uuid_re ]] || {
  echo "FAIL: missing execution IDs for same-Worker claims" >&2
  exit 1
}

complete_claim two-task a "$id_a" "$exec_a"
complete_claim two-task b "$id_b" "$exec_b"

# The first race must leave no claimable fixtures behind. A completion RPC can
# return a JSON failure without making psql exit nonzero, so verify persisted
# terminal state and the project queue before starting the second race.
remaining_claimable="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
select count(*)
from public.tasks
where project_id = '$SUPABASE_PROJECT_ID'
  and (status = 'pending' or (status = 'running' and lease_until < clock_timestamp()));
SQL
)"
if [[ "$remaining_claimable" != "0" ]]; then
  echo "FAIL: first-case fixtures were not fully drained; $remaining_claimable claimable task(s) remain" >&2
  psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 <<SQL >&2
select id, status, assigned_worker_id, current_execution_id, lease_until, requirements
from public.tasks
where project_id = '$SUPABASE_PROJECT_ID'
  and (status = 'pending' or (status = 'running' and lease_until < clock_timestamp()))
order by created_at, id;
SQL
  exit 1
fi

# Case 2: two sessions, one eligible task, exactly one winner.
single_task="$(create_task single)"
[[ "$single_task" =~ $uuid_re ]] || { echo "Could not create single-task fixture" >&2; exit 1; }
echo "Single-task concurrency fixture: $single_task" >&2

# Prove isolation before releasing either claimant: the only claimable task
# must be the single fixture created for this case.
single_claimable_count="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
select count(*)
from public.tasks
where project_id = '$SUPABASE_PROJECT_ID'
  and (status = 'pending' or (status = 'running' and lease_until < clock_timestamp()));
SQL
)"
single_claimable_id="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
select id
from public.tasks
where project_id = '$SUPABASE_PROJECT_ID'
  and (status = 'pending' or (status = 'running' and lease_until < clock_timestamp()));
SQL
)"
if [[ "$single_claimable_count" != "1" || "$single_claimable_id" != "$single_task" ]]; then
  echo "FAIL: one-task race is not isolated; expected only $single_task, found count=$single_claimable_count ids=$single_claimable_id" >&2
  exit 1
fi

rm -f "$tmp/ready-a" "$tmp/ready-b" "$tmp/go"
claim_session a &
pid_a=$!
claim_session b &
pid_b=$!
while [[ ! -f "$tmp/ready-a" || ! -f "$tmp/ready-b" ]]; do sleep 0.02; done
touch "$tmp/go"
wait "$pid_a"
wait "$pid_b"

id_a="$(jq -r '.data.task_id // empty' "$tmp/a.json")"
id_b="$(jq -r '.data.task_id // empty' "$tmp/b.json")"
exec_a="$(jq -r '.data.execution_id // empty' "$tmp/a.json")"
exec_b="$(jq -r '.data.execution_id // empty' "$tmp/b.json")"

if [[ "$id_a" == "$single_task" && -z "$id_b" ]]; then
  complete_claim single-task a "$single_task" "$exec_a"
elif [[ "$id_b" == "$single_task" && -z "$id_a" ]]; then
  complete_claim single-task b "$single_task" "$exec_b"
else
  echo "FAIL: exactly one same-Worker session must claim the single task; a=$id_a b=$id_b" >&2
  echo "Responses: $(cat "$tmp/a.json") / $(cat "$tmp/b.json")" >&2
  exit 1
fi

echo "PASS: concurrent sessions sharing Worker $SHARED_WORKER_ID claimed distinct tasks and never duplicated a single task."
