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
  v_expected_config jsonb;
  v_legacy_autonomy jsonb;
  v_result jsonb;
BEGIN
  SELECT config INTO v_before FROM public.projects WHERE id=v_project;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FAIL: activation fixture project is missing';
  END IF;

  -- Malformed autonomy values must fail closed rather than being replaced with
  -- an object and silently destroying pre-existing configuration.
  FOR v_legacy_autonomy IN
    SELECT value
    FROM jsonb_array_elements('["legacy-scalar",["legacy-array"]]'::jsonb)
      AS legacy_values(value)
  LOOP
    v_expected_config := jsonb_set(
      v_before,'{autonomy}',v_legacy_autonomy,true
    );
    UPDATE public.projects SET config=v_expected_config WHERE id=v_project;

    BEGIN
      PERFORM private.set_project_task_activation(
        v_project,'active_session_autonomy',2
      );
      RAISE EXCEPTION 'FAIL: malformed autonomy config was silently overwritten: %',
        v_legacy_autonomy;
    EXCEPTION WHEN SQLSTATE '22023' THEN
      IF SQLERRM <> 'PROJECT_AUTONOMY_CONFIG_INVALID' THEN RAISE; END IF;
    END;

    SELECT config INTO v_after FROM public.projects WHERE id=v_project;
    IF v_after IS DISTINCT FROM v_expected_config THEN
      RAISE EXCEPTION 'FAIL: rejected autonomy config was modified: expected %, actual %',
        v_expected_config,v_after;
    END IF;
  END LOOP;

  -- A non-object root config is also invalid for nested project settings and
  -- must not be modified by a failed activation attempt.
  UPDATE public.projects
  SET config='"legacy-root-scalar"'::jsonb
  WHERE id=v_project;
  BEGIN
    PERFORM private.set_project_task_activation(
      v_project,'active_session_autonomy',2
    );
    RAISE EXCEPTION 'FAIL: non-object project config was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'PROJECT_CONFIG_INVALID' THEN RAISE; END IF;
  END;
  SELECT config INTO v_after FROM public.projects WHERE id=v_project;
  IF v_after IS DISTINCT FROM '"legacy-root-scalar"'::jsonb THEN
    RAISE EXCEPTION 'FAIL: rejected root config was modified: %',v_after;
  END IF;

  -- Restore the original project configuration before the positive-path tests.
  UPDATE public.projects SET config=v_before WHERE id=v_project;

  IF has_function_privilege(
       'anon','private.set_project_task_activation(uuid,text,integer)','EXECUTE'
     ) OR has_function_privilege(
       'authenticated','private.set_project_task_activation(uuid,text,integer)','EXECUTE'
     ) THEN
    RAISE EXCEPTION 'FAIL: private activation RPC is executable by anon/authenticated roles';
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
  IF ((v_after->'autonomy') - 'max_active_executions'::text)
      IS DISTINCT FROM (coalesce(v_before->'autonomy','{}'::jsonb) - 'max_active_executions'::text) THEN
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

  RAISE NOTICE 'PASS: owner-only activation mutation, project isolation, allowed modes, pause/resume, max 1..2, invalid-value rejection, malformed-config preservation, and unrelated-config preservation';
END;
$activation_config_test$;
