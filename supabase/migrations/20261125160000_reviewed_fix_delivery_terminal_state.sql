-- Finalize a reviewed fix-delivery task together with its original task.
-- Submitted delivery results/executions remain immutable historical evidence.
-- This is a repository/CI migration; production deployment is separately gated.
BEGIN;

-- A reviewed fix child must be able to retain its own review decision and provenance.
-- Implementations keep the existing invariant: decision/evidence metadata belongs to
-- review tasks; a distinct fix task receives that provenance when its review is finalized.
ALTER TABLE public.tasks
  DROP CONSTRAINT tasks_check1;

ALTER TABLE public.tasks
  ADD CONSTRAINT tasks_check1 CHECK (
    (
      task_type = 'review'
      AND review_target_original_task_id IS NOT NULL
      AND review_target_delivery_task_id IS NOT NULL
      AND review_target_execution_id IS NOT NULL
      AND requires_review = false
      AND fixes_task_id IS NULL
    )
    OR
    (
      task_type <> 'review'
      AND review_target_original_task_id IS NULL
      AND review_target_delivery_task_id IS NULL
      AND review_target_execution_id IS NULL
      AND (
        (
          task_type = 'fix'
          AND (
            (review_decision IS NULL AND latest_review_task_id IS NULL)
            OR
            (review_decision IS NOT NULL AND latest_review_task_id IS NOT NULL)
          )
        )
        OR
        (
          task_type = 'implementation'
          AND review_decision IS NULL
          AND review_evidence IS NULL
        )
      )
    )
  );

-- Implementation deliveries retain root-only review metadata. A distinct fix
-- delivery may store the final review outcome, but only in a matching terminal
-- state with durable review evidence and a same-project review-task pointer.
ALTER TABLE public.tasks
  DROP CONSTRAINT tasks_check1;

ALTER TABLE public.tasks
  ADD CONSTRAINT tasks_check1 CHECK (
    (
      task_type = 'review'
      AND review_target_original_task_id IS NOT NULL
      AND review_target_delivery_task_id IS NOT NULL
      AND review_target_execution_id IS NOT NULL
      AND requires_review = false
      AND fixes_task_id IS NULL
    )
    OR
    (
      task_type = 'implementation'
      AND review_target_original_task_id IS NULL
      AND review_target_delivery_task_id IS NULL
      AND review_target_execution_id IS NULL
      AND review_decision IS NULL
      AND review_evidence IS NULL
    )
    OR
    (
      task_type = 'fix'
      AND review_target_original_task_id IS NULL
      AND review_target_delivery_task_id IS NULL
      AND review_target_execution_id IS NULL
      AND (
        (review_decision IS NULL AND review_evidence IS NULL)
        OR
        (
          status IN ('accepted', 'rejected')
          AND review_decision IS NOT NULL
          AND review_decision = status
          AND review_evidence IS NOT NULL
          AND latest_review_task_id IS NOT NULL
          AND completed_at IS NOT NULL
        )
      )
    )
  );

COMMENT ON CONSTRAINT tasks_check1 ON public.tasks IS
  'Review rows require exact targets; implementation rows retain null review outcome fields; fix rows may store review outcome/evidence only when terminal with a review pointer and completion timestamp.';

CREATE OR REPLACE FUNCTION public.review_result(
  p_review_task_id uuid,
  p_execution_id uuid,
  p_reviewer_worker_id uuid,
  p_decision text,
  p_review jsonb,
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
DECLARE
  v_review public.tasks%rowtype;
  v_original public.tasks%rowtype;
  v_delivery public.tasks%rowtype;
  v_exec public.executions%rowtype;
  v_project uuid;
  v_hash text;
  v_replay jsonb;
  v_response jsonb;
  v_now timestamptz;
BEGIN
  SELECT * INTO v_review
  FROM public.tasks
  WHERE id = p_review_task_id AND task_type = 'review';

  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode = 'P0002', message = 'REVIEW_TASK_NOT_FOUND';
  END IF;

  v_project := v_review.project_id;
  PERFORM private.assert_worker_actor(v_project, p_reviewer_worker_id);

  v_hash := private.request_hash(jsonb_build_object(
    'review_task_id', p_review_task_id,
    'execution_id', p_execution_id,
    'reviewer_worker_id', p_reviewer_worker_id,
    'decision', p_decision,
    'review', p_review
  ));

  v_replay := private.idempotency_get(v_project, 'review_result', p_idempotency_key, v_hash);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;

  -- Preserve the deployed lock order: Original Task, Delivery Task,
  -- Review Task, then Review Execution.
  SELECT * INTO v_original
  FROM public.tasks
  WHERE id = v_review.review_target_original_task_id
  FOR UPDATE;

  IF NOT FOUND OR v_original.project_id IS DISTINCT FROM v_project THEN
    RAISE EXCEPTION USING errcode = '55000', message = 'ORIGINAL_TASK_CHANGED';
  END IF;

  SELECT * INTO v_delivery
  FROM public.tasks
  WHERE id = v_review.review_target_delivery_task_id
  FOR UPDATE;

  IF NOT FOUND OR v_delivery.project_id IS DISTINCT FROM v_project THEN
    RAISE EXCEPTION USING errcode = '55000', message = 'DELIVERY_TASK_CHANGED';
  END IF;

  SELECT * INTO v_review
  FROM public.tasks
  WHERE id = p_review_task_id
  FOR UPDATE;

  IF v_review.current_execution_id IS DISTINCT FROM p_execution_id THEN
    RAISE EXCEPTION USING errcode = '55000', message = 'EXECUTION_SUPERSEDED';
  END IF;

  v_now := clock_timestamp();

  IF v_review.lease_until IS NULL OR v_review.lease_until <= v_now THEN
    RAISE EXCEPTION USING errcode = '55000', message = 'EXECUTION_EXPIRED';
  END IF;

  IF v_review.status <> 'running' THEN
    RAISE EXCEPTION USING errcode = '55000', message = 'TASK_NOT_RUNNING';
  END IF;

  IF v_review.assigned_worker_id IS DISTINCT FROM p_reviewer_worker_id THEN
    RAISE EXCEPTION USING errcode = '42501', message = 'REVIEWER_NOT_ASSIGNED';
  END IF;

  SELECT * INTO v_exec
  FROM public.executions
  WHERE id = p_execution_id AND task_id = p_review_task_id
  FOR UPDATE;

  IF NOT FOUND OR v_exec.status <> 'running' THEN
    RAISE EXCEPTION USING errcode = '55000', message = 'EXECUTION_SUPERSEDED';
  END IF;

  IF v_exec.worker_id IS DISTINCT FROM p_reviewer_worker_id THEN
    RAISE EXCEPTION USING errcode = '42501', message = 'TASK_NOT_OWNED';
  END IF;

  IF p_decision NOT IN ('accepted', 'rejected') THEN
    RAISE EXCEPTION USING errcode = '22023', message = 'INVALID_REVIEW_DECISION';
  END IF;

  -- A review can only finalize the exact latest submitted delivery version.
  IF v_original.status <> 'submitted'
    OR v_original.latest_delivery_task_id IS DISTINCT FROM v_review.review_target_delivery_task_id
    OR v_original.latest_delivery_execution_id IS DISTINCT FROM v_review.review_target_execution_id THEN
    RAISE EXCEPTION USING errcode = '55000', message = 'DELIVERY_VERSION_NOT_CURRENT';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.executions
    WHERE id = v_review.review_target_execution_id
      AND task_id = v_review.review_target_delivery_task_id
      AND status = 'submitted'
  ) THEN
    RAISE EXCEPTION USING errcode = '55000', message = 'DELIVERY_EXECUTION_CHANGED';
  END IF;

  -- A distinct delivery must still be the submitted fix child of this root.
  -- Direct deliveries use the original task row and retain existing behavior.
  IF v_delivery.id IS DISTINCT FROM v_original.id
    AND (
      v_delivery.task_type <> 'fix'
      OR v_delivery.fixes_task_id IS DISTINCT FROM v_original.id
      OR v_delivery.status <> 'submitted'
    ) THEN
    RAISE EXCEPTION USING errcode = '55000', message = 'FIX_DELIVERY_TASK_CHANGED';
  END IF;

  v_now := clock_timestamp();

  UPDATE public.executions
  SET status = 'succeeded', result = p_review, finished_at = v_now
  WHERE id = p_execution_id
    AND task_id = p_review_task_id
    AND status = 'running';

  UPDATE public.tasks
  SET status = 'accepted',
      review_decision = p_decision,
      review_evidence = p_review,
      current_execution_id = NULL,
      lease_until = NULL,
      updated_at = v_now,
      completed_at = v_now
  WHERE id = p_review_task_id;

  -- Keep implementation/root rows on the established root-only metadata model.
  UPDATE public.tasks
  SET status = CASE WHEN p_decision = 'accepted' THEN 'accepted' ELSE 'rejected' END,
      latest_delivery_task_id = v_review.review_target_delivery_task_id,
      latest_delivery_execution_id = v_review.review_target_execution_id,
      latest_review_task_id = p_review_task_id,
      updated_at = v_now,
      completed_at = v_now
  WHERE id = v_original.id;

  IF v_delivery.id IS DISTINCT FROM v_original.id THEN
    UPDATE public.tasks
    SET status = p_decision,
        review_decision = p_decision,
        review_evidence = coalesce(p_review, '{}'::jsonb),
        latest_review_task_id = p_review_task_id,
        updated_at = v_now,
        completed_at = v_now
    WHERE id = v_delivery.id
      AND project_id = v_project
      AND task_type = 'fix'
      AND fixes_task_id = v_original.id
      AND status = 'submitted'
    RETURNING * INTO v_delivery;

    IF NOT FOUND THEN
      RAISE EXCEPTION USING errcode = '55000', message = 'FIX_DELIVERY_TASK_CHANGED';
    END IF;

    PERFORM private.add_event(
      v_project,
      v_delivery.id,
      v_review.review_target_execution_id,
      p_reviewer_worker_id,
      CASE WHEN p_decision = 'accepted'
        THEN 'fix_delivery_review_accepted'
        ELSE 'fix_delivery_review_rejected'
      END,
      jsonb_build_object(
        'decision', p_decision,
        'original_task_id', v_original.id,
        'review_task_id', p_review_task_id,
        'delivery_execution_id', v_review.review_target_execution_id,
        'review_evidence', coalesce(p_review, '{}'::jsonb)
      )
    );
  END IF;

  IF p_decision = 'accepted' THEN
    PERFORM private.add_event(
      v_project, p_review_task_id, p_execution_id, p_reviewer_worker_id,
      'review_accepted', coalesce(p_review, '{}'::jsonb)
    );
  ELSE
    PERFORM private.add_event(
      v_project, p_review_task_id, p_execution_id, p_reviewer_worker_id,
      'review_rejected', coalesce(p_review, '{}'::jsonb)
    );
  END IF;

  v_response := jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'review_task_id', p_review_task_id,
      'decision', p_decision,
      'original_task_id', v_original.id
    )
  );

  PERFORM private.idempotency_put(
    v_project, 'review_result', p_idempotency_key, v_hash, v_response
  );

  RETURN v_response;
END;
$function$;

COMMIT;
