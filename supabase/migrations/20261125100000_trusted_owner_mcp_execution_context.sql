-- Trusted Owner-MCP context for the existing single-owner Supabase MCP pilot.
-- This is a separate database-admin trust path, not a fabricated Supabase JWT.
-- External PostgREST/authenticated clients continue to require auth.uid().
BEGIN;

CREATE TABLE private.owner_mcp_audit (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transaction_id bigint NOT NULL,
  project_id uuid NOT NULL REFERENCES public.projects(id) ON DELETE RESTRICT,
  owner_id uuid NOT NULL,
  database_role name NOT NULL,
  backend_pid integer NOT NULL,
  application_name text NOT NULL DEFAULT '',
  context_version text NOT NULL DEFAULT 'v1',
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT uq_owner_mcp_audit_transaction_project_owner
    UNIQUE (transaction_id, project_id, owner_id)
);

ALTER TABLE private.owner_mcp_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.owner_mcp_audit FROM PUBLIC, anon, authenticated;
CREATE INDEX idx_owner_mcp_audit_project_created
  ON private.owner_mcp_audit(project_id, created_at DESC);

COMMENT ON TABLE private.owner_mcp_audit IS
  'Audit trail for transaction-scoped Owner authority established through the trusted Supabase MCP postgres session. Not exposed through the Data API.';

CREATE OR REPLACE FUNCTION private.owner_mcp_context_matches(p_project_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
DECLARE
  v_context_project_id uuid;
  v_context_owner_id uuid;
BEGIN
  IF session_user <> 'postgres' OR p_project_id IS NULL THEN
    RETURN false;
  END IF;

  IF current_setting('rae.owner_mcp_version', true) IS DISTINCT FROM 'v1' THEN
    RETURN false;
  END IF;

  BEGIN
    v_context_project_id :=
      nullif(current_setting('rae.owner_mcp_project_id', true), '')::uuid;
    v_context_owner_id :=
      nullif(current_setting('rae.owner_mcp_owner_id', true), '')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RETURN false;
  END;

  IF v_context_project_id IS DISTINCT FROM p_project_id
    OR v_context_owner_id IS NULL THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.projects p
    WHERE p.id = p_project_id
      AND p.owner_id = v_context_owner_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION private.owner_mcp_context_matches(uuid)
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION private.owner_mcp_context_matches(uuid) IS
  'Internal predicate for a transaction-local trusted Owner-MCP context. Requires the original postgres database session and a live project-owner match.';

CREATE OR REPLACE FUNCTION private.begin_owner_mcp_context(
  p_project_id uuid,
  p_owner_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
DECLARE
  v_actual_owner_id uuid;
  v_project_status text;
  v_existing_project text;
  v_existing_owner text;
BEGIN
  -- Supabase MCP execute_sql connects through the already-authorized,
  -- privileged postgres management session. No JWT identity is synthesized.
  IF session_user <> 'postgres' THEN
    RAISE EXCEPTION USING errcode = '42501',
      message = 'OWNER_MCP_ADMIN_SESSION_REQUIRED';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    RAISE EXCEPTION USING errcode = '42501',
      message = 'OWNER_MCP_CONTEXT_ONLY_WHEN_AUTH_UID_NULL';
  END IF;

  IF p_project_id IS NULL OR p_owner_id IS NULL THEN
    RAISE EXCEPTION USING errcode = '22023',
      message = 'OWNER_MCP_CONTEXT_ARGUMENT_INVALID';
  END IF;

  v_existing_project := nullif(current_setting('rae.owner_mcp_project_id', true), '');
  v_existing_owner := nullif(current_setting('rae.owner_mcp_owner_id', true), '');

  IF v_existing_project IS NOT NULL OR v_existing_owner IS NOT NULL THEN
    IF current_setting('rae.owner_mcp_version', true) = 'v1'
      AND v_existing_project = p_project_id::text
      AND v_existing_owner = p_owner_id::text
      AND private.owner_mcp_context_matches(p_project_id) THEN
      RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
          'project_id', p_project_id,
          'owner_id', p_owner_id,
          'mode', 'trusted_owner_mcp',
          'scope', 'current_transaction',
          'reused', true
        )
      );
    END IF;

    RAISE EXCEPTION USING errcode = '42501',
      message = 'OWNER_MCP_CONTEXT_ALREADY_BOUND';
  END IF;

  SELECT p.owner_id, p.status
  INTO v_actual_owner_id, v_project_status
  FROM public.projects p
  WHERE p.id = p_project_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode = 'P0002',
      message = 'PROJECT_NOT_FOUND';
  END IF;

  IF v_project_status <> 'active' THEN
    RAISE EXCEPTION USING errcode = '55000',
      message = 'PROJECT_NOT_ACTIVE';
  END IF;

  IF v_actual_owner_id IS DISTINCT FROM p_owner_id THEN
    RAISE EXCEPTION USING errcode = '42501',
      message = 'PROJECT_FORBIDDEN';
  END IF;

  PERFORM set_config('rae.owner_mcp_project_id', p_project_id::text, true);
  PERFORM set_config('rae.owner_mcp_owner_id', p_owner_id::text, true);
  PERFORM set_config('rae.owner_mcp_version', 'v1', true);

  INSERT INTO private.owner_mcp_audit (
    transaction_id,
    project_id,
    owner_id,
    database_role,
    backend_pid,
    application_name,
    context_version
  )
  VALUES (
    txid_current(),
    p_project_id,
    p_owner_id,
    session_user,
    pg_backend_pid(),
    coalesce(current_setting('application_name', true), ''),
    'v1'
  )
  ON CONFLICT (transaction_id, project_id, owner_id) DO NOTHING;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'project_id', p_project_id,
      'owner_id', p_owner_id,
      'mode', 'trusted_owner_mcp',
      'scope', 'current_transaction',
      'reused', false
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION private.begin_owner_mcp_context(uuid, uuid)
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION private.begin_owner_mcp_context(uuid, uuid) IS
  'Establishes a project-bound, transaction-local Owner context only for the trusted postgres Supabase MCP session. Caller must pass the actual projects.owner_id. This is not a JWT and is not callable by anon/authenticated API roles.';

CREATE OR REPLACE FUNCTION private.assert_owner(p_project_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
DECLARE
  v_uid uuid;
BEGIN
  v_uid := auth.uid();

  IF v_uid IS NULL THEN
    IF private.owner_mcp_context_matches(p_project_id) THEN
      RETURN;
    END IF;
    RAISE EXCEPTION USING errcode = '28000',
      message = 'UNAUTHENTICATED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.projects p
    WHERE p.id = p_project_id
      AND p.owner_id = v_uid
  ) THEN
    RAISE EXCEPTION USING errcode = '42501',
      message = 'PROJECT_FORBIDDEN';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION private.assert_worker_actor(
  p_project_id uuid,
  p_worker_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
DECLARE
  v_uid uuid;
BEGIN
  v_uid := auth.uid();

  IF v_uid IS NULL THEN
    IF private.owner_mcp_context_matches(p_project_id) THEN
      RETURN;
    END IF;
    RAISE EXCEPTION USING errcode = '28000',
      message = 'UNAUTHENTICATED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.projects p
    WHERE p.id = p_project_id
      AND p.owner_id = v_uid
  ) THEN
    RETURN;
  END IF;

  IF p_worker_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.workers w
    WHERE w.id = p_worker_id
      AND w.project_id = p_project_id
      AND w.auth_user_id = v_uid
      AND w.status = 'active'
  ) THEN
    RAISE EXCEPTION USING errcode = '42501',
      message = 'WORKER_IDENTITY_MISMATCH';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION private.assert_owner(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.assert_worker_actor(uuid, uuid)
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION private.assert_owner(uuid) IS
  'Accepts either the normal Supabase auth.uid() Owner identity or a transaction-local trusted Owner-MCP context established by private.begin_owner_mcp_context.';
COMMENT ON FUNCTION private.assert_worker_actor(uuid, uuid) IS
  'Accepts normal Owner/Worker JWT identity or a transaction-local trusted Owner-MCP context; project, Worker route, lease, execution and task-state checks remain enforced by their existing RPCs.';

COMMIT;
