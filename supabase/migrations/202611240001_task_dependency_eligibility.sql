-- Task dependency eligibility v1.
-- Function-only change. No table, RLS, project, or production-data migration.
-- Deployment is gated on independent review and separate authorization.

CREATE OR REPLACE FUNCTION private.task_dependency_blockers(
  p_project_id uuid,
  p_requirements jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
DECLARE
  v_requirements jsonb := coalesce(p_requirements, '{}'::jsonb);
  v_resolutions jsonb;
  v_dependency jsonb;
  v_resolution jsonb;
  v_evidence jsonb;
  v_key text;
  v_dependency_id uuid;
  v_actual_status text;
  v_blockers jsonb := '[]'::jsonb;
BEGIN
  IF jsonb_typeof(v_requirements) IS DISTINCT FROM 'object' THEN
    RETURN jsonb_build_array(jsonb_build_object('kind','metadata','reason','task_requirements_must_be_an_object'));
  END IF;
  v_resolutions := v_requirements->'dependency_resolutions';
  IF v_resolutions IS NOT NULL AND jsonb_typeof(v_resolutions) IS DISTINCT FROM 'object' THEN
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('kind','metadata','reason','dependency_resolutions_must_be_an_object'));
    v_resolutions := '{}'::jsonb;
  END IF;
  v_resolutions := coalesce(v_resolutions, '{}'::jsonb);

  IF v_requirements ? 'depends_on' THEN
    IF jsonb_typeof(v_requirements->'depends_on') IS DISTINCT FROM 'array' THEN
      v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('kind','metadata','reason','depends_on_must_be_an_array'));
    ELSE
      FOR v_dependency IN SELECT value FROM jsonb_array_elements(v_requirements->'depends_on')
      LOOP
        IF jsonb_typeof(v_dependency) IS DISTINCT FROM 'string' THEN
          v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('kind','external','reason','depends_on_entries_must_be_strings'));
          CONTINUE;
        END IF;
        v_key := v_dependency #>> '{}';
        IF nullif(btrim(v_key), '') IS NULL THEN
          v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('kind','external','reason','dependency_key_is_empty'));
          CONTINUE;
        END IF;
        v_resolution := v_resolutions->v_key;
        v_evidence := v_resolution->'evidence';
        IF jsonb_typeof(v_resolution) IS DISTINCT FROM 'object'
          OR v_resolution->>'status' IS DISTINCT FROM 'satisfied'
          OR jsonb_typeof(v_evidence) IS DISTINCT FROM 'object'
          OR nullif(btrim(v_evidence->>'ref'), '') IS NULL
          OR nullif(btrim(v_evidence->>'observed_state'), '') IS NULL THEN
          v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('kind','external','key',v_key,'reason','dependency_not_resolved_with_evidence'));
        END IF;
      END LOOP;
    END IF;
  END IF;

  IF v_requirements ? 'dependencies' THEN
    IF jsonb_typeof(v_requirements->'dependencies') IS DISTINCT FROM 'array' THEN
      v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('kind','metadata','reason','dependencies_must_be_an_array'));
    ELSE
      FOR v_dependency IN SELECT value FROM jsonb_array_elements(v_requirements->'dependencies')
      LOOP
        IF jsonb_typeof(v_dependency) IS DISTINCT FROM 'object' THEN
          v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('kind','metadata','reason','dependency_entries_must_be_objects'));
          CONTINUE;
        END IF;
        IF v_dependency->>'type'='external' THEN
          v_key := v_dependency->>'key';
          IF nullif(btrim(v_key), '') IS NULL THEN
            v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('kind','external','reason','external_dependency_key_is_missing'));
            CONTINUE;
          END IF;
          v_resolution := v_resolutions->v_key;
          v_evidence := v_resolution->'evidence';
          IF jsonb_typeof(v_resolution) IS DISTINCT FROM 'object'
            OR v_resolution->>'status' IS DISTINCT FROM 'satisfied'
            OR jsonb_typeof(v_evidence) IS DISTINCT FROM 'object'
            OR nullif(btrim(v_evidence->>'ref'), '') IS NULL
            OR nullif(btrim(v_evidence->>'observed_state'), '') IS NULL THEN
            v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('kind','external','key',v_key,'reason','dependency_not_resolved_with_evidence'));
          END IF;
        ELSIF v_dependency->>'type'='task' THEN
          IF coalesce(v_dependency->>'required_status','accepted') <> 'accepted' THEN
            v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('kind','task','task_id',v_dependency->>'task_id','reason','only_accepted_task_prerequisites_are_supported'));
            CONTINUE;
          END IF;
          v_key := v_dependency->>'task_id';
          IF v_key IS NULL OR v_key !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
            v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('kind','task','reason','task_dependency_id_is_not_a_uuid'));
            CONTINUE;
          END IF;
          v_dependency_id := v_key::uuid;
          v_actual_status := NULL;
          SELECT t.status INTO v_actual_status FROM public.tasks t
          WHERE t.id=v_dependency_id AND t.project_id=p_project_id;
          IF v_actual_status IS DISTINCT FROM 'accepted' THEN
            v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
              'kind','task','task_id',v_dependency_id,'required_status','accepted',
              'actual_status',v_actual_status,
              'reason',CASE WHEN v_actual_status IS NULL THEN 'task_prerequisite_missing_or_cross_project' ELSE 'task_prerequisite_not_accepted' END
            ));
          END IF;
        ELSE
          v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('kind','metadata','reason','dependency_type_must_be_task_or_external'));
        END IF;
      END LOOP;
    END IF;
  END IF;
  RETURN v_blockers;
END;
$function$;

REVOKE ALL ON FUNCTION private.task_dependency_blockers(uuid,jsonb) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.claim_task(
  p_project_id uuid,
  p_worker_id uuid,
  p_lease_seconds integer,
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
DECLARE
  v_task public.tasks%rowtype;
  v_exec_id uuid;
  v_attempt integer;
  v_lease timestamptz;
  v_hash text;
  v_replay jsonb;
  v_response jsonb;
  v_now timestamptz;
  v_expired record;
  v_worker_key text;
  v_dependency_blockers jsonb := '[]'::jsonb;
  v_blocked record;
  v_last_dependency_event_type text;
  v_last_dependency_event_payload jsonb;
BEGIN
  PERFORM private.assert_worker_actor(p_project_id,p_worker_id);

  SELECT w.worker_key INTO v_worker_key
  FROM public.workers w
  WHERE w.id=p_worker_id AND w.project_id=p_project_id AND w.status='active';

  IF NOT FOUND OR v_worker_key IS NULL THEN
    RAISE EXCEPTION USING errcode='42501', message='WORKER_PROJECT_MISMATCH';
  END IF;

  IF p_lease_seconds < 60 OR p_lease_seconds > 600 THEN
    RAISE EXCEPTION USING errcode='22023', message='LEASE_SECONDS_OUT_OF_RANGE';
  END IF;

  v_hash := private.request_hash(jsonb_build_object(
    'project_id',p_project_id,'worker_id',p_worker_id,'lease_seconds',p_lease_seconds
  ));
  v_replay := private.idempotency_get(p_project_id,'claim_task',p_idempotency_key,v_hash);
  IF v_replay IS NOT NULL THEN RETURN v_replay; END IF;
  v_now := clock_timestamp();

  -- Record current dependency blockers without changing task/execution status.
  FOR v_blocked IN
    SELECT t.id,private.task_dependency_blockers(t.project_id,t.requirements) AS blockers
    FROM public.tasks t
    WHERE t.project_id=p_project_id
      AND v_worker_key = ANY(private.resolve_task_worker_keys(t.project_id,t.task_type,t.requirements))
      AND (t.status='pending' OR (t.status='running' AND t.lease_until < v_now))
      AND (t.task_type <> 'review' OR t.assigned_worker_id=p_worker_id)
      AND private.task_dependency_blockers(t.project_id,t.requirements) <> '[]'::jsonb
    ORDER BY t.priority ASC,t.created_at ASC
    FOR UPDATE OF t SKIP LOCKED
    LIMIT 25
  LOOP
    SELECT te.event_type,te.payload INTO v_last_dependency_event_type,v_last_dependency_event_payload
    FROM public.task_events te
    WHERE te.project_id=p_project_id AND te.task_id=v_blocked.id
      AND te.event_type IN ('dependency_blocked','dependency_unblocked')
    ORDER BY te.id DESC LIMIT 1;
    IF v_last_dependency_event_type IS DISTINCT FROM 'dependency_blocked'
      OR v_last_dependency_event_payload->'blockers' IS DISTINCT FROM v_blocked.blockers THEN
      PERFORM private.add_event(p_project_id,v_blocked.id,NULL,p_worker_id,'dependency_blocked',
        jsonb_build_object('blockers',v_blocked.blockers));
    END IF;
    v_dependency_blockers := v_dependency_blockers || jsonb_build_array(
      jsonb_build_object('task_id',v_blocked.id,'blockers',v_blocked.blockers));
  END LOOP;


  -- Only a Worker eligible for the task's route may terminally expire it.
  FOR v_expired IN
    SELECT t.id,t.current_execution_id,e.worker_id,e.attempt,
      CASE
        WHEN (t.requirements #>> '{retry,max_attempts}') ~ '^[1-9][0-9]?$'
        THEN CASE WHEN (t.requirements #>> '{retry,max_attempts}')::integer BETWEEN 1 AND 10
          THEN (t.requirements #>> '{retry,max_attempts}')::integer ELSE 3 END
        ELSE 3
      END AS max_attempts
    FROM public.tasks t
    JOIN public.executions e ON e.id=t.current_execution_id AND e.task_id=t.id
    WHERE t.project_id=p_project_id
      AND t.status='running'
      AND t.lease_until < v_now
      AND private.task_dependency_blockers(t.project_id,t.requirements) = '[]'::jsonb
      AND v_worker_key = ANY(private.resolve_task_worker_keys(t.project_id,t.task_type,t.requirements))
      AND (t.task_type <> 'review' OR t.assigned_worker_id=p_worker_id)
    FOR UPDATE OF t SKIP LOCKED
  LOOP
    IF v_expired.attempt >= v_expired.max_attempts THEN
      UPDATE public.executions SET status='expired',finished_at=v_now
        WHERE id=v_expired.current_execution_id AND task_id=v_expired.id AND status='running';
      UPDATE public.tasks
        SET status='failed',
            assigned_worker_id=CASE WHEN task_type='review' THEN assigned_worker_id ELSE NULL END,
            current_execution_id=NULL,lease_until=NULL,
            result=jsonb_build_object('error_code','LEASE_RETRY_LIMIT_REACHED'),
            updated_at=v_now,completed_at=v_now
        WHERE id=v_expired.id AND status='running';
      PERFORM private.add_event(p_project_id,v_expired.id,v_expired.current_execution_id,
        v_expired.worker_id,'execution_expired',jsonb_build_object('reason','retry_limit_reached'));
      PERFORM private.add_event(p_project_id,v_expired.id,v_expired.current_execution_id,
        v_expired.worker_id,'task_failed',jsonb_build_object(
          'error_code','LEASE_RETRY_LIMIT_REACHED','attempt',v_expired.attempt,
          'max_attempts',v_expired.max_attempts
        ));
    END IF;
  END LOOP;

  SELECT t.* INTO v_task
  FROM public.tasks t
  WHERE t.project_id=p_project_id
    AND v_worker_key = ANY(private.resolve_task_worker_keys(t.project_id,t.task_type,t.requirements))
    AND private.task_dependency_blockers(t.project_id,t.requirements) = '[]'::jsonb
    AND (
      (
        t.status='pending'
        AND (t.assigned_worker_id IS NULL OR t.assigned_worker_id=p_worker_id)
      )
      OR
      (
        t.status='running'
        AND t.lease_until < v_now
        AND (
          CASE
            WHEN (t.requirements #>> '{retry,backoff_seconds}') ~ '^[0-9]{1,5}$'
            THEN CASE WHEN (t.requirements #>> '{retry,backoff_seconds}')::integer BETWEEN 0 AND 86400
              THEN (t.requirements #>> '{retry,backoff_seconds}')::integer ELSE 0 END
            ELSE 0
          END
        ) <= extract(epoch FROM (v_now-t.lease_until))
      )
    )
    AND (t.task_type <> 'review' OR t.assigned_worker_id=p_worker_id)
  ORDER BY t.priority ASC,t.created_at ASC
  FOR UPDATE OF t SKIP LOCKED
  LIMIT 1;

  IF NOT FOUND THEN
    v_response := jsonb_build_object('success',true,'data',jsonb_build_object('task',null,'dependency_blockers',v_dependency_blockers));
    PERFORM private.idempotency_put(p_project_id,'claim_task',p_idempotency_key,v_hash,v_response);
    RETURN v_response;
  END IF;

  SELECT te.event_type,te.payload INTO v_last_dependency_event_type,v_last_dependency_event_payload
  FROM public.task_events te
  WHERE te.project_id=p_project_id AND te.task_id=v_task.id
    AND te.event_type IN ('dependency_blocked','dependency_unblocked')
  ORDER BY te.id DESC LIMIT 1;
  IF v_last_dependency_event_type='dependency_blocked' THEN
    PERFORM private.add_event(p_project_id,v_task.id,NULL,p_worker_id,'dependency_unblocked',
      jsonb_build_object('resolved_blockers',v_last_dependency_event_payload->'blockers'));
  END IF;

  IF v_task.status='running' THEN
    UPDATE public.executions SET status='expired',finished_at=v_now
      WHERE id=v_task.current_execution_id AND task_id=v_task.id AND status='running';
    PERFORM private.add_event(p_project_id,v_task.id,v_task.current_execution_id,
      v_task.assigned_worker_id,'execution_expired','{}'::jsonb);
  END IF;

  SELECT coalesce(max(attempt),0)+1 INTO v_attempt
  FROM public.executions WHERE task_id=v_task.id;

  INSERT INTO public.executions(task_id,worker_id,attempt,status,heartbeat_at)
  VALUES(v_task.id,p_worker_id,v_attempt,'running',v_now)
  RETURNING id INTO v_exec_id;

  v_lease := v_now+make_interval(secs=>p_lease_seconds);
  UPDATE public.tasks
  SET status='running',assigned_worker_id=p_worker_id,
      current_execution_id=v_exec_id,lease_until=v_lease,updated_at=v_now
  WHERE id=v_task.id;

  PERFORM private.add_event(p_project_id,v_task.id,v_exec_id,p_worker_id,
    'task_claimed',jsonb_build_object('attempt',v_attempt));
  PERFORM private.add_event(p_project_id,v_task.id,v_exec_id,p_worker_id,
    'execution_started',jsonb_build_object('attempt',v_attempt));

  v_response := jsonb_build_object('success',true,'data',jsonb_build_object(
    'task_id',v_task.id,'execution_id',v_exec_id,'attempt',v_attempt,
    'lease_until',v_lease,'requirements',v_task.requirements,
    'dependency_blockers',v_dependency_blockers
  ));
  PERFORM private.idempotency_put(p_project_id,'claim_task',p_idempotency_key,v_hash,v_response);
  RETURN v_response;
END;
$function$;
CREATE OR REPLACE FUNCTION public.resolve_task_dependency(
  p_task_id uuid,
  p_dependency_key text,
  p_state text,
  p_evidence jsonb,
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
DECLARE
  v_project_id uuid;
  v_task public.tasks%rowtype;
  v_requirements jsonb;
  v_resolutions jsonb;
  v_resolution jsonb;
  v_declared boolean := false;
  v_hash text;
  v_replay jsonb;
  v_response jsonb;
  v_now timestamptz;
BEGIN
  SELECT t.project_id INTO v_project_id FROM public.tasks t WHERE t.id=p_task_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING errcode='P0002',message='TASK_NOT_FOUND'; END IF;
  PERFORM private.assert_owner(v_project_id);
  SELECT * INTO v_task FROM public.tasks t WHERE t.id=p_task_id FOR UPDATE;

  IF nullif(btrim(coalesce(p_dependency_key,'')), '') IS NULL THEN
    RAISE EXCEPTION USING errcode='22023',message='DEPENDENCY_KEY_REQUIRED';
  END IF;
  IF p_state IS NULL OR p_state NOT IN ('satisfied','unresolved') THEN
    RAISE EXCEPTION USING errcode='22023',message='INVALID_DEPENDENCY_STATE';
  END IF;
  IF jsonb_typeof(p_evidence) IS DISTINCT FROM 'object' OR octet_length(p_evidence::text)>8192 THEN
    RAISE EXCEPTION USING errcode='22023',message='INVALID_DEPENDENCY_EVIDENCE';
  END IF;
  IF p_state='satisfied' THEN
    IF nullif(btrim(p_evidence->>'ref'), '') IS NULL OR nullif(btrim(p_evidence->>'observed_state'), '') IS NULL THEN
      RAISE EXCEPTION USING errcode='22023',message='SATISFIED_DEPENDENCY_REQUIRES_EVIDENCE';
    END IF;
  ELSIF nullif(btrim(p_evidence->>'reason'), '') IS NULL THEN
    RAISE EXCEPTION USING errcode='22023',message='UNRESOLVED_DEPENDENCY_REQUIRES_REASON';
  END IF;

  v_requirements := coalesce(v_task.requirements,'{}'::jsonb);
  IF jsonb_typeof(v_requirements) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION USING errcode='22023',message='TASK_REQUIREMENTS_MUST_BE_OBJECT';
  END IF;
  IF jsonb_typeof(v_requirements->'depends_on')='array' THEN
    SELECT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_requirements->'depends_on') item(value)
      WHERE jsonb_typeof(item.value)='string' AND item.value #>> '{}'=p_dependency_key
    ) INTO v_declared;
  END IF;
  IF NOT v_declared AND jsonb_typeof(v_requirements->'dependencies')='array' THEN
    SELECT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_requirements->'dependencies') item(value)
      WHERE jsonb_typeof(item.value)='object' AND item.value->>'type'='external'
        AND item.value->>'key'=p_dependency_key
    ) INTO v_declared;
  END IF;
  IF NOT v_declared THEN RAISE EXCEPTION USING errcode='22023',message='DEPENDENCY_NOT_DECLARED'; END IF;

  v_hash := private.request_hash(jsonb_build_object(
    'task_id',p_task_id,'dependency_key',p_dependency_key,'state',p_state,'evidence',p_evidence
  ));
  v_replay := private.idempotency_get(v_project_id,'resolve_task_dependency',p_idempotency_key,v_hash);
  IF v_replay IS NOT NULL THEN RETURN v_replay; END IF;

  v_resolutions := v_requirements->'dependency_resolutions';
  IF v_resolutions IS NULL OR jsonb_typeof(v_resolutions)='null' THEN
    v_resolutions := '{}'::jsonb;
  ELSIF jsonb_typeof(v_resolutions) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION USING errcode='22023',message='DEPENDENCY_RESOLUTIONS_MUST_BE_OBJECT';
  END IF;
  v_now := clock_timestamp();
  v_resolution := jsonb_build_object('status',p_state,'evidence',p_evidence,'resolved_at',v_now);
  v_resolutions := jsonb_set(v_resolutions,ARRAY[p_dependency_key],v_resolution,true);
  v_requirements := jsonb_set(v_requirements,'{dependency_resolutions}',v_resolutions,true);
  UPDATE public.tasks SET requirements=v_requirements,updated_at=v_now
  WHERE id=p_task_id AND project_id=v_project_id;
  PERFORM private.add_event(
    v_project_id,p_task_id,NULL,NULL,
    CASE WHEN p_state='satisfied' THEN 'dependency_resolved' ELSE 'dependency_reopened' END,
    jsonb_build_object('dependency_key',p_dependency_key,'state',p_state,'evidence',p_evidence)
  );
  v_response := jsonb_build_object('success',true,'data',jsonb_build_object(
    'task_id',p_task_id,'dependency_key',p_dependency_key,'status',p_state,'resolved_at',v_now
  ));
  PERFORM private.idempotency_put(v_project_id,'resolve_task_dependency',p_idempotency_key,v_hash,v_response);
  RETURN v_response;
END;
$function$;

REVOKE ALL ON FUNCTION public.resolve_task_dependency(uuid,text,text,jsonb,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_task_dependency(uuid,text,text,jsonb,text) TO authenticated;
