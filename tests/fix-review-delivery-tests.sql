-- Regression coverage for final review decisions on distinct fix-delivery tasks.
-- Fixtures use the existing RPC lifecycle and are rolled back as one transaction.
BEGIN;

SELECT set_config('request.jwt.claim.sub', :'owner_id', true);

DO $test$
DECLARE
  v_owner uuid := current_setting('request.jwt.claim.sub')::uuid;
  v_project uuid := gen_random_uuid();
  v_worker uuid := gen_random_uuid();
  v_reviewer uuid := gen_random_uuid();
  v_decision text;
  v_created jsonb;
  v_claim jsonb;
  v_submit jsonb;
  v_direct_review jsonb;
  v_fix jsonb;
  v_resubmit jsonb;
  v_review jsonb;
  v_review_result jsonb;
  v_replay jsonb;
  v_root_id uuid;
  v_root_execution_id uuid;
  v_direct_review_id uuid;
  v_direct_review_execution_id uuid;
  v_fix_id uuid;
  v_fix_execution_id uuid;
  v_review_id uuid;
  v_review_execution_id uuid;
  v_delivery_result jsonb;
  v_review_evidence jsonb;
  v_status text;
  v_review_decision text;
  v_stored_review_evidence jsonb;
  v_latest_review_task_id uuid;
  v_task_result jsonb;
  v_completed_at timestamptz;
  v_current_execution_id uuid;
  v_lease_until timestamptz;
  v_execution_status text;
  v_execution_result jsonb;
  v_execution_finished_at timestamptz;
  v_event_count integer;
  v_final_idempotency_key text;
BEGIN
  -- Isolate this regression from shared fixture project pause/cap mutations.
  -- The project and both Workers are rolled back with the test transaction.
  INSERT INTO public.projects(id, name, owner_id, status, config)
  VALUES (
    v_project,
    'fix-delivery-terminal-state-fixture',
    v_owner,
    'active',
    jsonb_build_object(
      'autonomy', jsonb_build_object('paused', false, 'max_active_executions', 2),
      'worker_routing', jsonb_build_object(
        'default_worker_key', 'test-worker-a',
        'task_type_worker_keys', jsonb_build_object('review', 'test-reviewer')
      )
    )
  );

  INSERT INTO public.workers(id, project_id, worker_key, display_name, status, auth_user_id)
  VALUES
    (v_worker, v_project, 'test-worker-a', 'Fix Delivery Executor', 'active', NULL),
    (v_reviewer, v_project, 'test-reviewer', 'Fix Delivery Reviewer', 'active', NULL);

  FOREACH v_decision IN ARRAY ARRAY['accepted', 'rejected'] LOOP
    -- First reject a direct implementation delivery. This exercises the
    -- delivery_task_id = original_task_id path before creating a fix child.
    v_created := public.create_task(
      v_project, v_worker, 'implementation',
      'Fix-delivery terminal-state fixture (' || v_decision || ')',
      'Transaction-scoped fixture for distinct fix-delivery review decisions',
      jsonb_build_object('required_worker_key', 'test-worker-a', 'case', v_decision),
      -2000, true, NULL, NULL,
      'fix-delivery-root-create-' || v_decision || '-' || gen_random_uuid()::text
    );
    v_root_id := (v_created->'data'->>'id')::uuid;

    v_claim := public.claim_task(
      v_project, v_worker, 600,
      'fix-delivery-root-claim-' || v_decision || '-' || gen_random_uuid()::text
    );
    IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_root_id::text THEN
      RAISE EXCEPTION 'FAIL: root delivery claim selected unexpected task: %', v_claim;
    END IF;
    v_root_execution_id := (v_claim->'data'->>'execution_id')::uuid;

    v_delivery_result := jsonb_build_object(
      'kind', 'root-delivery',
      'case', v_decision,
      'result_token', gen_random_uuid()::text
    );
    v_submit := public.submit_result(
      v_root_id, v_root_execution_id, v_worker, v_delivery_result,
      'fix-delivery-root-submit-' || v_decision || '-' || gen_random_uuid()::text
    );
    IF v_submit->'data'->>'status' <> 'submitted' THEN
      RAISE EXCEPTION 'FAIL: root delivery was not submitted: %', v_submit;
    END IF;

    v_direct_review := public.create_review_task(
      v_root_id, v_root_id, v_root_execution_id, v_reviewer,
      'fix-delivery-direct-review-create-' || v_decision || '-' || gen_random_uuid()::text
    );
    v_direct_review_id := (v_direct_review->'data'->>'id')::uuid;

    v_claim := public.claim_task(
      v_project, v_reviewer, 600,
      'fix-delivery-direct-review-claim-' || v_decision || '-' || gen_random_uuid()::text
    );
    IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_direct_review_id::text THEN
      RAISE EXCEPTION 'FAIL: direct review claim selected unexpected task: %', v_claim;
    END IF;
    v_direct_review_execution_id := (v_claim->'data'->>'execution_id')::uuid;

    v_review_evidence := jsonb_build_object(
      'decision', 'rejected',
      'summary', 'Initial direct-delivery review permits creation of a fix child'
    );
    v_review_result := public.review_result(
      v_direct_review_id, v_direct_review_execution_id, v_reviewer, 'rejected',
      v_review_evidence,
      'fix-delivery-direct-review-result-' || v_decision || '-' || gen_random_uuid()::text
    );
    IF v_review_result->'data'->>'decision' <> 'rejected' THEN
      RAISE EXCEPTION 'FAIL: direct delivery rejection was not recorded: %', v_review_result;
    END IF;

    -- Direct delivery remains represented by the root itself; the new logic
    -- must not attempt a second mutation of the same row.
    IF NOT EXISTS (
      SELECT 1
      FROM public.tasks
      WHERE id = v_root_id
        AND status = 'rejected'
        AND latest_delivery_task_id = v_root_id
        AND latest_delivery_execution_id = v_root_execution_id
        AND latest_review_task_id = v_direct_review_id
        AND completed_at IS NOT NULL
    ) OR NOT EXISTS (
      SELECT 1
      FROM public.tasks
      WHERE id = v_direct_review_id
        AND task_type = 'review'
        AND status = 'accepted'
        AND review_decision = 'rejected'
        AND review_evidence = v_review_evidence
    ) THEN
      RAISE EXCEPTION 'FAIL: direct-delivery review behavior changed for root %', v_root_id;
    END IF;

    v_fix := public.create_fix_task(
      v_root_id, v_direct_review_id,
      'Fix child (' || v_decision || ')',
      'Disposable fix child for review_result terminal-state regression',
      jsonb_build_object('required_worker_key', 'test-worker-a', 'case', v_decision),
      v_worker,
      'fix-delivery-fix-create-' || v_decision || '-' || gen_random_uuid()::text
    );
    v_fix_id := (v_fix->'data'->>'id')::uuid;

    v_claim := public.claim_task(
      v_project, v_worker, 600,
      'fix-delivery-fix-claim-' || v_decision || '-' || gen_random_uuid()::text
    );
    IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_fix_id::text THEN
      RAISE EXCEPTION 'FAIL: fix child claim selected unexpected task: %', v_claim;
    END IF;
    v_fix_execution_id := (v_claim->'data'->>'execution_id')::uuid;

    v_delivery_result := jsonb_build_object(
      'kind', 'fix-delivery',
      'case', v_decision,
      'result_token', gen_random_uuid()::text
    );
    v_submit := public.submit_result(
      v_fix_id, v_fix_execution_id, v_worker, v_delivery_result,
      'fix-delivery-fix-submit-' || v_decision || '-' || gen_random_uuid()::text
    );
    IF v_submit->'data'->>'status' <> 'submitted' THEN
      RAISE EXCEPTION 'FAIL: fix child delivery was not submitted: %', v_submit;
    END IF;

    v_resubmit := public.resubmit_after_fix(
      v_root_id, v_fix_id, v_fix_execution_id, v_worker,
      'fix-delivery-root-resubmit-' || v_decision || '-' || gen_random_uuid()::text
    );
    IF v_resubmit->'data'->>'status' <> 'submitted'
      OR v_resubmit->'data'->>'delivery_task_id' IS DISTINCT FROM v_fix_id::text THEN
      RAISE EXCEPTION 'FAIL: original task was not resubmitted against the fix delivery: %', v_resubmit;
    END IF;

    v_review := public.create_review_task(
      v_root_id, v_fix_id, v_fix_execution_id, v_reviewer,
      'fix-delivery-child-review-create-' || v_decision || '-' || gen_random_uuid()::text
    );
    v_review_id := (v_review->'data'->>'id')::uuid;

    v_claim := public.claim_task(
      v_project, v_reviewer, 600,
      'fix-delivery-child-review-claim-' || v_decision || '-' || gen_random_uuid()::text
    );
    IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_review_id::text THEN
      RAISE EXCEPTION 'FAIL: fix child review claim selected unexpected task: %', v_claim;
    END IF;
    v_review_execution_id := (v_claim->'data'->>'execution_id')::uuid;

    v_review_evidence := jsonb_build_object(
      'decision', v_decision,
      'summary', 'Independent review decision for a distinct fix delivery',
      'checks', jsonb_build_array('fix result inspected', 'submitted execution preserved'),
      'fixture', true
    );
    v_final_idempotency_key := 'fix-delivery-child-review-result-' || v_decision || '-' || gen_random_uuid()::text;
    v_review_result := public.review_result(
      v_review_id, v_review_execution_id, v_reviewer, v_decision,
      v_review_evidence, v_final_idempotency_key
    );
    IF v_review_result->'data'->>'decision' IS DISTINCT FROM v_decision THEN
      RAISE EXCEPTION 'FAIL: fix child review returned an unexpected decision: %', v_review_result;
    END IF;

    SELECT status, review_decision, review_evidence, latest_review_task_id,
           result, completed_at, current_execution_id, lease_until
    INTO v_status, v_review_decision, v_stored_review_evidence, v_latest_review_task_id,
         v_task_result, v_completed_at, v_current_execution_id, v_lease_until
    FROM public.tasks
    WHERE id = v_fix_id;

    IF v_status IS DISTINCT FROM v_decision
      OR v_review_decision IS DISTINCT FROM v_decision
      OR v_stored_review_evidence IS DISTINCT FROM v_review_evidence
      OR v_latest_review_task_id IS DISTINCT FROM v_review_id
      OR v_task_result IS DISTINCT FROM v_delivery_result
      OR v_completed_at IS NULL
      OR v_current_execution_id IS NOT NULL
      OR v_lease_until IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL: fix delivery did not persist terminal review state or preserve its result: task=%', v_fix_id;
    END IF;

    SELECT status, result, finished_at
    INTO v_execution_status, v_execution_result, v_execution_finished_at
    FROM public.executions
    WHERE id = v_fix_execution_id AND task_id = v_fix_id;

    IF v_execution_status IS DISTINCT FROM 'submitted'
      OR v_execution_result IS DISTINCT FROM v_delivery_result
      OR v_execution_finished_at IS NULL THEN
      RAISE EXCEPTION 'FAIL: submitted fix execution history was changed: execution=%', v_fix_execution_id;
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.tasks
      WHERE id = v_root_id
        AND status = v_decision
        AND latest_delivery_task_id = v_fix_id
        AND latest_delivery_execution_id = v_fix_execution_id
        AND latest_review_task_id = v_review_id
        AND completed_at IS NOT NULL
    ) THEN
      RAISE EXCEPTION 'FAIL: original task did not receive the same terminal review decision: %', v_root_id;
    END IF;

    v_replay := public.review_result(
      v_review_id, v_review_execution_id, v_reviewer, v_decision,
      v_review_evidence, v_final_idempotency_key
    );

    IF v_replay IS DISTINCT FROM v_review_result THEN
      RAISE EXCEPTION 'FAIL: review_result idempotent replay changed its response: %', v_replay;
    END IF;

    SELECT count(*) INTO v_event_count
    FROM public.task_events
    WHERE task_id = v_review_id
      AND event_type = CASE WHEN v_decision = 'accepted' THEN 'review_accepted' ELSE 'review_rejected' END;
    IF v_event_count <> 1 THEN
      RAISE EXCEPTION 'FAIL: review idempotent replay duplicated review events: %', v_event_count;
    END IF;
  END LOOP;

  RAISE NOTICE 'PASS: accepted/rejected distinct fix delivery state, review evidence/pointers, terminal timestamps, immutable submitted result/execution, idempotent replay, and direct-delivery non-regression';
END;
$test$;

ROLLBACK;
