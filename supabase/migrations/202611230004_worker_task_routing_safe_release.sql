-- Worker-key routing and fenced release v1.
-- Function-only plus a narrowly scoped, reversible routing-config seed.
-- Do not apply to production without the separate deployment gate.

CREATE OR REPLACE FUNCTION private.resolve_task_worker_keys(
  p_project_id uuid,
  p_task_type text,
  p_requirements jsonb
)
RETURNS text[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
DECLARE
  v_config jsonb;
  v_route jsonb;
  v_keys text[];
  v_active_count integer;
  v_sole_worker_key text;
  v_single_key text;
BEGIN
  SELECT p.config INTO v_config
  FROM public.projects p
  WHERE p.id=p_project_id;

  IF NOT FOUND THEN
    RETURN '{}'::text[];
  END IF;

  v_route := p_requirements->'required_worker_key';

  IF v_route IS NULL OR jsonb_typeof(v_route)='null' THEN
    v_route := v_config->'worker_routing'->'task_type_worker_keys'->p_task_type;
  END IF;

  IF v_route IS NULL OR jsonb_typeof(v_route)='null' THEN
    v_route := v_config->'worker_routing'->'default_worker_key';
  END IF;

  -- Explicit malformed/empty routes fail closed; they do not fall through.
  IF v_route IS NOT NULL AND jsonb_typeof(v_route)<>'null' THEN
    IF jsonb_typeof(v_route)='string' THEN
      v_single_key := nullif(btrim(v_route #>> '{}'),'');
      IF v_single_key IS NULL THEN
        RETURN '{}'::text[];
      END IF;
      RETURN ARRAY[v_single_key];
    ELSIF jsonb_typeof(v_route)='array' THEN
      SELECT coalesce(
        array_agg(DISTINCT btrim(value)) FILTER (WHERE btrim(value)<>''),
        '{}'::text[]
      )
      INTO v_keys
      FROM jsonb_array_elements_text(v_route);
      RETURN v_keys;
    ELSE
      RETURN '{}'::text[];
    END IF;
  END IF;

  -- Backwards compatibility is safe only when the project has exactly one
  -- active Worker. Multi-Worker projects without explicit routing are blocked.
  SELECT count(*), min(w.worker_key)
  INTO v_active_count, v_sole_worker_key
  FROM public.workers w
  WHERE w.project_id=p_project_id AND w.status='active';

  IF v_active_count=1 AND v_sole_worker_key IS NOT NULL THEN
    RETURN ARRAY[v_sole_worker_key];
  END IF;

  RETURN '{}'::text[];
END;
$function$;

REVOKE ALL ON FUNCTION private.resolve_task_worker_keys(uuid,text,jsonb)
  FROM PUBLIC, anon, authenticated;

-- Seed only projects that already have the established executor/reviewer pair.
-- Existing explicit routing values are preserved.
DO $migration$
DECLARE
  v_project record;
  v_routing jsonb;
  v_task_routes jsonb;
BEGIN
  FOR v_project IN
    SELECT p.id,p.config
    FROM public.projects p
    WHERE EXISTS (
      SELECT 1 FROM public.workers w
      WHERE w.project_id=p.id AND w.status='active' AND w.worker_key='shared-executor'
    )
    AND EXISTS (
      SELECT 1 FROM public.workers w
      WHERE w.project_id=p.id AND w.status='active' AND w.worker_key='independent-reviewer'
    )
  LOOP
    v_routing := v_project.config->'worker_routing';
    IF v_routing IS NULL THEN
      v_routing := '{}'::jsonb;
    ELSIF jsonb_typeof(v_routing)<>'object' THEN
      RAISE EXCEPTION 'Invalid worker_routing object for project %',v_project.id;
    END IF;

    v_task_routes := v_routing->'task_type_worker_keys';
    IF v_task_routes IS NULL THEN
      v_task_routes := '{}'::jsonb;
    ELSIF jsonb_typeof(v_task_routes)<>'object' THEN
      RAISE EXCEPTION 'Invalid worker_routing.task_type_worker_keys object for project %',v_project.id;
    END IF;

    IF NOT (v_routing ? 'default_worker_key') THEN
      v_routing := jsonb_set(v_routing,'{default_worker_key}','"shared-executor"'::jsonb,true);
    END IF;

    IF NOT (v_task_routes ? 'review') THEN
      v_task_routes := jsonb_set(v_task_routes,'{review}','"independent-reviewer"'::jsonb,true);
    END IF;

    v_routing := jsonb_set(v_routing,'{task_type_worker_keys}',v_task_routes,true);
    UPDATE public.projects
    SET config=jsonb_set(coalesce(config,'{}'::jsonb),'{worker_routing}',v_routing,true),
        updated_at=clock_timestamp()
    WHERE id=v_project.id;
  END LOOP;
END;
$migration$;

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
    v_response := jsonb_build_object('success',true,'data',jsonb_build_object('task',null));
    PERFORM private.idempotency_put(p_project_id,'claim_task',p_idempotency_key,v_hash,v_response);
    RETURN v_response;
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
    'lease_until',v_lease,'requirements',v_task.requirements
  ));
  PERFORM private.idempotency_put(p_project_id,'claim_task',p_idempotency_key,v_hash,v_response);
  RETURN v_response;
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_review_task(
  p_original_task_id uuid,
  p_delivery_task_id uuid,
  p_delivery_execution_id uuid,
  p_reviewer_worker_id uuid,
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
DECLARE
  v_original public.tasks%rowtype;
  v_delivery public.tasks%rowtype;
  v_exec public.executions%rowtype;
  v_reviewer_key text;
  v_allowed_worker_keys text[];
  v_hash text;
  v_replay jsonb;
  v_response jsonb;
  v_review_id uuid;
BEGIN
  SELECT * INTO v_original FROM public.tasks WHERE id=p_original_task_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='P0002',message='ORIGINAL_TASK_NOT_FOUND';
  END IF;
  PERFORM private.assert_owner(v_original.project_id);

  v_hash := private.request_hash(jsonb_build_object(
    'original_task_id',p_original_task_id,'delivery_task_id',p_delivery_task_id,
    'delivery_execution_id',p_delivery_execution_id,'reviewer_worker_id',p_reviewer_worker_id
  ));
  v_replay := private.idempotency_get(v_original.project_id,'create_review_task',p_idempotency_key,v_hash);
  IF v_replay IS NOT NULL THEN RETURN v_replay; END IF;

  SELECT * INTO v_delivery
  FROM public.tasks
  WHERE id=p_delivery_task_id AND project_id=v_original.project_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='23503',message='DELIVERY_TASK_PROJECT_MISMATCH';
  END IF;

  SELECT * INTO v_exec
  FROM public.executions
  WHERE id=p_delivery_execution_id AND task_id=p_delivery_task_id
  FOR UPDATE;
  IF NOT FOUND OR v_exec.status <> 'submitted' THEN
    RAISE EXCEPTION USING errcode='55000',message='DELIVERY_EXECUTION_NOT_SUBMITTED';
  END IF;

  IF v_original.status <> 'submitted' THEN
    RAISE EXCEPTION USING errcode='55000',message='ORIGINAL_TASK_NOT_SUBMITTED';
  END IF;
  IF v_delivery.task_type NOT IN ('implementation','fix') THEN
    RAISE EXCEPTION USING errcode='22023',message='INVALID_DELIVERY_TASK_TYPE';
  END IF;

  IF p_delivery_task_id=p_original_task_id THEN
    IF v_original.latest_delivery_task_id IS DISTINCT FROM p_original_task_id
      OR v_original.latest_delivery_execution_id IS DISTINCT FROM p_delivery_execution_id THEN
      RAISE EXCEPTION USING errcode='55000',message='DELIVERY_VERSION_NOT_CURRENT';
    END IF;
  ELSIF v_delivery.task_type <> 'fix'
    OR v_delivery.fixes_task_id IS DISTINCT FROM p_original_task_id
    OR v_original.latest_delivery_task_id IS DISTINCT FROM p_delivery_task_id
    OR v_original.latest_delivery_execution_id IS DISTINCT FROM p_delivery_execution_id THEN
    RAISE EXCEPTION USING errcode='55000',message='FIX_DELIVERY_NOT_CURRENT';
  END IF;

  SELECT w.worker_key INTO v_reviewer_key
  FROM public.workers w
  WHERE w.id=p_reviewer_worker_id
    AND w.project_id=v_original.project_id
    AND w.status='active';
  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='42501',message='REVIEWER_PROJECT_MISMATCH';
  END IF;

  v_allowed_worker_keys := private.resolve_task_worker_keys(
    v_original.project_id,'review','{}'::jsonb
  );
  IF NOT coalesce(v_reviewer_key = ANY(v_allowed_worker_keys),false) THEN
    RAISE EXCEPTION USING errcode='42501',message='REVIEWER_ROUTE_MISMATCH';
  END IF;

  IF v_exec.worker_id=p_reviewer_worker_id THEN
    RAISE EXCEPTION USING errcode='42501',message='REVIEWER_CANNOT_REVIEW_OWN_EXECUTION';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.tasks
    WHERE task_type='review'
      AND review_target_original_task_id=p_original_task_id
      AND review_target_delivery_task_id=p_delivery_task_id
      AND review_target_execution_id=p_delivery_execution_id
  ) THEN
    RAISE EXCEPTION USING errcode='23505',message='REVIEW_ALREADY_EXISTS';
  END IF;

  INSERT INTO public.tasks(
    project_id,parent_task_id,task_type,title,description,requirements,requires_review,status,
    assigned_worker_id,review_target_original_task_id,review_target_delivery_task_id,
    review_target_execution_id,created_by_worker_id
  )
  VALUES(
    v_original.project_id,p_original_task_id,'review','Review: '||v_original.title,
    'Review fixed delivery execution '||p_delivery_execution_id,
    jsonb_build_object(
      'original_task_id',p_original_task_id,
      'delivery_task_id',p_delivery_task_id,
      'delivery_execution_id',p_delivery_execution_id
    ),
    false,'pending',p_reviewer_worker_id,p_original_task_id,p_delivery_task_id,
    p_delivery_execution_id,null
  )
  RETURNING id INTO v_review_id;

  PERFORM private.add_event(v_original.project_id,v_review_id,null,p_reviewer_worker_id,
    'review_created',jsonb_build_object(
      'original_task_id',p_original_task_id,
      'delivery_task_id',p_delivery_task_id,
      'delivery_execution_id',p_delivery_execution_id
    ));

  v_response := jsonb_build_object(
    'success',true,'data',(SELECT to_jsonb(t) FROM public.tasks t WHERE t.id=v_review_id)
  );
  PERFORM private.idempotency_put(v_original.project_id,'create_review_task',p_idempotency_key,v_hash,v_response);
  RETURN v_response;
END;
$function$;

CREATE OR REPLACE FUNCTION public.release_execution(
  p_task_id uuid,
  p_execution_id uuid,
  p_worker_id uuid,
  p_reason text,
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
  v_execution public.executions%rowtype;
  v_reason text;
  v_execution_status text;
  v_hash text;
  v_replay jsonb;
  v_response jsonb;
  v_now timestamptz;
BEGIN
  SELECT t.project_id INTO v_project_id
  FROM public.tasks t
  WHERE t.id=p_task_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='P0002',message='TASK_NOT_FOUND';
  END IF;

  PERFORM private.assert_worker_actor(v_project_id,p_worker_id);

  v_reason := regexp_replace(coalesce(p_reason,''),'[[:cntrl:]]','','g');
  v_reason := regexp_replace(v_reason,
    '(?i)(bearer[[:space:]]+)[A-Za-z0-9._~+/=-]+','\1[REDACTED]','g');
  v_reason := regexp_replace(v_reason,
    '(?i)((api[_-]?key|token|secret|password)[[:space:]]*[:=][[:space:]]*)[^[:space:],;]+',
    '\1[REDACTED]','g');
  IF length(btrim(v_reason))=0 THEN
    RAISE EXCEPTION USING errcode='22023',message='RELEASE_REASON_REQUIRED';
  END IF;
  IF length(v_reason)>2000 THEN
    RAISE EXCEPTION USING errcode='22023',message='RELEASE_REASON_TOO_LONG';
  END IF;

  v_hash := private.request_hash(jsonb_build_object(
    'task_id',p_task_id,'execution_id',p_execution_id,
    'worker_id',p_worker_id,'reason',v_reason
  ));
  v_replay := private.idempotency_get(v_project_id,'release_execution',p_idempotency_key,v_hash);
  IF v_replay IS NOT NULL THEN RETURN v_replay; END IF;

  SELECT * INTO v_task
  FROM public.tasks
  WHERE id=p_task_id
  FOR UPDATE;
  IF v_task.current_execution_id IS DISTINCT FROM p_execution_id THEN
    RAISE EXCEPTION USING errcode='55000',message='EXECUTION_SUPERSEDED';
  END IF;
  IF v_task.status <> 'running' THEN
    RAISE EXCEPTION USING errcode='55000',message='TASK_NOT_RUNNING';
  END IF;

  SELECT * INTO v_execution
  FROM public.executions
  WHERE id=p_execution_id AND task_id=p_task_id
  FOR UPDATE;
  IF NOT FOUND OR v_execution.status <> 'running' THEN
    RAISE EXCEPTION USING errcode='55000',message='EXECUTION_SUPERSEDED';
  END IF;

  IF v_task.assigned_worker_id IS DISTINCT FROM p_worker_id
    OR v_execution.worker_id IS DISTINCT FROM p_worker_id THEN
    RAISE EXCEPTION USING errcode='42501',message='TASK_NOT_OWNED';
  END IF;

  v_now := clock_timestamp();
  v_execution_status := CASE
    WHEN v_task.lease_until IS NULL OR v_task.lease_until <= v_now THEN 'expired'
    ELSE 'superseded'
  END;

  UPDATE public.executions
  SET status=v_execution_status,
      error_message=left(v_reason,2000),
      result=jsonb_build_object('released',true,'reason',left(v_reason,1000)),
      finished_at=v_now
  WHERE id=p_execution_id AND task_id=p_task_id AND status='running';
  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='55000',message='EXECUTION_SUPERSEDED';
  END IF;

  UPDATE public.tasks
  SET status='pending',
      assigned_worker_id=CASE WHEN task_type='review' THEN assigned_worker_id ELSE NULL END,
      current_execution_id=NULL,
      lease_until=NULL,
      result=NULL,
      completed_at=NULL,
      updated_at=v_now
  WHERE id=p_task_id
    AND current_execution_id=p_execution_id
    AND status='running';
  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='55000',message='EXECUTION_SUPERSEDED';
  END IF;

  PERFORM private.add_event(v_project_id,p_task_id,p_execution_id,p_worker_id,
    'execution_released',jsonb_build_object('execution_status',v_execution_status));
  PERFORM private.add_event(v_project_id,p_task_id,p_execution_id,p_worker_id,
    'task_released',jsonb_build_object(
      'reason',left(v_reason,1000),
      'execution_status',v_execution_status
    ));

  v_response := jsonb_build_object('success',true,'data',jsonb_build_object(
    'task_id',p_task_id,
    'execution_id',p_execution_id,
    'status','pending',
    'execution_status',v_execution_status
  ));
  PERFORM private.idempotency_put(v_project_id,'release_execution',p_idempotency_key,v_hash,v_response);
  RETURN v_response;
END;
$function$;

REVOKE ALL ON FUNCTION public.release_execution(uuid,uuid,uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.release_execution(uuid,uuid,uuid,text,text) TO authenticated;
