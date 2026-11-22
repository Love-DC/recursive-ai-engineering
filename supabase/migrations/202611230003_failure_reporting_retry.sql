-- Fenced Worker failure reporting and owner-controlled bounded retry.
-- Function-only migration: no table/schema/RLS changes. Do not apply to production
-- without separate explicit deployment authorization.

CREATE OR REPLACE FUNCTION public.fail_execution(
  p_task_id uuid,
  p_execution_id uuid,
  p_worker_id uuid,
  p_error_code text,
  p_error_message text,
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
DECLARE
  v_task public.tasks%rowtype;
  v_project uuid;
  v_hash text;
  v_replay jsonb;
  v_response jsonb;
  v_now timestamptz;
  v_error_code text;
  v_error_message text;
  v_failure jsonb;
BEGIN
  SELECT * INTO v_task FROM public.tasks WHERE id=p_task_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='P0002', message='TASK_NOT_FOUND';
  END IF;

  PERFORM private.assert_worker_actor(v_task.project_id,p_worker_id);

  v_error_code := upper(btrim(coalesce(p_error_code,'')));
  v_error_message := regexp_replace(coalesce(p_error_message,''),'[[:cntrl:]]','','g');
  v_error_message := regexp_replace(v_error_message,
    '(?i)(bearer[[:space:]]+)[A-Za-z0-9._~+/=-]+','\\1[REDACTED]','g');
  v_error_message := regexp_replace(v_error_message,
    '(?i)((api[_-]?key|token|secret|password)[[:space:]]*[:=][[:space:]]*)[^[:space:],;]+',
    '\\1[REDACTED]','g');
  IF v_error_code !~ '^[A-Z0-9_]{1,64}
  v_replay := private.idempotency_get(v_task.project_id,'fail_execution',p_idempotency_key,v_hash);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;

  -- Locks the task and execution and rejects stale, expired, mismatched or
  -- non-running executions before any state transition.
  PERFORM private.assert_current_execution(p_task_id,p_execution_id,p_worker_id);
  SELECT * INTO v_task FROM public.tasks WHERE id=p_task_id;
  v_now := clock_timestamp();

  v_failure := jsonb_build_object('error_code',v_error_code,'message',v_error_message);
  UPDATE public.executions
    SET status='failed', error_message=v_error_message, result=v_failure, finished_at=v_now
    WHERE id=p_execution_id AND task_id=p_task_id AND status='running';
  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='55000', message='EXECUTION_SUPERSEDED';
  END IF;

  UPDATE public.tasks
    SET status='failed', result=v_failure, current_execution_id=NULL, lease_until=NULL,
        updated_at=v_now, completed_at=v_now
    WHERE id=p_task_id AND current_execution_id=p_execution_id AND status='running';
  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='55000', message='TASK_NOT_RUNNING';
  END IF;

  PERFORM private.add_event(v_task.project_id,p_task_id,p_execution_id,p_worker_id,
    'execution_failed',jsonb_build_object('error_code',v_error_code));
  PERFORM private.add_event(v_task.project_id,p_task_id,p_execution_id,p_worker_id,
    'task_failed',jsonb_build_object('error_code',v_error_code));

  v_response := jsonb_build_object('success',true,'data',jsonb_build_object(
    'task_id',p_task_id,'execution_id',p_execution_id,'status','failed',
    'error_code',v_error_code
  ));
  PERFORM private.idempotency_put(v_task.project_id,'fail_execution',p_idempotency_key,v_hash,v_response);
  RETURN v_response;
END;
$function$;


CREATE OR REPLACE FUNCTION public.requeue_failed_task(
  p_task_id uuid,
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
  v_task public.tasks%rowtype;
  v_hash text;
  v_replay jsonb;
  v_response jsonb;
  v_now timestamptz;
  v_attempt integer;
  v_max_attempts integer;
  v_last_finished timestamptz;
  v_reason text;
BEGIN
  SELECT project_id INTO v_project FROM public.tasks WHERE id=p_task_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='P0002', message='TASK_NOT_FOUND';
  END IF;

  -- Authorize before acquiring the task row lock.
  PERFORM private.assert_owner(v_project);
  SELECT * INTO v_task FROM public.tasks WHERE id=p_task_id FOR UPDATE;
  IF p_worker_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.workers
    WHERE id=p_worker_id AND project_id=v_task.project_id AND status='active'
  ) THEN
    RAISE EXCEPTION USING errcode='42501', message='WORKER_PROJECT_MISMATCH';
  END IF;

  v_reason := regexp_replace(coalesce(p_reason,''),'[[:cntrl:]]','','g');
  v_reason := regexp_replace(v_reason,
    '(?i)(bearer[[:space:]]+)[A-Za-z0-9._~+/=-]+','\\1[REDACTED]','g');
  v_reason := regexp_replace(v_reason,
    '(?i)((api[_-]?key|token|secret|password)[[:space:]]*[:=][[:space:]]*)[^[:space:],;]+',
    '\\1[REDACTED]','g');
  IF length(btrim(v_reason))=0 THEN
    RAISE EXCEPTION USING errcode='22023', message='REQUEUE_REASON_REQUIRED';
  END IF;

  IF length(v_reason)>2000 THEN
    RAISE EXCEPTION USING errcode='22023', message='REQUEUE_REASON_TOO_LONG';
  END IF;
  v_hash := private.request_hash(jsonb_build_object(
    'task_id',p_task_id,'worker_id',p_worker_id,'reason',v_reason
  ));
  v_reason := left(v_reason,1000);
  v_replay := private.idempotency_get(v_task.project_id,'requeue_failed_task',p_idempotency_key,v_hash);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;

  IF v_task.status <> 'failed' OR v_task.current_execution_id IS NOT NULL OR v_task.lease_until IS NOT NULL THEN
    RAISE EXCEPTION USING errcode='55000', message='TASK_NOT_FAILED';
  END IF;

  v_max_attempts := coalesce(nullif(v_task.requirements #>> '{retry,max_attempts}','')::integer,3);
  v_backoff_seconds := coalesce(nullif(v_task.requirements #>> '{retry,backoff_seconds}','')::integer,0);
  IF v_max_attempts < 1 OR v_max_attempts > 10 OR v_backoff_seconds < 0 OR v_backoff_seconds > 86400 THEN
    RAISE EXCEPTION USING errcode='22023', message='INVALID_RETRY_POLICY';
  END IF;

  SELECT coalesce(max(attempt),0), max(finished_at)
    INTO v_attempt,v_last_finished
    FROM public.executions WHERE task_id=p_task_id;
  IF v_attempt >= v_max_attempts THEN
    RAISE EXCEPTION USING errcode='55000', message='RETRY_LIMIT_REACHED';
  END IF;
  IF v_last_finished IS NOT NULL
     AND v_last_finished + make_interval(secs=>v_backoff_seconds) > clock_timestamp() THEN
    RAISE EXCEPTION USING errcode='55000', message='RETRY_BACKOFF_ACTIVE';
  END IF;

  v_now := clock_timestamp();
  UPDATE public.tasks
    SET status='pending', assigned_worker_id=NULL, current_execution_id=NULL,
        lease_until=NULL, result=NULL, completed_at=NULL, updated_at=v_now
    WHERE id=p_task_id AND status='failed';

  PERFORM private.add_event(v_task.project_id,p_task_id,NULL,p_worker_id,'task_requeued',
    jsonb_build_object('reason',v_reason,'previous_attempts',v_attempt,'max_attempts',v_max_attempts,
      'backoff_seconds',v_backoff_seconds));

  v_response := jsonb_build_object('success',true,'data',jsonb_build_object(
    'task_id',p_task_id,'status','pending','previous_attempts',v_attempt,
    'max_attempts',v_max_attempts
  ));
  PERFORM private.idempotency_put(v_task.project_id,'requeue_failed_task',p_idempotency_key,v_hash,v_response);
  RETURN v_response;
END;
$function$;


-- Bound automatic lease-expiry recovery as well as explicit failed-task retries.
-- Expired attempts at the configured limit become terminal failed tasks; otherwise
-- claim_task reclaims only after the configured lease-expiry backoff has elapsed.
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
BEGIN
  PERFORM private.assert_worker_actor(p_project_id,p_worker_id);
  IF p_lease_seconds < 60 OR p_lease_seconds > 600 THEN
    RAISE EXCEPTION USING errcode='22023', message='LEASE_SECONDS_OUT_OF_RANGE';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.workers
    WHERE id=p_worker_id AND project_id=p_project_id AND status='active'
  ) THEN
    RAISE EXCEPTION USING errcode='42501', message='WORKER_PROJECT_MISMATCH';
  END IF;

  v_hash := private.request_hash(jsonb_build_object(
    'project_id',p_project_id,'worker_id',p_worker_id,'lease_seconds',p_lease_seconds
  ));
  v_replay := private.idempotency_get(p_project_id,'claim_task',p_idempotency_key,v_hash);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;
  v_now := clock_timestamp();

  -- A lease-expired execution cannot be retried forever. Resolve attempts at
  -- their configured cap before selecting the next claimable task.
  FOR v_expired IN
    SELECT t.id,t.current_execution_id,e.worker_id,e.attempt,
      CASE
        WHEN (t.requirements #>> '{retry,max_attempts}') ~ '^[1-9][0-9]*(uuid,uuid,uuid,text,text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fail_execution(uuid,uuid,uuid,text,text,text) TO authenticated;
REVOKE ALL ON FUNCTION public.requeue_failed_task(uuid,uuid,text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.requeue_failed_task(uuid,uuid,text,text) TO authenticated;

         AND (t.requirements #>> '{retry,max_attempts}')::integer BETWEEN 1 AND 10
        THEN (t.requirements #>> '{retry,max_attempts}')::integer
        ELSE 3
      END AS max_attempts
    FROM public.tasks t
    JOIN public.executions e ON e.id=t.current_execution_id AND e.task_id=t.id
    WHERE t.project_id=p_project_id
      AND t.status='running'
      AND t.lease_until < v_now
      AND (t.task_type <> 'review' OR t.assigned_worker_id=p_worker_id)
    FOR UPDATE OF t SKIP LOCKED
  LOOP
    IF v_expired.attempt >= v_expired.max_attempts THEN
      UPDATE public.executions
        SET status='expired',finished_at=v_now
        WHERE id=v_expired.current_execution_id AND task_id=v_expired.id AND status='running';
      UPDATE public.tasks
        SET status='failed',assigned_worker_id=NULL,current_execution_id=NULL,lease_until=NULL,
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

  SELECT * INTO v_task FROM public.tasks t
  WHERE t.project_id=p_project_id
    AND (
      (t.status='pending' AND (t.assigned_worker_id IS NULL OR t.assigned_worker_id=p_worker_id))
      OR
      (t.status='running' AND t.lease_until < v_now
        AND (
          CASE
            WHEN (t.requirements #>> '{retry,backoff_seconds}') ~ '^[0-9]+(uuid,uuid,uuid,text,text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fail_execution(uuid,uuid,uuid,text,text,text) TO authenticated;
REVOKE ALL ON FUNCTION public.requeue_failed_task(uuid,uuid,text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.requeue_failed_task(uuid,uuid,text,text) TO authenticated;

             AND (t.requirements #>> '{retry,backoff_seconds}')::integer BETWEEN 0 AND 86400
            THEN (t.requirements #>> '{retry,backoff_seconds}')::integer
            ELSE 0
          END
        ) <= extract(epoch FROM (v_now - t.lease_until))
        AND (t.task_type <> 'review' OR t.assigned_worker_id=p_worker_id))
    )
    AND (t.task_type <> 'review' OR t.assigned_worker_id=p_worker_id)
  ORDER BY t.priority ASC,t.created_at ASC
  FOR UPDATE SKIP LOCKED
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
  UPDATE public.tasks SET status='running',assigned_worker_id=p_worker_id,
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

REVOKE ALL ON FUNCTION public.fail_execution(uuid,uuid,uuid,text,text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fail_execution(uuid,uuid,uuid,text,text,text) TO authenticated;
REVOKE ALL ON FUNCTION public.requeue_failed_task(uuid,uuid,text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.requeue_failed_task(uuid,uuid,text,text) TO authenticated;
 THEN
    RAISE EXCEPTION USING errcode='22023', message='INVALID_ERROR_CODE';
  END IF;
  IF length(btrim(v_error_message))=0 THEN
    RAISE EXCEPTION USING errcode='22023', message='ERROR_MESSAGE_REQUIRED';
  END IF;
  IF length(v_error_message)>4000 THEN
    RAISE EXCEPTION USING errcode='22023', message='ERROR_MESSAGE_TOO_LONG';
  END IF;

  v_hash := private.request_hash(jsonb_build_object(
    'task_id',p_task_id,
    'execution_id',p_execution_id,
    'worker_id',p_worker_id,
    'error_code',v_error_code,
    'error_message',v_error_message
  ));
  v_error_message := left(v_error_message,2000);
  v_replay := private.idempotency_get(v_task.project_id,'fail_execution',p_idempotency_key,v_hash);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;

  -- Locks the task and execution and rejects stale, expired, mismatched or
  -- non-running executions before any state transition.
  PERFORM private.assert_current_execution(p_task_id,p_execution_id,p_worker_id);
  SELECT * INTO v_task FROM public.tasks WHERE id=p_task_id;
  v_now := clock_timestamp();

  v_failure := jsonb_build_object('error_code',v_error_code,'message',v_error_message);
  UPDATE public.executions
    SET status='failed', error_message=v_error_message, result=v_failure, finished_at=v_now
    WHERE id=p_execution_id AND task_id=p_task_id AND status='running';
  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='55000', message='EXECUTION_SUPERSEDED';
  END IF;

  UPDATE public.tasks
    SET status='failed', result=v_failure, current_execution_id=NULL, lease_until=NULL,
        updated_at=v_now, completed_at=v_now
    WHERE id=p_task_id AND current_execution_id=p_execution_id AND status='running';
  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='55000', message='TASK_NOT_RUNNING';
  END IF;

  PERFORM private.add_event(v_task.project_id,p_task_id,p_execution_id,p_worker_id,
    'execution_failed',jsonb_build_object('error_code',v_error_code,'message',v_error_message));
  PERFORM private.add_event(v_task.project_id,p_task_id,p_execution_id,p_worker_id,
    'task_failed',jsonb_build_object('error_code',v_error_code));

  v_response := jsonb_build_object('success',true,'data',jsonb_build_object(
    'task_id',p_task_id,'execution_id',p_execution_id,'status','failed',
    'error_code',v_error_code
  ));
  PERFORM private.idempotency_put(v_task.project_id,'fail_execution',p_idempotency_key,v_hash,v_response);
  RETURN v_response;
END;
$function$;


CREATE OR REPLACE FUNCTION public.requeue_failed_task(
  p_task_id uuid,
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
  v_task public.tasks%rowtype;
  v_hash text;
  v_replay jsonb;
  v_response jsonb;
  v_now timestamptz;
  v_attempt integer;
  v_max_attempts integer;
  v_backoff_seconds integer;
  v_last_finished timestamptz;
  v_reason text;
BEGIN
  SELECT * INTO v_task FROM public.tasks WHERE id=p_task_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='P0002', message='TASK_NOT_FOUND';
  END IF;

  -- Retry is an owner decision; a Worker identity is recorded only for audit.
  PERFORM private.assert_owner(v_task.project_id);
  IF p_worker_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.workers
    WHERE id=p_worker_id AND project_id=v_task.project_id AND status='active'
  ) THEN
    RAISE EXCEPTION USING errcode='42501', message='WORKER_PROJECT_MISMATCH';
  END IF;

  v_reason := left(regexp_replace(coalesce(p_reason,''),'[[:cntrl:]]','','g'),1000);
  IF length(btrim(v_reason))=0 THEN
    RAISE EXCEPTION USING errcode='22023', message='REQUEUE_REASON_REQUIRED';
  END IF;

  v_hash := private.request_hash(jsonb_build_object(
    'task_id',p_task_id,'worker_id',p_worker_id,'reason',v_reason
  ));
  v_replay := private.idempotency_get(v_task.project_id,'requeue_failed_task',p_idempotency_key,v_hash);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;

  IF v_task.status <> 'failed' OR v_task.current_execution_id IS NOT NULL OR v_task.lease_until IS NOT NULL THEN
    RAISE EXCEPTION USING errcode='55000', message='TASK_NOT_FAILED';
  END IF;

  v_max_attempts := coalesce(nullif(v_task.requirements #>> '{retry,max_attempts}','')::integer,3);
  v_backoff_seconds := coalesce(nullif(v_task.requirements #>> '{retry,backoff_seconds}','')::integer,0);
  IF v_max_attempts < 1 OR v_max_attempts > 10 OR v_backoff_seconds < 0 OR v_backoff_seconds > 86400 THEN
    RAISE EXCEPTION USING errcode='22023', message='INVALID_RETRY_POLICY';
  END IF;

  SELECT coalesce(max(attempt),0), max(finished_at)
    INTO v_attempt,v_last_finished
    FROM public.executions WHERE task_id=p_task_id;
  IF v_attempt >= v_max_attempts THEN
    RAISE EXCEPTION USING errcode='55000', message='RETRY_LIMIT_REACHED';
  END IF;
  IF v_last_finished IS NOT NULL
     AND v_last_finished + make_interval(secs=>v_backoff_seconds) > clock_timestamp() THEN
    RAISE EXCEPTION USING errcode='55000', message='RETRY_BACKOFF_ACTIVE';
  END IF;

  v_now := clock_timestamp();
  UPDATE public.tasks
    SET status='pending', assigned_worker_id=NULL, current_execution_id=NULL,
        lease_until=NULL, result=NULL, completed_at=NULL, updated_at=v_now
    WHERE id=p_task_id AND status='failed';

  PERFORM private.add_event(v_task.project_id,p_task_id,NULL,p_worker_id,'task_requeued',
    jsonb_build_object('reason',v_reason,'previous_attempts',v_attempt,'max_attempts',v_max_attempts,
      'backoff_seconds',v_backoff_seconds));

  v_response := jsonb_build_object('success',true,'data',jsonb_build_object(
    'task_id',p_task_id,'status','pending','previous_attempts',v_attempt,
    'max_attempts',v_max_attempts
  ));
  PERFORM private.idempotency_put(v_task.project_id,'requeue_failed_task',p_idempotency_key,v_hash,v_response);
  RETURN v_response;
END;
$function$;


-- Bound automatic lease-expiry recovery as well as explicit failed-task retries.
-- Expired attempts at the configured limit become terminal failed tasks; otherwise
-- claim_task reclaims only after the configured lease-expiry backoff has elapsed.
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
  v_backoff_seconds integer;
BEGIN
  PERFORM private.assert_worker_actor(p_project_id,p_worker_id);
  IF p_lease_seconds < 60 OR p_lease_seconds > 600 THEN
    RAISE EXCEPTION USING errcode='22023', message='LEASE_SECONDS_OUT_OF_RANGE';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.workers
    WHERE id=p_worker_id AND project_id=p_project_id AND status='active'
  ) THEN
    RAISE EXCEPTION USING errcode='42501', message='WORKER_PROJECT_MISMATCH';
  END IF;

  v_hash := private.request_hash(jsonb_build_object(
    'project_id',p_project_id,'worker_id',p_worker_id,'lease_seconds',p_lease_seconds
  ));
  v_replay := private.idempotency_get(p_project_id,'claim_task',p_idempotency_key,v_hash);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;
  v_now := clock_timestamp();

  -- A lease-expired execution cannot be retried forever. Resolve attempts at
  -- their configured cap before selecting the next claimable task.
  FOR v_expired IN
    SELECT t.id,t.current_execution_id,e.worker_id,e.attempt,
      CASE
        WHEN (t.requirements #>> '{retry,max_attempts}') ~ '^[1-9][0-9]*(uuid,uuid,uuid,text,text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fail_execution(uuid,uuid,uuid,text,text,text) TO authenticated;
REVOKE ALL ON FUNCTION public.requeue_failed_task(uuid,uuid,text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.requeue_failed_task(uuid,uuid,text,text) TO authenticated;

         AND (t.requirements #>> '{retry,max_attempts}')::integer BETWEEN 1 AND 10
        THEN (t.requirements #>> '{retry,max_attempts}')::integer
        ELSE 3
      END AS max_attempts
    FROM public.tasks t
    JOIN public.executions e ON e.id=t.current_execution_id AND e.task_id=t.id
    WHERE t.project_id=p_project_id
      AND t.status='running'
      AND t.lease_until < v_now
      AND (t.task_type <> 'review' OR t.assigned_worker_id=p_worker_id)
    FOR UPDATE OF t SKIP LOCKED
  LOOP
    IF v_expired.attempt >= v_expired.max_attempts THEN
      UPDATE public.executions
        SET status='expired',finished_at=v_now
        WHERE id=v_expired.current_execution_id AND task_id=v_expired.id AND status='running';
      UPDATE public.tasks
        SET status='failed',assigned_worker_id=NULL,current_execution_id=NULL,lease_until=NULL,
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

  SELECT * INTO v_task FROM public.tasks t
  WHERE t.project_id=p_project_id
    AND (
      (t.status='pending' AND (t.assigned_worker_id IS NULL OR t.assigned_worker_id=p_worker_id))
      OR
      (t.status='running' AND t.lease_until < v_now
        AND (
          CASE
            WHEN (t.requirements #>> '{retry,backoff_seconds}') ~ '^[0-9]+(uuid,uuid,uuid,text,text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fail_execution(uuid,uuid,uuid,text,text,text) TO authenticated;
REVOKE ALL ON FUNCTION public.requeue_failed_task(uuid,uuid,text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.requeue_failed_task(uuid,uuid,text,text) TO authenticated;

             AND (t.requirements #>> '{retry,backoff_seconds}')::integer BETWEEN 0 AND 86400
            THEN (t.requirements #>> '{retry,backoff_seconds}')::integer
            ELSE 0
          END
        ) <= extract(epoch FROM (v_now - t.lease_until))
        AND (t.task_type <> 'review' OR t.assigned_worker_id=p_worker_id))
    )
    AND (t.task_type <> 'review' OR t.assigned_worker_id=p_worker_id)
  ORDER BY t.priority ASC,t.created_at ASC
  FOR UPDATE SKIP LOCKED
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
  UPDATE public.tasks SET status='running',assigned_worker_id=p_worker_id,
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

REVOKE ALL ON FUNCTION public.fail_execution(uuid,uuid,uuid,text,text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fail_execution(uuid,uuid,uuid,text,text,text) TO authenticated;
REVOKE ALL ON FUNCTION public.requeue_failed_task(uuid,uuid,text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.requeue_failed_task(uuid,uuid,text,text) TO authenticated;
