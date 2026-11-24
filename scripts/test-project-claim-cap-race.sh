#!/usr/bin/env bash
# Race three independent sessions against a project-wide cap of two active executions.
# All fixture tasks are completed before the script exits.
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
select count(*) from public.tasks
where project_id='$SUPABASE_PROJECT_ID'
  and (status='pending' or (status='running' and lease_until < clock_timestamp()));
SQL
)"
if [[ "$claimable_count" != "0" ]]; then
  echo "Refusing concurrency-cap race: $claimable_count pending or expired task(s) could be leased as collateral." >&2
  exit 2
fi

create_task() {
  local label="$1"
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
with auth as (
  select set_config('request.jwt.claim.sub','$SUPABASE_OWNER_ID',true)
)
select (public.create_task(
  '$SUPABASE_PROJECT_ID','$SHARED_WORKER_ID','implementation',
  'Project cap race $run_key $label',
  'Disposable task for the three-session project concurrency cap regression.',
  '{"acceptance":["task is claimed only when project active executions are below two"]}'::jsonb,
  0,false,null,null,'project-cap-create-$run_key-$label'
)->'data'->>'id') from auth;
SQL
}

task_a="$(create_task a)"
task_b="$(create_task b)"
task_c="$(create_task c)"
for id in "$task_a" "$task_b" "$task_c"; do
  [[ "$id" =~ $uuid_re ]] || { echo "Could not create cap-race fixture: $id" >&2; exit 1; }
done

claim_session() {
  local label="$1"
  : > "$tmp/ready-$label"
  while [[ ! -f "$tmp/go" ]]; do sleep 0.02; done
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL > "$tmp/$label.json"
with auth as (
  select set_config('request.jwt.claim.sub','$SUPABASE_OWNER_ID',true)
)
select public.claim_task(
  '$SUPABASE_PROJECT_ID','$SHARED_WORKER_ID',600,
  'project-cap-claim-$run_key-$label'
) from auth;
SQL
}

claim_session a &
pid_a=$!
claim_session b &
pid_b=$!
claim_session c &
pid_c=$!
while [[ ! -f "$tmp/ready-a" || ! -f "$tmp/ready-b" || ! -f "$tmp/ready-c" ]]; do sleep 0.02; done
touch "$tmp/go"
wait "$pid_a"
wait "$pid_b"
wait "$pid_c"

id_a="$(jq -r '.data.task_id // empty' "$tmp/a.json")"
id_b="$(jq -r '.data.task_id // empty' "$tmp/b.json")"
id_c="$(jq -r '.data.task_id // empty' "$tmp/c.json")"
exec_a="$(jq -r '.data.execution_id // empty' "$tmp/a.json")"
exec_b="$(jq -r '.data.execution_id // empty' "$tmp/b.json")"
exec_c="$(jq -r '.data.execution_id // empty' "$tmp/c.json")"

claimed=()
for id in "$id_a" "$id_b" "$id_c"; do
  [[ -n "$id" ]] && claimed+=("$id")
done
if [[ "${#claimed[@]}" -ne 2 || "${claimed[0]}" == "${claimed[1]}" ]]; then
  echo "FAIL: expected exactly two distinct claims; a=$id_a b=$id_b c=$id_c" >&2
  echo "Responses: $(cat "$tmp/a.json") / $(cat "$tmp/b.json") / $(cat "$tmp/c.json")" >&2
  exit 1
fi

blocked_count=0
for label in a b c; do
  if [[ -z "$(jq -r '.data.task_id // empty' "$tmp/$label.json")" ]]; then
    jq -e '.data.blocked_reason == "PROJECT_CONCURRENCY_LIMIT_REACHED" and .data.active_executions == 2 and .data.max_active_executions == 2' "$tmp/$label.json" >/dev/null
    blocked_count=$((blocked_count+1))
  fi
done
[[ "$blocked_count" -eq 1 ]] || { echo "FAIL: exactly one session must be blocked at cap" >&2; exit 1; }

complete_task() {
  local task_id="$1"
  local execution_id="$2"
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL >/dev/null
with auth as (
  select set_config('request.jwt.claim.sub','$SUPABASE_OWNER_ID',true)
)
select public.complete_execution(
  '$task_id','$execution_id','$SHARED_WORKER_ID',
  jsonb_build_object('summary','Completed project concurrency cap fixture','test_run','$run_key'),
  'project-cap-complete-$run_key-$task_id'
) from auth;
SQL
}

for label in a b c; do
  id="$(jq -r '.data.task_id // empty' "$tmp/$label.json")"
  exec_id="$(jq -r '.data.execution_id // empty' "$tmp/$label.json")"
  if [[ -n "$id" ]]; then
    [[ "$exec_id" =~ $uuid_re ]] || { echo "Missing execution ID for $label" >&2; exit 1; }
    complete_task "$id" "$exec_id"
  fi
done

remaining_task=""
for id in "$task_a" "$task_b" "$task_c"; do
  if [[ "$id" != "$id_a" && "$id" != "$id_b" && "$id" != "$id_c" ]]; then
    remaining_task="$id"
  fi
done
[[ "$remaining_task" =~ $uuid_re ]] || { echo "Could not identify the unclaimed fixture task" >&2; exit 1; }

after_release="$(psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
with auth as (
  select set_config('request.jwt.claim.sub','$SUPABASE_OWNER_ID',true)
)
select public.claim_task(
  '$SUPABASE_PROJECT_ID','$SHARED_WORKER_ID',600,'project-cap-after-release-$run_key'
) from auth;
SQL
)"
after_id="$(printf '%s' "$after_release" | jq -r '.data.task_id // empty')"
after_exec="$(printf '%s' "$after_release" | jq -r '.data.execution_id // empty')"
if [[ "$after_id" != "$remaining_task" || ! "$after_exec" =~ $uuid_re ]]; then
  echo "FAIL: a released slot did not allow the remaining task to be claimed: $after_release" >&2
  exit 1
fi
complete_task "$after_id" "$after_exec"

echo "PASS: three concurrent sessions never exceeded two active project executions; the blocked task became claimable after a slot was released."
