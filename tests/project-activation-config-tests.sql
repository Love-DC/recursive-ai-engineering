-- Owner-scoped project activation configuration tests.
-- Included inside the task lifecycle harness transaction; all fixture writes roll back.

DO $activation_config_test$
DECLARE
  v_project uuid := current_setting('test.project_id')::uuid;
  v_owner uuid := current_setting('request.jwt.claim.sub')::uuid;
  v_other_owner uuid := gen_random_uuid();
  v_other_project uuid := gen_random_uuid();
  v_before jsonb;
  v_after jsonb;
  v_result jsonb;
BEGIN
  SELECT config INTO v_before FROM public.projects WHERE id=v_project;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FAIL: activation fixture project is missing';
  END IF;

  v_result := private.set_project_task_activation(
    v_project,'active_session_autonomy',2
  );
  SELECT config INTO v_after FROM public.projects WHERE id=v_project;
  IF v_after->>'task_activation' IS DISTINCT FROM 'active_session_autonomy'
    OR v_after #>> '{autonomy,max_active_executions}' IS DISTINCT FROM '2' THEN
    RAISE EXCEPTION 'FAIL: owner could not enable bounded autonomy: %',v_after;
  END IF;
  IF (v_after - 'task_activation' - 'autonomy')
      IS DISTINCT FROM (v_before - 'task_activation' - 'autonomy') THEN
    RAISE EXCEPTION 'FAIL: activation RPC changed unrelated project config: before %, after %',v_before,v_after;
  END IF;
  IF (v_after->'autonomy' - 'max_active_executions')
      IS DISTINCT FROM (coalesce(v_before->'autonomy','{}'::jsonb) - 'max_active_executions') THEN
    RAISE EXCEPTION 'FAIL: activation RPC changed unrelated autonomy config: before %, after %',v_before,v_after;
  END IF;
  IF v_result->'data'->>'project_id' IS DISTINCT FROM v_project::text THEN
    RAISE EXCEPTION 'FAIL: activation RPC returned the wrong project: %',v_result;
  END IF;

  PERFORM private.set_project_task_activation(v_project,'active_session_autonomy',1);
  SELECT config INTO v_after FROM public.projects WHERE id=v_project;
  IF v_after #>> '{autonomy,max_active_executions}' IS DISTINCT FROM '1' THEN
    RAISE EXCEPTION 'FAIL: max_active_executions=1 was not retained: %',v_after;
  END IF;

  PERFORM private.set_project_task_activation(v_project,'paused',2);
  SELECT config INTO v_after FROM public.projects WHERE id=v_project;
  IF v_after->>'task_activation' IS DISTINCT FROM 'paused' THEN
    RAISE EXCEPTION 'FAIL: owner could not pause project task activation: %',v_after;
  END IF;

  PERFORM private.set_project_task_activation(
    v_project,'explicit_owner_authorization_only',2
  );
  SELECT config INTO v_after FROM public.projects WHERE id=v_project;
  IF v_after->>'task_activation' IS DISTINCT FROM 'explicit_owner_authorization_only' THEN
    RAISE EXCEPTION 'FAIL: owner could not restore explicit-owner mode: %',v_after;
  END IF;

  BEGIN
    PERFORM private.set_project_task_activation(v_project,'unapproved_mode',2);
    RAISE EXCEPTION 'FAIL: invalid task activation mode was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'PROJECT_TASK_ACTIVATION_INVALID' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM private.set_project_task_activation(v_project,'active_session_autonomy',3);
    RAISE EXCEPTION 'FAIL: max_active_executions above two was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'PROJECT_MAX_ACTIVE_EXECUTIONS_INVALID' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM private.set_project_task_activation(v_project,'active_session_autonomy',NULL);
    RAISE EXCEPTION 'FAIL: null max_active_executions was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'PROJECT_MAX_ACTIVE_EXECUTIONS_INVALID' THEN RAISE; END IF;
  END;

  INSERT INTO auth.users(id) VALUES(v_other_owner);
  INSERT INTO public.projects(id,name,owner_id,status,config)
  VALUES(v_other_project,'activation-isolation-test',v_other_owner,'active',
    '{"unrelated":"other-project"}'::jsonb);

  PERFORM set_config('request.jwt.claim.sub',v_other_owner::text,true);
  BEGIN
    PERFORM private.set_project_task_activation(v_project,'paused',2);
    RAISE EXCEPTION 'FAIL: non-owner changed another project activation';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    IF SQLERRM <> 'PROJECT_FORBIDDEN' THEN RAISE; END IF;
  END;

  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);
  BEGIN
    PERFORM private.set_project_task_activation(v_other_project,'paused',2);
    RAISE EXCEPTION 'FAIL: owner changed a different owner project activation';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    IF SQLERRM <> 'PROJECT_FORBIDDEN' THEN RAISE; END IF;
  END;

  SELECT config INTO v_after FROM public.projects WHERE id=v_other_project;
  IF v_after IS DISTINCT FROM '{"unrelated":"other-project"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL: cross-project activation attempt changed other project config: %',v_after;
  END IF;

  RAISE NOTICE 'PASS: owner-only activation mutation, project isolation, allowed modes, pause/resume, max 1..2, invalid-value rejection, and unrelated-config preservation';
END;
$activation_config_test$;
