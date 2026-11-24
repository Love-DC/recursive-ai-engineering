-- End-to-end transactional acceptance for the AI initiative lifecycle.
-- All fixture rows, RPC idempotency records, and task executions are rolled back.
BEGIN;
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT id::text FROM auth.users WHERE deleted_at IS NULL ORDER BY created_at LIMIT 1),
  true
);
SELECT set_config(
  'request.jwt.claims',
  jsonb_build_object('sub',current_setting('request.jwt.claim.sub'),'role','authenticated')::text,
  true
);

DO $initiative_test$
DECLARE
  v_key text := 'initiative-test-'||gen_random_uuid()::text;
  v_project jsonb;
  v_owner_worker jsonb;
  v_reviewer_worker jsonb;
  v_project_id uuid;
  v_worker_id uuid;
  v_reviewer_id uuid;
  v_proposal jsonb;
  v_duplicate jsonb;
  v_initiative_id uuid;
  v_support jsonb;
  v_support_duplicate jsonb;
  v_support_id uuid;
  v_support_decision jsonb;
  v_plan jsonb;
  v_decision jsonb;
  v_advance jsonb;
  v_claim jsonb;
  v_task_a uuid;
  v_exec_a uuid;
  v_task_b uuid;
  v_exec_b uuid;
  v_review_task jsonb;
  v_review_id uuid;
  v_review_claim jsonb;
  v_review_exec uuid;
  v_submit jsonb;
  v_review_result jsonb;
  v_task_c uuid;
  v_exec_c uuid;
  v_task_d uuid;
  v_exec_d uuid;
  v_learning jsonb;
  v_known jsonb;
  v_rejected jsonb;
  v_rejected_id uuid;
  v_abandon_proposal jsonb;
  v_abandon_id uuid;
  v_abandon_decision jsonb;
  v_abandon_advance jsonb;
  v_abandoned jsonb;
  v_abandoned_task uuid;
  v_state jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'FAIL: authenticated Owner context is required'; END IF;

  v_project:=public.register_project(
    'AI initiative lifecycle test','transactional fixture',NULL,'{}'::jsonb,v_key||'-project'
  );
  v_project_id:=(v_project->'data'->>'id')::uuid;
  v_owner_worker:=public.register_worker(v_project_id,'initiative-test-executor','Initiative Test Executor','test');
  v_reviewer_worker:=public.register_worker(v_project_id,'initiative-test-reviewer','Initiative Test Reviewer','test');
  v_worker_id:=(v_owner_worker->'data'->>'id')::uuid;
  v_reviewer_id:=(v_reviewer_worker->'data'->>'id')::uuid;

  -- Proposal creation and project-scoped fingerprint deduplication.
  v_proposal:=public.propose_initiative(v_project_id,v_worker_id,jsonb_build_object(
    'origin','ai_initiative',
    'title','Exercise durable initiative lifecycle',
    'summary','Verify proposal, support, DAG, task waves, review, and learning.',
    'rationale','The lifecycle must survive temporary GPT sessions and prevent duplicate work.',
    'desired_outcome','A durable initiative can be approved, executed in dependency order, reviewed, and learned from.',
    'scope',jsonb_build_array('transactional test project'),
    'evidence',jsonb_build_array(jsonb_build_object('kind','test_fixture','ref','tests/ai-initiative-lifecycle.sql','observation','Acceptance fixture')),
    'risk','low','priority',5,
    'resource_budget',jsonb_build_object('external_spend_allowed',false,'bounded_execution',true),
    'support_needed',jsonb_build_array(),
    'deduplication_fingerprint','test:initiative:lifecycle'
  ),v_key||'-proposal');
  v_initiative_id:=(v_proposal->'data'->>'initiative_id')::uuid;
  IF v_proposal->'data'->>'created'<>'true' THEN RAISE EXCEPTION 'FAIL: initial proposal was not created'; END IF;
  IF (SELECT priority FROM public.initiatives WHERE id=v_initiative_id)<>5 THEN
    RAISE EXCEPTION 'FAIL: initiative priority was not persisted';
  END IF;

  v_duplicate:=public.propose_initiative(v_project_id,v_worker_id,jsonb_build_object(
    'origin','ai_initiative',
    'title','Duplicate lifecycle proposal',
    'summary','A second proposal for the same root cause.',
    'rationale','It must be suppressed.',
    'desired_outcome','Reuse the existing initiative.',
    'scope',jsonb_build_array('transactional test project'),
    'evidence',jsonb_build_array(jsonb_build_object('kind','test_fixture','ref','tests/ai-initiative-lifecycle.sql','observation','Same root cause')),
    'risk','low','priority',50,
    'resource_budget',jsonb_build_object('external_spend_allowed',false),
    'support_needed',jsonb_build_array(),
    'deduplication_fingerprint','test:initiative:lifecycle'
  ),v_key||'-proposal-duplicate');
  IF v_duplicate->'data'->>'duplicate'<>'true'
     OR (v_duplicate->'data'->>'initiative_id')::uuid<>v_initiative_id THEN
    RAISE EXCEPTION 'FAIL: duplicate fingerprint did not return the existing initiative';
  END IF;

  -- Durable support request, duplicate suppression, and Owner decision.
  v_support:=public.request_initiative_support(v_initiative_id,v_worker_id,jsonb_build_object(
    'request_kind','permission',
    'capability','Read-only access to a test integration',
    'rationale','The test initiative requires a connected read-only capability.',
    'alternatives_checked',jsonb_build_array('Existing project metadata','Current repository files'),
    'unlocks','The missing integration can be verified.',
    'requested_resources',jsonb_build_object('access','read-only')
  ),v_key||'-support');
  v_support_id:=(v_support->'data'->>'support_request_id')::uuid;
  v_support_duplicate:=public.request_initiative_support(v_initiative_id,v_worker_id,jsonb_build_object(
    'request_kind','permission',
    'capability','Read-only access to a test integration',
    'rationale','The test initiative requires a connected read-only capability.',
    'alternatives_checked',jsonb_build_array('Existing project metadata','Current repository files'),
    'unlocks','The missing integration can be verified.',
    'requested_resources',jsonb_build_object('access','read-only')
  ),v_key||'-support-duplicate');
  IF v_support_duplicate->'data'->>'duplicate'<>'true'
     OR (v_support_duplicate->'data'->>'support_request_id')::uuid<>v_support_id THEN
    RAISE EXCEPTION 'FAIL: pending support request was not deduplicated';
  END IF;
  -- A/B are independent; C depends on both; D depends on C.
  v_plan:=jsonb_build_array(
    jsonb_build_object('work_key','a','title','Inspect initiative path','description','Inspect the first independent workstream.','priority',10,'requires_review',true,'depends_on',jsonb_build_array()),
    jsonb_build_object('work_key','b','title','Build initiative fixture','description','Complete the second independent workstream.','priority',20,'requires_review',false,'depends_on',jsonb_build_array()),
    jsonb_build_object('work_key','c','title','Integrate initiative work','description','Integrate only after both independent workstreams are accepted.','priority',30,'requires_review',false,'depends_on',jsonb_build_array('a','b')),
    jsonb_build_object('work_key','d','title','Verify initiative outcome','description','Verify after integration is accepted.','priority',40,'requires_review',false,'depends_on',jsonb_build_array('c'))
  );
  v_decision:=public.decide_initiative(v_initiative_id,'approve','Approved bounded test plan.',v_plan,v_key||'-approve');
  IF v_decision->'data'->>'status'<>'approved'
     OR (v_decision->'data'->>'work_item_count')::integer<>4 THEN
    RAISE EXCEPTION 'FAIL: initiative approval did not persist the work plan';
  END IF;

  -- A pending human-support request must block all task materialization.
  v_advance:=public.advance_initiative(v_initiative_id,v_worker_id,v_key||'-advance-blocked-support');
  IF v_advance->'data'->>'blocked_by_support'<>'true'
     OR (v_advance->'data'->>'materialized_count')::integer<>0 THEN
    RAISE EXCEPTION 'FAIL: unresolved support request did not block task materialization';
  END IF;
  v_support_decision:=public.decide_initiative_support(
    v_support_id,'grant','Read-only access granted for this bounded test.',
    jsonb_build_object('access','read-only'),v_key||'-support-decision'
  );
  IF v_support_decision->'data'->>'status'<>'granted' THEN
    RAISE EXCEPTION 'FAIL: support grant was not recorded';
  END IF;

  -- Cyclic plans must be rejected without changing the proposal.
  v_rejected:=public.propose_initiative(v_project_id,v_worker_id,jsonb_build_object(
    'origin','ai_initiative','title','Reject cyclic work plan','summary','A cycle fixture.',
    'rationale','Test DAG validation.','desired_outcome','Reject cyclic dependencies.',
    'scope',jsonb_build_array('test'),'evidence',jsonb_build_array(jsonb_build_object('kind','test','ref','fixture','observation','cycle')),
    'risk','low','resource_budget','{}'::jsonb,'support_needed','[]'::jsonb,
    'deduplication_fingerprint','test:initiative:cycle'
  ),v_key||'-cycle-proposal');
  v_rejected_id:=(v_rejected->'data'->>'initiative_id')::uuid;
  BEGIN
    PERFORM public.decide_initiative(v_rejected_id,'approve','Must reject cycle.',
      jsonb_build_array(
        jsonb_build_object('work_key','x','title','Cycle item X','description','Depends on Y.','depends_on',jsonb_build_array('y')),
        jsonb_build_object('work_key','y','title','Cycle item Y','description','Depends on X.','depends_on',jsonb_build_array('x'))
      ),v_key||'-cycle-decision');
    RAISE EXCEPTION 'FAIL: cyclic work plan unexpectedly approved';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM<>'WORK_PLAN_DEPENDENCY_CYCLE' THEN RAISE; END IF;
  END;
  v_state:=public.get_initiative(v_rejected_id);
  IF v_state->'data'->'initiative'->>'status'<>'proposed' THEN
    RAISE EXCEPTION 'FAIL: rejected cycle changed initiative state';
  END IF;

  -- Only the initial independent wave becomes claimable.
  v_advance:=public.advance_initiative(v_initiative_id,v_worker_id,v_key||'-advance-1');
  IF (v_advance->'data'->>'materialized_count')::integer<>2 THEN
    RAISE EXCEPTION 'FAIL: initial wave should contain exactly two independent tasks: %',v_advance;
  END IF;
  SELECT task_id INTO v_task_a FROM public.initiative_work_items
    WHERE initiative_id=v_initiative_id AND work_key='a';
  SELECT task_id INTO v_task_b FROM public.initiative_work_items
    WHERE initiative_id=v_initiative_id AND work_key='b';

  -- A requires review; B can complete while A awaits independent review.
  v_claim:=public.claim_task(v_project_id,v_worker_id,300,v_key||'-claim-a');
  IF (v_claim->'data'->>'task_id')::uuid<>v_task_a THEN
    RAISE EXCEPTION 'FAIL: priority order did not claim work item A: %',v_claim;
  END IF;
  v_exec_a:=(v_claim->'data'->>'execution_id')::uuid;
  v_submit:=public.submit_result(v_task_a,v_exec_a,v_worker_id,
    jsonb_build_object('summary','A delivered for independent review'),v_key||'-submit-a');
  IF v_submit->'data'->>'status'<>'submitted' THEN RAISE EXCEPTION 'FAIL: A was not submitted'; END IF;
  v_review_task:=public.create_review_task(v_task_a,v_task_a,v_exec_a,v_reviewer_id,v_key||'-create-review-a');
  v_review_id:=(v_review_task->'data'->>'id')::uuid;

  v_claim:=public.claim_task(v_project_id,v_worker_id,300,v_key||'-claim-b');
  IF (v_claim->'data'->>'task_id')::uuid<>v_task_b THEN
    RAISE EXCEPTION 'FAIL: worker did not claim independent work item B: %',v_claim;
  END IF;
  v_exec_b:=(v_claim->'data'->>'execution_id')::uuid;
  PERFORM public.complete_execution(v_task_b,v_exec_b,v_worker_id,
    jsonb_build_object('summary','B accepted'),v_key||'-complete-b');

  v_advance:=public.advance_initiative(v_initiative_id,v_worker_id,v_key||'-advance-blocked');
  IF (v_advance->'data'->>'materialized_count')::integer<>0 THEN
    RAISE EXCEPTION 'FAIL: dependent work C was released before A review acceptance';
  END IF;

  v_review_claim:=public.claim_task(v_project_id,v_reviewer_id,300,v_key||'-claim-review-a');
  IF (v_review_claim->'data'->>'task_id')::uuid<>v_review_id THEN
    RAISE EXCEPTION 'FAIL: independent reviewer did not receive A review task: %',v_review_claim;
  END IF;
  v_review_exec:=(v_review_claim->'data'->>'execution_id')::uuid;
  v_review_result:=public.review_result(v_review_id,v_review_exec,v_reviewer_id,'accepted',
    jsonb_build_object('summary','Independent review accepted A'),v_key||'-accept-review-a');
  IF v_review_result->'data'->>'decision'<>'accepted' THEN
    RAISE EXCEPTION 'FAIL: independent review did not accept A';
  END IF;

  v_advance:=public.advance_initiative(v_initiative_id,v_worker_id,v_key||'-advance-2');
  IF (v_advance->'data'->>'materialized_count')::integer<>1 THEN
    RAISE EXCEPTION 'FAIL: C should be released after both A and B are accepted: %',v_advance;
  END IF;
  SELECT task_id INTO v_task_c FROM public.initiative_work_items
    WHERE initiative_id=v_initiative_id AND work_key='c';
  v_claim:=public.claim_task(v_project_id,v_worker_id,300,v_key||'-claim-c');
  IF (v_claim->'data'->>'task_id')::uuid<>v_task_c THEN RAISE EXCEPTION 'FAIL: C claim'; END IF;
  v_exec_c:=(v_claim->'data'->>'execution_id')::uuid;
  PERFORM public.complete_execution(v_task_c,v_exec_c,v_worker_id,
    jsonb_build_object('summary','C accepted'),v_key||'-complete-c');

  v_advance:=public.advance_initiative(v_initiative_id,v_worker_id,v_key||'-advance-3');
  IF (v_advance->'data'->>'materialized_count')::integer<>1 THEN
    RAISE EXCEPTION 'FAIL: D should be released after C is accepted: %',v_advance;
  END IF;
  SELECT task_id INTO v_task_d FROM public.initiative_work_items
    WHERE initiative_id=v_initiative_id AND work_key='d';
  v_claim:=public.claim_task(v_project_id,v_worker_id,300,v_key||'-claim-d');
  IF (v_claim->'data'->>'task_id')::uuid<>v_task_d THEN RAISE EXCEPTION 'FAIL: D claim'; END IF;
  v_exec_d:=(v_claim->'data'->>'execution_id')::uuid;
  PERFORM public.complete_execution(v_task_d,v_exec_d,v_worker_id,
    jsonb_build_object('summary','D accepted'),v_key||'-complete-d');

  v_advance:=public.advance_initiative(v_initiative_id,v_worker_id,v_key||'-advance-final');
  IF v_advance->'data'->>'status'<>'ready_to_close'
     OR (v_advance->'data'->>'remaining_work_items')::integer<>0 THEN
    RAISE EXCEPTION 'FAIL: initiative did not reach ready_to_close after all work items were accepted: %',v_advance;
  END IF;

  v_learning:=public.record_initiative_learning(
    v_initiative_id,'test:initiative:lifecycle','success',
    'The ready-wave protocol prevents dependent work from entering the claimable queue before every prerequisite is accepted.',
    jsonb_build_array(jsonb_build_object('kind','test','ref','tests/ai-initiative-lifecycle.sql','observation','All DAG wave assertions passed')),
    v_key||'-learning'
  );
  IF (SELECT status FROM public.initiatives WHERE id=v_initiative_id)<>'completed' THEN
    RAISE EXCEPTION 'FAIL: initiative was not completed after its learning record was persisted';
  END IF;
  v_known:=public.propose_initiative(v_project_id,v_worker_id,jsonb_build_object(
    'origin','ai_initiative','title','Repeat learned initiative','summary','Same completed root cause.',
    'rationale','The learning record should suppress this proposal.','desired_outcome','Reuse the lesson.',
    'scope',jsonb_build_array('test'),'evidence',jsonb_build_array(jsonb_build_object('kind','test','ref','fixture','observation','same fingerprint')),
    'risk','low','resource_budget','{}'::jsonb,'support_needed','[]'::jsonb,
    'deduplication_fingerprint','test:initiative:lifecycle'
  ),v_key||'-known-learning');
  IF v_known->'data'->>'known_learning'<>'true'
     OR v_known->'data'->>'learning_id'<>v_learning->'data'->>'learning_id' THEN
    RAISE EXCEPTION 'FAIL: prior learning did not suppress duplicate initiative';
  END IF;

  -- Abandonment cancels pending tasks and refuses to leave them claimable.
  v_abandon_proposal:=public.propose_initiative(v_project_id,v_worker_id,jsonb_build_object(
    'origin','maintenance','title','Abandon pending initiative','summary','Test safe cancellation of pending initiative work.',
    'rationale','A bounded negative lifecycle test.','desired_outcome','Pending tasks are cancelled.',
    'scope',jsonb_build_array('test'),'evidence',jsonb_build_array(jsonb_build_object('kind','test','ref','fixture','observation','abandon test')),
    'risk','low','resource_budget','{}'::jsonb,'support_needed','[]'::jsonb,
    'deduplication_fingerprint','test:initiative:abandon'
  ),v_key||'-abandon-proposal');
  v_abandon_id:=(v_abandon_proposal->'data'->>'initiative_id')::uuid;
  v_abandon_decision:=public.decide_initiative(v_abandon_id,'approve','Approve cancellation fixture.',
    jsonb_build_array(jsonb_build_object('work_key','pending','title','Pending task fixture','description','Will be cancelled.','requires_review',false,'depends_on',jsonb_build_array())),
    v_key||'-abandon-approve');
  v_abandon_advance:=public.advance_initiative(v_abandon_id,v_worker_id,v_key||'-abandon-advance');
  SELECT task_id INTO v_abandoned_task FROM public.initiative_work_items
    WHERE initiative_id=v_abandon_id AND work_key='pending';
  v_abandoned:=public.abandon_initiative(v_abandon_id,'Test owner-directed stop.',v_key||'-abandon');
  IF v_abandoned->'data'->>'status'<>'abandoned'
     OR (SELECT status FROM public.tasks WHERE id=v_abandoned_task)<>'cancelled' THEN
    RAISE EXCEPTION 'FAIL: abandon did not cancel pending work';
  END IF;

  v_state:=public.get_initiative(v_initiative_id);
  IF jsonb_array_length(v_state->'data'->'events')<6
     OR jsonb_array_length(v_state->'data'->'work_items')<>4
     OR jsonb_array_length(v_state->'data'->'support_requests')<>1
     OR jsonb_array_length(v_state->'data'->'learnings')<>1 THEN
    RAISE EXCEPTION 'FAIL: initiative audit/read model is incomplete';
  END IF;

  RAISE NOTICE 'PASS: proposal, fingerprint dedup, support request/grant, DAG validation, staged parallel task materialization, independent review gate, dependency wave release, completion, learning suppression, abandonment cancellation, and durable read model';
END
$initiative_test$;
ROLLBACK;
