-- Align the physical uniqueness rule with review retry semantics.
-- Cancelled/failed reviews are immutable history; active/completed reviews remain unique.
DROP INDEX IF EXISTS public.uq_review_target_once;
CREATE UNIQUE INDEX uq_review_target_once
  ON public.tasks(
    review_target_original_task_id,
    review_target_delivery_task_id,
    review_target_execution_id
  )
  WHERE task_type='review' AND status NOT IN ('cancelled','failed');

-- Allow a replacement review after a prior review attempt was cancelled or exhausted.
-- Historical review tasks remain immutable; only active or completed review records block recreation.
-- The create_review_task function locks the original task before checking the target triple,
-- serializing concurrent attempts for the same delivery execution.

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

  -- A cancelled or exhausted review attempt is historical, not a permanent lock.
  -- The original-task row lock above serializes concurrent replacements for this delivery.
  IF EXISTS (
    SELECT 1 FROM public.tasks
    WHERE task_type='review'
      AND review_target_original_task_id=p_original_task_id
      AND review_target_delivery_task_id=p_delivery_task_id
      AND review_target_execution_id=p_delivery_execution_id
      AND status NOT IN ('cancelled','failed')
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
