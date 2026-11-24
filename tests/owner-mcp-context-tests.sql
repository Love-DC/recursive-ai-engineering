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

-- Additional owned/foreign projects and reports exercise the cross-project inbox.
INSERT INTO auth.users(id)
VALUES ('00000000-0000-4000-8000-000000000099')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.projects(
  id, name, description, github_repo, config, owner_id, status
)
VALUES
  ('00000000-0000-4000-8000-000000000011','trusted-owner-mcp-second-project',
   'second project owned by the same Owner','test/trusted-owner-mcp-second','{}'::jsonb,
   '00000000-0000-4000-8000-000000000001','active'),
  ('00000000-0000-4000-8000-000000000012','trusted-owner-mcp-foreign-project',
   'project owned by a different Owner','test/trusted-owner-mcp-foreign','{}'::jsonb,
   '00000000-0000-4000-8000-000000000099','active')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.problem_reports(
  id, project_id, category, severity, status, title, summary, impact,
  evidence, source, fingerprint
)
VALUES
  ('00000000-0000-4000-8000-000000000013','00000000-0000-4000-8000-000000000011',
   'risk','high','open','Same Owner second-project report',
   'A second owned project has an unresolved report.',
   'The Owner digest must include this project.',
   '[{"kind":"test","ref":"fixture:owner-mcp-second","observation":"Owned by the same Owner."}]',
   'automated','test:owner-mcp:second-project'),
  ('00000000-0000-4000-8000-000000000014','00000000-0000-4000-8000-000000000008',
   'risk','medium','open','Same Owner anchor-project report',
   'The context anchor project has an unresolved report.',
   'The Owner digest must include its anchor project.',
   '[{"kind":"test","ref":"fixture:owner-mcp-anchor","observation":"Anchor report."}]',
   'automated','test:owner-mcp:anchor-project'),
  ('00000000-0000-4000-8000-000000000015','00000000-0000-4000-8000-000000000012',
   'risk','critical','open','Foreign Owner report',
   'This report belongs to another Owner.',
   'It must never appear in the first Owner digest.',
   '[{"kind":"test","ref":"fixture:owner-mcp-foreign","observation":"Must remain private."}]',
   'automated','test:owner-mcp:foreign-owner')
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
  IF has_function_privilege('authenticated','private.owner_mcp_context_owner_id()','EXECUTE')
    OR has_function_privilege('anon','private.owner_mcp_context_owner_id()','EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: API roles can execute owner_mcp_context_owner_id';
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


-- The trusted Owner-MCP context powers the cross-project inbox without
-- widening project-scoped task lifecycle authorization.
BEGIN;
DO $owner_mcp_problem_inbox$
DECLARE
  v_list jsonb;
  v_detail jsonb;
  v_update jsonb;
  v_status text;
  v_event_count integer;
  v_rejected boolean;
BEGIN
  IF auth.uid() IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: Owner-MCP Problem Inbox test must not synthesize auth.uid()';
  END IF;

  PERFORM private.begin_owner_mcp_context(
    '00000000-0000-4000-8000-000000000008'::uuid,
    '00000000-0000-4000-8000-000000000001'::uuid
  );
  IF private.owner_mcp_context_owner_id()
    IS DISTINCT FROM '00000000-0000-4000-8000-000000000001'::uuid THEN
    RAISE EXCEPTION 'FAIL: validated Owner-MCP context did not resolve its Owner';
  END IF;

  v_list := public.list_problem_reports('unresolved', NULL, 200);
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_list->'data') item
    WHERE item->>'id'='00000000-0000-4000-8000-000000000013'
  ) OR NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_list->'data') item
    WHERE item->>'id'='00000000-0000-4000-8000-000000000014'
  ) OR EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_list->'data') item
    WHERE item->>'id'='00000000-0000-4000-8000-000000000015'
  ) THEN
    RAISE EXCEPTION 'FAIL: Owner-MCP digest omitted an owned report or leaked a foreign report: %',v_list;
  END IF;

  v_detail := public.get_problem_report('00000000-0000-4000-8000-000000000013'::uuid);
  IF v_detail->'data'->'report'->>'id' IS DISTINCT FROM '00000000-0000-4000-8000-000000000013'
    OR v_detail->'data'->'project'->>'github_repo' IS DISTINCT FROM 'test/trusted-owner-mcp-second' THEN
    RAISE EXCEPTION 'FAIL: Owner-MCP could not read a same-Owner report outside its anchor project: %',v_detail;
  END IF;

  v_update := public.update_problem_report(
    '00000000-0000-4000-8000-000000000013'::uuid,
    'triaged',
    'Owner-MCP verified the cross-project report and retained its evidence.',
    NULL,
    'https://github.com/example/repo/pull/owner-mcp-test',
    'owner-mcp-problem-inbox-update-second-project'
  );
  IF v_update->'data'->>'status' IS DISTINCT FROM 'triaged' THEN
    RAISE EXCEPTION 'FAIL: Owner-MCP could not update a same-Owner report outside its anchor project: %',v_update;
  END IF;

  SELECT status INTO v_status
  FROM public.problem_reports
  WHERE id='00000000-0000-4000-8000-000000000013'::uuid;
  SELECT count(*) INTO v_event_count
  FROM public.problem_report_events
  WHERE report_id='00000000-0000-4000-8000-000000000013'::uuid
    AND event_type='status_changed';
  IF v_status IS DISTINCT FROM 'triaged' OR v_event_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: Owner-MCP update did not persist status and append its event';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.get_problem_report('00000000-0000-4000-8000-000000000015'::uuid);
  EXCEPTION WHEN SQLSTATE 'P0002' THEN
    IF SQLERRM <> 'PROBLEM_REPORT_NOT_FOUND' THEN RAISE; END IF;
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'FAIL: Owner-MCP read a foreign-Owner report';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.update_problem_report(
      '00000000-0000-4000-8000-000000000015'::uuid,
      'triaged',
      'Foreign-owner update must be rejected.',
      NULL,
      NULL,
      'owner-mcp-problem-inbox-update-foreign-project'
    );
  EXCEPTION WHEN SQLSTATE 'P0002' THEN
    IF SQLERRM <> 'PROBLEM_REPORT_NOT_FOUND' THEN RAISE; END IF;
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'FAIL: Owner-MCP updated a foreign-Owner report';
  END IF;

  RAISE NOTICE 'PASS: Owner-MCP cross-project digest, detail, update/audit, and foreign-Owner isolation';
END
$owner_mcp_problem_inbox$;
COMMIT;

-- The normal PostgREST auth boundary remains unchanged. A caller that
-- authenticates as the API role cannot forge the privileged postgres session
-- by supplying transaction-local Owner-MCP GUC names.
BEGIN;
SET LOCAL SESSION AUTHORIZATION authenticated;
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT set_config('rae.owner_mcp_project_id', '00000000-0000-4000-8000-000000000008', true);
SELECT set_config('rae.owner_mcp_owner_id', '00000000-0000-4000-8000-000000000001', true);
SELECT set_config('rae.owner_mcp_version', 'v1', true);
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
    PERFORM public.get_problem_report('00000000-0000-4000-8000-000000000013'::uuid);
    RAISE EXCEPTION 'FAIL: authenticated role read a report by forging Owner-MCP GUCs';
  EXCEPTION WHEN SQLSTATE 'P0002' THEN
    IF SQLERRM <> 'PROBLEM_REPORT_NOT_FOUND' THEN RAISE; END IF;
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'FAIL: forged Owner-MCP context exposed report details';
  END IF;
  v_rejected := false;
  BEGIN
    PERFORM public.update_problem_report(
      '00000000-0000-4000-8000-000000000013'::uuid,
      'triaged',
      'Authenticated forged-context update must be rejected.',
      NULL,NULL,'authenticated-forged-owner-mcp-update'
    );
    RAISE EXCEPTION 'FAIL: authenticated role updated a report by forging Owner-MCP GUCs';
  EXCEPTION WHEN SQLSTATE 'P0002' THEN
    IF SQLERRM <> 'PROBLEM_REPORT_NOT_FOUND' THEN RAISE; END IF;
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'FAIL: forged Owner-MCP context mutated a Problem Inbox report';
  END IF;
END
$authenticated$;
ROLLBACK;
