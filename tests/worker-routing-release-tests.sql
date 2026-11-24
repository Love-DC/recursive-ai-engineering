-- Worker-key routing and fenced release integration tests.
-- All fixture rows, events and idempotency records are rolled back.

BEGIN;
SELECT set_config('request.jwt.claim.sub', :'owner_id', true);
SELECT set_config('test.project_id', :'project_id', true);
SELECT set_config('test.owner_id', :'owner_id', true);
SELECT set_config('test.worker_a', :'worker_a', true);
SELECT set_config('test.worker_b', :'worker_b', true);
SELECT set_config('test.reviewer_worker', :'reviewer_worker', true);

-- Explicit Worker-key arrays are strict JSON string arrays. Never coerce malformed
-- elements to text or partially accept a mixed-validity route.
DO $route_array_test$
DECLARE
  v_project uuid := current_setting('test.project_id')::uuid;
  v_keys text[];
BEGIN
  -- Missing task route inherits the configured project route; explicit JSON null
  -- is malformed and must not inherit that same route.
  v_keys := private.resolve_task_worker_keys(v_project,'implementation','{}'::jsonb);
  IF cardinality(v_keys) <> 2
    OR NOT ('test-worker-a'=ANY(v_keys))
    OR NOT ('test-worker-b'=ANY(v_keys)) THEN
    RAISE EXCEPTION 'FAIL: missing task route did not inherit project routing: %',v_keys;
  END IF;

  v_keys := private.resolve_task_worker_keys(v_project,'implementation',
    '{"required_worker_key":null}'::jsonb);
  IF v_keys IS DISTINCT FROM '{}'::text[] THEN
    RAISE EXCEPTION 'FAIL: explicit JSON null task route fell back to project routing: %',v_keys;
  END IF;

  v_keys := private.resolve_task_worker_keys(v_project,'implementation',
    '{"required_worker_key":[123]}'::jsonb);
  IF v_keys IS DISTINCT FROM '{}'::text[] THEN
    RAISE EXCEPTION 'FAIL: numeric Worker-key array element was coerced: %',v_keys;
  END IF;

  v_keys := private.resolve_task_worker_keys(v_project,'implementation',
    '{"required_worker_key":[true]}'::jsonb);
  IF v_keys IS DISTINCT FROM '{}'::text[] THEN
    RAISE EXCEPTION 'FAIL: boolean Worker-key array element was coerced: %',v_keys;
  END IF;

  v_keys := private.resolve_task_worker_keys(v_project,'implementation',
    '{"required_worker_key":[{}]}'::jsonb);
  IF v_keys IS DISTINCT FROM '{}'::text[] THEN
    RAISE EXCEPTION 'FAIL: object Worker-key array element was coerced: %',v_keys;
  END IF;

  v_keys := private.resolve_task_worker_keys(v_project,'implementation',
    '{"required_worker_key":[null]}'::jsonb);
  IF v_keys IS DISTINCT FROM '{}'::text[] THEN
    RAISE EXCEPTION 'FAIL: null Worker-key array element was accepted: %',v_keys;
  END IF;

  v_keys := private.resolve_task_worker_keys(v_project,'implementation',
    '{"required_worker_key":["test-worker-a",123]}'::jsonb);
  IF v_keys IS DISTINCT FROM '{}'::text[] THEN
    RAISE EXCEPTION 'FAIL: mixed-validity Worker-key array was partially accepted: %',v_keys;
  END IF;

  v_keys := private.resolve_task_worker_keys(v_project,'implementation',
    '{"required_worker_key":["test-worker-a","   "]}'::jsonb);
  IF v_keys IS DISTINCT FROM '{}'::text[] THEN
    RAISE EXCEPTION 'FAIL: blank Worker-key array element was accepted: %',v_keys;
  END IF;

  v_keys := private.resolve_task_worker_keys(v_project,'implementation',
    jsonb_build_object('required_worker_key',chr(9)));
  IF v_keys IS DISTINCT FROM '{}'::text[] THEN
    RAISE EXCEPTION 'FAIL: tab-only scalar Worker-key route was accepted: %',v_keys;
  END IF;

  v_keys := private.resolve_task_worker_keys(v_project,'implementation',
    jsonb_build_object('required_worker_key',chr(10)));
  IF v_keys IS DISTINCT FROM '{}'::text[] THEN
    RAISE EXCEPTION 'FAIL: newline-only scalar Worker-key route was accepted: %',v_keys;
  END IF;

  v_keys := private.resolve_task_worker_keys(v_project,'implementation',
    jsonb_build_object('required_worker_key',chr(11)));
  IF v_keys IS DISTINCT FROM '{}'::text[] THEN
    RAISE EXCEPTION 'FAIL: vertical-tab-only scalar Worker-key route was accepted: %',v_keys;
  END IF;

  v_keys := private.resolve_task_worker_keys(v_project,'implementation',
    jsonb_build_object('required_worker_key',jsonb_build_array(chr(9))));
  IF v_keys IS DISTINCT FROM '{}'::text[] THEN
    RAISE EXCEPTION 'FAIL: tab-only array Worker-key element was accepted: %',v_keys;
  END IF;

  v_keys := private.resolve_task_worker_keys(v_project,'implementation',
    jsonb_build_object('required_worker_key',jsonb_build_array(chr(10))));
  IF v_keys IS DISTINCT FROM '{}'::text[] THEN
    RAISE EXCEPTION 'FAIL: newline-only array Worker-key element was accepted: %',v_keys;
  END IF;

  v_keys := private.resolve_task_worker_keys(v_project,'implementation',
    jsonb_build_object('required_worker_key',jsonb_build_array(chr(11))));
  IF v_keys IS DISTINCT FROM '{}'::text[] THEN
    RAISE EXCEPTION 'FAIL: vertical-tab-only array Worker-key element was accepted: %',v_keys;
  END IF;

  v_keys := private.resolve_task_worker_keys(v_project,'implementation',
    jsonb_build_object('required_worker_key',jsonb_build_array('test-worker-a',chr(9))));
  IF v_keys IS DISTINCT FROM '{}'::text[] THEN
    RAISE EXCEPTION 'FAIL: mixed valid/tab-only Worker-key array was accepted: %',v_keys;
  END IF;

  v_keys := private.resolve_task_worker_keys(v_project,'implementation',
    jsonb_build_object('required_worker_key',jsonb_build_array('test-worker-a',chr(10))));
  IF v_keys IS DISTINCT FROM '{}'::text[] THEN
    RAISE EXCEPTION 'FAIL: mixed valid/newline-only Worker-key array was accepted: %',v_keys;
  END IF;

  v_keys := private.resolve_task_worker_keys(v_project,'implementation',
    jsonb_build_object('required_worker_key',' '||chr(9)||'test-worker-a'||chr(10)||' '));
  IF v_keys IS DISTINCT FROM ARRAY['test-worker-a']::text[] THEN
    RAISE EXCEPTION 'FAIL: nonblank Worker-key route was not normalized across whitespace: %',v_keys;
  END IF;

  v_keys := private.resolve_task_worker_keys(v_project,'implementation',
    '{"required_worker_key":["test-worker-a","test-worker-b"]}'::jsonb);
  IF cardinality(v_keys) <> 2
    OR NOT ('test-worker-a'=ANY(v_keys))
    OR NOT ('test-worker-b'=ANY(v_keys)) THEN
    RAISE EXCEPTION 'FAIL: valid string Worker-key array was not preserved: %',v_keys;
  END IF;

  RAISE NOTICE 'PASS: Worker-key arrays reject numeric, boolean, object, null, blank, and mixed-validity elements; valid string arrays remain supported';
END;
$route_array_test$;

DO $test$
DECLARE
  v_project uuid := current_setting('test.project_id')::uuid;
  v_owner uuid := current_setting('test.owner_id')::uuid;
  v_a uuid := current_setting('test.worker_a')::uuid;
  v_b uuid := current_setting('test.worker_b')::uuid;
  v_reviewer uuid := current_setting('test.reviewer_worker')::uuid;
  v_created jsonb;
  v_claim jsonb;
  v_result jsonb;
  v_task_id uuid;
  v_execution_id uuid;
  v_review_id uuid;
  v_single_project uuid;
  v_single_worker uuid;
  v_ambiguous_project uuid;
  v_ambiguous_a uuid;
  v_ambiguous_b uuid;
  v_single_task uuid;
  v_ambiguous_task uuid;
  v_cap_task uuid;
  v_cap_execution uuid;
  v_cap_execution_count integer;
  v_old_execution uuid;
  v_new_execution uuid;
  v_release_key text;
  v_event_count integer;
BEGIN
  -- A Reviewer route must not claim ordinary implementation work.
  v_created := public.create_task(
    v_project,v_a,'implementation','Route test: default executor task',
    'Fixture for default worker route',
    '{}'::jsonb,-100,false,null,null,'route-default-create-'||gen_random_uuid()::text
  );
  v_task_id := (v_created->'data'->>'id')::uuid;

  v_claim := public.claim_task(v_project,v_reviewer,120,'route-reviewer-denied-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: independent reviewer claimed implementation task %',v_claim;
  END IF;

  v_claim := public.claim_task(v_project,v_a,120,'route-default-claim-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_task_id::text THEN
    RAISE EXCEPTION 'FAIL: default executor route could not claim its task: %',v_claim;
  END IF;
  v_execution_id := (v_claim->'data'->>'execution_id')::uuid;
  PERFORM public.complete_execution(
    v_task_id,v_execution_id,v_a,'{"summary":"default route passed"}'::jsonb,
    'route-default-complete-'||gen_random_uuid()::text
  );

  -- A per-task required_worker_key overrides project defaults.
  v_created := public.create_task(
    v_project,v_a,'implementation','Route test: explicit worker task',
    'Fixture for required_worker_key precedence',
    '{"required_worker_key":"test-worker-b"}'::jsonb,-90,false,null,null,
    'route-explicit-create-'||gen_random_uuid()::text
  );
  v_task_id := (v_created->'data'->>'id')::uuid;

  v_claim := public.claim_task(v_project,v_a,120,'route-explicit-a-denied-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: default executor bypassed explicit required_worker_key';
  END IF;
  v_claim := public.claim_task(v_project,v_b,120,'route-explicit-b-claim-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_task_id::text THEN
    RAISE EXCEPTION 'FAIL: explicitly routed Worker B could not claim task: %',v_claim;
  END IF;
  v_execution_id := (v_claim->'data'->>'execution_id')::uuid;
  PERFORM public.complete_execution(
    v_task_id,v_execution_id,v_b,'{"summary":"explicit route passed"}'::jsonb,
    'route-explicit-complete-'||gen_random_uuid()::text
  );

  -- Expired executions must use the same route filter as pending tasks.
  v_created := public.create_task(
    v_project,v_a,'implementation','Route test: expired reclaim',
    'Fixture for route-safe lease reclaim',
    '{"required_worker_key":"test-worker-a"}'::jsonb,-80,false,null,null,
    'route-expired-create-'||gen_random_uuid()::text
  );
  v_task_id := (v_created->'data'->>'id')::uuid;
  v_claim := public.claim_task(v_project,v_a,120,'route-expired-initial-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_task_id::text THEN
    RAISE EXCEPTION 'FAIL: Worker A could not claim its routed task';
  END IF;
  v_old_execution := (v_claim->'data'->>'execution_id')::uuid;
  UPDATE public.tasks SET lease_until=clock_timestamp()-interval '1 second'
  WHERE id=v_task_id AND current_execution_id=v_old_execution;

  v_claim := public.claim_task(v_project,v_b,120,'route-expired-b-denied-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: Worker B reclaimed a task routed only to Worker A';
  END IF;
  v_claim := public.claim_task(v_project,v_a,120,'route-expired-a-reclaim-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_task_id::text
    OR (v_claim->'data'->>'attempt')::integer <> 2 THEN
    RAISE EXCEPTION 'FAIL: eligible Worker A could not reclaim its expired task: %',v_claim;
  END IF;
  v_execution_id := (v_claim->'data'->>'execution_id')::uuid;
  PERFORM public.complete_execution(
    v_task_id,v_execution_id,v_a,'{"summary":"route-safe reclaim passed"}'::jsonb,
    'route-expired-complete-'||gen_random_uuid()::text
  );

  -- Review creation and claim are pinned to the configured reviewer route.
  v_created := public.create_task(
    v_project,v_a,'implementation','Route test: review delivery',
    'Fixture for review-route validation',
    '{}'::jsonb,-70,true,null,null,'route-review-delivery-create-'||gen_random_uuid()::text
  );
  v_task_id := (v_created->'data'->>'id')::uuid;
  v_claim := public.claim_task(v_project,v_a,120,'route-review-delivery-claim-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_task_id::text THEN
    RAISE EXCEPTION 'FAIL: executor could not claim review-gated delivery';
  END IF;
  v_execution_id := (v_claim->'data'->>'execution_id')::uuid;
  PERFORM public.submit_result(
    v_task_id,v_execution_id,v_a,'{"summary":"delivery submitted"}'::jsonb,
    'route-review-delivery-submit-'||gen_random_uuid()::text
  );

  BEGIN
    PERFORM public.create_review_task(
      v_task_id,v_task_id,v_execution_id,v_b,
      'route-review-wrong-reviewer-'||gen_random_uuid()::text
    );
    RAISE EXCEPTION 'FAIL: create_review_task accepted a non-reviewer Worker';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    IF SQLERRM <> 'REVIEWER_ROUTE_MISMATCH' THEN RAISE; END IF;
  END;

  v_result := public.create_review_task(
    v_task_id,v_task_id,v_execution_id,v_reviewer,
    'route-review-create-'||gen_random_uuid()::text
  );
  v_review_id := (v_result->'data'->>'id')::uuid;

  v_claim := public.claim_task(v_project,v_a,120,'route-review-executor-denied-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: executor claimed a task pinned to independent-reviewer';
  END IF;
  v_claim := public.claim_task(v_project,v_reviewer,120,'route-reviewer-claim-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_review_id::text THEN
    RAISE EXCEPTION 'FAIL: independent reviewer could not claim its assigned review task: %',v_claim;
  END IF;

  -- Wrong Worker release is denied; correct release is idempotent and fenced.
  v_created := public.create_task(
    v_project,v_a,'implementation','Release test: active execution',
    'Fixture for explicit execution release',
    '{}'::jsonb,-60,false,null,null,'release-create-'||gen_random_uuid()::text
  );
  v_task_id := (v_created->'data'->>'id')::uuid;
  v_claim := public.claim_task(v_project,v_a,120,'release-claim-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_task_id::text THEN
    RAISE EXCEPTION 'FAIL: release fixture was not claimed';
  END IF;
  v_old_execution := (v_claim->'data'->>'execution_id')::uuid;

  BEGIN
    PERFORM public.release_execution(
      v_task_id,v_old_execution,v_b,'wrong worker','release-wrong-worker-'||gen_random_uuid()::text
    );
    RAISE EXCEPTION 'FAIL: wrong Worker released another Worker execution';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    IF SQLERRM <> 'TASK_NOT_OWNED' THEN RAISE; END IF;
  END;

  v_release_key := 'release-valid-'||gen_random_uuid()::text;
  v_result := public.release_execution(
    v_task_id,v_old_execution,v_a,'intentional handoff',v_release_key
  );
  IF v_result->'data'->>'status' <> 'pending'
    OR v_result->'data'->>'execution_status' <> 'superseded' THEN
    RAISE EXCEPTION 'FAIL: active lease release returned unexpected state: %',v_result;
  END IF;

  v_result := public.release_execution(
    v_task_id,v_old_execution,v_a,'intentional handoff',v_release_key
  );
  IF v_result->'data'->>'status' <> 'pending' THEN
    RAISE EXCEPTION 'FAIL: idempotent release replay failed: %',v_result;
  END IF;

  SELECT count(*) INTO v_event_count
  FROM public.task_events
  WHERE task_id=v_task_id AND event_type='task_released';
  IF v_event_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: idempotent release created % task_released events',v_event_count;
  END IF;

  v_claim := public.claim_task(v_project,v_a,120,'release-reclaim-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_task_id::text
    OR (v_claim->'data'->>'attempt')::integer <> 2 THEN
    RAISE EXCEPTION 'FAIL: released task was not safely claimable again: %',v_claim;
  END IF;
  v_new_execution := (v_claim->'data'->>'execution_id')::uuid;

  BEGIN
    PERFORM public.release_execution(
      v_task_id,v_old_execution,v_a,'stale release','release-stale-'||gen_random_uuid()::text
    );
    RAISE EXCEPTION 'FAIL: stale execution release unexpectedly succeeded';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM <> 'EXECUTION_SUPERSEDED' THEN RAISE; END IF;
  END;

  -- Release remains safe after lease expiry, provided no new execution superseded it.
  UPDATE public.tasks SET lease_until=clock_timestamp()-interval '1 second'
  WHERE id=v_task_id AND current_execution_id=v_new_execution;
  v_result := public.release_execution(
    v_task_id,v_new_execution,v_a,'expired lease cleanup','release-expired-'||gen_random_uuid()::text
  );
  IF v_result->'data'->>'status' <> 'pending'
    OR v_result->'data'->>'execution_status' <> 'expired' THEN
    RAISE EXCEPTION 'FAIL: expired lease release returned unexpected state: %',v_result;
  END IF;

  -- Releasing an expired execution at max_attempts must terminally fail the
  -- task; it must not reopen pending work or permit attempt max_attempts + 1.
  v_created := public.create_task(
    v_project,v_a,'implementation','Release test: retry cap',
    'A released execution at the configured cap must become terminally failed',
    '{"required_worker_key":"test-worker-b","retry":{"max_attempts":1}}'::jsonb,
    -1000,false,null,null,'release-retry-cap-create-'||gen_random_uuid()::text
  );
  v_cap_task := (v_created->'data'->>'id')::uuid;
  v_claim := public.claim_task(
    v_project,v_b,120,'release-retry-cap-claim-'||gen_random_uuid()::text
  );
  IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_cap_task::text
    OR (v_claim->'data'->>'attempt')::integer <> 1 THEN
    RAISE EXCEPTION 'FAIL: retry-cap fixture was not claimed as attempt 1: %',v_claim;
  END IF;
  v_cap_execution := (v_claim->'data'->>'execution_id')::uuid;
  UPDATE public.tasks SET lease_until=clock_timestamp()-interval '1 second'
  WHERE id=v_cap_task AND current_execution_id=v_cap_execution;

  v_result := public.release_execution(
    v_cap_task,v_cap_execution,v_b,'expired at retry cap',
    'release-retry-cap-'||gen_random_uuid()::text
  );
  IF v_result->'data'->>'status' <> 'failed'
    OR v_result->'data'->>'error_code' <> 'LEASE_RETRY_LIMIT_REACHED' THEN
    RAISE EXCEPTION 'FAIL: release bypassed max_attempts=1: %',v_result;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.tasks
    WHERE id=v_cap_task AND status='failed'
      AND result->>'error_code'='LEASE_RETRY_LIMIT_REACHED'
      AND current_execution_id IS NULL AND lease_until IS NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: retry-cap release did not persist terminal task failure';
  END IF;
  SELECT count(*) INTO v_cap_execution_count
  FROM public.executions WHERE task_id=v_cap_task;
  IF v_cap_execution_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: retry-cap fixture unexpectedly has % executions before reclaim',v_cap_execution_count;
  END IF;

  v_claim := public.claim_task(
    v_project,v_b,120,'release-retry-cap-no-reclaim-'||gen_random_uuid()::text
  );
  IF v_claim->'data'->>'task_id' = v_cap_task::text THEN
    RAISE EXCEPTION 'FAIL: task at max_attempts was claimable after release: %',v_claim;
  END IF;
  SELECT count(*) INTO v_cap_execution_count
  FROM public.executions WHERE task_id=v_cap_task;
  IF v_cap_execution_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: retry cap was bypassed; task now has % executions',v_cap_execution_count;
  END IF;

  -- A project with exactly one active Worker retains the safe legacy fallback.
  v_single_project := gen_random_uuid();
  v_single_worker := gen_random_uuid();
  INSERT INTO public.projects(id,name,owner_id,status,config)
  VALUES(v_single_project,'single-worker-route-fixture',v_owner,'active','{}'::jsonb);
  INSERT INTO public.workers(id,project_id,worker_key,display_name,status)
  VALUES(v_single_worker,v_single_project,'only-worker','Only Worker','active');
  v_created := public.create_task(
    v_single_project,v_single_worker,'implementation','Single worker fallback',
    'One active Worker means route is unambiguous','{}'::jsonb,-50,false,null,null,
    'single-worker-create-'||gen_random_uuid()::text
  );
  v_single_task := (v_created->'data'->>'id')::uuid;
  v_claim := public.claim_task(
    v_single_project,v_single_worker,120,'single-worker-claim-'||gen_random_uuid()::text
  );
  IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_single_task::text THEN
    RAISE EXCEPTION 'FAIL: sole active Worker fallback was not preserved: %',v_claim;
  END IF;

  -- A multi-Worker project with no explicit route fails closed.
  v_ambiguous_project := gen_random_uuid();
  v_ambiguous_a := gen_random_uuid();
  v_ambiguous_b := gen_random_uuid();
  INSERT INTO public.projects(id,name,owner_id,status,config)
  VALUES(v_ambiguous_project,'ambiguous-worker-route-fixture',v_owner,'active','{}'::jsonb);
  INSERT INTO public.workers(id,project_id,worker_key,display_name,status)
  VALUES
    (v_ambiguous_a,v_ambiguous_project,'ambiguous-a','Ambiguous A','active'),
    (v_ambiguous_b,v_ambiguous_project,'ambiguous-b','Ambiguous B','active');
  v_created := public.create_task(
    v_ambiguous_project,v_ambiguous_a,'implementation','Ambiguous route fixture',
    'Two active Workers and no routing metadata must not allow arbitrary claim',
    '{}'::jsonb,-40,false,null,null,'ambiguous-route-create-'||gen_random_uuid()::text
  );
  v_ambiguous_task := (v_created->'data'->>'id')::uuid;

  v_claim := public.claim_task(
    v_ambiguous_project,v_ambiguous_a,120,'ambiguous-a-claim-'||gen_random_uuid()::text
  );
  IF v_claim->'data'->>'task_id' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: ambiguous Worker A claimed without a route';
  END IF;
  v_claim := public.claim_task(
    v_ambiguous_project,v_ambiguous_b,120,'ambiguous-b-claim-'||gen_random_uuid()::text
  );
  IF v_claim->'data'->>'task_id' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: ambiguous Worker B claimed without a route';
  END IF;

  RAISE NOTICE 'PASS: reviewer isolation, default and explicit routes, review creation/claim routing, expired reclaim routing, safe release, retry-cap terminal failure/no-reclaim, ownership denial, idempotency, stale fencing, single-worker fallback, and ambiguous-route fail-closed behavior';
END;
$test$;

ROLLBACK;
