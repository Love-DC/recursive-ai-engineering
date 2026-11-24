-- Safely reconcile obsolete submitted deliveries without erasing execution history.
-- This is an additive migration. It is intended for reviewed code/fixture CI only;
-- production deployment is a separate operation.
CREATE OR REPLACE FUNCTION public.reconcile_submitted_task(
  p_task_id uuid,
  p_expected_updated_at timestamptz,
  p_reason text,
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
  v_reason text;
  v_evidence jsonb;
  v_hash text;
  v_replay jsonb;
  v_response jsonb;
  v_now timestamptz;
  v_related_task_ids uuid[];
  v_old_result jsonb;
BEGIN
  IF p_task_id IS NULL OR p_expected_updated_at IS NULL THEN
    RAISE EXCEPTION USING errcode='22023',message='RECONCILIATION_EXPECTED_STATE_REQUIRED';
  END IF;
  IF nullif(btrim(coalesce(p_idempotency_key,'')),'') IS NULL
    OR length(p_idempotency_key)>200 THEN
    RAISE EXCEPTION USING errcode='22023',message='RECONCILIATION_IDEMPOTENCY_KEY_REQUIRED';
  END IF;

  v_reason := regexp_replace(coalesce(p_reason,''),'[[:cntrl:]]','','g');
  v_reason := regexp_replace(v_reason,
    '(?i)(bearer[[:space:]]+)[A-Za-z0-9._~+/=-]+','\\1[REDACTED]','g');
  v_reason := regexp_replace(v_reason,
    '(?i)((api[_-]?key|token|secret|password)[[:space:]]*[:=][[:space:]]*)[^[:space:],;]+',
    '\\1[REDACTED]','g');
  IF length(btrim(v_reason))=0 THEN
    RAISE EXCEPTION USING errcode='22023',message='RECONCILIATION_REASON_REQUIRED';
  END IF;
  IF length(v_reason)>2000 THEN
    RAISE EXCEPTION USING errcode='22023',message='RECONCILIATION_REASON_TOO_LONG';
  END IF;

  IF jsonb_typeof(p_evidence) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION USING errcode='22023',message='RECONCILIATION_EVIDENCE_REQUIRED';
  END IF;
  IF jsonb_array_length(p_evidence) NOT BETWEEN 1 AND 20 THEN
    RAISE EXCEPTION USING errcode='22023',message='RECONCILIATION_EVIDENCE_REQUIRED';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_evidence) item(value)
    WHERE jsonb_typeof(item.value) IS DISTINCT FROM 'object'
      OR nullif(btrim(item.value->>'kind'),'') IS NULL
      OR nullif(btrim(item.value->>'ref'),'') IS NULL
      OR nullif(btrim(item.value->>'observation'),'') IS NULL
      OR length(item.value->>'kind')>100
      OR length(item.value->>'ref')>2000
      OR length(item.value->>'observation')>4000
  ) THEN
    RAISE EXCEPTION USING errcode='22023',message='RECONCILIATION_EVIDENCE_INVALID';
  END IF;

  -- Keep the durable audit payload useful without copying common credential
  -- formats that may have been pasted accidentally into an evidence note.
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'kind',regexp_replace(item.value->>'kind','[[:cntrl:]]','','g'),
    'ref',regexp_replace(
      regexp_replace(item.value->>'ref',
        '(?i)(bearer[[:space:]]+)[A-Za-z0-9._~+/=-]+','\\1[REDACTED]','g'),
      '(?i)((api[_-]?key|token|secret|password)[[:space:]]*[:=][[:space:]]*)[^[:space:],;]+',
      '\\1[REDACTED]','g'),
    'observation',regexp_replace(
      regexp_replace(item.value->>'observation',
        '(?i)(bearer[[:space:]]+)[A-Za-z0-9._~+/=-]+','\\1[REDACTED]','g'),
      '(?i)((api[_-]?key|token|secret|password)[[:space:]]*[:=][[:space:]]*)[^[:space:],;]+',
      '\\1[REDACTED]','g')
  ) ORDER BY item.ordinality),'[]'::jsonb)
  INTO v_evidence
  FROM jsonb_array_elements(p_evidence) WITH ORDINALITY item(value,ordinality);

  SELECT t.project_id INTO v_project_id
  FROM public.tasks t
  WHERE t.id=p_task_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='P0002',message='TASK_NOT_FOUND';
  END IF;
  PERFORM private.assert_owner(v_project_id);

  -- Serialize all attempts for this task. Idempotent retries are checked after
  -- acquiring the same row lock, so a successful first attempt replays cleanly.
  SELECT t.* INTO v_task
  FROM public.tasks t
  WHERE t.id=p_task_id AND t.project_id=v_project_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='P0002',message='TASK_NOT_FOUND';
  END IF;

  v_hash := private.request_hash(jsonb_build_object(
    'task_id',p_task_id,
    'expected_updated_at',p_expected_updated_at,
    'reason',v_reason,
    'evidence',v_evidence
  ));
  v_replay := private.idempotency_get(
    v_project_id,'reconcile_submitted_task',p_idempotency_key,v_hash
  );
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;

  IF v_task.status <> 'submitted' THEN
    RAISE EXCEPTION USING errcode='55000',message='TASK_NOT_SUBMITTED';
  END IF;
  IF v_task.updated_at IS DISTINCT FROM p_expected_updated_at THEN
    RAISE EXCEPTION USING errcode='55000',message='TASK_STATE_STALE';
  END IF;

  v_related_task_ids := ARRAY[p_task_id];
  IF v_task.latest_delivery_task_id IS NOT NULL
    AND v_task.latest_delivery_task_id <> p_task_id THEN
    v_related_task_ids := array_append(v_related_task_ids,v_task.latest_delivery_task_id);
  END IF;

  -- A task or its latest delivery with an unexpired lease or a still-running
  -- execution cannot be retired. Do not rewrite, fail, or expire executions.
  IF EXISTS (
    SELECT 1
    FROM public.tasks related
    WHERE related.id=ANY(v_related_task_ids)
      AND (
        related.lease_until > clock_timestamp()
        OR EXISTS (
          SELECT 1 FROM public.executions e
          WHERE e.task_id=related.id AND e.status='running'
        )
      )
  ) THEN
    RAISE EXCEPTION USING errcode='55000',message='TASK_HAS_LIVE_EXECUTION';
  END IF;

  -- Pending/running/submitted reviews still need a review outcome. An accepted
  -- review is already a durable decision and also forbids reconciliation.
  IF EXISTS (
    SELECT 1 FROM public.tasks r
    WHERE r.task_type='review'
      AND (
        r.review_target_original_task_id=ANY(v_related_task_ids)
        OR r.review_target_delivery_task_id=ANY(v_related_task_ids)
        OR r.review_target_execution_id=v_task.latest_delivery_execution_id
      )
      AND r.status IN ('pending','running','submitted')
  ) THEN
    RAISE EXCEPTION USING errcode='55000',message='TASK_HAS_PENDING_REVIEW';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.tasks r
    WHERE r.task_type='review'
      AND (
        r.review_target_original_task_id=ANY(v_related_task_ids)
        OR r.review_target_delivery_task_id=ANY(v_related_task_ids)
        OR r.review_target_execution_id=v_task.latest_delivery_execution_id
      )
      AND r.status='accepted'
  ) THEN
    RAISE EXCEPTION USING errcode='55000',message='TASK_HAS_ACCEPTED_REVIEW';
  END IF;

  -- Preserve any non-terminal task that is structurally or explicitly
  -- dependent on this delivery. Historical terminal tasks do not block.
  IF EXISTS (
    SELECT 1
    FROM public.tasks dependent
    WHERE dependent.project_id=v_project_id
      AND dependent.id<>p_task_id
      AND dependent.status NOT IN ('accepted','cancelled','failed','rejected')
      AND (
        dependent.parent_task_id=ANY(v_related_task_ids)
        OR dependent.fixes_task_id=ANY(v_related_task_ids)
        OR EXISTS (
          SELECT 1
          FROM jsonb_array_elements(
            CASE WHEN jsonb_typeof(dependent.requirements->'dependencies')='array'
              THEN dependent.requirements->'dependencies' ELSE '[]'::jsonb END
          ) d(value)
          WHERE d.value->>'type'='task'
            AND d.value->>'task_id'=ANY(ARRAY(SELECT x::text FROM unnest(v_related_task_ids) x))
        )
        OR EXISTS (
          SELECT 1
          FROM jsonb_array_elements(
            CASE WHEN jsonb_typeof(dependent.requirements->'depends_on')='array'
              THEN dependent.requirements->'depends_on' ELSE '[]'::jsonb END
          ) d(value)
          WHERE jsonb_typeof(d.value)='string'
            AND d.value #>> '{}' = ANY(ARRAY(SELECT x::text FROM unnest(v_related_task_ids) x))
        )
      )
  ) THEN
    RAISE EXCEPTION USING errcode='55000',message='TASK_HAS_DEPENDENT_WORK';
  END IF;

  v_now := clock_timestamp();
  v_old_result := CASE
    WHEN jsonb_typeof(v_task.result)='object' THEN coalesce(v_task.result,'{}'::jsonb)
    WHEN v_task.result IS NULL THEN '{}'::jsonb
    ELSE jsonb_build_object('previous_result',v_task.result)
  END;

  UPDATE public.tasks
  SET status='cancelled',
      current_execution_id=NULL,
      lease_until=NULL,
      result=v_old_result || jsonb_build_object(
        'reconciliation',jsonb_build_object(
          'reason',v_reason,
          'evidence',v_evidence,
          'reconciled_at',v_now,
          'previous_status','submitted',
          'expected_updated_at',p_expected_updated_at
        )
      ),
      updated_at=v_now,
      completed_at=v_now
  WHERE id=p_task_id
    AND project_id=v_project_id
    AND status='submitted'
    AND updated_at=p_expected_updated_at
  RETURNING * INTO v_task;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='55000',message='TASK_STATE_STALE';
  END IF;

  PERFORM private.add_event(
    v_project_id,p_task_id,NULL,NULL,'task_reconciled',
    jsonb_build_object(
      'previous_status','submitted',
      'new_status','cancelled',
      'reason',v_reason,
      'evidence',v_evidence,
      'latest_delivery_task_id',v_task.latest_delivery_task_id,
      'latest_delivery_execution_id',v_task.latest_delivery_execution_id
    )
  );

  v_response := jsonb_build_object('success',true,'data',jsonb_build_object(
    'task_id',v_task.id,
    'status',v_task.status,
    'updated_at',v_task.updated_at,
    'completed_at',v_task.completed_at,
    'latest_delivery_task_id',v_task.latest_delivery_task_id,
    'latest_delivery_execution_id',v_task.latest_delivery_execution_id
  ));
  PERFORM private.idempotency_put(
    v_project_id,'reconcile_submitted_task',p_idempotency_key,v_hash,v_response
  );
  RETURN v_response;
END;
$function$;

REVOKE ALL ON FUNCTION public.reconcile_submitted_task(uuid,timestamptz,text,jsonb,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reconcile_submitted_task(uuid,timestamptz,text,jsonb,text)
  TO authenticated;
