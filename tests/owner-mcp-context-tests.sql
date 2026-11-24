-- End-to-end test for the trusted Owner-MCP database-admin context.
-- Run against the PostgreSQL 17 integration fixture after PR #66 and this
-- migration have been applied. The owner identity is passed explicitly and
-- checked against projects.owner_id; this test never fabricates auth.uid().
\set ON_ERROR_STOP on

INSERT INTO auth.users(id)
VALUES ('00000000-0000-4000-8000-000000000001')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.projects(
  id, name, description, github_repo, config, owner_id, status
)
VALUES (
  '00000000-0000-4000-8000-000000000008',
  'trusted-owner-mcp-test',
  'isolated test fixture',
  'test/trusted-owner-mcp',
  '{
    "autonomy": {"paused": false, "max_active_executions": 2},
    "worker_routing": {
      "default_worker_key": "mcp-executor",
      "task_type_worker_keys": {"review": "mcp-reviewer"}
    }
  }'::jsonb,
  '00000000-0000-4000-8000-000000000001',
  'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.workers(id, project_id, worker_key, display_name, status, auth_user_id)
VALUES
  (
    '00000000-0000-4000-8000-000000000009',
    '00000000-0000-4000-8000-000000000008',
    'mcp-executor',
    'MCP Test Executor',
    'active',
    NULL
  ),
  (
    '00000000-0000-4000-8000-000000000010',
    '00000000-0000-4000-8000-000000000008',
    'mcp-reviewer',
    'MCP Test Reviewer',
    'active',
    NULL
  )
ON CONFLICT (id) DO NOTHING;

-- A second project for the same Owner verifies the inbox's cross-project
-- listing scope without permitting project-crossing get/update operations.
INSERT INTO public.projects(
  id, name, description, github_repo, config, owner_id, status
)
VALUES (
  '00000000-0000-4000-8000-000000000011',
  'trusted-owner-mcp-secondary-test',
  'second project for Owner-MCP inbox scope tests',
  'test/trusted-owner-mcp-secondary',
  '{"autonomy":{"paused":true,"max_active_executions":2},"worker_routing":{"default_worker_key":"mcp-secondary"}}'::jsonb,
  '00000000-0000-4000-8000-000000000001',
  'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.workers(id, project_id, worker_key, display_name, status, auth_user_id)
VALUES (
  '00000000-0000-4000-8000-000000000012',
  '00000000-0000-4000-8000-000000000011',
  'mcp-secondary',
  'MCP Secondary Project Worker',
  'active',
  NULL
)
ON CONFLICT (id) DO NOTHING;

-- The Owner-MCP entry point is unavailable to ordinary API roles.
DO $acl$
BEGIN
  IF has_schema_privilege('authenticated', 'private', 'USAGE') THEN
    RAISE EXCEPTION 'FAIL: authenticated has private schema usage';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'private.begin_owner_mcp_context(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated can execute begin_owner_mcp_context';
  END IF;
  IF has_function_privilege(
    'anon',
    'private.begin_owner_mcp_context(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: anon can execute begin_owner_mcp_context';
  END IF;
END
$acl$;

-- A privileged SQL connection still cannot claim the Owner context for a
-- different project's Owner.
DO $wrong_owner$
DECLARE
  v_rejected boolean := false;
BEGIN
  BEGIN
    PERFORM private.begin_owner_mcp_context(
      '00000000-0000-4000-8000-000000000008'::uuid,
      '00000000-0000-4000-8000-000000000099'::uuid
    );
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM <> 'PROJECT_FORBIDDEN' THEN
      RAISE;
    END IF;
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'FAIL: wrong Owner ID was accepted';
  END IF;
END
$wrong_owner$;

-- Without a JWT or an explicitly established Owner-MCP transaction context,
-- the existing project-scoped RPC still rejects an unauthenticated call.
DO $no_context$
DECLARE
  v_rejected boolean := false;
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
    IF SQLERRM <> 'UNAUTHENTICATED' THEN
      RAISE;
    END IF;
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'FAIL: public RPC accepted an unauthenticated call';
  END IF;
END
$no_context$;

-- Project registration also remains unavailable without a real JWT or
-- a validated Owner-MCP context.
DO $register_without_context$
DECLARE
  v_rejected boolean := false;
BEGIN
  BEGIN
    PERFORM public.register_project(
      'unauthenticated-register-test',
      'must be rejected without Owner context',
      'test/unauthenticated-register',
      '{}'::jsonb,
      'unauthenticated-register-project'
    );
  EXCEPTION WHEN SQLSTATE '28000' THEN
    IF SQLERRM <> 'UNAUTHENTICATED' THEN
      RAISE;
    END IF;
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'FAIL: register_project accepted an unauthenticated call';
  END IF;
END
$register_without_context$;

-- Exercise the complete existing task lifecycle through the transaction-local
-- Owner-MCP context: create -> claim -> heartbeat -> submit -> independent
-- reviewer claim -> review acceptance. The RPCs retain their normal routing,
-- task state, lease, idempotency, and execution fences.
BEGIN;
DO $lifecycle$
DECLARE
  v_task jsonb;
  v_claim jsonb;
  v_heartbeat jsonb;
  v_submit jsonb;
  v_review_task jsonb;
  v_review_claim jsonb;
  v_review_result jsonb;
  v_task_id uuid;
  v_execution_id uuid;
  v_review_task_id uuid;
  v_review_execution_id uuid;
  v_task_status text;
  v_review_status text;
  v_audit_count integer;
BEGIN
  PERFORM private.begin_owner_mcp_context(
    '00000000-0000-4000-8000-000000000008'::uuid,
    '00000000-0000-4000-8000-000000000001'::uuid
  );

  v_task := public.create_task(
    '00000000-0000-4000-8000-000000000008'::uuid,
    '00000000-0000-4000-8000-000000000009'::uuid,
    'implementation',
    'Trusted Owner-MCP lifecycle acceptance',
    'Exercise the existing owner-scoped task lifecycle through a transaction-local trusted MCP context.',
    jsonb_build_object(
      'target', jsonb_build_object(
        'repository', 'test/trusted-owner-mcp',
        'base_branch', 'main',
        'base_sha', repeat('a', 40),
        'branch', 'test/owner-mcp-lifecycle'
      ),
      'decision_gate', 'engineering_only',
      'owner_authorization', 'trusted_owner_mcp_integration_test'
    ),
    1,
    true,
    NULL,
    NULL,
    'owner-mcp-test-create-task'
  );
  v_task_id := (v_task->'data'->>'id')::uuid;

  v_claim := public.claim_task(
    '00000000-0000-4000-8000-000000000008'::uuid,
    '00000000-0000-4000-8000-000000000009'::uuid,
    300,
    'owner-mcp-test-claim-delivery'
  );
  v_execution_id := (v_claim->'data'->>'execution_id')::uuid;
  IF (v_claim->'data'->>'task_id')::uuid IS DISTINCT FROM v_task_id THEN
    RAISE EXCEPTION 'FAIL: Owner-MCP claim did not return the created task';
  END IF;

  v_heartbeat := public.heartbeat_execution(
    v_task_id,
    v_execution_id,
    '00000000-0000-4000-8000-000000000009'::uuid,
    'owner-mcp-test-heartbeat'
  );
  IF coalesce((v_heartbeat->>'success')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL: Owner-MCP heartbeat failed: %', v_heartbeat;
  END IF;

  v_submit := public.submit_result(
    v_task_id,
    v_execution_id,
    '00000000-0000-4000-8000-000000000009'::uuid,
    '{"summary":"Owner-MCP delivery submitted","validation":{"fixture":"postgres-task-lifecycle"}}'::jsonb,
    'owner-mcp-test-submit'
  );
  IF v_submit->'data'->>'status' IS DISTINCT FROM 'submitted' THEN
    RAISE EXCEPTION 'FAIL: Owner-MCP submit_result failed: %', v_submit;
  END IF;

  v_review_task := public.create_review_task(
    v_task_id,
    v_task_id,
    v_execution_id,
    '00000000-0000-4000-8000-000000000010'::uuid,
    'owner-mcp-test-create-review'
  );
  v_review_task_id := (v_review_task->'data'->>'id')::uuid;

  v_review_claim := public.claim_task(
    '00000000-0000-4000-8000-000000000008'::uuid,
    '00000000-0000-4000-8000-000000000010'::uuid,
    300,
    'owner-mcp-test-claim-review'
  );
  v_review_execution_id := (v_review_claim->'data'->>'execution_id')::uuid;
  IF (v_review_claim->'data'->>'task_id')::uuid IS DISTINCT FROM v_review_task_id THEN
    RAISE EXCEPTION 'FAIL: independent Reviewer Worker did not claim its routed review task';
  END IF;

  v_review_result := public.review_result(
    v_review_task_id,
    v_review_execution_id,
    '00000000-0000-4000-8000-000000000010'::uuid,
    'accepted',
    '{"summary":"Owner-MCP integration lifecycle accepted"}'::jsonb,
    'owner-mcp-test-review-result'
  );
  IF v_review_result->'data'->>'decision' IS DISTINCT FROM 'accepted' THEN
    RAISE EXCEPTION 'FAIL: Owner-MCP review_result failed: %', v_review_result;
  END IF;

  SELECT status INTO v_task_status
  FROM public.tasks WHERE id = v_task_id;
  SELECT status INTO v_review_status
  FROM public.tasks WHERE id = v_review_task_id;

  IF v_task_status IS DISTINCT FROM 'accepted'
    OR v_review_status IS DISTINCT FROM 'accepted' THEN
    RAISE EXCEPTION 'FAIL: lifecycle did not finish accepted (task %, review %)',
      v_task_status, v_review_status;
  END IF;

  SELECT count(*) INTO v_audit_count
  FROM private.owner_mcp_audit
  WHERE transaction_id = txid_current()
    AND project_id = '00000000-0000-4000-8000-000000000008'::uuid
    AND owner_id = '00000000-0000-4000-8000-000000000001'::uuid;
  IF v_audit_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: expected one durable Owner-MCP audit row, found %', v_audit_count;
  END IF;

  RAISE NOTICE 'PASS: trusted Owner-MCP context, create/claim/heartbeat/submit, routed independent review, accepted lifecycle, and durable audit';
END
$lifecycle$;
COMMIT;

-- Transaction-local context must be cleared automatically on COMMIT.
DO $cleared$
BEGIN
  IF private.owner_mcp_context_matches(
    '00000000-0000-4000-8000-000000000008'::uuid
  ) THEN
    RAISE EXCEPTION 'FAIL: Owner-MCP context leaked past transaction COMMIT';
  END IF;
END
$cleared$;

-- Project bootstrap uses the real Owner from a context anchored to an
-- existing project. Idempotent replay must return the same new project.
BEGIN;
DO $register_project$
DECLARE
  v_config jsonb := jsonb_build_object(
    'project_key', 'owner-mcp-registered',
    'default_branch', 'main',
    'autonomy', jsonb_build_object(
      'paused', true,
      'max_active_executions', 2
    ),
    'worker_routing', jsonb_build_object(
      'default_worker_key', 'mcp-executor',
      'task_type_worker_keys', jsonb_build_object('review', 'mcp-reviewer')
    )
  );
  v_registered jsonb;
  v_replay jsonb;
  v_project_id uuid;
BEGIN
  PERFORM private.begin_owner_mcp_context(
    '00000000-0000-4000-8000-000000000008'::uuid,
    '00000000-0000-4000-8000-000000000001'::uuid
  );

  v_registered := public.register_project(
    'owner-mcp-registered-test',
    'isolated Owner-MCP project-registration fixture',
    'test/owner-mcp-registered',
    v_config,
    'owner-mcp-register-project'
  );

  IF coalesce((v_registered->>'success')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL: Owner-MCP register_project failed: %', v_registered;
  END IF;

  v_project_id := (v_registered->'data'->>'id')::uuid;
  IF (v_registered->'data'->>'owner_id')::uuid
    IS DISTINCT FROM '00000000-0000-4000-8000-000000000001'::uuid THEN
    RAISE EXCEPTION 'FAIL: registered project Owner does not match the bound Owner';
  END IF;

  v_replay := public.register_project(
    'owner-mcp-registered-test',
    'isolated Owner-MCP project-registration fixture',
    'test/owner-mcp-registered',
    v_config,
    'owner-mcp-register-project'
  );

  IF (v_replay->'data'->>'id')::uuid IS DISTINCT FROM v_project_id THEN
    RAISE EXCEPTION 'FAIL: idempotent registration did not return the same project';
  END IF;

  RAISE NOTICE 'PASS: trusted Owner-MCP project registration and idempotent replay';
END
$register_project$;
COMMIT;

-- Worker registration is separately bound to the newly registered project.
-- The fail-closed operational pause is preserved in the project config.
BEGIN;
DO $register_project_workers$
DECLARE
  v_project_id uuid;
  v_executor jsonb;
  v_reviewer jsonb;
  v_worker_count integer;
  v_paused boolean;
BEGIN
  SELECT id INTO v_project_id
  FROM public.projects
  WHERE github_repo = 'test/owner-mcp-registered'
    AND owner_id = '00000000-0000-4000-8000-000000000001'::uuid;

  IF v_project_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: registered project was not persisted';
  END IF;

  PERFORM private.begin_owner_mcp_context(
    v_project_id,
    '00000000-0000-4000-8000-000000000001'::uuid
  );

  v_executor := public.register_worker(
    v_project_id,
    'mcp-executor',
    'MCP Test Executor',
    'Project-scoped implementation Worker'
  );
  v_reviewer := public.register_worker(
    v_project_id,
    'mcp-reviewer',
    'MCP Test Reviewer',
    'Project-scoped independent Reviewer Worker'
  );

  IF v_executor->'data'->>'worker_key' IS DISTINCT FROM 'mcp-executor'
    OR v_reviewer->'data'->>'worker_key' IS DISTINCT FROM 'mcp-reviewer' THEN
    RAISE EXCEPTION 'FAIL: Owner-MCP Worker registration returned invalid routes';
  END IF;

  SELECT count(*) INTO v_worker_count
  FROM public.workers
  WHERE project_id = v_project_id
    AND worker_key IN ('mcp-executor', 'mcp-reviewer')
    AND status = 'active';

  SELECT (config #>> '{autonomy,paused}')::boolean INTO v_paused
  FROM public.projects WHERE id = v_project_id;

  IF v_worker_count <> 2 THEN
    RAISE EXCEPTION 'FAIL: expected exactly two project-scoped Workers, found %', v_worker_count;
  END IF;
  IF v_paused IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: project registration did not preserve fail-closed autonomy pause';
  END IF;

  RAISE NOTICE 'PASS: project-scoped executor/reviewer registration with operational pause retained';
END
$register_project_workers$;
COMMIT;

-- Create a report in a second project owned by the same Owner. The
-- transaction-scoped context is bound to that exact project for the write.
BEGIN;
DO $secondary_inbox_report$
DECLARE
  v_report jsonb;
BEGIN
  PERFORM private.begin_owner_mcp_context(
    '00000000-0000-4000-8000-000000000011'::uuid,
    '00000000-0000-4000-8000-000000000001'::uuid
  );

  v_report := public.report_problem(
    '00000000-0000-4000-8000-000000000011'::uuid,
    '00000000-0000-4000-8000-000000000012'::uuid,
    jsonb_build_object(
      'category','defect',
      'severity','medium',
      'status','open',
      'title','Secondary project Owner-MCP inbox fixture',
      'summary','A fixture report used to verify Owner-scoped cross-project inbox listing.',
      'impact','The integration test must show that one verified Owner can list reports from all of their active projects.',
      'recommended_action','No product action; this is an isolated integration fixture.',
      'evidence',jsonb_build_array(jsonb_build_object(
        'kind','test',
        'ref','tests/owner-mcp-context-tests.sql',
        'observation','The secondary project report is created through the normal report_problem RPC.'
      )),
      'source','automated',
      'source_ref','tests/owner-mcp-context-tests.sql',
      'fingerprint','test:owner-mcp-problem-inbox:secondary-project'
    ),
    'owner-mcp-problem-inbox-secondary-report'
  );

  IF coalesce((v_report->'success')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL: secondary-project Owner-MCP report creation failed: %',v_report;
  END IF;
END
$secondary_inbox_report$;
COMMIT;

-- The verified Owner-MCP context can list all active projects belonging to
-- that Owner, but detail and update calls remain restricted to the bound
-- project. Existing JWT-based authorization is unchanged.
BEGIN;
DO $owner_mcp_problem_inbox$
DECLARE
  v_primary_report jsonb;
  v_secondary_report_id uuid;
  v_list jsonb;
  v_detail jsonb;
  v_update jsonb;
  v_status text;
  v_cross_project_get_rejected boolean := false;
  v_cross_project_update_rejected boolean := false;
BEGIN
  PERFORM private.begin_owner_mcp_context(
    '00000000-0000-4000-8000-000000000008'::uuid,
    '00000000-0000-4000-8000-000000000001'::uuid
  );

  v_primary_report := public.report_problem(
    '00000000-0000-4000-8000-000000000008'::uuid,
    '00000000-0000-4000-8000-000000000009'::uuid,
    jsonb_build_object(
      'category','blocker',
      'severity','high',
      'status','open',
      'title','Primary project Owner-MCP inbox fixture',
      'summary','A report used to verify list, detail, and update through the trusted Owner-MCP context.',
      'impact','The Problem Inbox must remain usable without fabricating an Auth JWT.',
      'recommended_action','Exercise the existing owner-scoped RPCs through the transaction-local context.',
      'evidence',jsonb_build_array(jsonb_build_object(
        'kind','test',
        'ref','tests/owner-mcp-context-tests.sql',
        'observation','The primary project report is created through the normal report_problem RPC.'
      )),
      'source','automated',
      'source_ref','tests/owner-mcp-context-tests.sql',
      'fingerprint','test:owner-mcp-problem-inbox:primary-project'
    ),
    'owner-mcp-problem-inbox-primary-report'
  );

  IF coalesce((v_primary_report->'success')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL: primary-project Owner-MCP report creation failed: %',v_primary_report;
  END IF;

  SELECT id INTO v_secondary_report_id
  FROM public.problem_reports
  WHERE project_id='00000000-0000-4000-8000-000000000011'::uuid
    AND fingerprint='test:owner-mcp-problem-inbox:secondary-project';
  IF v_secondary_report_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: secondary-project report fixture is missing';
  END IF;

  v_list := public.list_problem_reports('unresolved',NULL,200);
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_list->'data') AS items(item)
    WHERE item->>'id'=v_primary_report->'data'->>'report_id'
  ) THEN
    RAISE EXCEPTION 'FAIL: Owner-MCP inbox list omitted the bound project's report: %',v_list;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_list->'data') AS items(item)
    WHERE item->>'id'=v_secondary_report_id::text
  ) THEN
    RAISE EXCEPTION 'FAIL: Owner-MCP inbox list omitted another active project owned by the same Owner: %',v_list;
  END IF;

  v_detail := public.get_problem_report((v_primary_report->'data'->>'report_id')::uuid);
  IF v_detail->'data'->'report'->>'id' IS DISTINCT FROM v_primary_report->'data'->>'report_id' THEN
    RAISE EXCEPTION 'FAIL: Owner-MCP get_problem_report returned the wrong report: %',v_detail;
  END IF;

  v_update := public.update_problem_report(
    (v_primary_report->'data'->>'report_id')::uuid,
    'in_progress',
    'Verified Owner-MCP update through the bound project context.',
    NULL,
    NULL,
    'owner-mcp-problem-inbox-primary-update'
  );
  IF v_update->'data'->>'status' IS DISTINCT FROM 'in_progress' THEN
    RAISE EXCEPTION 'FAIL: Owner-MCP update_problem_report failed: %',v_update;
  END IF;

  SELECT status INTO v_status
  FROM public.problem_reports
  WHERE id=(v_primary_report->'data'->>'report_id')::uuid;
  IF v_status IS DISTINCT FROM 'in_progress' THEN
    RAISE EXCEPTION 'FAIL: Owner-MCP update was not persisted: %',v_status;
  END IF;

  BEGIN
    PERFORM public.get_problem_report(v_secondary_report_id);
  EXCEPTION WHEN SQLSTATE 'P0002' THEN
    v_cross_project_get_rejected := true;
  END;
  IF NOT v_cross_project_get_rejected THEN
    RAISE EXCEPTION 'FAIL: Owner-MCP get_problem_report crossed its bound project';
  END IF;

  BEGIN
    PERFORM public.update_problem_report(
      v_secondary_report_id,
      'in_progress',
      'This cross-project update must be rejected.',
      NULL,
      NULL,
      'owner-mcp-problem-inbox-cross-project-update'
    );
  EXCEPTION WHEN SQLSTATE 'P0002' THEN
    v_cross_project_update_rejected := true;
  END;
  IF NOT v_cross_project_update_rejected THEN
    RAISE EXCEPTION 'FAIL: Owner-MCP update_problem_report crossed its bound project';
  END IF;

  RAISE NOTICE 'PASS: Owner-MCP Problem Inbox list/get/update, owner-wide listing, and project-bound detail/update isolation';
END
$owner_mcp_problem_inbox$;
ROLLBACK;

-- The normal PostgREST auth boundary remains unchanged. An authenticated role
-- with no JWT does not inherit the trusted postgres Owner-MCP context.
BEGIN;
SET LOCAL ROLE authenticated;
DO $authenticated$
DECLARE
  v_rejected boolean := false;
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
    IF SQLERRM <> 'UNAUTHENTICATED' THEN
      RAISE;
    END IF;
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'FAIL: authenticated role bypassed the JWT guard';
  END IF;

  v_rejected := false;
  BEGIN
    -- The Problem Inbox must independently reject an authenticated DB role
    -- without a JWT or a verified postgres Owner-MCP context.
    PERFORM public.list_problem_reports('unresolved',NULL,20);
  EXCEPTION WHEN SQLSTATE '28000' THEN
    IF SQLERRM <> 'UNAUTHENTICATED' THEN
      RAISE;
    END IF;
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'FAIL: list_problem_reports bypassed the Owner/JWT guard';
  END IF;
END
$authenticated$;
ROLLBACK;
