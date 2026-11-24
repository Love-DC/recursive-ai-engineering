-- Narrow owner-authorized mutation for project task-activation policy.
-- Kept in the private schema: this is an MCP-only control, not a public API.
CREATE OR REPLACE FUNCTION private.set_project_task_activation(
  p_project_id uuid,
  p_task_activation text,
  p_max_active_executions integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
DECLARE
  v_project public.projects%rowtype;
  v_config jsonb;
  v_autonomy jsonb;
BEGIN
  PERFORM private.assert_owner(p_project_id);

  IF p_task_activation IS NULL
    OR p_task_activation NOT IN (
      'active_session_autonomy',
      'explicit_owner_authorization_only',
      'paused'
    ) THEN
    RAISE EXCEPTION USING errcode='22023',
      message='PROJECT_TASK_ACTIVATION_INVALID';
  END IF;

  IF p_max_active_executions IS NULL
    OR p_max_active_executions NOT BETWEEN 1 AND 2 THEN
    RAISE EXCEPTION USING errcode='22023',
      message='PROJECT_MAX_ACTIVE_EXECUTIONS_INVALID';
  END IF;

  SELECT p.* INTO v_project
  FROM public.projects p
  WHERE p.id=p_project_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='P0002',
      message='PROJECT_NOT_FOUND';
  END IF;

  IF v_project.status <> 'active' THEN
    RAISE EXCEPTION USING errcode='55000',
      message='PROJECT_NOT_ACTIVE';
  END IF;

  v_config := coalesce(v_project.config,'{}'::jsonb);
  v_autonomy := CASE
    WHEN jsonb_typeof(v_config->'autonomy')='object'
      THEN v_config->'autonomy'
    ELSE '{}'::jsonb
  END;

  v_config := jsonb_set(
    v_config,
    '{task_activation}',
    to_jsonb(p_task_activation),
    true
  );
  v_config := jsonb_set(
    v_config,
    '{autonomy}',
    v_autonomy || jsonb_build_object(
      'max_active_executions',p_max_active_executions
    ),
    true
  );

  UPDATE public.projects
  SET config=v_config,updated_at=clock_timestamp()
  WHERE id=p_project_id
  RETURNING config INTO v_config;

  RETURN jsonb_build_object(
    'success',true,
    'data',jsonb_build_object(
      'project_id',p_project_id,
      'task_activation',p_task_activation,
      'max_active_executions',p_max_active_executions,
      'config',v_config
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION private.set_project_task_activation(uuid,text,integer)
  FROM PUBLIC, anon, authenticated;
