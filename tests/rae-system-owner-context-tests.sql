-- RAE system principal integration tests.
-- Run after tests/owner-mcp-context-tests.sql in the isolated PostgreSQL 17
-- fixture. Proves project-scoped engineering authority without an Auth user,
-- while preserving human-only product decisions and legacy Owner compatibility.
\set ON_ERROR_STOP on

DO $principal$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM private.system_principals
    WHERE principal_key='rae-core' AND status='active'
  ) THEN
    RAISE EXCEPTION 'FAIL: active RAE system principal is missing';
  END IF;

  IF has_schema_privilege('authenticated','private','USAGE')
    OR has_function_privilege(
      'authenticated','private.begin_rae_system_context(uuid)','EXECUTE'
    )
    OR has_function_privilege(
      'anon','private.begin_rae_system_context(uuid)','EXECUTE'
    ) THEN
    RAISE EXCEPTION 'FAIL: RAE system context is exposed to API roles';
  END IF;
END
$principal$;

-- The system principal can run the normal engineering task lifecycle, but
-- remains bound to one project and cannot make a human product decision.
BEGIN;
DO $system_lifecycle$
DECLARE
  v_context jsonb;
  v_task jsonb;
  v_claim jsonb;
  v_done jsonb;
  v_task_id uuid;
  v_execution_id uuid;
  v_audit_count integer;
  v_human_rejected boolean:=false;
  v_cross_project_rejected boolean:=false;
  v_kill_switch_rejected boolean:=false;
BEGIN
  v_context:=private.begin_rae_system_context(
    '00000000-0000-4000-8000-000000000008'::uuid
  );

  IF v_context->'data'->>'principal_key' IS DISTINCT FROM 'rae-core'
    OR v_context->'data'->>'authority' IS DISTINCT FROM 'project_scoped_engineering'
    OR NOT private.rae_system_context_matches(
      '00000000-0000-4000-8000-000000000008'::uuid
    ) THEN
    RAISE EXCEPTION 'FAIL: RAE system context was not established: %',v_context;
  END IF;

  IF private.rae_system_context_matches(
    '00000000-0000-4000-8000-000000000011'::uuid
  ) THEN
    RAISE EXCEPTION 'FAIL: RAE system context crossed into another project';
  END IF;

  PERFORM private.assert_owner(
    '00000000-0000-4000-8000-000000000008'::uuid
  );
  PERFORM private.assert_worker_actor(
    '00000000-0000-4000-8000-000000000008'::uuid,
    '00000000-0000-4000-8000-000000000009'::uuid
  );

  BEGIN
    PERFORM private.assert_owner(
      '00000000-0000-4000-8000-000000000011'::uuid
    );
  EXCEPTION WHEN SQLSTATE '28000' THEN
    v_cross_project_rejected:=true;
  END;
  IF NOT v_cross_project_rejected THEN
    RAISE EXCEPTION 'FAIL: RAE system context authorized a different project';
  END IF;

  BEGIN
    PERFORM private.assert_human_owner(
      '00000000-0000-4000-8000-000000000008'::uuid
    );
  EXCEPTION WHEN SQLSTATE '28000' THEN
    IF SQLERRM <> 'HUMAN_OWNER_DECISION_REQUIRED' THEN
      RAISE;
    END IF;
    v_human_rejected:=true;
  END;
  IF NOT v_human_rejected THEN
    RAISE EXCEPTION 'FAIL: RAE system principal was accepted as a human decision-maker';
  END IF;

  BEGIN
    PERFORM private.set_project_execution_controls(
      '00000000-0000-4000-8000-000000000008'::uuid,
      false,
      2
    );
  EXCEPTION WHEN SQLSTATE '28000' THEN
    IF SQLERRM <> 'HUMAN_OWNER_DECISION_REQUIRED' THEN
      RAISE;
    END IF;
    v_kill_switch_rejected:=true;
  END;
  IF NOT v_kill_switch_rejected THEN
    RAISE EXCEPTION 'FAIL: RAE system principal changed the human-reserved pause control';
  END IF;

  v_task:=public.create_task(
    '00000000-0000-4000-8000-000000000008'::uuid,
    '00000000-0000-4000-8000-000000000009'::uuid,
    'implementation',
    'RAE System Owner lifecycle acceptance',
    'Verify that RAE system principal can create, claim, and complete bounded engineering work.',
    jsonb_build_object(
      'target',jsonb_build_object(
        'repository','test/trusted-owner-mcp',
        'base_branch','main',
        'base_sha',repeat('b',40),
        'branch','test/rae-system-owner'
      ),
      'decision_gate','engineering_only',
      'owner_authorization','rae_system_principal_integration_test'
    ),
    1,
    false,
    NULL,
    NULL,
    'rae-system-owner-create-task'
  );
  v_task_id:=(v_task->'data'->>'id')::uuid;

  v_claim:=public.claim_task(
    '00000000-0000-4000-8000-000000000008'::uuid,
    '00000000-0000-4000-8000-000000000009'::uuid,
    300,
    'rae-system-owner-claim-task'
  );
  v_execution_id:=(v_claim->'data'->>'execution_id')::uuid;
  IF (v_claim->'data'->>'task_id')::uuid IS DISTINCT FROM v_task_id THEN
    RAISE EXCEPTION 'FAIL: RAE system Owner did not claim its created task: %',v_claim;
  END IF;

  v_done:=public.complete_execution(
    v_task_id,
    v_execution_id,
    '00000000-0000-4000-8000-000000000009'::uuid,
    '{"summary":"RAE system principal lifecycle accepted"}'::jsonb,
    'rae-system-owner-complete-task'
  );
  IF v_done->'data'->>'status' IS DISTINCT FROM 'accepted' THEN
    RAISE EXCEPTION 'FAIL: RAE system principal could not complete engineering task: %',v_done;
  END IF;

  SELECT count(*) INTO v_audit_count
  FROM private.system_actor_audit
  WHERE transaction_id=txid_current()
    AND project_id='00000000-0000-4000-8000-000000000008'::uuid
    AND principal_id=(
      SELECT id FROM private.system_principals WHERE principal_key='rae-core'
    );
  IF v_audit_count<>1 THEN
    RAISE EXCEPTION 'FAIL: expected one RAE system audit row, found %',v_audit_count;
  END IF;

  RAISE NOTICE 'PASS: RAE system-scoped engineering lifecycle, project isolation, human decision boundary, and audit';
END
$system_lifecycle$;
COMMIT;

DO $context_cleared$
BEGIN
  IF private.rae_system_context_matches(
    '00000000-0000-4000-8000-000000000008'::uuid
  ) THEN
    RAISE EXCEPTION 'FAIL: RAE system context leaked after COMMIT';
  END IF;
END
$context_cleared$;

-- Project bootstrap inherits the real human product-owner reference from the
-- anchor project and cannot accept a caller-supplied owner identity.
BEGIN;
DO $system_register_project$
DECLARE
  v_owner_id uuid;
  v_registered jsonb;
  v_replay jsonb;
  v_project_id uuid;
BEGIN
  PERFORM private.begin_rae_system_context(
    '00000000-0000-4000-8000-000000000008'::uuid
  );

  SELECT owner_id INTO v_owner_id
  FROM public.projects
  WHERE id='00000000-0000-4000-8000-000000000008'::uuid;

  v_registered:=public.register_project(
    'rae-system-registered-test',
    'isolated RAE system principal project-registration fixture',
    'test/rae-system-registered',
    jsonb_build_object(
      'project_key','rae-system-registered',
      'autonomy',jsonb_build_object('paused',true,'max_active_executions',2),
      'worker_routing',jsonb_build_object('default_worker_key','rae-system-worker')
    ),
    'rae-system-register-project'
  );

  IF coalesce((v_registered->>'success')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL: RAE system project registration failed: %',v_registered;
  END IF;

  v_project_id:=(v_registered->'data'->>'id')::uuid;
  IF (v_registered->'data'->>'owner_id')::uuid IS DISTINCT FROM v_owner_id THEN
    RAISE EXCEPTION 'FAIL: system registration did not preserve human product ownership';
  END IF;

  v_replay:=public.register_project(
    'rae-system-registered-test',
    'isolated RAE system principal project-registration fixture',
    'test/rae-system-registered',
    jsonb_build_object(
      'project_key','rae-system-registered',
      'autonomy',jsonb_build_object('paused',true,'max_active_executions',2),
      'worker_routing',jsonb_build_object('default_worker_key','rae-system-worker')
    ),
    'rae-system-register-project'
  );
  IF (v_replay->'data'->>'id')::uuid IS DISTINCT FROM v_project_id THEN
    RAISE EXCEPTION 'FAIL: RAE system project registration replay changed the project ID';
  END IF;

  RAISE NOTICE 'PASS: RAE system project registration preserves the human product-owner reference';
END
$system_register_project$;
COMMIT;

-- A separate transaction binds the newly registered project. The system can
-- manage that project's engineering routes without sharing the anchor context.
BEGIN;
DO $system_register_worker$
DECLARE
  v_project_id uuid;
  v_worker jsonb;
BEGIN
  SELECT id INTO v_project_id
  FROM public.projects
  WHERE github_repo='test/rae-system-registered';

  PERFORM private.begin_rae_system_context(v_project_id);
  v_worker:=public.register_worker(
    v_project_id,
    'rae-system-worker',
    'RAE System Test Worker',
    'Project-scoped Worker registered by the RAE system principal'
  );

  IF v_worker->'data'->>'worker_key' IS DISTINCT FROM 'rae-system-worker' THEN
    RAISE EXCEPTION 'FAIL: RAE system Worker registration failed: %',v_worker;
  END IF;
  RAISE NOTICE 'PASS: RAE system principal registers project-scoped Workers';
END
$system_register_worker$;
COMMIT;

-- The RAE system can inspect/update the Problem Inbox in its bound project,
-- list same-owner reports, and cannot read or update a different bound project.
BEGIN;
DO $system_problem_inbox$
DECLARE
  v_report jsonb;
  v_list jsonb;
  v_detail jsonb;
  v_update jsonb;
  v_secondary_report_id uuid;
  v_cross_get_rejected boolean:=false;
  v_cross_update_rejected boolean:=false;
BEGIN
  PERFORM private.begin_rae_system_context(
    '00000000-0000-4000-8000-000000000008'::uuid
  );

  v_report:=public.report_problem(
    '00000000-0000-4000-8000-000000000008'::uuid,
    '00000000-0000-4000-8000-000000000009'::uuid,
    jsonb_build_object(
      'category','defect',
      'severity','medium',
      'status','open',
      'title','RAE system Problem Inbox fixture',
      'summary','Verify that the RAE system principal can use the project-scoped Problem Inbox RPCs.',
      'impact','The coordinator must preserve material findings across sessions.',
      'recommended_action','Use the project-bound system context.',
      'evidence',jsonb_build_array(jsonb_build_object(
        'kind','test','ref','tests/rae-system-owner-context-tests.sql',
        'observation','The report is created through report_problem under RAE system context.'
      )),
      'source','automated',
      'source_ref','tests/rae-system-owner-context-tests.sql',
      'fingerprint','test:rae-system-owner:problem-inbox'
    ),
    'rae-system-owner-problem-report'
  );
  IF coalesce((v_report->>'success')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL: RAE system Problem Inbox report failed: %',v_report;
  END IF;

  v_list:=public.list_problem_reports('unresolved',NULL,200);
  IF NOT EXISTS(
    SELECT 1 FROM jsonb_array_elements(v_list->'data') AS x(item)
    WHERE x.item->>'id'=v_report->'data'->>'report_id'
  ) THEN
    RAISE EXCEPTION 'FAIL: RAE system Problem Inbox list omitted its bound project report';
  END IF;

  SELECT id INTO v_secondary_report_id
  FROM public.problem_reports
  WHERE project_id='00000000-0000-4000-8000-000000000011'::uuid
    AND fingerprint='test:owner-mcp-problem-inbox:secondary-project';
  IF v_secondary_report_id IS NOT NULL AND NOT EXISTS(
    SELECT 1 FROM jsonb_array_elements(v_list->'data') AS x(item)
    WHERE x.item->>'id'=v_secondary_report_id::text
  ) THEN
    RAISE EXCEPTION 'FAIL: RAE system inbox list lost the human-owner-wide scope';
  END IF;

  v_detail:=public.get_problem_report((v_report->'data'->>'report_id')::uuid);
  IF v_detail->'data'->'report'->>'id' IS DISTINCT FROM v_report->'data'->>'report_id' THEN
    RAISE EXCEPTION 'FAIL: RAE system Problem Inbox detail returned the wrong report';
  END IF;

  v_update:=public.update_problem_report(
    (v_report->'data'->>'report_id')::uuid,
    'in_progress',
    'RAE system principal verified the report and began the tracked work.',
    NULL,
    NULL,
    'rae-system-owner-problem-report-update'
  );
  IF v_update->'data'->>'status' IS DISTINCT FROM 'in_progress' THEN
    RAISE EXCEPTION 'FAIL: RAE system Problem Inbox update failed: %',v_update;
  END IF;

  IF v_secondary_report_id IS NOT NULL THEN
    BEGIN
      PERFORM public.get_problem_report(v_secondary_report_id);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN
      v_cross_get_rejected:=true;
    END;
    IF NOT v_cross_get_rejected THEN
      RAISE EXCEPTION 'FAIL: RAE system Problem Inbox detail crossed project scope';
    END IF;

    BEGIN
      PERFORM public.update_problem_report(
        v_secondary_report_id,'in_progress',
        'This cross-project mutation must be rejected.',
        NULL,NULL,'rae-system-owner-cross-project-update'
      );
    EXCEPTION WHEN SQLSTATE 'P0002' THEN
      v_cross_update_rejected:=true;
    END;
    IF NOT v_cross_update_rejected THEN
      RAISE EXCEPTION 'FAIL: RAE system Problem Inbox update crossed project scope';
    END IF;
  END IF;

  RAISE NOTICE 'PASS: RAE system Problem Inbox list/get/update and project isolation';
END
$system_problem_inbox$;
COMMIT;

-- A non-postgres API session cannot forge the private RAE system context by
-- setting its transaction-local GUC values.
BEGIN;
SET LOCAL SESSION AUTHORIZATION authenticated;
SELECT set_config('rae.system_version','v1',true);
SELECT set_config('rae.system_project_id','00000000-0000-4000-8000-000000000008',true);
SELECT set_config(
  'rae.system_principal_id',
  (SELECT id::text FROM private.system_principals WHERE principal_key='rae-core'),
  true
);
SET LOCAL SESSION AUTHORIZATION authenticated;
DO $forged_context$
DECLARE
  v_rejected boolean:=false;
BEGIN

  BEGIN
    PERFORM public.list_tasks(
      '00000000-0000-4000-8000-000000000008'::uuid,
      NULL,
      '00000000-0000-4000-8000-000000000009'::uuid,
      10,
      NULL
    );
  EXCEPTION WHEN SQLSTATE '28000' THEN
    IF SQLERRM<>'UNAUTHENTICATED' THEN RAISE; END IF;
    v_rejected:=true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'FAIL: forged RAE system context passed task RPC authorization';
  END IF;
  RAISE NOTICE 'PASS: non-postgres session cannot forge the RAE system principal';
END
$forged_context$;
ROLLBACK;
