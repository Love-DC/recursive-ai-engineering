#!/usr/bin/env bash
# Prove active repository-branch leases are exclusive across independent claims.
# Runs only against the disposable PostgreSQL fixture in postgres-task-lifecycle.yml.
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
  echo "Two distinct project Worker UUIDs are required" >&2
  exit 2
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
run_key="$(openssl rand -hex 16 2>/dev/null || printf '%s-%s' "$(date +%s)" "$$")"
repo_name="Love-DC/recursive-ai-engineering"
same_branch="rae-branch-exclusive-$run_key"
other_branch="rae-branch-independent-$run_key"
expired_branch="rae-branch-expired-$run_key"

claimable_count="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
with auth as (
  select set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', true)
)
select count(*)
from public.tasks, auth
where project_id='$SUPABASE_PROJECT_ID'
  and (status='pending' or (status='running' and lease_until < clock_timestamp()));
SQL
)"
if [[ "$claimable_count" != "0" ]]; then
  echo "Refusing branch contention test: $claimable_count pending/expired task(s) could be claimed as collateral." >&2
  exit 2
fi

worker_count="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
with auth as (
  select set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', true)
)
select count(*)
from public.workers, auth
where project_id='$SUPABASE_PROJECT_ID'
  and id in ('$SHARED_WORKER_ID','$SECOND_WORKER_ID')
  and status='active';
SQL
)"
[[ "$worker_count" == "2" ]] || {
  echo "Both distinct Workers must be active in the selected project" >&2
  exit 2
}

fixtures="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
with auth as (
  select set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', true)
)
select jsonb_build_object(
  'same_a', (public.create_task(
    '$SUPABASE_PROJECT_ID','$SHARED_WORKER_ID','implementation',
    'Branch exclusion same-resource A $run_key',
    'Disposable two-session fixture for target.branch.',
    jsonb_build_object('target',jsonb_build_object('repository','$repo_name','branch','$same_branch')),
    -20,false,null,null,'branch-exclusion-create-$run_key-a'
  )->'data'->>'id'),
  'same_b', (public.create_task(
    '$SUPABASE_PROJECT_ID','$SHARED_WORKER_ID','implementation',
    'Branch exclusion same-resource B $run_key',
    'Disposable two-session fixture for target.worker_branch.',
    jsonb_build_object('target',jsonb_build_object('repository','$repo_name','worker_branch','$same_branch')),
    -19,false,null,null,'branch-exclusion-create-$run_key-b'
  )->'data'->>'id'),
  'other', (public.create_task(
    '$SUPABASE_PROJECT_ID','$SHARED_WORKER_ID','implementation',
    'Branch exclusion independent resource $run_key',
    'This unrelated branch must remain claimable while the first branch is reserved.',
    jsonb_build_object('target',jsonb_build_object('repository','$repo_name','branch','$other_branch')),
    100,false,null,null,'branch-exclusion-create-$run_key-other'
  )->'data'->>'id')
)
from auth;
SQL
)"

same_a="$(jq -r '.same_a' <<<"$fixtures")"
same_b="$(jq -r '.same_b' <<<"$fixtures")"
other_task="$(jq -r '.other' <<<"$fixtures")"
for value in "$same_a" "$same_b" "$other_task"; do
  [[ "$value" =~ $uuid_re ]] || { echo "Could not create branch fixture tasks: $fixtures" >&2; exit 1; }
done

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
  '$SUPABASE_PROJECT_ID','$worker_id',600,
  'branch-exclusion-claim-$run_key-$label'
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

same_claims=0
other_claims=0
for task in "$id_a" "$id_b"; do
  case "$task" in
    "$same_a"|"$same_b") same_claims=$((same_claims + 1)) ;;
    "$other_task") other_claims=$((other_claims + 1)) ;;
    *) echo "Unexpected or empty claim result: a=$id_a b=$id_b" >&2; exit 1 ;;
  esac
done
[[ "$same_claims" == "1" && "$other_claims" == "1" ]] || {
  echo "FAIL: expected one claim for the shared branch and one for the independent branch; a=$id_a b=$id_b" >&2
  echo "Responses: $(cat "$tmp/a.json") / $(cat "$tmp/b.json")" >&2
  exit 1
}

for response in "$tmp/a.json" "$tmp/b.json"; do
  jq -e '.success == true and (.data.execution_id | type == "string")' "$response" >/dev/null
done

active_same_count="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
select count(*)
from public.tasks
where project_id='$SUPABASE_PROJECT_ID'
  and id in ('$same_a','$same_b')
  and status='running'
  and lease_until > clock_timestamp();
SQL
)"
[[ "$active_same_count" == "1" ]] || {
  echo "FAIL: expected exactly one non-expired execution on $same_branch; found $active_same_count" >&2
  exit 1
}

complete_claim() {
  local task_id="$1"
  local execution_id="$2"
  local worker_id="$3"
  local suffix="$4"
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL >/dev/null
with auth as (
  select set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', true)
)
select public.complete_execution(
  '$task_id','$execution_id','$worker_id',
  jsonb_build_object('summary','Branch exclusion integration fixture completed','test_run','$run_key'),
  'branch-exclusion-complete-$run_key-$suffix'
)
from auth;
SQL
}

if [[ "$id_a" == "$same_a" || "$id_a" == "$same_b" ]]; then
  complete_claim "$id_a" "$exec_a" "$SHARED_WORKER_ID" first
else
  complete_claim "$id_a" "$exec_a" "$SHARED_WORKER_ID" other-first
fi
if [[ "$id_b" == "$same_a" || "$id_b" == "$same_b" ]]; then
  complete_claim "$id_b" "$exec_b" "$SECOND_WORKER_ID" second
else
  complete_claim "$id_b" "$exec_b" "$SECOND_WORKER_ID" other-second
fi

remaining_same="$same_a"
[[ "$id_a" != "$same_a" && "$id_b" != "$same_a" ]] || remaining_same="$same_b"

remaining_claim="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
with auth as (
  select set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', true)
)
select public.claim_task(
  '$SUPABASE_PROJECT_ID','$SHARED_WORKER_ID',600,
  'branch-exclusion-reclaim-$run_key'
)
from auth;
SQL
)"
remaining_id="$(jq -r '.data.task_id // empty' <<<"$remaining_claim")"
remaining_exec="$(jq -r '.data.execution_id // empty' <<<"$remaining_claim")"
[[ "$remaining_id" == "$remaining_same" && "$remaining_exec" =~ $uuid_re ]] || {
  echo "FAIL: released same-branch resource did not become claimable: $remaining_claim" >&2
  exit 1
}
complete_claim "$remaining_id" "$remaining_exec" "$SHARED_WORKER_ID" remaining

# A stale lease must not retain its branch reservation. The expired task is
# routed only to Worker A; Worker B must claim the same branch's pending task.
expired_fixtures="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
with auth as (
  select set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', true)
)
select jsonb_build_object(
  'expired', (public.create_task(
    '$SUPABASE_PROJECT_ID','$SHARED_WORKER_ID','implementation',
    'Expired branch owner $run_key',
    'Worker A lease will be expired before Worker B claims the same branch.',
    jsonb_build_object(
      'required_worker_key','test-worker-a',
      'target',jsonb_build_object('repository','$repo_name','branch','$expired_branch')
    ),
    -20,false,null,null,'branch-exclusion-expired-create-$run_key-a'
  )->'data'->>'id'),
  'replacement', (public.create_task(
    '$SUPABASE_PROJECT_ID','$SHARED_WORKER_ID','implementation',
    'Expired branch replacement $run_key',
    'Worker B must proceed after the previous branch lease expires.',
    jsonb_build_object(
      'required_worker_key','test-worker-b',
      'target',jsonb_build_object('repository','$repo_name','worker_branch','$expired_branch')
    ),
    -19,false,null,null,'branch-exclusion-expired-create-$run_key-b'
  )->'data'->>'id')
)
from auth;
SQL
)"
expired_id="$(jq -r '.expired' <<<"$expired_fixtures")"
replacement_id="$(jq -r '.replacement' <<<"$expired_fixtures")"
[[ "$expired_id" =~ $uuid_re && "$replacement_id" =~ $uuid_re ]] || {
  echo "Could not create expired-lease fixtures: $expired_fixtures" >&2
  exit 1
}

expired_claim="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
with auth as (
  select set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', true)
)
select public.claim_task(
  '$SUPABASE_PROJECT_ID','$SHARED_WORKER_ID',600,
  'branch-exclusion-expired-owner-$run_key'
)
from auth;
SQL
)"
expired_claim_id="$(jq -r '.data.task_id // empty' <<<"$expired_claim")"
expired_execution="$(jq -r '.data.execution_id // empty' <<<"$expired_claim")"
[[ "$expired_claim_id" == "$expired_id" && "$expired_execution" =~ $uuid_re ]] || {
  echo "Could not claim the expired-reservation fixture: $expired_claim" >&2
  exit 1
}

psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 -v task_id="$expired_id" <<'SQL' >/dev/null
UPDATE public.tasks
SET lease_until=clock_timestamp()-interval '1 second'
WHERE id=:'task_id'::uuid AND status='running';
SQL

replacement_claim="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
with auth as (
  select set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', true)
)
select public.claim_task(
  '$SUPABASE_PROJECT_ID','$SECOND_WORKER_ID',600,
  'branch-exclusion-expired-replacement-$run_key'
)
from auth;
SQL
)"
replacement_claim_id="$(jq -r '.data.task_id // empty' <<<"$replacement_claim")"
replacement_execution="$(jq -r '.data.execution_id // empty' <<<"$replacement_claim")"
[[ "$replacement_claim_id" == "$replacement_id" && "$replacement_execution" =~ $uuid_re ]] || {
  echo "FAIL: expired branch lease incorrectly blocked the eligible replacement: $replacement_claim" >&2
  exit 1
}
complete_claim "$replacement_id" "$replacement_execution" "$SECOND_WORKER_ID" expired-replacement

reclaimed_expired="$(
  psql "$SUPABASE_DB_URL" -XAtq -v ON_ERROR_STOP=1 <<SQL
with auth as (
  select set_config('request.jwt.claim.sub', '$SUPABASE_OWNER_ID', true)
)
select public.claim_task(
  '$SUPABASE_PROJECT_ID','$SHARED_WORKER_ID',600,
  'branch-exclusion-expired-reclaim-$run_key'
)
from auth;
SQL
)"
reclaimed_id="$(jq -r '.data.task_id // empty' <<<"$reclaimed_expired")"
reclaimed_execution="$(jq -r '.data.execution_id // empty' <<<"$reclaimed_expired")"
[[ "$reclaimed_id" == "$expired_id" && "$reclaimed_execution" =~ $uuid_re ]] || {
  echo "FAIL: the expired task itself could not be safely reclaimed after branch release: $reclaimed_expired" >&2
  exit 1
}
complete_claim "$expired_id" "$reclaimed_execution" "$SHARED_WORKER_ID" expired-owner-reclaimed

echo "PASS: same-branch dual claims are mutually exclusive across two sessions."
echo "PASS: an unrelated branch remains claimable while the first branch is leased."
echo "PASS: the same branch is reusable after completion and after lease expiry."
