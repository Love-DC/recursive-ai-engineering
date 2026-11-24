-- Owner-authorized pending-task reassignment and cancelled-review retry tests.
-- All fixture rows, executions, events and idempotency records are rolled back.

BEGIN;
SELECT set_config('request.jwt.claim.sub', :'owner_id', true);
SELECT set_config('test.project_id', :'project_id', true);
SELECT set_config('test.owner_id', :'owner_id', true);
SELECT set_config('test.worker_a', :'worker_a', true);
SELECT set_config('test.worker_b', :'worker_b', true);
SELECT set_config('test.reviewer_worker', :'reviewer_worker', true);

DO $test$
DECLARE
  v_project uuid := current_setting('test.project_id')::uuid;
  v_owner uuid := current_setting('test.owner_id')::uuid;
  v_a uuid := current_setting('test.worker_a')::uuid;
  v_b uuid := current_setting('test.worker_b')::uuid;
  v_reviewer uuid := current_setting('test.reviewer_worker')::uuid;
  v_created jsonb;
  v_result jsonb;
  v_replay jsonb;
  v_claim jsonb;
  v_task_id uuid;
  v_execution_id uuid;
  v_fix_task_id uuid;
  v_delivery_task_id uuid;
  v_delivery_execution_id uuid;
  v_review_id uuid;
  v_retry_review_id uuid;
  v_reassign_key text := 'reassign-'||gen_random_uuid()::text;
  v_event_count integer;
BEGIN
  -- Repair a pending task that was assigned to the wrong task-type Worker.
  v_created := public.create_task(
    v_project,v_a,'implementation','Reassignment test: wrong initial Worker',
    'Pending fixture assigned to the reviewer by an old routing bug',
    '{}'::jsonb,-1000,false,null,null,'reassign-create-'||gen_random_uuid()::text
  );
  v_task_id := (v_created->'data'->>'id')::uuid;
  UPDATE public.tasks SET assigned_worker_id=v_reviewer WHERE id=v_task_id;

  -- Only the project owner may repair task assignment.
  PERFORM set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
  BEGIN
    PERFORM public.reassign_pending_task(
      v_task_id,v_reviewer,v_a,'Unauthorized reassignment','reassign-unauthorized-'||gen_random_uuid()::text
    );
    RAISE EXCEPTION 'FAIL: non-owner reassigned a project task';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    IF SQLERRM <> 'PROJECT_FORBIDDEN' THEN RAISE; END IF;
  END;
  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);

  v_result := public.reassign_pending_task(
    v_task_id,v_reviewer,v_a,'Correct implementation task route; token=fixture-secret',v_reassign_key
  );
  IF v_result->'data'->>'status' <> 'pending'
    OR v_result->'data'->>'previous_worker_id' <> v_reviewer::text
    OR v_result->'data'->>'assigned_worker_id' <> v_a::text THEN
    RAISE EXCEPTION 'FAIL: pending implementation reassignment returned the wrong result: %',v_result;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.tasks
    WHERE id=v_task_id AND status='pending' AND assigned_worker_id=v_a
      AND current_execution_id IS NULL AND lease_until IS NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: reassignment did not preserve pending/unleased task state';
  END IF;

  -- Exact replay returns the original response and emits only one audit event.
  v_replay := public.reassign_pending_task(
    v_task_id,v_reviewer,v_a,'Correct implementation task route; token=fixture-secret',v_reassign_key
  );
  IF v_replay IS DISTINCT FROM v_result THEN
    RAISE EXCEPTION 'FAIL: identical reassignment replay did not return the stored response';
  END IF;
  SELECT count(*) INTO v_event_count FROM public.task_events
  WHERE task_id=v_task_id AND event_type='task_reassigned';
  IF v_event_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: idempotent reassignment created % audit events',v_event_count;
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.task_events
    WHERE task_id=v_task_id AND event_type='task_reassigned'
      AND payload->>'reason' LIKE '%fixture-secret%'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.task_events
    WHERE task_id=v_task_id AND event_type='task_reassigned'
      AND payload->>'reason' LIKE '%[REDACTED]%'
  ) THEN
    RAISE EXCEPTION 'FAIL: reassignment audit reason was not safely redacted';
  END IF;

  -- Reusing the idempotency key with different input must be rejected before
  -- observing/mutating the now-updated task assignment.
  BEGIN
    PERFORM public.reassign_pending_task(
      v_task_id,v_reviewer,v_b,'Changed destination with the same key',v_reassign_key
    );
    RAISE EXCEPTION 'FAIL: changed reassignment request reused an idempotency key';
  EXCEPTION WHEN unique_violation THEN
    IF SQLERRM <> 'IDEMPOTENCY_CONFLICT' THEN RAISE; END IF;
  END;

  -- An out-of-date expected Worker is fenced, and an ineligible destination
  -- cannot bypass the task-type route.
  BEGIN
    PERFORM public.reassign_pending_task(
      v_task_id,v_reviewer,v_b,'Stale expected assignment', 'reassign-stale-'||gen_random_uuid()::text
    );
    RAISE EXCEPTION 'FAIL: stale expected assignment was accepted';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM <> 'TASK_ASSIGNMENT_STALE' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM public.reassign_pending_task(
      v_task_id,v_a,v_reviewer,'Wrong task-type destination', 'reassign-wrong-route-'||gen_random_uuid()::text
    );
    RAISE EXCEPTION 'FAIL: task was reassigned to a Worker outside its route';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    IF SQLERRM <> 'TASK_ROUTE_MISMATCH' THEN RAISE; END IF;
  END;

  -- Once a claim starts, reassignment must wait for the row lock and then reject
  -- the now-running task without changing the execution or lease.
  v_claim := public.claim_task(v_project,v_a,120,'reassign-claim-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_task_id::text THEN
    RAISE EXCEPTION 'FAIL: reassigned implementation task was not claimable by its routed Worker: %',v_claim;
  END IF;
  v_execution_id := (v_claim->'data'->>'execution_id')::uuid;

  BEGIN
    PERFORM public.reassign_pending_task(
      v_task_id,v_a,v_b,'Cannot reassign a running task','reassign-running-'||gen_random_uuid()::text
    );
    RAISE EXCEPTION 'FAIL: running task was reassigned';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM <> 'TASK_NOT_PENDING' THEN RAISE; END IF;
  END;
  IF NOT EXISTS (
    SELECT 1 FROM public.tasks
    WHERE id=v_task_id AND status='running' AND assigned_worker_id=v_a
      AND current_execution_id=v_execution_id AND lease_until > clock_timestamp()
  ) THEN
    RAISE EXCEPTION 'FAIL: rejected reassignment changed the running execution or lease';
  END IF;

  -- Fix tasks use the same task-type/default/required-worker routing. This
  -- fixture pins a fix to Worker B and proves Worker A cannot claim it.
  INSERT INTO public.tasks(
    project_id,fixes_task_id,task_type,title,description,requirements,
    priority,requires_review,created_by_worker_id
  )
  VALUES(
    v_project,v_task_id,'fix','Reassignment test: routed fix',
    'A fix task explicitly routed to Worker B',
    '{"required_worker_key":"test-worker-b"}'::jsonb,
    -900,false,v_a
  )
  RETURNING id INTO v_fix_task_id;

  v_claim := public.claim_task(v_project,v_a,120,'fix-route-a-denied-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: Worker A claimed a fix routed to Worker B: %',v_claim;
  END IF;
  v_claim := public.claim_task(v_project,v_b,120,'fix-route-b-claim-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_fix_task_id::text THEN
    RAISE EXCEPTION 'FAIL: Worker B could not claim its explicitly routed fix task: %',v_claim;
  END IF;

  -- Create and submit a delivery, then create a correctly routed review.
  v_created := public.create_task(
    v_project,v_a,'implementation','Reassignment test: review delivery',
    'Submitted delivery used to test review reassignment and retry',
    '{}'::jsonb,-800,true,null,null,'review-delivery-create-'||gen_random_uuid()::text
  );
  v_delivery_task_id := (v_created->'data'->>'id')::uuid;
  v_claim := public.claim_task(v_project,v_a,120,'review-delivery-claim-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_delivery_task_id::text THEN
    RAISE EXCEPTION 'FAIL: review delivery was not claimed by its routed implementation Worker: %',v_claim;
  END IF;
  v_delivery_execution_id := (v_claim->'data'->>'execution_id')::uuid;

  -- Submitted deliveries are terminal for reassignment even after their
  -- execution lease has been cleared.
  BEGIN
    PERFORM public.reassign_pending_task(
      v_delivery_task_id,v_a,v_b,'Cannot reassign a submitted delivery',
      'reassign-submitted-'||gen_random_uuid()::text
    );
    RAISE EXCEPTION 'FAIL: submitted delivery was reassigned';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM <> 'TASK_NOT_PENDING' THEN RAISE; END IF;
  END;

  PERFORM public.submit_result(
    v_delivery_task_id,v_delivery_execution_id,v_a,
    '{"summary":"delivery submitted for review reassignment tests"}'::jsonb,
    'review-delivery-submit-'||gen_random_uuid()::text
  );

  v_result := public.create_review_task(
    v_delivery_task_id,v_delivery_task_id,v_delivery_execution_id,v_reviewer,
    'review-create-first-'||gen_random_uuid()::text
  );
  v_review_id := (v_result->'data'->>'id')::uuid;

  -- Review reassignment to an implementation Worker must fail closed.
  BEGIN
    PERFORM public.reassign_pending_task(
      v_review_id,v_reviewer,v_a,'Wrong reviewer route','review-wrong-route-'||gen_random_uuid()::text
    );
    RAISE EXCEPTION 'FAIL: review task was reassigned outside its configured reviewer route';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    IF SQLERRM <> 'TASK_ROUTE_MISMATCH' THEN RAISE; END IF;
  END;

  -- Simulate the legacy misrouted pending-review row. The owner RPC repairs it
  -- only after checking the expected old assignment and delivery execution.
  UPDATE public.tasks SET assigned_worker_id=v_a WHERE id=v_review_id;
  v_result := public.reassign_pending_task(
    v_review_id,v_a,v_reviewer,'Restore the configured independent reviewer',
    'review-reassign-'||gen_random_uuid()::text
  );
  IF v_result->'data'->>'assigned_worker_id' <> v_reviewer::text THEN
    RAISE EXCEPTION 'FAIL: misrouted review task could not be safely reassigned: %',v_result;
  END IF;

  -- A cancelled review is no longer a duplicate: the same exact delivery may
  -- receive a fresh pending review record with a new idempotency key.
  UPDATE public.tasks
  SET status='cancelled',updated_at=clock_timestamp()
  WHERE id=v_review_id AND status='pending';

  BEGIN
    PERFORM public.reassign_pending_task(
      v_review_id,v_reviewer,v_a,'Cannot reassign a cancelled review',
      'reassign-cancelled-'||gen_random_uuid()::text
    );
    RAISE EXCEPTION 'FAIL: cancelled review was reassigned';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM <> 'TASK_NOT_PENDING' THEN RAISE; END IF;
  END;

  v_result := public.create_review_task(
    v_delivery_task_id,v_delivery_task_id,v_delivery_execution_id,v_reviewer,
    'review-create-retry-'||gen_random_uuid()::text
  );
  v_retry_review_id := (v_result->'data'->>'id')::uuid;
  IF v_retry_review_id IS NULL OR v_retry_review_id=v_review_id
    OR NOT EXISTS (
      SELECT 1 FROM public.tasks
      WHERE id=v_retry_review_id AND status='pending'
        AND assigned_worker_id=v_reviewer
        AND review_target_execution_id=v_delivery_execution_id
    ) THEN
    RAISE EXCEPTION 'FAIL: cancelled review did not permit a new correctly routed review: %',v_result;
  END IF;

  RAISE NOTICE 'PASS: pending-only reassignment, expected-assignment fencing, route eligibility, idempotent replay/conflict, single audit event, running-execution protection, fix task routing, review route protection, and cancelled-review retry';
END;
$test$;

ROLLBACK;
