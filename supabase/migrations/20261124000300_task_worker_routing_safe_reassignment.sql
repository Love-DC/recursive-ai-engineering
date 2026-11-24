-- Safe pending-task reassignment and cancelled-review retry behavior.
-- Function-only migration. Never apply to production without the separate deployment gate.

-- This unique index intentionally excludes cancelled reviews. A cancelled review
-- is a closed attempt and must not permanently block a retry for the same delivery.
DROP INDEX IF EXISTS public.uq_review_target_once;
CREATE UNIQUE INDEX uq_review_target_once
  ON public.tasks(
    review_target_original_task_id,
    review_target_delivery_task_id,
    review_target_execution_id
  )
  WHERE task_type='review' AND status <> 'cancelled';

CREATE OR REPLACE FUNCTION public.reassign_pending_task(
  p_task_id uuid,
  p_expected_worker_id uuid,
  p_destination_worker_id uuid,
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
  v_destination_worker_key text;
  v_allowed_worker_keys text[];
  v_delivery_worker_id uuid;
  v_reason text;
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

  PERFORM private.assert_owner(v_project_id);

  v_reason := regexp_replace(coalesce(p_reason,''),'[[:cntrl:]]','','g');
  v_reason := regexp_replace(v_reason,
    '(?i)(bearer[[:space:]]+)[A-Za-z0-9._~+/=-]+','\1[REDACTED]','g');
  v_reason := regexp_replace(v_reason,
    '(?i)((api[_-]?key|token|secret|password)[[:space:]]*[:=][[:space:]]*)[^[:space:],;]+',
    '\1[REDACTED]','g');
  IF length(btrim(v_reason))=0 THEN
    RAISE EXCEPTION USING errcode='22023',message='REASSIGN_REASON_REQUIRED';
  END IF;
  IF length(v_reason)>2000 THEN
    RAISE EXCEPTION USING errcode='22023',message='REASSIGN_REASON_TOO_LONG';
  END IF;

  v_hash := private.request_hash(jsonb_build_object(
    'task_id',p_task_id,
    'expected_worker_id',p_expected_worker_id,
    'destination_worker_id',p_destination_worker_id,
    'reason',v_reason
  ));
  v_replay := private.idempotency_get(
    v_project_id,'reassign_pending_task',p_idempotency_key,v_hash
  );
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;

  -- Serialize reassignment against claim_task. After waiting for a concurrent
  -- claim, this row is re-read and its new status/current execution is checked.
  SELECT t.* INTO v_task
  FROM public.tasks t
  WHERE t.id=p_task_id AND t.project_id=v_project_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='P0002',message='TASK_NOT_FOUND';
  END IF;

  IF v_task.status <> 'pending' THEN
    RAISE EXCEPTION USING errcode='55000',message='TASK_NOT_PENDING';
  END IF;
  IF v_task.current_execution_id IS NOT NULL OR v_task.lease_until IS NOT NULL
    OR EXISTS (
      SELECT 1 FROM public.executions e
      WHERE e.task_id=v_task.id AND e.status='running'
    ) THEN
    RAISE EXCEPTION USING errcode='55000',message='TASK_HAS_ACTIVE_EXECUTION';
  END IF;

  IF v_task.assigned_worker_id IS DISTINCT FROM p_expected_worker_id THEN
    RAISE EXCEPTION USING errcode='55000',message='TASK_ASSIGNMENT_STALE';
  END IF;
  IF p_destination_worker_id IS NULL THEN
    RAISE EXCEPTION USING errcode='22023',message='DESTINATION_WORKER_REQUIRED';
  END IF;
  IF v_task.assigned_worker_id IS NOT DISTINCT FROM p_destination_worker_id THEN
    RAISE EXCEPTION USING errcode='55000',message='TASK_ALREADY_ASSIGNED';
  END IF;

  SELECT w.worker_key INTO v_destination_worker_key
  FROM public.workers w
  WHERE w.id=p_destination_worker_id
    AND w.project_id=v_project_id
    AND w.status='active';
  IF NOT FOUND OR v_destination_worker_key IS NULL THEN
    RAISE EXCEPTION USING errcode='42501',message='DESTINATION_WORKER_PROJECT_MISMATCH';
  END IF;

  v_allowed_worker_keys := private.resolve_task_worker_keys(
    v_project_id,v_task.task_type,v_task.requirements
  );
  IF NOT coalesce(v_destination_worker_key = ANY(v_allowed_worker_keys),false) THEN
    RAISE EXCEPTION USING errcode='42501',message='TASK_ROUTE_MISMATCH';
  END IF;

  -- A review must remain assigned to a routed Reviewer who did not implement
  -- the exact delivery execution under review.
  IF v_task.task_type='review' THEN
    SELECT e.worker_id INTO v_delivery_worker_id
    FROM public.executions e
    WHERE e.id=v_task.review_target_execution_id
      AND e.task_id=v_task.review_target_delivery_task_id;
    IF v_delivery_worker_id IS NULL THEN
      RAISE EXCEPTION USING errcode='55000',message='REVIEW_DELIVERY_EXECUTION_MISSING';
    END IF;
    IF v_delivery_worker_id=p_destination_worker_id THEN
      RAISE EXCEPTION USING errcode='42501',message='REVIEWER_CANNOT_REVIEW_OWN_EXECUTION';
    END IF;
  END IF;

  v_now := clock_timestamp();
  UPDATE public.tasks
  SET assigned_worker_id=p_destination_worker_id,
      updated_at=v_now
  WHERE id=v_task.id
    AND project_id=v_project_id
    AND status='pending'
    AND current_execution_id IS NULL
    AND lease_until IS NULL
    AND assigned_worker_id IS NOT DISTINCT FROM p_expected_worker_id
  RETURNING * INTO v_task;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='55000',message='TASK_ASSIGNMENT_STALE';
  END IF;

  PERFORM private.add_event(
    v_project_id,v_task.id,NULL,NULL,'task_reassigned',
    jsonb_build_object(
      'previous_worker_id',p_expected_worker_id,
      'destination_worker_id',p_destination_worker_id,
      'destination_worker_key',v_destination_worker_key,
      'task_type',v_task.task_type,
      'reason',v_reason
    )
  );

  v_response := jsonb_build_object('success',true,'data',jsonb_build_object(
    'task_id',v_task.id,
    'status',v_task.status,
    'previous_worker_id',p_expected_worker_id,
    'assigned_worker_id',v_task.assigned_worker_id,
    'updated_at',v_task.updated_at
  ));
  PERFORM private.idempotency_put(
    v_project_id,'reassign_pending_task',p_idempotency_key,v_hash,v_response
  );
  RETURN v_response;
END;
$function$;

REVOKE ALL ON FUNCTION public.reassign_pending_task(uuid,uuid,uuid,text,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reassign_pending_task(uuid,uuid,uuid,text,text)
  TO authenticated;

-- A cancelled review is a closed attempt, not a live duplicate. Keep the
-- existing identity, route, and delivery-version checks unchanged.
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
      AND status <> 'cancelled'
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

REVOKE ALL ON FUNCTION public.create_review_task(uuid,uuid,uuid,uuid,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_review_task(uuid,uuid,uuid,uuid,text)
  TO authenticated;
