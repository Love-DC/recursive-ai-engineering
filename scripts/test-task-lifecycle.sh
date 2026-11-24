#!/usr/bin/env bash
# Transactional lifecycle smoke test. All fixture rows and idempotency records roll back.
# Requires psql plus an owner-authorized connection to the target Supabase project.
set -euo pipefail

: "${SUPABASE_DB_URL:?Set SUPABASE_DB_URL to an authorized PostgreSQL connection string}"
: "${SUPABASE_OWNER_ID:?Set SUPABASE_OWNER_ID}"
: "${SUPABASE_PROJECT_ID:?Set SUPABASE_PROJECT_ID}"
: "${SHARED_WORKER_ID:?Set SHARED_WORKER_ID}"
: "${REVIEWER_WORKER_ID:?Set REVIEWER_WORKER_ID}"
[[ "${TASK_LIFECYCLE_TEST_ALLOW_MUTATIONS:-}" == "YES" ]] || {
  echo "Refusing to run: set TASK_LIFECYCLE_TEST_ALLOW_MUTATIONS=YES to acknowledge transactional fixture writes." >&2
  exit 2
}
command -v psql >/dev/null || { echo "psql is required" >&2; exit 2; }

uuid_re='^[0-9a-fA-F-]{36}$'
for value in "$SUPABASE_OWNER_ID" "$SUPABASE_PROJECT_ID" "$SHARED_WORKER_ID" "$REVIEWER_WORKER_ID"; do
  [[ "$value" =~ $uuid_re ]] || { echo "Expected UUID environment values" >&2; exit 2; }
done

psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 \
  -v owner_id="$SUPABASE_OWNER_ID" \
  -v project_id="$SUPABASE_PROJECT_ID" \
  -v worker_id="$SHARED_WORKER_ID" \
  -v reviewer_worker_id="$REVIEWER_WORKER_ID" <<'SQL'
BEGIN;
SELECT set_config('request.jwt.claim.sub', :'owner_id', true);
SELECT set_config('test.project_id', :'project_id', true);
SELECT set_config('test.worker_id', :'worker_id', true);
SELECT set_config('test.reviewer_worker_id', :'reviewer_worker_id', true);
\i supabase/migrations/20261124172155_submitted_task_reconciliation.sql

DO $test$
DECLARE
  v_project uuid := current_setting('test.project_id')::uuid;
  v_worker uuid := current_setting('test.worker_id')::uuid;
  v_root jsonb;
  v_create_replay jsonb;
  v_create_key text := 'lifecycle-root-' || gen_random_uuid()::text;
  v_child jsonb;
  v_grandchild jsonb;
  v_root_id uuid;
  v_child_id uuid;
  v_grandchild_id uuid;
  v_claim jsonb;
  v_replay jsonb;
  v_root_exec uuid;
  v_child_exec uuid;
  v_reclaimed jsonb;
  v_new_root_exec uuid;
  v_completion jsonb;
  v_task jsonb;
  v_list jsonb;
  v_heartbeat jsonb;
  v_heartbeat_before timestamptz;
  v_heartbeat_after timestamptz;
  v_heartbeat_lease timestamptz;
BEGIN
  -- Create a three-level tree; repeated create with the same key must replay.
  v_root := public.create_task(v_project,v_worker,'implementation',
    'Lifecycle test root','Disposable transaction-scoped fixture',
    '{"acceptance":["root claim and completion"]}'::jsonb,-100,false,
    null,null,v_create_key);
  v_root_id := (v_root->'data'->>'id')::uuid;
  v_create_replay := public.create_task(v_project,v_worker,'implementation',
    'Lifecycle test root','Disposable transaction-scoped fixture',
    '{"acceptance":["root claim and completion"]}'::jsonb,-100,false,
    null,null,v_create_key);
  IF (v_create_replay->'data'->>'id')::uuid <> v_root_id THEN
    RAISE EXCEPTION 'FAIL: create_task idempotency replay changed task';
  END IF;
  v_child := public.create_task(v_project,v_worker,'implementation',
    'Lifecycle test child','Child fixture', '{"acceptance":["child completion"]}'::jsonb,
    -90,false,v_root_id,null,'lifecycle-child-' || gen_random_uuid()::text);
  v_child_id := (v_child->'data'->>'id')::uuid;
  v_grandchild := public.create_task(v_project,v_worker,'implementation',
    'Lifecycle test grandchild','Grandchild fixture', '{}'::jsonb,
    -80,false,v_child_id,null,'lifecycle-grandchild-' || gen_random_uuid()::text);
  v_grandchild_id := (v_grandchild->'data'->>'id')::uuid;

  IF (v_child->'data'->>'parent_task_id')::uuid <> v_root_id
     OR (v_grandchild->'data'->>'parent_task_id')::uuid <> v_child_id THEN
    RAISE EXCEPTION 'FAIL: recursive parent_task_id linkage';
  END IF;

  v_claim := public.claim_task(v_project,v_worker,600,'lifecycle-root-claim-' || gen_random_uuid()::text);
  IF (v_claim->'data'->>'task_id')::uuid <> v_root_id THEN
    RAISE EXCEPTION 'FAIL: priority ordering did not claim root first: %',v_claim;
  END IF;
  v_root_exec := (v_claim->'data'->>'execution_id')::uuid;

  -- A real execution heartbeat renews the fixture lease and advances heartbeat_at.
  SELECT heartbeat_at INTO v_heartbeat_before
    FROM public.executions WHERE id=v_root_exec AND task_id=v_root_id;
  v_heartbeat := public.heartbeat_execution(
    v_root_id,v_root_exec,v_worker,'lifecycle-root-heartbeat-' || gen_random_uuid()::text
  );
  SELECT e.heartbeat_at,t.lease_until INTO v_heartbeat_after,v_heartbeat_lease
    FROM public.executions e JOIN public.tasks t ON t.id=v_root_id
    WHERE e.id=v_root_exec AND e.task_id=t.id;
  IF v_heartbeat->>'success' <> 'true'
     OR v_heartbeat_after <= v_heartbeat_before
     OR v_heartbeat_lease < clock_timestamp()+interval '240 seconds' THEN
    RAISE EXCEPTION 'FAIL: heartbeat did not advance heartbeat_at and lease_until: %, %, %',
      v_heartbeat,v_heartbeat_after,v_heartbeat_lease;
  END IF;

  -- A repeated idempotency key with identical arguments returns the same execution.
  v_replay := public.claim_task(v_project,v_worker,600,
    (SELECT idempotency_key FROM public.operation_requests
      WHERE operation='claim_task' AND project_id=v_project
      ORDER BY created_at DESC LIMIT 1));
  IF (v_replay->'data'->>'execution_id')::uuid <> v_root_exec THEN
    RAISE EXCEPTION 'FAIL: claim idempotency replay changed execution';
  END IF;

  v_claim := public.claim_task(v_project,v_worker,600,'lifecycle-child-claim-' || gen_random_uuid()::text);
  IF (v_claim->'data'->>'task_id')::uuid <> v_child_id THEN
    RAISE EXCEPTION 'FAIL: child was not next claim: %',v_claim;
  END IF;
  v_child_exec := (v_claim->'data'->>'execution_id')::uuid;

  v_completion := public.complete_execution(v_child_id,v_child_exec,v_worker,
    '{"summary":"child complete"}'::jsonb,'lifecycle-child-complete-' || gen_random_uuid()::text);
  IF v_completion->'data'->>'status' <> 'accepted' THEN
    RAISE EXCEPTION 'FAIL: child completion did not accept';
  END IF;

  -- Force only this disposable fixture's lease to expire, then reclaim it.
  UPDATE public.tasks SET lease_until=clock_timestamp()-interval '1 second'
    WHERE id=v_root_id AND current_execution_id=v_root_exec;
  v_reclaimed := public.claim_task(v_project,v_worker,600,'lifecycle-root-reclaim-' || gen_random_uuid()::text);
  IF (v_reclaimed->'data'->>'task_id')::uuid <> v_root_id
     OR (v_reclaimed->'data'->>'attempt')::integer <> 2 THEN
    RAISE EXCEPTION 'FAIL: expired task was not reclaimed as attempt 2: %',v_reclaimed;
  END IF;
  v_new_root_exec := (v_reclaimed->'data'->>'execution_id')::uuid;

  -- The fenced execution must not be allowed to complete after reclamation.
  BEGIN
    PERFORM public.complete_execution(v_root_id,v_root_exec,v_worker,
      '{"summary":"must be rejected"}'::jsonb,'lifecycle-stale-complete-' || gen_random_uuid()::text);
    RAISE EXCEPTION 'FAIL: stale execution unexpectedly completed';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM NOT IN ('EXECUTION_SUPERSEDED','EXECUTION_EXPIRED') THEN RAISE; END IF;
  END;

  PERFORM public.complete_execution(v_root_id,v_new_root_exec,v_worker,
    '{"summary":"reclaimed root complete"}'::jsonb,'lifecycle-root-complete-' || gen_random_uuid()::text);

  v_task := public.get_task(v_root_id);
  IF v_task->'data'->'task'->>'status' <> 'accepted'
     OR jsonb_array_length(v_task->'data'->'executions') <> 2 THEN
    RAISE EXCEPTION 'FAIL: get_task did not expose final state and both attempts';
  END IF;
  v_list := public.list_tasks(v_project,null,null,100,null);
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_list->'data') t
    WHERE t->>'id'=v_grandchild_id::text
  ) THEN
    RAISE EXCEPTION 'FAIL: list_tasks omitted recursive descendant';
  END IF;

  RAISE NOTICE 'PASS: recursive parent linkage, ordered claims, claim idempotency replay, execution heartbeat and lease renewal, child completion, lease expiry/reclaim, stale-execution fencing, completion, get_task and list_tasks';
END
$test$;


DO $reconciliation_test$
DECLARE
  v_project uuid := current_setting('test.project_id')::uuid;
  v_worker uuid := current_setting('test.worker_id')::uuid;
  v_reviewer uuid := current_setting('test.reviewer_worker_id')::uuid;
  v_target uuid;
  v_exec uuid;
  v_review uuid;
  v_dependent uuid;
  v_expected timestamptz;
  v_result jsonb;
  v_replay jsonb;
  v_history_status text;
  v_event_count integer;
  v_evidence jsonb := '[{"kind":"github_pr","ref":"https://github.com/Love-DC/recursive-ai-engineering/pull/28","observation":"PR is closed unmerged; no active execution, review, or dependent task remains."}]'::jsonb;
BEGIN
  -- One eligible submitted delivery is reconciled and replayed idempotently.
  INSERT INTO public.tasks(
    project_id,task_type,title,description,requirements,requires_review,status,priority
  ) VALUES (
    v_project,'implementation','Reconciliation fixture: eligible','Disposable fixture','{}'::jsonb,
    true,'submitted',-200
  ) RETURNING id INTO v_target;
  INSERT INTO public.executions(task_id,worker_id,attempt,status)
  VALUES(v_target,v_worker,1,'submitted') RETURNING id INTO v_exec;
  UPDATE public.tasks
  SET latest_delivery_task_id=v_target,
      latest_delivery_execution_id=v_exec,
      result='{"existing":"preserve-me"}'::jsonb,
      updated_at=clock_timestamp()
  WHERE id=v_target
  RETURNING updated_at INTO v_expected;

  -- Invalid reason and evidence are rejected before the state transition.
  BEGIN
    PERFORM public.reconcile_submitted_task(
      v_target,v_expected,'   ',v_evidence,'reconcile-missing-reason-'||gen_random_uuid()::text
    );
    RAISE EXCEPTION 'FAIL: empty reconciliation reason unexpectedly passed';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'RECONCILIATION_REASON_REQUIRED' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.reconcile_submitted_task(
      v_target,v_expected,'Evidence-backed obsolete delivery','[]'::jsonb,
      'reconcile-missing-evidence-'||gen_random_uuid()::text
    );
    RAISE EXCEPTION 'FAIL: empty reconciliation evidence unexpectedly passed';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'RECONCILIATION_EVIDENCE_REQUIRED' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.reconcile_submitted_task(
      v_target,v_expected-interval '1 second','Evidence-backed obsolete delivery',v_evidence,
      'reconcile-stale-state-'||gen_random_uuid()::text
    );
    RAISE EXCEPTION 'FAIL: stale submitted-task state unexpectedly passed';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM <> 'TASK_STATE_STALE' THEN RAISE; END IF;
  END;

  v_result := public.reconcile_submitted_task(
    v_target,v_expected,'PR #28 is closed unmerged; no live work remains',v_evidence,
    'reconcile-success-'||gen_random_uuid()::text
  );
  IF v_result->'data'->>'status' <> 'cancelled' THEN
    RAISE EXCEPTION 'FAIL: eligible submitted task was not reconciled: %',v_result;
  END IF;
  SELECT status INTO v_history_status FROM public.executions WHERE id=v_exec AND task_id=v_target;
  IF v_history_status <> 'submitted' THEN
    RAISE EXCEPTION 'FAIL: reconciliation rewrote historical execution status: %',v_history_status;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.tasks
    WHERE id=v_target AND status='cancelled'
      AND result->>'existing'='preserve-me'
      AND result->'reconciliation'->>'reason'='PR #28 is closed unmerged; no live work remains'
  ) THEN
    RAISE EXCEPTION 'FAIL: task result/history was not preserved with reconciliation metadata';
  END IF;
  SELECT count(*) INTO v_event_count FROM public.task_events
  WHERE project_id=v_project AND task_id=v_target AND event_type='task_reconciled';
  IF v_event_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: expected one task_reconciled audit event, found %',v_event_count;
  END IF;
  v_replay := public.reconcile_submitted_task(
    v_target,v_expected,'PR #28 is closed unmerged; no live work remains',v_evidence,
    (SELECT idempotency_key FROM public.operation_requests
      WHERE project_id=v_project AND operation='reconcile_submitted_task'
      ORDER BY created_at DESC LIMIT 1)
  );
  IF v_replay->'data'->>'task_id' <> v_target::text
    OR v_replay->'data'->>'status' <> 'cancelled' THEN
    RAISE EXCEPTION 'FAIL: idempotent reconciliation replay changed its result: %',v_replay;
  END IF;

  -- Any running execution / live task lease blocks reconciliation.
  INSERT INTO public.tasks(
    project_id,task_type,title,description,requirements,requires_review,status,priority
  ) VALUES (
    v_project,'implementation','Reconciliation fixture: live lease','Disposable fixture','{}'::jsonb,
    true,'submitted',-190
  ) RETURNING id INTO v_target;
  INSERT INTO public.executions(task_id,worker_id,attempt,status)
  VALUES(v_target,v_worker,1,'running') RETURNING id INTO v_exec;
  UPDATE public.tasks
  SET current_execution_id=v_exec,lease_until=clock_timestamp()+interval '5 minutes',
      latest_delivery_task_id=v_target,latest_delivery_execution_id=v_exec
  WHERE id=v_target
  RETURNING updated_at INTO v_expected;
  BEGIN
    PERFORM public.reconcile_submitted_task(
      v_target,v_expected,'Attempt to reconcile a live execution',v_evidence,
      'reconcile-live-lease-'||gen_random_uuid()::text
    );
    RAISE EXCEPTION 'FAIL: live execution was unexpectedly reconciled';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM <> 'TASK_HAS_LIVE_EXECUTION' THEN RAISE; END IF;
  END;

  -- Pending review and accepted review outcomes both block retirement.
  INSERT INTO public.tasks(
    project_id,task_type,title,description,requirements,requires_review,status,priority
  ) VALUES (
    v_project,'implementation','Reconciliation fixture: pending review','Disposable fixture','{}'::jsonb,
    true,'submitted',-180
  ) RETURNING id INTO v_target;
  INSERT INTO public.executions(task_id,worker_id,attempt,status)
  VALUES(v_target,v_worker,1,'submitted') RETURNING id INTO v_exec;
  UPDATE public.tasks
  SET latest_delivery_task_id=v_target,latest_delivery_execution_id=v_exec
  WHERE id=v_target RETURNING updated_at INTO v_expected;
  INSERT INTO public.tasks(
    project_id,parent_task_id,task_type,title,description,requirements,requires_review,status,priority,
    assigned_worker_id,review_target_original_task_id,review_target_delivery_task_id,review_target_execution_id
  ) VALUES (
    v_project,v_target,'review','Reconciliation fixture pending review','Disposable fixture','{}'::jsonb,
    false,'pending',-170,v_reviewer,v_target,v_target,v_exec
  ) RETURNING id INTO v_review;
  BEGIN
    PERFORM public.reconcile_submitted_task(
      v_target,v_expected,'Attempt to reconcile while a review is pending',v_evidence,
      'reconcile-pending-review-'||gen_random_uuid()::text
    );
    RAISE EXCEPTION 'FAIL: pending review did not block reconciliation';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM <> 'TASK_HAS_PENDING_REVIEW' THEN RAISE; END IF;
  END;

  INSERT INTO public.tasks(
    project_id,task_type,title,description,requirements,requires_review,status,priority
  ) VALUES (
    v_project,'implementation','Reconciliation fixture: accepted review','Disposable fixture','{}'::jsonb,
    true,'submitted',-160
  ) RETURNING id INTO v_target;
  INSERT INTO public.executions(task_id,worker_id,attempt,status)
  VALUES(v_target,v_worker,1,'submitted') RETURNING id INTO v_exec;
  UPDATE public.tasks
  SET latest_delivery_task_id=v_target,latest_delivery_execution_id=v_exec
  WHERE id=v_target RETURNING updated_at INTO v_expected;
  INSERT INTO public.tasks(
    project_id,parent_task_id,task_type,title,description,requirements,requires_review,status,priority,
    assigned_worker_id,review_target_original_task_id,review_target_delivery_task_id,review_target_execution_id,
    review_decision
  ) VALUES (
    v_project,v_target,'review','Reconciliation fixture accepted review','Disposable fixture','{}'::jsonb,
    false,'accepted',-150,v_reviewer,v_target,v_target,v_exec,'accepted'
  ) RETURNING id INTO v_review;
  BEGIN
    PERFORM public.reconcile_submitted_task(
      v_target,v_expected,'Attempt to reconcile an accepted review',v_evidence,
      'reconcile-accepted-review-'||gen_random_uuid()::text
    );
    RAISE EXCEPTION 'FAIL: accepted review did not block reconciliation';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM <> 'TASK_HAS_ACCEPTED_REVIEW' THEN RAISE; END IF;
  END;

  -- A live, non-terminal task depending on the delivery prevents reconciliation.
  INSERT INTO public.tasks(
    project_id,task_type,title,description,requirements,requires_review,status,priority
  ) VALUES (
    v_project,'implementation','Reconciliation fixture: dependency target','Disposable fixture','{}'::jsonb,
    true,'submitted',-140
  ) RETURNING id INTO v_target;
  INSERT INTO public.executions(task_id,worker_id,attempt,status)
  VALUES(v_target,v_worker,1,'submitted') RETURNING id INTO v_exec;
  UPDATE public.tasks
  SET latest_delivery_task_id=v_target,latest_delivery_execution_id=v_exec
  WHERE id=v_target RETURNING updated_at INTO v_expected;
  INSERT INTO public.tasks(
    project_id,task_type,title,description,requirements,requires_review,status,priority
  ) VALUES (
    v_project,'implementation','Reconciliation fixture dependent task','Disposable fixture',
    jsonb_build_object('dependencies',jsonb_build_array(jsonb_build_object(
      'type','task','task_id',v_target::text,'required_status','accepted'
    ))),
    true,'pending',-130
  ) RETURNING id INTO v_dependent;
  BEGIN
    PERFORM public.reconcile_submitted_task(
      v_target,v_expected,'Attempt to reconcile a required prerequisite',v_evidence,
      'reconcile-dependent-work-'||gen_random_uuid()::text
    );
    RAISE EXCEPTION 'FAIL: dependent task did not block reconciliation';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM <> 'TASK_HAS_DEPENDENT_WORK' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'PASS: submitted reconciliation owner gate, evidence/reason validation, stale-state fencing, audit/history preservation, idempotency replay, live-execution guard, pending/accepted review guards, and dependency guard';
END
$reconciliation_test$;

ROLLBACK;
SQL

echo "PASS: lifecycle integration assertions completed; transaction rolled back."
