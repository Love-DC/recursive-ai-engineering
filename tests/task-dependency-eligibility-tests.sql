-- Task dependency eligibility integration tests.
-- All task, execution, event and idempotency fixture writes roll back.

BEGIN;
SELECT set_config('request.jwt.claim.sub', :'owner_id', true);
SELECT set_config('test.project_id', :'project_id', true);
SELECT set_config('test.worker_id', :'worker_id', true);

DO $dependency_test$
DECLARE
  v_project uuid := current_setting('test.project_id')::uuid;
  v_worker uuid := current_setting('test.worker_id')::uuid;
  v_created jsonb;
  v_claim jsonb;
  v_replay jsonb;
  v_task_id uuid;
  v_independent_id uuid;
  v_prerequisite_id uuid;
  v_dependent_id uuid;
  v_expired_id uuid;
  v_expired_independent_id uuid;
  v_cap_id uuid;
  v_execution_id uuid;
  v_old_execution_id uuid;
  v_attempt integer;
  v_status text;
  v_exec_status text;
  v_blocked_events integer;
  v_unblocked_events integer;
  v_dependency_events integer;
  v_exec_count integer;
  v_key text;
  v_evidence jsonb;
BEGIN
  -- A higher-priority external dependency stays pending and is reported,
  -- while an independent eligible task is still claimable.
  v_key := 'external:colony-sim-pr-428-merged';
  v_created := public.create_task(
    v_project,v_worker,'implementation','Dependency test: blocked external prerequisite',
    'Must remain pending until external evidence is recorded',
    jsonb_build_object('depends_on',jsonb_build_array(v_key)),
    -100,false,null,null,'dependency-external-blocked-create-'||gen_random_uuid()::text
  );
  v_task_id := (v_created->'data'->>'id')::uuid;

  v_created := public.create_task(
    v_project,v_worker,'implementation','Dependency test: independent eligible work',
    'Must remain claimable despite a higher-priority blocked task',
    '{}'::jsonb,-90,false,null,null,
    'dependency-independent-create-'||gen_random_uuid()::text
  );
  v_independent_id := (v_created->'data'->>'id')::uuid;

  v_claim := public.claim_task(v_project,v_worker,120,'dependency-independent-claim-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_independent_id::text THEN
    RAISE EXCEPTION 'FAIL: dependency-blocked higher-priority task prevented independent claim: %',v_claim;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_claim->'data'->'dependency_blockers') b
    WHERE b->>'task_id'=v_task_id::text
      AND b->'blockers' @> '[{"kind":"external","key":"external:colony-sim-pr-428-merged"}]'::jsonb
  ) THEN
    RAISE EXCEPTION 'FAIL: claim response omitted the external dependency blocker: %',v_claim;
  END IF;
  SELECT count(*) INTO v_blocked_events FROM public.task_events
  WHERE task_id=v_task_id AND event_type='dependency_blocked';
  IF v_blocked_events <> 1 THEN
    RAISE EXCEPTION 'FAIL: expected one initial dependency_blocked event, found %',v_blocked_events;
  END IF;

  -- A second scan reports the same blocker but does not spam duplicate events.
  v_claim := public.claim_task(v_project,v_worker,120,'dependency-blocked-repeat-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS NOT NULL
    OR jsonb_array_length(v_claim->'data'->'dependency_blockers') <> 1 THEN
    RAISE EXCEPTION 'FAIL: repeated blocked scan returned unexpected claim or blocker summary: %',v_claim;
  END IF;
  SELECT count(*) INTO v_blocked_events FROM public.task_events
  WHERE task_id=v_task_id AND event_type='dependency_blocked';
  IF v_blocked_events <> 1 THEN
    RAISE EXCEPTION 'FAIL: duplicate dependency_blocked events were emitted: %',v_blocked_events;
  END IF;
  SELECT status INTO v_status FROM public.tasks WHERE id=v_task_id;
  IF v_status <> 'pending' THEN
    RAISE EXCEPTION 'FAIL: unresolved external dependency changed pending task state to %',v_status;
  END IF;
  SELECT count(*) INTO v_exec_count FROM public.executions WHERE task_id=v_task_id;
  IF v_exec_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: unresolved external dependency created % executions',v_exec_count;
  END IF;

  PERFORM public.complete_execution(
    v_independent_id,(v_claim->'data'->>'execution_id')::uuid,v_worker,
    '{"summary":"independent work completed while another task remained dependency-blocked"}'::jsonb,
    'dependency-independent-complete-'||gen_random_uuid()::text
  );

  v_evidence := jsonb_build_object(
    'ref','https://github.com/Love-DC/colony-sim/pull/428',
    'observed_state','merged'
  );
  v_replay := public.resolve_task_dependency(
    v_task_id,v_key,'satisfied',v_evidence,'dependency-external-resolve-'||gen_random_uuid()::text
  );
  -- Exact replay returns the same durable resolution response.
  v_claim := public.resolve_task_dependency(
    v_task_id,v_key,'satisfied',v_evidence,
    (SELECT idempotency_key FROM public.operation_requests
      WHERE project_id=v_project AND operation='resolve_task_dependency'
      ORDER BY created_at DESC LIMIT 1)
  );
  IF v_claim IS DISTINCT FROM v_replay THEN
    RAISE EXCEPTION 'FAIL: dependency resolution idempotency replay changed response';
  END IF;

  v_claim := public.claim_task(v_project,v_worker,120,'dependency-external-unlocked-claim-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_task_id::text
    OR (v_claim->'data'->>'attempt')::integer <> 1 THEN
    RAISE EXCEPTION 'FAIL: task remained unclaimable after external dependency evidence: %',v_claim;
  END IF;
  v_execution_id := (v_claim->'data'->>'execution_id')::uuid;
  PERFORM public.complete_execution(
    v_task_id,v_execution_id,v_worker,
    '{"summary":"external dependency unlocked using recorded evidence"}'::jsonb,
    'dependency-external-complete-'||gen_random_uuid()::text
  );
  SELECT count(*) INTO v_unblocked_events FROM public.task_events
  WHERE task_id=v_task_id AND event_type='dependency_unblocked';
  IF v_unblocked_events <> 1 THEN
    RAISE EXCEPTION 'FAIL: expected dependency_unblocked event after claim, found %',v_unblocked_events;
  END IF;
  SELECT count(*) INTO v_dependency_events FROM public.task_events
  WHERE task_id=v_task_id AND event_type='dependency_resolved';
  IF v_dependency_events <> 1 THEN
    RAISE EXCEPTION 'FAIL: dependency resolution audit event missing or duplicated: %',v_dependency_events;
  END IF;

  -- Structured internal dependencies are satisfied only by an accepted task
  -- in the same project. The prerequisite must run first.
  v_created := public.create_task(
    v_project,v_worker,'implementation','Dependency test: internal prerequisite',
    'Internal prerequisite fixture','{}'::jsonb,-80,false,null,null,
    'dependency-internal-prerequisite-create-'||gen_random_uuid()::text
  );
  v_prerequisite_id := (v_created->'data'->>'id')::uuid;

  v_created := public.create_task(
    v_project,v_worker,'implementation','Dependency test: internal dependent',
    'Cannot run until the prerequisite is accepted',
    jsonb_build_object('dependencies',jsonb_build_array(jsonb_build_object(
      'type','task','task_id',v_prerequisite_id,'required_status','accepted'
    ))),
    -90,false,null,null,'dependency-internal-dependent-create-'||gen_random_uuid()::text
  );
  v_dependent_id := (v_created->'data'->>'id')::uuid;

  v_claim := public.claim_task(v_project,v_worker,120,'dependency-internal-prerequisite-claim-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_prerequisite_id::text THEN
    RAISE EXCEPTION 'FAIL: internal dependent was claimed before its prerequisite: %',v_claim;
  END IF;
  PERFORM public.complete_execution(
    v_prerequisite_id,(v_claim->'data'->>'execution_id')::uuid,v_worker,
    '{"summary":"internal prerequisite accepted"}'::jsonb,
    'dependency-internal-prerequisite-complete-'||gen_random_uuid()::text
  );
  v_claim := public.claim_task(v_project,v_worker,120,'dependency-internal-dependent-claim-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_dependent_id::text THEN
    RAISE EXCEPTION 'FAIL: accepted internal prerequisite did not unlock dependent: %',v_claim;
  END IF;
  PERFORM public.complete_execution(
    v_dependent_id,(v_claim->'data'->>'execution_id')::uuid,v_worker,
    '{"summary":"dependent completed after prerequisite acceptance"}'::jsonb,
    'dependency-internal-dependent-complete-'||gen_random_uuid()::text
  );

  -- An expired task with unresolved dependencies is not swept to failed,
  -- even when its lease expired. Independent work remains claimable.
  v_key := 'external:maintenance-window-closed';
  v_created := public.create_task(
    v_project,v_worker,'implementation','Dependency test: expired task blocked by dependency',
    'An unresolved dependency must not terminally expire this lease',
    jsonb_build_object('depends_on',jsonb_build_array(v_key),'retry',jsonb_build_object('max_attempts',2)),
    -100,false,null,null,'dependency-expired-create-'||gen_random_uuid()::text
  );
  v_expired_id := (v_created->'data'->>'id')::uuid;
  v_claim := public.claim_task(v_project,v_worker,120,'dependency-expired-initial-claim-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_expired_id::text THEN
    RAISE EXCEPTION 'FAIL: expired-dependency fixture was not initially claimed: %',v_claim;
  END IF;
  v_old_execution_id := (v_claim->'data'->>'execution_id')::uuid;
  UPDATE public.tasks SET lease_until=clock_timestamp()-interval '1 second'
  WHERE id=v_expired_id AND current_execution_id=v_old_execution_id;

  v_created := public.create_task(
    v_project,v_worker,'implementation','Dependency test: work independent of expired blocker',
    'Independent task must remain eligible','{}'::jsonb,-90,false,null,null,
    'dependency-expired-independent-create-'||gen_random_uuid()::text
  );
  v_expired_independent_id := (v_created->'data'->>'id')::uuid;
  v_claim := public.claim_task(v_project,v_worker,120,'dependency-expired-independent-claim-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_expired_independent_id::text THEN
    RAISE EXCEPTION 'FAIL: expired dependency blocker prevented independent claim: %',v_claim;
  END IF;
  SELECT status INTO v_status FROM public.tasks WHERE id=v_expired_id;
  SELECT status INTO v_exec_status FROM public.executions WHERE id=v_old_execution_id;
  IF v_status <> 'running' OR v_exec_status <> 'running' THEN
    RAISE EXCEPTION 'FAIL: dependency-blocked expired task/execution was swept: task %, execution %',v_status,v_exec_status;
  END IF;
  PERFORM public.complete_execution(
    v_expired_independent_id,(v_claim->'data'->>'execution_id')::uuid,v_worker,
    '{"summary":"independent task completed during dependency blockage"}'::jsonb,
    'dependency-expired-independent-complete-'||gen_random_uuid()::text
  );

  PERFORM public.resolve_task_dependency(
    v_expired_id,v_key,'satisfied',
    jsonb_build_object('ref','https://status.example.test/maintenance','observed_state','closed'),
    'dependency-expired-resolve-'||gen_random_uuid()::text
  );
  v_claim := public.claim_task(v_project,v_worker,120,'dependency-expired-reclaim-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_expired_id::text
    OR (v_claim->'data'->>'attempt')::integer <> 2 THEN
    RAISE EXCEPTION 'FAIL: resolved expired task did not reclaim as attempt 2: %',v_claim;
  END IF;
  v_execution_id := (v_claim->'data'->>'execution_id')::uuid;
  SELECT status INTO v_exec_status FROM public.executions WHERE id=v_old_execution_id;
  IF v_exec_status <> 'expired' THEN
    RAISE EXCEPTION 'FAIL: prior expired execution was not fenced; status %',v_exec_status;
  END IF;
  PERFORM public.complete_execution(
    v_expired_id,v_execution_id,v_worker,
    '{"summary":"expired task reclaimed after dependency resolution"}'::jsonb,
    'dependency-expired-complete-'||gen_random_uuid()::text
  );

  -- At retry cap, an expired task with unresolved dependency remains running
  -- (with no live lease) rather than being terminally expired as a side effect.
  v_key := 'external:release-approval-captured';
  v_created := public.create_task(
    v_project,v_worker,'implementation','Dependency test: retry cap while blocked',
    'Do not terminally fail until the dependency is satisfied',
    jsonb_build_object('depends_on',jsonb_build_array(v_key),'retry',jsonb_build_object('max_attempts',1)),
    -100,false,null,null,'dependency-cap-create-'||gen_random_uuid()::text
  );
  v_cap_id := (v_created->'data'->>'id')::uuid;
  v_claim := public.claim_task(v_project,v_worker,120,'dependency-cap-initial-claim-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS DISTINCT FROM v_cap_id::text
    OR (v_claim->'data'->>'attempt')::integer <> 1 THEN
    RAISE EXCEPTION 'FAIL: retry-cap dependency fixture was not claimed as attempt 1: %',v_claim;
  END IF;
  v_execution_id := (v_claim->'data'->>'execution_id')::uuid;
  UPDATE public.tasks SET lease_until=clock_timestamp()-interval '1 second'
  WHERE id=v_cap_id AND current_execution_id=v_execution_id;

  v_claim := public.claim_task(v_project,v_worker,120,'dependency-cap-blocked-claim-'||gen_random_uuid()::text);
  IF v_claim->'data'->>'task_id' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: claim unexpectedly leased a dependency-blocked retry-cap task: %',v_claim;
  END IF;
  SELECT status INTO v_status FROM public.tasks WHERE id=v_cap_id;
  SELECT status INTO v_exec_status FROM public.executions WHERE id=v_execution_id;
  IF v_status <> 'running' OR v_exec_status <> 'running' THEN
    RAISE EXCEPTION 'FAIL: unresolved dependency caused retry-cap task to terminally fail: task %, execution %',v_status,v_exec_status;
  END IF;

  PERFORM public.resolve_task_dependency(
    v_cap_id,v_key,'satisfied',
    jsonb_build_object('ref','https://github.com/Love-DC/recursive-ai-engineering/issues/12','observed_state','captured'),
    'dependency-cap-resolve-'||gen_random_uuid()::text
  );
  v_claim := public.claim_task(v_project,v_worker,120,'dependency-cap-finalize-claim-'||gen_random_uuid()::text);
  SELECT status INTO v_status FROM public.tasks WHERE id=v_cap_id;
  SELECT status INTO v_exec_status FROM public.executions WHERE id=v_execution_id;
  SELECT count(*) INTO v_exec_count FROM public.executions WHERE task_id=v_cap_id;
  IF v_status <> 'failed' OR v_exec_status <> 'expired' OR v_exec_count <> 1
    OR v_claim->'data'->>'task_id' = v_cap_id::text THEN
    RAISE EXCEPTION 'FAIL: satisfied dependency at retry cap did not terminally expire without attempt 2: task %, execution %, attempts %, claim %',
      v_status,v_exec_status,v_exec_count,v_claim;
  END IF;

  RAISE NOTICE 'PASS: legacy external dependency evidence/idempotency, blocker event dedupe and claim reporting, independent eligible work, structured same-project task dependency, expired lease dependency gating, retry-cap dependency gating, and no extra attempts';
END;
$dependency_test$;
ROLLBACK;
