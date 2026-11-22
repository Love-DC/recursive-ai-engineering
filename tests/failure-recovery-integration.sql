-- Runs only against an isolated PostgreSQL database loaded from database-schema.sql.
-- Every fixture is transaction-scoped and rolled back.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000001', true);


CREATE OR REPLACE FUNCTION public.test_reject_execution_failed_event()
RETURNS trigger
LANGUAGE plpgsql
AS $trigger$
BEGIN
  IF NEW.event_type='execution_failed' THEN
    RAISE EXCEPTION 'injected task-event write failure';
  END IF;
  RETURN NEW;
END;
$trigger$;

CREATE TRIGGER test_reject_execution_failed_event
BEFORE INSERT ON public.task_events
FOR EACH ROW EXECUTE FUNCTION public.test_reject_execution_failed_event();

DO $test$
DECLARE
  v_project uuid := '00000000-0000-4000-8000-000000000002';
  v_worker uuid := '00000000-0000-4000-8000-000000000003';
  v_other_worker uuid := '00000000-0000-4000-8000-000000000004';
  v_task jsonb;
  v_task_id uuid;
  v_claim jsonb;
  v_exec uuid;
  v_claim2 jsonb;
  v_exec2 uuid;
  v_fail jsonb;
  v_replay jsonb;
  v_requeue jsonb;
  v_status text;
  v_message text;
BEGIN
  -- Atomicity: injected event failure must roll back execution and task state.
  v_task := public.create_task(v_project,v_worker,'implementation','Atomic failure fixture',
    'Disposable transaction fixture','{"retry":{"max_attempts":2,"backoff_seconds":0}}'::jsonb,
    1,false,null,null,'failure-atomic-create');
  v_task_id := (v_task->'data'->>'id')::uuid;
  v_claim := public.claim_task(v_project,v_worker,600,'failure-atomic-claim');
  v_exec := (v_claim->'data'->>'execution_id')::uuid;
  BEGIN
    PERFORM public.fail_execution(v_task_id,v_exec,v_worker,'INJECTED','must roll back','failure-atomic-report');
    RAISE EXCEPTION 'FAIL: injected event failure was not raised';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'injected task-event write failure%' THEN RAISE; END IF;
  END;
  SELECT status INTO v_status FROM public.tasks WHERE id=v_task_id;
  IF v_status <> 'running'
     OR (SELECT status FROM public.executions WHERE id=v_exec) <> 'running' THEN
    RAISE EXCEPTION 'FAIL: failure event error did not roll back task and execution';
  END IF;
  DROP TRIGGER test_reject_execution_failed_event ON public.task_events;

  -- Wrong Worker cannot fail another Worker execution.
  BEGIN
    PERFORM public.fail_execution(v_task_id,v_exec,v_other_worker,'WRONG_WORKER','no','failure-wrong-worker');
    RAISE EXCEPTION 'FAIL: wrong Worker unexpectedly failed execution';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    IF SQLERRM <> 'TASK_NOT_OWNED' THEN RAISE; END IF;
  END;

  -- Valid failure persists, and same idempotency key replays.
  v_fail := public.fail_execution(v_task_id,v_exec,v_worker,'BUILD_FAILED','compiler exited 1','failure-valid-report');
  v_replay := public.fail_execution(v_task_id,v_exec,v_worker,'BUILD_FAILED','compiler exited 1','failure-valid-report');
  IF v_fail <> v_replay OR v_fail->'data'->>'status' <> 'failed' THEN
    RAISE EXCEPTION 'FAIL: fail_execution idempotency replay mismatch';
  END IF;
  IF (SELECT status FROM public.tasks WHERE id=v_task_id) <> 'failed'
     OR (SELECT status FROM public.executions WHERE id=v_exec) <> 'failed'
     OR (SELECT error_message FROM public.executions WHERE id=v_exec) <> 'compiler exited 1'
     OR (SELECT current_execution_id FROM public.tasks WHERE id=v_task_id) IS NOT NULL
     OR (SELECT lease_until FROM public.tasks WHERE id=v_task_id) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: failure state was not persisted correctly';
  END IF;

  -- Reusing an idempotency key with different arguments must conflict.
  BEGIN
    PERFORM public.fail_execution(v_task_id,v_exec,v_worker,'OTHER_ERROR','different message','failure-valid-report');
    RAISE EXCEPTION 'FAIL: idempotency key reuse unexpectedly succeeded';
  EXCEPTION WHEN SQLSTATE '23505' THEN
    IF SQLERRM <> 'IDEMPOTENCY_CONFLICT' THEN RAISE; END IF;
  END;

  -- Owner-controlled retry preserves history and increments the next attempt.
  v_requeue := public.requeue_failed_task(v_task_id,v_worker,'Retry after fixing build','failure-requeue-1');
  IF v_requeue->'data'->>'status' <> 'pending' THEN
    RAISE EXCEPTION 'FAIL: failed task was not requeued';
  END IF;
  v_claim2 := public.claim_task(v_project,v_worker,600,'failure-retry-claim-2');
  v_exec2 := (v_claim2->'data'->>'execution_id')::uuid;
  IF (v_claim2->'data'->>'attempt')::integer <> 2 OR v_exec2=v_exec THEN
    RAISE EXCEPTION 'FAIL: retry did not create a new execution attempt';
  END IF;
  PERFORM public.fail_execution(v_task_id,v_exec2,v_worker,'BUILD_FAILED','second failure','failure-valid-report-2');
  BEGIN
    PERFORM public.requeue_failed_task(v_task_id,v_worker,'Would exceed retry cap','failure-requeue-over-cap');
    RAISE EXCEPTION 'FAIL: retry cap was not enforced';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM <> 'RETRY_LIMIT_REACHED' THEN RAISE; END IF;
  END;
  IF (SELECT count(*) FROM public.executions WHERE task_id=v_task_id) <> 2 THEN
    RAISE EXCEPTION 'FAIL: execution history was not preserved';
  END IF;

  -- Backoff is enforced before another claim can occur.
  v_task := public.create_task(v_project,v_worker,'implementation','Backoff fixture',
    'Disposable transaction fixture','{"retry":{"max_attempts":3,"backoff_seconds":60}}'::jsonb,
    2,false,null,null,'failure-backoff-create');
  v_task_id := (v_task->'data'->>'id')::uuid;
  v_claim := public.claim_task(v_project,v_worker,600,'failure-backoff-claim');
  v_exec := (v_claim->'data'->>'execution_id')::uuid;
  PERFORM public.fail_execution(v_task_id,v_exec,v_worker,'TEST_FAILURE','backoff','failure-backoff-report');
  BEGIN
    PERFORM public.requeue_failed_task(v_task_id,v_worker,'Too early','failure-backoff-early');
    RAISE EXCEPTION 'FAIL: retry backoff was not enforced';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM <> 'RETRY_BACKOFF_ACTIVE' THEN RAISE; END IF;
  END;
  UPDATE public.executions SET finished_at=clock_timestamp()-interval '61 seconds' WHERE id=v_exec;
  PERFORM public.requeue_failed_task(v_task_id,v_worker,'Backoff elapsed','failure-backoff-late');
  v_claim2 := public.claim_task(v_project,v_worker,600,'failure-backoff-claim-after-requeue');
  v_exec2 := (v_claim2->'data'->>'execution_id')::uuid;
  PERFORM public.complete_execution(v_task_id,v_exec2,v_worker,
    '{"summary":"backoff retry fixture complete"}'::jsonb,'failure-backoff-complete');

  -- Expired execution is fenced; ordinary claim_task performs recovery.
  v_task := public.create_task(v_project,v_worker,'implementation','Expired failure fixture',
    'Disposable transaction fixture','{"retry":{"max_attempts":3}}'::jsonb,
    3,false,null,null,'failure-expired-create');
  v_task_id := (v_task->'data'->>'id')::uuid;
  v_claim := public.claim_task(v_project,v_worker,600,'failure-expired-claim-1');
  v_exec := (v_claim->'data'->>'execution_id')::uuid;
  UPDATE public.tasks SET lease_until=clock_timestamp()-interval '1 second' WHERE id=v_task_id;
  BEGIN
    PERFORM public.fail_execution(v_task_id,v_exec,v_worker,'LATE_FAILURE','late report','failure-expired-report');
    RAISE EXCEPTION 'FAIL: expired execution accepted failure report';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM <> 'EXECUTION_EXPIRED' THEN RAISE; END IF;
  END;
  v_claim2 := public.claim_task(v_project,v_worker,600,'failure-expired-reclaim');
  IF (v_claim2->'data'->>'attempt')::integer <> 2
     OR (SELECT status FROM public.executions WHERE id=v_exec) <> 'expired' THEN
    RAISE EXCEPTION 'FAIL: expired execution was not safely reclaimed';
  END IF;

  -- Cancellation remains a distinct terminal state, not a retryable failure.
  v_task := public.create_task(v_project,v_worker,'implementation','Cancellation fixture',
    'Disposable transaction fixture','{}'::jsonb,4,false,null,null,'failure-cancel-create');
  v_task_id := (v_task->'data'->>'id')::uuid;
  v_claim := public.claim_task(v_project,v_worker,600,'failure-cancel-claim');
  v_exec := (v_claim->'data'->>'execution_id')::uuid;
  PERFORM public.cancel_task(v_task_id,v_worker,'operator cancelled','failure-cancel-task');
  IF (SELECT status FROM public.tasks WHERE id=v_task_id) <> 'cancelled'
     OR (SELECT status FROM public.executions WHERE id=v_exec) <> 'failed' THEN
    RAISE EXCEPTION 'FAIL: cancellation semantics changed';
  END IF;
  BEGIN
    PERFORM public.requeue_failed_task(v_task_id,v_worker,'Must not retry cancellation','failure-cancel-requeue');
    RAISE EXCEPTION 'FAIL: cancelled task was requeued';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM <> 'TASK_NOT_FAILED' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'PASS: atomic failure persistence, wrong-worker fencing, idempotency replay/conflict, retry attempt history, retry cap, backoff, expired-execution fencing/reclaim, and cancellation separation';
END
$test$;

DROP TRIGGER IF EXISTS test_reject_execution_failed_event ON public.task_events;
DROP FUNCTION IF EXISTS public.test_reject_execution_failed_event();
ROLLBACK;
