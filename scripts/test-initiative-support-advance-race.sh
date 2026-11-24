#!/usr/bin/env bash
set -euo pipefail

: "${SUPABASE_DB_URL:?Set SUPABASE_DB_URL to the isolated PostgreSQL test database}"
command -v psql >/dev/null || { echo "psql is required" >&2; exit 2; }

tmp_dir="$(mktemp -d)"
request_pid=""
project_id=""
cleanup() {
  if [[ -n "$request_pid" ]]; then
    kill "$request_pid" >/dev/null 2>&1 || true
    wait "$request_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$project_id" ]]; then
    psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 \
      -c "DELETE FROM public.projects WHERE id='$project_id'::uuid;" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

owner_id="$(psql "$SUPABASE_DB_URL" -X -At -v ON_ERROR_STOP=1 \
  -c "SELECT id FROM auth.users WHERE deleted_at IS NULL ORDER BY created_at LIMIT 1")"
[[ -n "$owner_id" ]] || { echo "FAIL: no fixture Owner exists" >&2; exit 1; }

fixture="$(psql "$SUPABASE_DB_URL" -X -qAt -v ON_ERROR_STOP=1 -v owner_id="$owner_id" <<'SQL'
SELECT set_config('request.jwt.claim.sub', :'owner_id', false) AS auth_context \gset
SELECT (public.register_project(
  'initiative support/advance race test','isolated concurrency fixture',NULL,'{}'::jsonb,
  'initiative-support-race-'||gen_random_uuid()::text
)->'data'->>'id') AS project_id \gset
SELECT (public.register_worker(:'project_id'::uuid,'support-race-executor',
  'Support Race Executor','isolated concurrency test')->'data'->>'id') AS worker_id \gset
SELECT (public.propose_initiative(
  :'project_id'::uuid, :'worker_id'::uuid,
  jsonb_build_object(
    'origin','ai_initiative',
    'title','Exercise support and advancement serialization',
    'summary','A pending support request must block task materialization under concurrency.',
    'rationale','The race harness deliberately overlaps request and advancement transactions.',
    'desired_outcome','No initiative task exists while support is pending.',
    'scope',jsonb_build_array('isolated PostgreSQL concurrency fixture'),
    'evidence',jsonb_build_array(jsonb_build_object(
      'kind','test','ref','tests/test-initiative-support-advance-race.sh',
      'observation','Deterministic two-connection race fixture'
    )),
    'risk','low','resource_budget','{}'::jsonb,'support_needed','[]'::jsonb,
    'deduplication_fingerprint','test:initiative:support-advance-race:'||gen_random_uuid()::text
  ),
  'support-race-proposal-'||gen_random_uuid()::text
)->'data'->>'initiative_id') AS initiative_id \gset
SELECT public.decide_initiative(
  :'initiative_id'::uuid,'approve','Approve one bounded race-test work item.',
  jsonb_build_array(jsonb_build_object(
    'work_key','only-work','title','Materialize only after support is resolved',
    'description','This task must remain unmaterialized while support is pending.',
    'requires_review',false,'depends_on',jsonb_build_array()
  )),
  'support-race-approve-'||gen_random_uuid()::text
) AS decision_result \gset
\echo :project_id :worker_id :initiative_id
SQL
)"
read -r project_id worker_id initiative_id <<< "$fixture"
[[ -n "$project_id" && -n "$worker_id" && -n "$initiative_id" ]] || {
  echo "FAIL: fixture identifiers were not created" >&2
  exit 1
}

# Connection A creates the pending support request and deliberately holds its
# transaction open after the RPC returns. The RPC must retain the initiative
# row lock until commit.
PGAPPNAME=initiative-support-race-request psql "$SUPABASE_DB_URL" -X -qAt -v ON_ERROR_STOP=1 \
  -v owner_id="$owner_id" -v initiative_id="$initiative_id" -v worker_id="$worker_id" \
  >"$tmp_dir/request.log" 2>&1 <<'SQL' &
SELECT set_config('request.jwt.claim.sub', :'owner_id', false) AS auth_context \gset
BEGIN;
SELECT public.request_initiative_support(
  :'initiative_id'::uuid, :'worker_id'::uuid,
  jsonb_build_object(
    'request_kind','permission',
    'capability','Temporary read-only test capability',
    'rationale','The concurrent test requires a pending support gate.',
    'alternatives_checked',jsonb_build_array('Existing fixture state'),
    'unlocks','The support/advance serialization assertion.',
    'requested_resources',jsonb_build_object('access','read-only')
  ),
  'support-race-request-'||gen_random_uuid()::text
);
SELECT pg_sleep(2);
COMMIT;
SQL
request_pid=$!

# Wait until connection A has returned from the RPC and is holding its
# transaction open in pg_sleep. This avoids relying on connection startup time.
lock_ready=0
for _ in $(seq 1 50); do
  active_hold="$(psql "$SUPABASE_DB_URL" -X -At -v ON_ERROR_STOP=1 \
    -c "SELECT count(*) FROM pg_stat_activity WHERE application_name='initiative-support-race-request' AND state='active' AND query ILIKE '%pg_sleep%'")"
  if [[ "$active_hold" == "1" ]]; then
    lock_ready=1
    break
  fi
  sleep 0.1
done
if [[ "$lock_ready" -ne 1 ]]; then
  echo "FAIL: support-request transaction did not reach the synchronized hold point" >&2
  cat "$tmp_dir/request.log" >&2
  exit 1
fi

advance_result="$(psql "$SUPABASE_DB_URL" -X -qAt -v ON_ERROR_STOP=1 \
  -v owner_id="$owner_id" -v initiative_id="$initiative_id" -v worker_id="$worker_id" \
  -v project_id="$project_id" <<'SQL'
SELECT set_config('request.jwt.claim.sub', :'owner_id', false) AS auth_context \gset
WITH advanced AS (
  SELECT public.advance_initiative(
    :'initiative_id'::uuid, :'worker_id'::uuid,
    'support-race-advance-'||gen_random_uuid()::text
  ) AS result
), materialized AS (
  SELECT count(*) AS task_count FROM public.tasks
  WHERE project_id=:'project_id'::uuid
    AND requirements->'initiative'->>'initiative_id'=:'initiative_id'
)
SELECT CASE
  WHEN (advanced.result->'data'->>'blocked_by_support')::boolean IS TRUE
   AND (advanced.result->'data'->>'materialized_count')::integer=0
   AND materialized.task_count=0
  THEN 'PASS: pending support serialized before advancement; no task materialized'
  ELSE 'FAIL: support gate was bypassed: response='||advanced.result::text
       ||', materialized_task_count='||materialized.task_count::text
END
FROM advanced CROSS JOIN materialized;
SQL
)"
wait "$request_pid"
request_pid=""

if [[ "$advance_result" != PASS:* ]]; then
  echo "$advance_result" >&2
  cat "$tmp_dir/request.log" >&2
  exit 1
fi

echo "$advance_result"
