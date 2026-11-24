-- Allow the trusted, transaction-local Owner-MCP context to register a
-- second project without fabricating auth.uid() or writing project rows
-- directly. The context must be anchored to an existing project owned by
-- the same Owner; normal JWT registration remains unchanged.
BEGIN;

CREATE OR REPLACE FUNCTION public.register_project(
  p_name text,
  p_description text,
  p_github_repo text,
  p_config jsonb,
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
DECLARE
  v_owner_id uuid;
  v_context_project_id uuid;
  v_context_owner_id uuid;
  v_id uuid;
  v_hash text;
  v_response jsonb;
  v_existing_hash text;
  v_existing_response jsonb;
  v_seed text;
BEGIN
  v_owner_id := auth.uid();

  -- The only no-JWT path is the private Owner-MCP context established for
  -- this same postgres management transaction. The helper revalidates the
  -- bound project/Owner pair; callers cannot choose an arbitrary owner id.
  IF v_owner_id IS NULL THEN
    IF session_user <> 'postgres'
      OR current_setting('rae.owner_mcp_version', true) IS DISTINCT FROM 'v1' THEN
      RAISE EXCEPTION USING errcode = '28000', message = 'UNAUTHENTICATED';
    END IF;

    BEGIN
      v_context_project_id :=
        nullif(current_setting('rae.owner_mcp_project_id', true), '')::uuid;
      v_context_owner_id :=
        nullif(current_setting('rae.owner_mcp_owner_id', true), '')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION USING errcode = '28000', message = 'UNAUTHENTICATED';
    END;

    IF v_context_project_id IS NULL
      OR v_context_owner_id IS NULL
      OR NOT private.owner_mcp_context_matches(v_context_project_id) THEN
      RAISE EXCEPTION USING errcode = '28000', message = 'UNAUTHENTICATED';
    END IF;

    v_owner_id := v_context_owner_id;
  END IF;

  IF p_idempotency_key IS NULL OR length(btrim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION USING errcode = '22023', message = 'IDEMPOTENCY_KEY_REQUIRED';
  END IF;

  v_hash := private.request_hash(jsonb_build_object(
    'name', p_name,
    'description', p_description,
    'github_repo', p_github_repo,
    'config', coalesce(p_config, '{}'::jsonb)
  ));

  v_seed := md5(v_owner_id::text || ':register_project:' || p_idempotency_key);
  v_id := (
    substr(v_seed, 1, 8) || '-' ||
    substr(v_seed, 9, 4) || '-4' ||
    substr(v_seed, 14, 3) || '-a' ||
    substr(v_seed, 18, 3) || '-' ||
    substr(v_seed, 21, 12)
  )::uuid;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_id::text, 0));

  SELECT request_hash, response
  INTO v_existing_hash, v_existing_response
  FROM public.operation_requests
  WHERE project_id = v_id
    AND operation = 'register_project'
    AND idempotency_key = p_idempotency_key;

  IF FOUND THEN
    IF v_existing_hash <> v_hash THEN
      RAISE EXCEPTION USING errcode = '23505', message = 'IDEMPOTENCY_CONFLICT';
    END IF;
    RETURN v_existing_response;
  END IF;

  INSERT INTO public.projects(
    id, name, description, github_repo, config, owner_id
  )
  VALUES (
    v_id,
    p_name,
    p_description,
    p_github_repo,
    coalesce(p_config, '{}'::jsonb),
    v_owner_id
  )
  ON CONFLICT (id) DO NOTHING;

  IF NOT EXISTS (
    SELECT 1
    FROM public.projects
    WHERE id = v_id
      AND owner_id = v_owner_id
  ) THEN
    RAISE EXCEPTION USING errcode = '42501', message = 'PROJECT_FORBIDDEN';
  END IF;

  v_response := jsonb_build_object(
    'success', true,
    'data', (SELECT to_jsonb(p) FROM public.projects p WHERE p.id = v_id)
  );

  INSERT INTO public.operation_requests(
    project_id, operation, idempotency_key, request_hash, response
  )
  VALUES (
    v_id, 'register_project', p_idempotency_key, v_hash, v_response
  );

  RETURN v_response;
END;
$function$;

COMMENT ON FUNCTION public.register_project(text, text, text, jsonb, text) IS
  'Registers a project for the authenticated Owner, or for the real Owner established by a validated transaction-local trusted Owner-MCP context on the postgres management session. No JWT claims are synthesized; project idempotency and ownership checks remain enforced.';

COMMIT;
