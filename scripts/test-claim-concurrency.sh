#!/usr/bin/env bash
# Exercise claim_task from two independent PostgreSQL sessions using distinct Workers.
# Required environment:
#   SUPABASE_DB_URL, SUPABASE_OWNER_ID, SUPABASE_PROJECT_ID, SHARED_WORKER_ID, SECOND_WORKER_ID
set -euo pipefail

: "${SUPABASE_DB_URL:?Set SUPABASE_DB_URL to the isolated PostgreSQL connection string}"
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
  echo "SHARED_WORKER_ID and SECOND_WORKER_ID must identify distinct Workers" >&2
  exit 2
}

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
  echo "Refusing concurrency probe: $claimable_count pending or expired task(s) could be leased as collateral." >&2
  exit 2
fi

worker_count="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
with auth as (
  select set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', true)
)
select count(*)
from public.workers, auth
where project_id = '$SUPABASE_PROJECT_ID'
  and id in ('$SHARED_WORKER_ID', '$SECOND_WORKER_ID')
  and status = 'active';
SQL
)"
if [[ "$worker_count" != "2" ]]; then
  echo "Refusing concurrency probe: both distinct Worker IDs must be active in the selected project." >&2
  exit 2
fi

task_id="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
with auth as (
  select set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', true)
)
select (public.create_task(
  '$SUPABASE_PROJECT_ID',
  '$SHARED_WORKER_ID',
  'implementation',
  'Concurrency probe $run_key',
  'Disposable task created by scripts/test-claim-concurrency.sh; completion is recorded after the two-session claim assertion.',
  '{"acceptance":["exactly one of two independent sessions using distinct Worker IDs receives this task"]}'::jsonb,
  0,
  false,
  null,
  null,
  'claim-concurrency-create-$run_key'
)->'data'->>'id')
from auth;
SQL
)"

[[ "$task_id" =~ $uuid_re ]] || { echo "Could not create test task: $task_id" >&2; exit 1; }

claim_session() {
  local label="$1"
  local worker_id="$2"
  : > "$tmp/ready-$label"
  while [[ ! -f "$tmp/go" ]]; do sleep 0.02; done
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL > "$tmp/$label.json"
with auth as (
  select set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', true)
)
select public.claim_task(
  '$SUPABASE_PROJECT_ID',
  '$worker_id',
  600,
  'claim-concurrency-$run_key-$label'
)
from auth;
SQL
}

claim_session a "$SHARED_WORKER_ID" &
pid_a=$!
claim_session b "$SECOND_WORKER_ID" &
pid_b=$!
while [[ ! -f "$tmp/ready-a" || ! -f "$tmp/ready-b" ]]; do sleep 0.02; done
touch "$tmp/go"
wait "$pid_a"
wait "$pid_b"

id_a="$(jq -r '.data.task_id // empty' "$tmp/a.json")"
id_b="$(jq -r '.data.task_id // empty' "$tmp/b.json")"
exec_a="$(jq -r '.data.execution_id // empty' "$tmp/a.json")"
exec_b="$(jq -r '.data.execution_id // empty' "$tmp/b.json")"

if [[ "$id_a" == "$task_id" && -z "$id_b" ]]; then
  winner_exec="$exec_a"
  winner_worker="$SHARED_WORKER_ID"
elif [[ "$id_b" == "$task_id" && -z "$id_a" ]]; then
  winner_exec="$exec_b"
  winner_worker="$SECOND_WORKER_ID"
else
  echo "FAIL: expected exactly one claim for $task_id; session a=$id_a session b=$id_b" >&2
  echo "Responses: $(cat "$tmp/a.json") / $(cat "$tmp/b.json")" >&2
  exit 1
fi

[[ "$winner_exec" =~ $uuid_re ]] || { echo "Missing winning execution ID" >&2; exit 1; }

psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
with auth as (
  select set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', true)
)
select public.complete_execution(
  '$task_id',
  '$winner_exec',
  '$winner_worker',
  jsonb_build_object(
    'summary', 'Two independent PostgreSQL sessions using distinct Worker IDs raced to claim one task; exactly one received the lease.',
    'verification', jsonb_build_array('session a task_id=' || nullif('$id_a',''), 'session b task_id=' || nullif('$id_b','')),
    'test_run', '$run_key',
    'winning_worker_id', '$winner_worker'
  ),
  'claim-concurrency-complete-$run_key'
)
from auth;
SQL

final_state="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
with auth as (
  select set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', true)
)
select jsonb_build_object(
  'task_status', t.status,
  'execution_status', e.status,
  'execution_worker_id', e.worker_id
)
from public.tasks t
join public.executions e on e.id = '$winner_exec' and e.task_id = t.id, auth
where t.id = '$task_id';
SQL
)"
echo "$final_state" | jq -e \
  --arg winner_worker "$winner_worker" \
  '.task_status == "accepted" and .execution_status == "succeeded" and .execution_worker_id == $winner_worker' >/dev/null

echo "PASS: exactly one of two independent sessions using distinct Workers claimed $task_id"
echo "Winning execution: $winner_exec"
echo "Winning Worker: $winner_worker"
