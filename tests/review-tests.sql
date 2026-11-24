-- Transactional integration coverage for cancelled/failed review recovery.
-- The caller supplies owner_id, project_id, worker_id and reviewer_worker_id via psql.
BEGIN;
SELECT set_config('request.jwt.claim.sub', :'owner_id', true);
SELECT set_config('test.project_id', :'project_id', true);
SELECT set_config('test.worker_id', :'worker_id', true);
SELECT set_config('test.reviewer_worker_id', :'reviewer_worker_id', true);

DO $test$
DECLARE
  v_project uuid := current_setting('test.project_id')::uuid;
  v_worker uuid := current_setting('test.worker_id')::uuid;
  v_reviewer uuid := current_setting('test.reviewer_worker_id')::uuid;

  v_original jsonb;
  v_original_id uuid;
  v_claim jsonb;
  v_impl_execution uuid;
  v_submit jsonb;
  v_review_one jsonb;
  v_review_one_id uuid;
  v_cancel jsonb;
  v_review_two jsonb;
  v_review_two_id uuid;
  v_review_claim jsonb;
  v_review_execution uuid;
  v_review_result jsonb;
  v_status text;
  v_review_count integer;

  v_failed_original jsonb;
  v_failed_original_id uuid;
  v_failed_claim jsonb;
  v_failed_execution uuid;
  v_failed_submit jsonb;
  v_failed_review jsonb;
  v_failed_review_id uuid;
  v_reclaim jsonb;
  v_attempt integer;
  v_recreated_review jsonb;
  v_recreated_review_id uuid;
BEGIN
  -- Create and submit a review-required implementation delivery.
  v_original := public.create_task(
    v_project,v_worker,'implementation',
    'Review recovery cancellation fixture',
    'Disposable transaction-scoped review cancellation fixture',
    '{"test":"review-cancel-recreate"}'::jsonb,-200,true,
    null,null,'review-recovery-original-' || gen_random_uuid()::text
  );
  v_original_id := (v_original->'data'->>'id')::uuid;

  SELECT public.claim_task(w.project_id,w.id,600,
    'review-recovery-implementation-claim-' || gen_random_uuid()::text)
    INTO v_claim
  FROM public.workers w
  WHERE w.id=v_worker AND w.project_id=v_project;
  IF (v_claim->'data'->>'task_id')::uuid IS DISTINCT FROM v_original_id THEN
    RAISE EXCEPTION 'FAIL: implementation claim selected unexpected task: %',v_claim;
  END IF;
  v_impl_execution := (v_claim->'data'->>'execution_id')::uuid;

  v_submit := public.submit_result(
    v_original_id,v_impl_execution,v_worker,
    '{"summary":"review cancellation fixture submitted"}'::jsonb,
    'review-recovery-implementation-submit-' || gen_random_uuid()::text
  );
  IF v_submit->'data'->>'status' <> 'submitted' THEN
    RAISE EXCEPTION 'FAIL: delivery was not submitted: %',v_submit;
  END IF;

  -- First review is cancelled; its immutable history must not block replacement.
  v_review_one := public.create_review_task(
    v_original_id,v_original_id,v_impl_execution,v_reviewer,
    'review-recovery-create-first-' || gen_random_uuid()::text
  );
  v_review_one_id := (v_review_one->'data'->>'id')::uuid;

  v_cancel := public.cancel_task(
    v_review_one_id,v_reviewer,'test cancellation for replacement recovery',
    'review-recovery-cancel-first-' || gen_random_uuid()::text
  );
  IF v_cancel->'data'->>'status' <> 'cancelled' THEN
    RAISE EXCEPTION 'FAIL: first review was not cancelled: %',v_cancel;
  END IF;

  v_review_two := public.create_review_task(
    v_original_id,v_original_id,v_impl_execution,v_reviewer,
    'review-recovery-create-after-cancel-' || gen_random_uuid()::text
  );
  v_review_two_id := (v_review_two->'data'->>'id')::uuid;
  IF v_review_two_id IS NULL OR v_review_two_id=v_review_one_id THEN
    RAISE EXCEPTION 'FAIL: replacement review was not created with a fresh task id';
  END IF;

  SELECT status INTO v_status FROM public.tasks WHERE id=v_review_one_id;
  IF v_status <> 'cancelled' THEN
    RAISE EXCEPTION 'FAIL: cancelled review history was mutated: %',v_status;
  END IF;
  SELECT count(*) INTO v_review_count
  FROM public.tasks
  WHERE task_type='review'
    AND review_target_original_task_id=v_original_id
    AND review_target_delivery_task_id=v_original_id
    AND review_target_execution_id=v_impl_execution;
  IF v_review_count <> 2 THEN
    RAISE EXCEPTION 'FAIL: expected two review records after one cancellation and one replacement, got %',v_review_count;
  END IF;

  -- A pending replacement still blocks a third active review.
  BEGIN
    PERFORM public.create_review_task(
      v_original_id,v_original_id,v_impl_execution,v_reviewer,
      'review-recovery-active-duplicate-' || gen_random_uuid()::text
    );
    RAISE EXCEPTION 'FAIL: active duplicate review unexpectedly created';
  EXCEPTION WHEN SQLSTATE '23505' THEN
    IF SQLERRM <> 'REVIEW_ALREADY_EXISTS' THEN RAISE; END IF;
  END;

  -- Complete the replacement with a rejected decision. Completed review history remains terminal.
  SELECT public.claim_task(w.project_id,w.id,600,
    'review-recovery-review-claim-' || gen_random_uuid()::text)
    INTO v_review_claim
  FROM public.workers w
  WHERE w.id=v_reviewer AND w.project_id=v_project;
  IF (v_review_claim->'data'->>'task_id')::uuid IS DISTINCT FROM v_review_two_id THEN
    RAISE EXCEPTION 'FAIL: Reviewer claim selected unexpected task: %',v_review_claim;
  END IF;
  v_review_execution := (v_review_claim->'data'->>'execution_id')::uuid;

  v_review_result := public.review_result(
    v_review_two_id,v_review_execution,v_reviewer,'rejected',
    '{"summary":"fixture confirms completed review decision is terminal"}'::jsonb,
    'review-recovery-review-result-' || gen_random_uuid()::text
  );
  IF v_review_result->'data'->>'decision' <> 'rejected' THEN
    RAISE EXCEPTION 'FAIL: rejected review result was not recorded: %',v_review_result;
  END IF;

  BEGIN
    PERFORM public.create_review_task(
      v_original_id,v_original_id,v_impl_execution,v_reviewer,
      'review-recovery-completed-duplicate-' || gen_random_uuid()::text
    );
    RAISE EXCEPTION 'FAIL: completed review unexpectedly recreated';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM <> 'ORIGINAL_TASK_NOT_SUBMITTED' THEN RAISE; END IF;
  END;
  SELECT count(*) INTO v_review_count
  FROM public.tasks
  WHERE task_type='review'
    AND review_target_original_task_id=v_original_id
    AND review_target_delivery_task_id=v_original_id
    AND review_target_execution_id=v_impl_execution;
  IF v_review_count <> 2 THEN
    RAISE EXCEPTION 'FAIL: completed review recreation created an unexpected task';
  END IF;

  -- Exhaust a second review through the real bounded-lease path; failed history must be retryable.
  v_failed_original := public.create_task(
    v_project,v_worker,'implementation',
    'Review recovery failed-attempt fixture',
    'Disposable transaction-scoped failed-review fixture',
    '{"test":"review-failure-recreate"}'::jsonb,-200,true,
    null,null,'review-recovery-failed-original-' || gen_random_uuid()::text
  );
  v_failed_original_id := (v_failed_original->'data'->>'id')::uuid;

  SELECT public.claim_task(w.project_id,w.id,600,
    'review-recovery-failed-implementation-claim-' || gen_random_uuid()::text)
    INTO v_failed_claim
  FROM public.workers w
  WHERE w.id=v_worker AND w.project_id=v_project;
  IF (v_failed_claim->'data'->>'task_id')::uuid IS DISTINCT FROM v_failed_original_id THEN
    RAISE EXCEPTION 'FAIL: failed-attempt implementation claim selected unexpected task: %',v_failed_claim;
  END IF;
  v_failed_execution := (v_failed_claim->'data'->>'execution_id')::uuid;

  v_failed_submit := public.submit_result(
    v_failed_original_id,v_failed_execution,v_worker,
    '{"summary":"failed-review fixture submitted"}'::jsonb,
    'review-recovery-failed-implementation-submit-' || gen_random_uuid()::text
  );
  IF v_failed_submit->'data'->>'status' <> 'submitted' THEN
    RAISE EXCEPTION 'FAIL: second delivery was not submitted: %',v_failed_submit;
  END IF;

  v_failed_review := public.create_review_task(
    v_failed_original_id,v_failed_original_id,v_failed_execution,v_reviewer,
    'review-recovery-create-failed-review-' || gen_random_uuid()::text
  );
  v_failed_review_id := (v_failed_review->'data'->>'id')::uuid;

  FOR v_attempt IN 1..3 LOOP
    SELECT public.claim_task(w.project_id,w.id,600,
      'review-recovery-failed-review-claim-' || v_attempt || '-' || gen_random_uuid()::text)
      INTO v_reclaim
    FROM public.workers w
    WHERE w.id=v_reviewer AND w.project_id=v_project;
    IF (v_reclaim->'data'->>'task_id')::uuid IS DISTINCT FROM v_failed_review_id THEN
      RAISE EXCEPTION 'FAIL: retry % claimed unexpected Reviewer task: %',v_attempt,v_reclaim;
    END IF;
    UPDATE public.tasks
    SET lease_until=clock_timestamp()-interval '1 second'
    WHERE id=v_failed_review_id AND status='running';
  END LOOP;

  -- The next claim observes the exhausted third attempt and marks it failed.
  SELECT public.claim_task(w.project_id,w.id,600,
    'review-recovery-failed-review-exhaust-' || gen_random_uuid()::text)
    INTO v_reclaim
  FROM public.workers w
  WHERE w.id=v_reviewer AND w.project_id=v_project;
  IF v_reclaim->'data'->>'task_id' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: exhausted review unexpectedly remained claimable: %',v_reclaim;
  END IF;
  SELECT status INTO v_status FROM public.tasks WHERE id=v_failed_review_id;
  IF v_status <> 'failed' THEN
    RAISE EXCEPTION 'FAIL: exhausted review did not become failed: %',v_status;
  END IF;

  v_recreated_review := public.create_review_task(
    v_failed_original_id,v_failed_original_id,v_failed_execution,v_reviewer,
    'review-recovery-create-after-failed-' || gen_random_uuid()::text
  );
  v_recreated_review_id := (v_recreated_review->'data'->>'id')::uuid;
  IF v_recreated_review_id IS NULL OR v_recreated_review_id=v_failed_review_id THEN
    RAISE EXCEPTION 'FAIL: replacement after failed review was not created';
  END IF;

  BEGIN
    PERFORM public.create_review_task(
      v_failed_original_id,v_failed_original_id,v_failed_execution,v_reviewer,
      'review-recovery-failed-active-duplicate-' || gen_random_uuid()::text
    );
    RAISE EXCEPTION 'FAIL: duplicate after failed-review replacement unexpectedly created';
  EXCEPTION WHEN SQLSTATE '23505' THEN
    IF SQLERRM <> 'REVIEW_ALREADY_EXISTS' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'PASS: cancelled review replacement, active duplicate rejection, completed rejection is terminal, bounded retry failure replacement, and immutable review history';
END
$test$;

ROLLBACK;
