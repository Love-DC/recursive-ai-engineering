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
END
$authenticated$;
ROLLBACK;
