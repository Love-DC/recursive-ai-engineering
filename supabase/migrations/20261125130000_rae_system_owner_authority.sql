-- Introduce the RAE system principal as the engineering Owner without
-- fabricating a Supabase Auth user or replacing the human product-owner link.
-- The existing projects.owner_id remains the human product owner. The new
-- transaction-local RAE context authorizes bounded platform engineering RPCs
-- only; human decision endpoints keep their separate assertion.
BEGIN;

CREATE TABLE private.system_principals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  principal_key text NOT NULL UNIQUE,
  display_name text NOT NULL,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active','disabled')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

ALTER TABLE private.system_principals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.system_principals FROM PUBLIC, anon, authenticated;

INSERT INTO private.system_principals(principal_key,display_name,status)
VALUES ('rae-core','RAE System Owner','active')
ON CONFLICT (principal_key) DO UPDATE
SET display_name=EXCLUDED.display_name,
    status=EXCLUDED.status,
    updated_at=clock_timestamp();

CREATE TABLE private.system_actor_audit (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transaction_id bigint NOT NULL,
  project_id uuid NOT NULL REFERENCES public.projects(id) ON DELETE RESTRICT,
  principal_id uuid NOT NULL REFERENCES private.system_principals(id) ON DELETE RESTRICT,
  product_owner_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  database_role name NOT NULL,
  backend_pid integer NOT NULL,
  application_name text NOT NULL DEFAULT '',
  context_version text NOT NULL DEFAULT 'v1',
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT uq_system_actor_audit_tx_project_principal
    UNIQUE (transaction_id,project_id,principal_id)
);

ALTER TABLE private.system_actor_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.system_actor_audit FROM PUBLIC, anon, authenticated;
CREATE INDEX idx_system_actor_audit_project_created
  ON private.system_actor_audit(project_id,created_at DESC);

COMMENT ON TABLE private.system_principals IS
  'Non-human platform principals. These are not Supabase Auth users and cannot sign in through PostgREST.';
COMMENT ON TABLE private.system_actor_audit IS
  'Durable audit trail for project-scoped RAE system-principal contexts established through the trusted postgres Supabase MCP connection.';
COMMENT ON COLUMN public.projects.owner_id IS
  'Human product owner / decision authority. RAE engineering authority is represented separately by a private system principal and a transaction-scoped context.';

CREATE OR REPLACE FUNCTION private.rae_system_context_matches(p_project_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog','public','auth','private'
AS $function$
DECLARE
  v_context_project_id uuid;
  v_context_principal_id uuid;
BEGIN
  IF session_user <> 'postgres' OR p_project_id IS NULL THEN
    RETURN false;
  END IF;

  IF current_setting('rae.system_version',true) IS DISTINCT FROM 'v1' THEN
    RETURN false;
  END IF;

  BEGIN
    v_context_project_id :=
      nullif(current_setting('rae.system_project_id',true),'')::uuid;
    v_context_principal_id :=
      nullif(current_setting('rae.system_principal_id',true),'')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RETURN false;
  END;

  IF v_context_project_id IS DISTINCT FROM p_project_id
    OR v_context_principal_id IS NULL THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM private.system_principals sp
    JOIN public.projects p ON p.id=v_context_project_id
    WHERE sp.id=v_context_principal_id
      AND sp.principal_key='rae-core'
      AND sp.status='active'
      AND p.id=p_project_id
      AND p.status='active'
  );
END;
$function$;

REVOKE ALL ON FUNCTION private.rae_system_context_matches(uuid)
  FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.begin_rae_system_context(p_project_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog','public','auth','private'
AS $function$
DECLARE
  v_project_status text;
  v_product_owner_id uuid;
  v_principal_id uuid;
  v_existing_project text;
BEGIN
  -- The connected MCP management session is already the trusted database
  -- boundary. This context labels and constrains its RAE engineering authority;
  -- it does not manufacture an Auth JWT or expose an API to client roles.
  IF session_user <> 'postgres' THEN
    RAISE EXCEPTION USING errcode='42501',
      message='RAE_SYSTEM_ADMIN_SESSION_REQUIRED';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    RAISE EXCEPTION USING errcode='42501',
      message='RAE_SYSTEM_CONTEXT_ONLY_WHEN_AUTH_UID_NULL';
  END IF;

  IF p_project_id IS NULL THEN
    RAISE EXCEPTION USING errcode='22023',
      message='RAE_SYSTEM_CONTEXT_PROJECT_REQUIRED';
  END IF;

  v_existing_project := nullif(current_setting('rae.system_project_id',true),'');
  IF v_existing_project IS NOT NULL
     OR nullif(current_setting('rae.owner_mcp_project_id',true),'') IS NOT NULL
     OR nullif(current_setting('rae.owner_mcp_owner_id',true),'') IS NOT NULL THEN
    RAISE EXCEPTION USING errcode='42501',
      message='RAE_SYSTEM_CONTEXT_ALREADY_BOUND';
  END IF;

  SELECT p.status,p.owner_id,sp.id
  INTO v_project_status,v_product_owner_id,v_principal_id
  FROM public.projects p
  CROSS JOIN private.system_principals sp
  WHERE p.id=p_project_id
    AND sp.principal_key='rae-core'
    AND sp.status='active';

  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='55000',
      message='RAE_SYSTEM_PRINCIPAL_OR_PROJECT_UNAVAILABLE';
  END IF;

  IF v_project_status <> 'active' THEN
    RAISE EXCEPTION USING errcode='55000',
      message='PROJECT_NOT_ACTIVE';
  END IF;

  PERFORM set_config('rae.system_project_id',p_project_id::text,true);
  PERFORM set_config('rae.system_principal_id',v_principal_id::text,true);
  PERFORM set_config('rae.system_version','v1',true);

  INSERT INTO private.system_actor_audit(
    transaction_id,project_id,principal_id,product_owner_id,
    database_role,backend_pid,application_name,context_version
  )
  VALUES(
    txid_current(),p_project_id,v_principal_id,v_product_owner_id,
    session_user,pg_backend_pid(),
    coalesce(current_setting('application_name',true),''),'v1'
  )
  ON CONFLICT(transaction_id,project_id,principal_id) DO NOTHING;

  RETURN jsonb_build_object(
    'success',true,
    'data',jsonb_build_object(
      'project_id',p_project_id,
      'principal_id',v_principal_id,
      'principal_key','rae-core',
      'mode','rae_system_owner',
      'authority','project_scoped_engineering',
      'scope','current_transaction'
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION private.begin_rae_system_context(uuid)
  FROM PUBLIC,anon,authenticated;

COMMENT ON FUNCTION private.begin_rae_system_context(uuid) IS
  'Binds the active RAE system principal to exactly one active project for the current postgres MCP transaction. Does not synthesize auth.uid(); human product-owner decisions remain separately guarded.';

CREATE OR REPLACE FUNCTION private.assert_owner(p_project_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog','public','auth','private'
AS $function$
DECLARE
  v_uid uuid;
BEGIN
  v_uid:=auth.uid();

  IF v_uid IS NULL THEN
    IF private.rae_system_context_matches(p_project_id)
       OR private.owner_mcp_context_matches(p_project_id) THEN
      RETURN;
    END IF;
    RAISE EXCEPTION USING errcode='28000',message='UNAUTHENTICATED';
  END IF;

  IF NOT EXISTS(
    SELECT 1 FROM public.projects p
    WHERE p.id=p_project_id AND p.owner_id=v_uid
  ) THEN
    RAISE EXCEPTION USING errcode='42501',message='PROJECT_FORBIDDEN';
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
SET search_path TO 'pg_catalog','public','auth','private'
AS $function$
DECLARE
  v_uid uuid;
BEGIN
  v_uid:=auth.uid();

  IF v_uid IS NULL THEN
    IF private.rae_system_context_matches(p_project_id)
       OR private.owner_mcp_context_matches(p_project_id) THEN
      RETURN;
    END IF;
    RAISE EXCEPTION USING errcode='28000',message='UNAUTHENTICATED';
  END IF;

  IF EXISTS(
    SELECT 1 FROM public.projects p
    WHERE p.id=p_project_id AND p.owner_id=v_uid
  ) THEN
    RETURN;
  END IF;

  IF p_worker_id IS NULL OR NOT EXISTS(
    SELECT 1 FROM public.workers w
    WHERE w.id=p_worker_id
      AND w.project_id=p_project_id
      AND w.auth_user_id=v_uid
      AND w.status='active'
  ) THEN
    RAISE EXCEPTION USING errcode='42501',message='WORKER_IDENTITY_MISMATCH';
  END IF;
END;
$function$;

-- Explicit human-decision guard. RAE system context is intentionally excluded.
-- A real Owner JWT or the legacy Owner-MCP context bound to the real
-- projects.owner_id is required for these operations.
CREATE OR REPLACE FUNCTION private.assert_human_owner(p_project_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog','public','auth','private'
AS $function$
DECLARE
  v_uid uuid;
BEGIN
  v_uid:=auth.uid();

  IF v_uid IS NOT NULL THEN
    IF EXISTS(
      SELECT 1 FROM public.projects p
      WHERE p.id=p_project_id AND p.owner_id=v_uid
    ) THEN
      RETURN;
    END IF;
    RAISE EXCEPTION USING errcode='42501',message='PROJECT_FORBIDDEN';
  END IF;

  IF private.owner_mcp_context_matches(p_project_id) THEN
    RETURN;
  END IF;

  RAISE EXCEPTION USING errcode='28000',message='HUMAN_OWNER_DECISION_REQUIRED';
END;
$function$;

REVOKE ALL ON FUNCTION private.assert_owner(uuid)
  FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.assert_worker_actor(uuid,uuid)
  FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.assert_human_owner(uuid)
  FROM PUBLIC,anon,authenticated;

-- Preserve human authority over explicit decisions, support/resource approval,
-- and the operational pause/kill-switch. Other project-scoped engineering
-- RPCs continue to use assert_owner and now accept the RAE system principal.
DO $human_decisions$
DECLARE
  r record;
  v_definition text;
  v_replacement text;
BEGIN
  FOR r IN
    SELECT p.oid,n.nspname,p.proname
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE p.prokind='f'
      AND (
        (n.nspname='public' AND p.proname IN (
          'decide_initiative','decide_initiative_support','abandon_initiative'
        ))
        OR
        (n.nspname='private' AND p.proname='set_project_execution_controls')
      )
  LOOP
    v_definition:=pg_get_functiondef(r.oid);
    v_replacement:=replace(
      v_definition,
      'private.assert_owner(',
      'private.assert_human_owner('
    );
    IF v_replacement=v_definition THEN
      RAISE EXCEPTION 'Expected human Owner assertion missing in %.%',r.nspname,r.proname;
    END IF;
    EXECUTE v_replacement;
  END LOOP;
END;
$human_decisions$;

-- Project registration from RAE inherits the real human product owner from
-- the already-bound anchor project. It never accepts an arbitrary owner UUID.
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
SET search_path TO 'pg_catalog','public','auth','private'
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
  v_owner_id:=auth.uid();

  IF v_owner_id IS NULL THEN
    IF session_user <> 'postgres' THEN
      RAISE EXCEPTION USING errcode='28000',message='UNAUTHENTICATED';
    END IF;

    IF current_setting('rae.system_version',true)='v1' THEN
      BEGIN
        v_context_project_id:=
          nullif(current_setting('rae.system_project_id',true),'')::uuid;
      EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION USING errcode='28000',message='UNAUTHENTICATED';
      END;

      IF v_context_project_id IS NULL
         OR NOT private.rae_system_context_matches(v_context_project_id) THEN
        RAISE EXCEPTION USING errcode='28000',message='UNAUTHENTICATED';
      END IF;

      SELECT p.owner_id INTO v_owner_id
      FROM public.projects p
      WHERE p.id=v_context_project_id AND p.status='active';
      IF NOT FOUND OR v_owner_id IS NULL THEN
        RAISE EXCEPTION USING errcode='28000',message='UNAUTHENTICATED';
      END IF;
    ELSE
      IF current_setting('rae.owner_mcp_version',true) IS DISTINCT FROM 'v1' THEN
        RAISE EXCEPTION USING errcode='28000',message='UNAUTHENTICATED';
      END IF;

      BEGIN
        v_context_project_id:=
          nullif(current_setting('rae.owner_mcp_project_id',true),'')::uuid;
        v_context_owner_id:=
          nullif(current_setting('rae.owner_mcp_owner_id',true),'')::uuid;
      EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION USING errcode='28000',message='UNAUTHENTICATED';
      END;

      IF v_context_project_id IS NULL
         OR v_context_owner_id IS NULL
         OR NOT private.owner_mcp_context_matches(v_context_project_id) THEN
        RAISE EXCEPTION USING errcode='28000',message='UNAUTHENTICATED';
      END IF;
      v_owner_id:=v_context_owner_id;
    END IF;
  END IF;

  IF p_idempotency_key IS NULL OR length(btrim(p_idempotency_key))=0 THEN
    RAISE EXCEPTION USING errcode='22023',message='IDEMPOTENCY_KEY_REQUIRED';
  END IF;

  v_hash:=private.request_hash(jsonb_build_object(
    'name',p_name,
    'description',p_description,
    'github_repo',p_github_repo,
    'config',coalesce(p_config,'{}'::jsonb)
  ));

  v_seed:=md5(v_owner_id::text||':register_project:'||p_idempotency_key);
  v_id:=(
    substr(v_seed,1,8)||'-'||
    substr(v_seed,9,4)||'-4'||
    substr(v_seed,14,3)||'-a'||
    substr(v_seed,18,3)||'-'||
    substr(v_seed,21,12)
  )::uuid;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_id::text,0));

  SELECT request_hash,response
  INTO v_existing_hash,v_existing_response
  FROM public.operation_requests
  WHERE project_id=v_id
    AND operation='register_project'
    AND idempotency_key=p_idempotency_key;

  IF FOUND THEN
    IF v_existing_hash<>v_hash THEN
      RAISE EXCEPTION USING errcode='23505',message='IDEMPOTENCY_CONFLICT';
    END IF;
    RETURN v_existing_response;
  END IF;

  INSERT INTO public.projects(
    id,name,description,github_repo,config,owner_id
  )
  VALUES(
    v_id,p_name,p_description,p_github_repo,coalesce(p_config,'{}'::jsonb),v_owner_id
  )
  ON CONFLICT(id) DO NOTHING;

  IF NOT EXISTS(
    SELECT 1 FROM public.projects
    WHERE id=v_id AND owner_id=v_owner_id
  ) THEN
    RAISE EXCEPTION USING errcode='42501',message='PROJECT_FORBIDDEN';
  END IF;

  v_response:=jsonb_build_object(
    'success',true,
    'data',(SELECT to_jsonb(p) FROM public.projects p WHERE p.id=v_id)
  );

  INSERT INTO public.operation_requests(
    project_id,operation,idempotency_key,request_hash,response
  )
  VALUES(v_id,'register_project',p_idempotency_key,v_hash,v_response);

  RETURN v_response;
END;
$function$;

-- Extend only the existing project-bound Problem Inbox checks. Listing retains
-- the original owner-wide scope; report detail and mutation remain bound to
-- the one project selected for the RAE transaction.
DO $problem_inbox$
DECLARE
  r record;
  v_definition text;
  v_replacement text;
BEGIN
  FOR r IN
    SELECT p.oid,p.proname
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public'
      AND p.prokind='f'
      AND p.proname IN (
        'list_problem_reports','get_problem_report','update_problem_report'
      )
  LOOP
    v_definition:=pg_get_functiondef(r.oid);
    IF r.proname='list_problem_reports' THEN
      v_replacement:=replace(
        v_definition,
        'OR NOT private.owner_mcp_context_matches(v_context_project_id) THEN',
        'OR NOT (private.owner_mcp_context_matches(v_context_project_id) OR private.rae_system_context_matches(v_context_project_id)) THEN'
      );
    ELSE
      v_replacement:=replace(
        v_definition,
        'private.owner_mcp_context_matches(r.project_id)',
        '(private.owner_mcp_context_matches(r.project_id) OR private.rae_system_context_matches(r.project_id))'
      );
    END IF;

    IF v_replacement=v_definition THEN
      RAISE EXCEPTION 'Expected Owner-MCP Problem Inbox check missing in public.%',r.proname;
    END IF;
    EXECUTE v_replacement;
  END LOOP;
END;
$problem_inbox$;

COMMENT ON FUNCTION private.assert_owner(uuid) IS
  'Project-scoped engineering authority: authenticated human Owner, legacy verified Owner-MCP context, or active RAE system principal context. Human decision RPCs must call assert_human_owner.';
COMMENT ON FUNCTION private.assert_human_owner(uuid) IS
  'Human product/decision authority only. Accepts a real Owner JWT or the legacy transaction-bound Owner-MCP context; deliberately rejects the RAE system principal.';
COMMENT ON FUNCTION private.assert_worker_actor(uuid,uuid) IS
  'Worker execution authorization accepts the project Owner, correctly bound Worker, legacy verified Owner-MCP context, or active project-bound RAE system principal. Existing Worker route, lease, task, dependency, and execution fences remain enforced.';

COMMIT;
