-- Owner-scoped operational execution-control tests.
-- Included inside the task lifecycle harness transaction; all fixture writes roll back.
DO $execution_controls_test$
DECLARE
  v_project uuid := current_setting('test.project_id')::uuid;
  v_owner uuid := current_setting('request.jwt.claim.sub')::uuid;
  v_other_owner uuid := gen_random_uuid();
  v_other_project uuid := gen_random_uuid();
  v_before jsonb;
  v_after jsonb;
  v_expected jsonb;
  v_bad jsonb;
  v_result jsonb;
BEGIN
  SELECT config INTO v_before FROM public.projects WHERE id=v_project;
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: execution-controls fixture project is missing'; END IF;
  IF v_before ? 'task_activation' THEN RAISE EXCEPTION 'FAIL: DB still stores task_activation: %',v_before; END IF;
  IF v_before #>> '{autonomy,paused}' IS DISTINCT FROM 'true'
     OR v_before #>> '{autonomy,max_active_executions}' IS DISTINCT FROM '2' THEN
    RAISE EXCEPTION 'FAIL: migration did not default projects to paused/max-two: %',v_before;
  END IF;
  FOR v_bad IN SELECT value FROM jsonb_array_elements('["legacy-scalar",["legacy-array"]]'::jsonb) AS x(value)
  LOOP
    v_expected:=jsonb_set(v_before,'{autonomy}',v_bad,true);
    UPDATE public.projects SET config=v_expected WHERE id=v_project;
    BEGIN
      PERFORM private.set_project_execution_controls(v_project,false,2);
      RAISE EXCEPTION 'FAIL: malformed autonomy config was overwritten: %',v_bad;
    EXCEPTION WHEN SQLSTATE '22023' THEN
      IF SQLERRM <> 'PROJECT_AUTONOMY_CONFIG_INVALID' THEN RAISE; END IF;
    END;
    SELECT config INTO v_after FROM public.projects WHERE id=v_project;
    IF v_after IS DISTINCT FROM v_expected THEN RAISE EXCEPTION 'FAIL: malformed autonomy config changed: %',v_after; END IF;
  END LOOP;
  UPDATE public.projects SET config='"legacy-root-scalar"'::jsonb WHERE id=v_project;
  BEGIN
    PERFORM private.set_project_execution_controls(v_project,false,2);
    RAISE EXCEPTION 'FAIL: non-object root config was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'PROJECT_CONFIG_INVALID' THEN RAISE; END IF;
  END;
  SELECT config INTO v_after FROM public.projects WHERE id=v_project;
  IF v_after IS DISTINCT FROM '"legacy-root-scalar"'::jsonb THEN RAISE EXCEPTION 'FAIL: root config changed: %',v_after; END IF;
  UPDATE public.projects SET config=v_before WHERE id=v_project;

  v_expected:=v_before||jsonb_build_object('task_activation','active_session_autonomy');
  UPDATE public.projects SET config=v_expected WHERE id=v_project;
  BEGIN
    PERFORM private.set_project_execution_controls(v_project,false,2);
    RAISE EXCEPTION 'FAIL: DB task_activation policy key was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'PROJECT_POLICY_MUST_BE_REPOSITORY_LOCAL' THEN RAISE; END IF;
  END;
  SELECT config INTO v_after FROM public.projects WHERE id=v_project;
  IF v_after IS DISTINCT FROM v_expected THEN RAISE EXCEPTION 'FAIL: rejected DB policy key was modified: %',v_after; END IF;
  UPDATE public.projects SET config=v_before WHERE id=v_project;

  IF to_regprocedure('private.set_project_task_activation(uuid,text,integer)') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: legacy DB policy writer still exists';
  END IF;
  IF has_function_privilege('anon','private.set_project_execution_controls(uuid,boolean,integer)','EXECUTE')
     OR has_function_privilege('authenticated','private.set_project_execution_controls(uuid,boolean,integer)','EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: private controls RPC is executable by anon/authenticated';
  END IF;
  IF NOT has_function_privilege('postgres','private.set_project_execution_controls(uuid,boolean,integer)','EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: postgres cannot execute private controls RPC';
  END IF;

  v_result:=private.set_project_execution_controls(v_project,false,2);
  SELECT config INTO v_after FROM public.projects WHERE id=v_project;
  IF v_after ? 'task_activation'
     OR v_after #>> '{autonomy,paused}' IS DISTINCT FROM 'false'
     OR v_after #>> '{autonomy,max_active_executions}' IS DISTINCT FROM '2' THEN
    RAISE EXCEPTION 'FAIL: operational controls not updated: %',v_after;
  END IF;
  IF (v_after-'autonomy') IS DISTINCT FROM (v_before-'autonomy')
     OR ((v_after->'autonomy')-'paused'-'max_active_executions')
        IS DISTINCT FROM ((v_before->'autonomy')-'paused'-'max_active_executions') THEN
    RAISE EXCEPTION 'FAIL: unrelated config changed: before %, after %',v_before,v_after;
  END IF;
  IF v_result->'data'->>'project_id' IS DISTINCT FROM v_project::text THEN
    RAISE EXCEPTION 'FAIL: wrong project in RPC result: %',v_result;
  END IF;
  PERFORM private.set_project_execution_controls(v_project,false,1);
  SELECT config INTO v_after FROM public.projects WHERE id=v_project;
  IF v_after #>> '{autonomy,max_active_executions}' IS DISTINCT FROM '1' THEN RAISE EXCEPTION 'FAIL: max one not retained'; END IF;
  PERFORM private.set_project_execution_controls(v_project,true,2);
  SELECT config INTO v_after FROM public.projects WHERE id=v_project;
  IF v_after #>> '{autonomy,paused}' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'FAIL: pause flag not set'; END IF;
  BEGIN
    PERFORM private.assert_task_activation(v_project);
    RAISE EXCEPTION 'FAIL: paused project passed task guard';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM <> 'PROJECT_TASK_ACTIVATION_PAUSED' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM private.set_project_execution_controls(v_project,false,3);
    RAISE EXCEPTION 'FAIL: max above two accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'PROJECT_MAX_ACTIVE_EXECUTIONS_INVALID' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM private.set_project_execution_controls(v_project,false,NULL);
    RAISE EXCEPTION 'FAIL: null max accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'PROJECT_MAX_ACTIVE_EXECUTIONS_INVALID' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM private.set_project_execution_controls(v_project,NULL,2);
    RAISE EXCEPTION 'FAIL: null pause flag accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'PROJECT_PAUSE_FLAG_INVALID' THEN RAISE; END IF;
  END;
  UPDATE public.projects SET config=jsonb_set(config,'{autonomy}',coalesce(config->'autonomy','{}')-'paused',true) WHERE id=v_project;
  BEGIN
    PERFORM private.assert_task_activation(v_project);
    RAISE EXCEPTION 'FAIL: missing pause flag did not fail closed';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM <> 'PROJECT_AUTONOMY_CONTROLS_INVALID' THEN RAISE; END IF;
  END;
  UPDATE public.projects SET config=v_before WHERE id=v_project;

  INSERT INTO auth.users(id) VALUES(v_other_owner);
  INSERT INTO public.projects(id,name,owner_id,status,config)
  VALUES(v_other_project,'execution-controls-isolation-test',v_other_owner,'active',
    '{"autonomy":{"paused":true,"max_active_executions":2},"unrelated":"other-project"}'::jsonb);
  PERFORM set_config('request.jwt.claim.sub',v_other_owner::text,true);
  BEGIN
    PERFORM private.set_project_execution_controls(v_project,false,2);
    RAISE EXCEPTION 'FAIL: non-owner changed project controls';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    IF SQLERRM <> 'PROJECT_FORBIDDEN' THEN RAISE; END IF;
  END;
  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);
  BEGIN
    PERFORM private.set_project_execution_controls(v_other_project,false,2);
    RAISE EXCEPTION 'FAIL: owner changed another owner's project';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    IF SQLERRM <> 'PROJECT_FORBIDDEN' THEN RAISE; END IF;
  END;
  SELECT config INTO v_after FROM public.projects WHERE id=v_other_project;
  IF v_after IS DISTINCT FROM '{"autonomy":{"paused":true,"max_active_executions":2},"unrelated":"other-project"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL: cross-project config changed: %',v_after;
  END IF;
  RAISE NOTICE 'PASS: repository policy separated from DB controls; owner-only operational RPC, fail-closed pause, cap, isolation, and config preservation';
END;
$execution_controls_test$;
