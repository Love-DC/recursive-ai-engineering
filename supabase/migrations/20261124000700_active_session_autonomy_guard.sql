-- Bounded active-session autonomy guard: project kill switch and hard claim cap.
-- The project lock makes the active execution count atomic across distinct branches.
CREATE OR REPLACE FUNCTION private.assert_task_activation(p_project_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
DECLARE
  v_activation text;
BEGIN
  SELECT coalesce(p.config->>'task_activation','')
    INTO v_activation
  FROM public.projects p
  WHERE p.id=p_project_id AND p.status='active';

  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='P0002', message='PROJECT_NOT_FOUND_OR_INACTIVE';
  END IF;

  IF v_activation='paused' THEN
    RAISE EXCEPTION USING errcode='55000', message='PROJECT_TASK_ACTIVATION_PAUSED';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION private.assert_task_activation(uuid) FROM PUBLIC, anon, authenticated;


-- Prevent overlapping non-expired executions from owning the same repository branch.
-- The advisory transaction lock serializes concurrent claims for one normalized
-- project/repository/branch key. The live lease check persists exclusion after
-- the claiming transaction commits without introducing a separate lock table.

-- Prevent overlapping non-expired executions from owning the same repository branch.
-- The advisory transaction lock serializes concurrent claims for one normalized
-- project/repository/branch key. The live lease check persists exclusion after
-- the claiming transaction commits without introducing a separate lock table.

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
  v_candidate public.tasks%rowtype;
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
  v_project_repository text;
  v_repository text;
  v_branch text;
  v_branch_lock_key bigint;
  v_skipped_task_ids uuid[] := '{}'::uuid[];
  v_active_executions integer;
  v_max_active_executions integer := 2;
  v_task_activation text;
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
  PERFORM private.assert_task_activation(p_project_id);
  v_now := clock_timestamp();

  SELECT p.github_repo INTO v_project_repository
  FROM public.projects p
  WHERE p.id=p_project_id;

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

  -- Serialize project claims so concurrent sessions cannot exceed the cap.
  PERFORM pg_advisory_xact_lock(hashtextextended('project-active-claims:'||p_project_id::text,0));

  SELECT
    p.config->>'task_activation',
    CASE
      WHEN (p.config #>> '{autonomy,max_active_executions}') ~ '^[1-9][0-9]?

  SELECT count(*)::integer INTO v_active_executions
  FROM public.tasks t
  WHERE t.project_id=p_project_id
    AND t.status='running'
    AND t.current_execution_id IS NOT NULL
    AND t.lease_until > v_now;

  IF v_task_activation='active_session_autonomy'
    AND v_active_executions >= v_max_active_executions THEN
    v_response := jsonb_build_object('success',true,'data',jsonb_build_object(
      'task',null,
      'dependency_blockers',v_dependency_blockers,
      'blocked_reason','PROJECT_CONCURRENCY_LIMIT_REACHED',
      'active_executions',v_active_executions,
      'max_active_executions',v_max_active_executions
    ));
    PERFORM private.idempotency_put(p_project_id,'claim_task',p_idempotency_key,v_hash,v_response);
    RETURN v_response;
  END IF;

  -- Select and lock one candidate per iteration. A PL/pgSQL cursor loop may
  -- prefetch and lock several rows before the loop body runs, starving another
  -- session that should be able to claim a different task for the same Worker.
  -- Remember branch-conflicted candidates and continue in queue order without
  -- retaining locks on unrelated candidates.
  LOOP
    SELECT t.* INTO v_candidate
    FROM public.tasks t
    WHERE t.project_id=p_project_id
      AND v_worker_key = ANY(private.resolve_task_worker_keys(t.project_id,t.task_type,t.requirements))
      AND private.task_dependency_blockers(t.project_id,t.requirements) = '[]'::jsonb
      AND NOT (t.id = ANY(v_skipped_task_ids))
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

    EXIT WHEN NOT FOUND;

    v_branch := coalesce(
      nullif(btrim(v_candidate.requirements #>> '{target,branch}'),''),
      nullif(btrim(v_candidate.requirements #>> '{target,worker_branch}'),'')
    );

    -- Tasks without a declared source branch retain the pre-existing claim path.
    IF v_branch IS NOT NULL THEN
      v_repository := coalesce(
        nullif(btrim(v_candidate.requirements #>> '{target,repository}'),''),
        v_project_repository,
        ''
      );

      -- The transaction lock serializes claim attempts for the same resource.
      -- It is try-only: contention skips this candidate instead of blocking
      -- unrelated queue work behind a branch lock.
      v_branch_lock_key := hashtextextended(
        jsonb_build_array(p_project_id,lower(v_repository),v_branch)::text,
        0
      );
      IF NOT pg_try_advisory_xact_lock(v_branch_lock_key) THEN
        v_skipped_task_ids := array_append(v_skipped_task_ids,v_candidate.id);
        CONTINUE;
      END IF;

      -- Once an earlier claimant commits, its non-expired task row becomes the
      -- durable reservation. Expired leases do not reserve a branch.
      IF EXISTS (
        SELECT 1
        FROM public.tasks active
        WHERE active.project_id=p_project_id
          AND active.id <> v_candidate.id
          AND active.status='running'
          AND active.current_execution_id IS NOT NULL
          AND active.lease_until > v_now
          AND lower(coalesce(
            nullif(btrim(active.requirements #>> '{target,repository}'),''),
            v_project_repository,
            ''
          )) = lower(v_repository)
          AND coalesce(
            nullif(btrim(active.requirements #>> '{target,branch}'),''),
            nullif(btrim(active.requirements #>> '{target,worker_branch}'),'')
          ) = v_branch
      ) THEN
        v_skipped_task_ids := array_append(v_skipped_task_ids,v_candidate.id);
        CONTINUE;
      END IF;
    END IF;

    v_task := v_candidate;
    EXIT;
  END LOOP;

  IF v_task.id IS NULL THEN
    v_response := jsonb_build_object('success',true,'data',jsonb_build_object(
      'task',null,'dependency_blockers',v_dependency_blockers
    ));
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

REVOKE ALL ON FUNCTION public.claim_task(uuid,uuid,integer,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_task(uuid,uuid,integer,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.create_task(p_project_id uuid, p_worker_id uuid, p_task_type text, p_title text, p_description text, p_requirements jsonb, p_priority integer, p_requires_review boolean, p_parent_task_id uuid, p_fixes_task_id uuid, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
declare v_hash text; v_replay jsonb; v_response jsonb; v_id uuid;
begin
  perform private.assert_owner(p_project_id);
  if p_task_type <> 'implementation' or p_fixes_task_id is not null then
    raise exception using errcode='22023',message='USE_SPECIALIZED_TASK_RPC';
  end if;
  if not exists(select 1 from public.workers where id=p_worker_id and project_id=p_project_id and status='active') then
    raise exception using errcode='42501',message='WORKER_PROJECT_MISMATCH';
  end if;
  if p_parent_task_id is not null and not exists(select 1 from public.tasks where id=p_parent_task_id and project_id=p_project_id) then
    raise exception using errcode='23503',message='PARENT_TASK_PROJECT_MISMATCH';
  end if;
  v_hash:=private.request_hash(jsonb_build_object('project_id',p_project_id,'worker_id',p_worker_id,'task_type',p_task_type,'title',p_title,'description',p_description,'requirements',coalesce(p_requirements,'{}'::jsonb),'priority',p_priority,'requires_review',p_requires_review,'parent_task_id',p_parent_task_id,'fixes_task_id',p_fixes_task_id));
  v_replay:=private.idempotency_get(p_project_id,'create_task',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay; end if;
  perform private.assert_task_activation(p_project_id);
  insert into public.tasks(project_id,parent_task_id,task_type,title,description,requirements,priority,requires_review,created_by_worker_id)
  values(p_project_id,p_parent_task_id,'implementation',p_title,p_description,coalesce(p_requirements,'{}'::jsonb),coalesce(p_priority,100),coalesce(p_requires_review,true),p_worker_id)
  returning id into v_id;
  perform private.add_event(p_project_id,v_id,null,p_worker_id,'task_created',jsonb_build_object('task_type','implementation'));
  v_response:=jsonb_build_object('success',true,'data',(select to_jsonb(t) from public.tasks t where t.id=v_id));
  perform private.idempotency_put(p_project_id,'create_task',p_idempotency_key,v_hash,v_response);
  return v_response;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.create_review_task(p_original_task_id uuid, p_delivery_task_id uuid, p_delivery_execution_id uuid, p_reviewer_worker_id uuid, p_idempotency_key text)
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
  if v_replay is not null then return v_replay; end if;
  perform private.assert_task_activation(v_original.project_id);

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
$function$
;
CREATE OR REPLACE FUNCTION public.create_fix_task(p_original_task_id uuid, p_review_task_id uuid, p_title text, p_description text, p_requirements jsonb, p_worker_id uuid, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
declare v_original public.tasks%rowtype; v_review public.tasks%rowtype; v_hash text; v_replay jsonb; v_response jsonb; v_fix_id uuid;
begin
  select * into v_original from public.tasks where id=p_original_task_id for update;
  if not found then raise exception using errcode='P0002',message='ORIGINAL_TASK_NOT_FOUND'; end if;
  perform private.assert_owner(v_original.project_id);
  v_hash:=private.request_hash(jsonb_build_object('original_task_id',p_original_task_id,'review_task_id',p_review_task_id,'title',p_title,'description',p_description,'requirements',coalesce(p_requirements,'{}'::jsonb),'worker_id',p_worker_id));
  v_replay:=private.idempotency_get(v_original.project_id,'create_fix_task',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay; end if;
  perform private.assert_task_activation(v_original.project_id);
  select * into v_review from public.tasks where id=p_review_task_id and task_type='review' and project_id=v_original.project_id;
  if not found or v_review.status <> 'accepted' or v_review.review_decision <> 'rejected'
    or v_review.review_target_original_task_id <> p_original_task_id or v_original.status <> 'rejected' then
    raise exception using errcode='55000',message='REJECTED_REVIEW_REQUIRED';
  end if;
  if v_review.review_evidence ? 'issues'
    and coalesce(p_requirements,'{}'::jsonb)->'issues' is distinct from v_review.review_evidence->'issues' then
    raise exception using errcode='22023',message='FIX_REQUIREMENTS_MUST_MATCH_REVIEW_ISSUES';
  end if;
  if not exists(select 1 from public.workers where id=p_worker_id and project_id=v_original.project_id and status='active') then
    raise exception using errcode='42501',message='WORKER_PROJECT_MISMATCH';
  end if;
  insert into public.tasks(project_id,parent_task_id,fixes_task_id,task_type,title,description,requirements,
    requires_review,status,created_by_worker_id)
  values(v_original.project_id,p_original_task_id,p_original_task_id,'fix',p_title,p_description,
    coalesce(p_requirements,'{}'::jsonb),true,'pending',p_worker_id)
  returning id into v_fix_id;
  perform private.add_event(v_original.project_id,v_fix_id,null,p_worker_id,'fix_task_created',
    jsonb_build_object('original_task_id',p_original_task_id,'review_task_id',p_review_task_id));
  v_response:=jsonb_build_object('success',true,'data',(select to_jsonb(t) from public.tasks t where t.id=v_fix_id));
  perform private.idempotency_put(v_original.project_id,'create_fix_task',p_idempotency_key,v_hash,v_response);
  return v_response;
end;
$function$
;
        THEN LEAST((p.config #>> '{autonomy,max_active_executions}')::integer,2)
      ELSE 2
    END
  INTO v_task_activation,v_max_active_executions
  FROM public.projects p
  WHERE p.id=p_project_id;

  SELECT count(*)::integer INTO v_active_executions
  FROM public.tasks t
  WHERE t.project_id=p_project_id
    AND t.status='running'
    AND t.current_execution_id IS NOT NULL
    AND t.lease_until > v_now;

  IF v_active_executions >= v_max_active_executions THEN
    v_response := jsonb_build_object('success',true,'data',jsonb_build_object(
      'task',null,
      'dependency_blockers',v_dependency_blockers,
      'blocked_reason','PROJECT_CONCURRENCY_LIMIT_REACHED',
      'active_executions',v_active_executions,
      'max_active_executions',v_max_active_executions
    ));
    PERFORM private.idempotency_put(p_project_id,'claim_task',p_idempotency_key,v_hash,v_response);
    RETURN v_response;
  END IF;

  -- Select and lock one candidate per iteration. A PL/pgSQL cursor loop may
  -- prefetch and lock several rows before the loop body runs, starving another
  -- session that should be able to claim a different task for the same Worker.
  -- Remember branch-conflicted candidates and continue in queue order without
  -- retaining locks on unrelated candidates.
  LOOP
    SELECT t.* INTO v_candidate
    FROM public.tasks t
    WHERE t.project_id=p_project_id
      AND v_worker_key = ANY(private.resolve_task_worker_keys(t.project_id,t.task_type,t.requirements))
      AND private.task_dependency_blockers(t.project_id,t.requirements) = '[]'::jsonb
      AND NOT (t.id = ANY(v_skipped_task_ids))
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

    EXIT WHEN NOT FOUND;

    v_branch := coalesce(
      nullif(btrim(v_candidate.requirements #>> '{target,branch}'),''),
      nullif(btrim(v_candidate.requirements #>> '{target,worker_branch}'),'')
    );

    -- Tasks without a declared source branch retain the pre-existing claim path.
    IF v_branch IS NOT NULL THEN
      v_repository := coalesce(
        nullif(btrim(v_candidate.requirements #>> '{target,repository}'),''),
        v_project_repository,
        ''
      );

      -- The transaction lock serializes claim attempts for the same resource.
      -- It is try-only: contention skips this candidate instead of blocking
      -- unrelated queue work behind a branch lock.
      v_branch_lock_key := hashtextextended(
        jsonb_build_array(p_project_id,lower(v_repository),v_branch)::text,
        0
      );
      IF NOT pg_try_advisory_xact_lock(v_branch_lock_key) THEN
        v_skipped_task_ids := array_append(v_skipped_task_ids,v_candidate.id);
        CONTINUE;
      END IF;

      -- Once an earlier claimant commits, its non-expired task row becomes the
      -- durable reservation. Expired leases do not reserve a branch.
      IF EXISTS (
        SELECT 1
        FROM public.tasks active
        WHERE active.project_id=p_project_id
          AND active.id <> v_candidate.id
          AND active.status='running'
          AND active.current_execution_id IS NOT NULL
          AND active.lease_until > v_now
          AND lower(coalesce(
            nullif(btrim(active.requirements #>> '{target,repository}'),''),
            v_project_repository,
            ''
          )) = lower(v_repository)
          AND coalesce(
            nullif(btrim(active.requirements #>> '{target,branch}'),''),
            nullif(btrim(active.requirements #>> '{target,worker_branch}'),'')
          ) = v_branch
      ) THEN
        v_skipped_task_ids := array_append(v_skipped_task_ids,v_candidate.id);
        CONTINUE;
      END IF;
    END IF;

    v_task := v_candidate;
    EXIT;
  END LOOP;

  IF v_task.id IS NULL THEN
    v_response := jsonb_build_object('success',true,'data',jsonb_build_object(
      'task',null,'dependency_blockers',v_dependency_blockers
    ));
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

REVOKE ALL ON FUNCTION public.claim_task(uuid,uuid,integer,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_task(uuid,uuid,integer,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.create_task(p_project_id uuid, p_worker_id uuid, p_task_type text, p_title text, p_description text, p_requirements jsonb, p_priority integer, p_requires_review boolean, p_parent_task_id uuid, p_fixes_task_id uuid, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
declare v_hash text; v_replay jsonb; v_response jsonb; v_id uuid;
begin
  perform private.assert_owner(p_project_id);
  if p_task_type <> 'implementation' or p_fixes_task_id is not null then
    raise exception using errcode='22023',message='USE_SPECIALIZED_TASK_RPC';
  end if;
  if not exists(select 1 from public.workers where id=p_worker_id and project_id=p_project_id and status='active') then
    raise exception using errcode='42501',message='WORKER_PROJECT_MISMATCH';
  end if;
  if p_parent_task_id is not null and not exists(select 1 from public.tasks where id=p_parent_task_id and project_id=p_project_id) then
    raise exception using errcode='23503',message='PARENT_TASK_PROJECT_MISMATCH';
  end if;
  v_hash:=private.request_hash(jsonb_build_object('project_id',p_project_id,'worker_id',p_worker_id,'task_type',p_task_type,'title',p_title,'description',p_description,'requirements',coalesce(p_requirements,'{}'::jsonb),'priority',p_priority,'requires_review',p_requires_review,'parent_task_id',p_parent_task_id,'fixes_task_id',p_fixes_task_id));
  v_replay:=private.idempotency_get(p_project_id,'create_task',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay; end if;
  perform private.assert_task_activation(p_project_id);
  insert into public.tasks(project_id,parent_task_id,task_type,title,description,requirements,priority,requires_review,created_by_worker_id)
  values(p_project_id,p_parent_task_id,'implementation',p_title,p_description,coalesce(p_requirements,'{}'::jsonb),coalesce(p_priority,100),coalesce(p_requires_review,true),p_worker_id)
  returning id into v_id;
  perform private.add_event(p_project_id,v_id,null,p_worker_id,'task_created',jsonb_build_object('task_type','implementation'));
  v_response:=jsonb_build_object('success',true,'data',(select to_jsonb(t) from public.tasks t where t.id=v_id));
  perform private.idempotency_put(p_project_id,'create_task',p_idempotency_key,v_hash,v_response);
  return v_response;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.create_review_task(p_original_task_id uuid, p_delivery_task_id uuid, p_delivery_execution_id uuid, p_reviewer_worker_id uuid, p_idempotency_key text)
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
  if v_replay is not null then return v_replay; end if;
  perform private.assert_task_activation(v_original.project_id);

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
$function$
;
CREATE OR REPLACE FUNCTION public.create_fix_task(p_original_task_id uuid, p_review_task_id uuid, p_title text, p_description text, p_requirements jsonb, p_worker_id uuid, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
declare v_original public.tasks%rowtype; v_review public.tasks%rowtype; v_hash text; v_replay jsonb; v_response jsonb; v_fix_id uuid;
begin
  select * into v_original from public.tasks where id=p_original_task_id for update;
  if not found then raise exception using errcode='P0002',message='ORIGINAL_TASK_NOT_FOUND'; end if;
  perform private.assert_owner(v_original.project_id);
  v_hash:=private.request_hash(jsonb_build_object('original_task_id',p_original_task_id,'review_task_id',p_review_task_id,'title',p_title,'description',p_description,'requirements',coalesce(p_requirements,'{}'::jsonb),'worker_id',p_worker_id));
  v_replay:=private.idempotency_get(v_original.project_id,'create_fix_task',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay; end if;
  perform private.assert_task_activation(v_original.project_id);
  select * into v_review from public.tasks where id=p_review_task_id and task_type='review' and project_id=v_original.project_id;
  if not found or v_review.status <> 'accepted' or v_review.review_decision <> 'rejected'
    or v_review.review_target_original_task_id <> p_original_task_id or v_original.status <> 'rejected' then
    raise exception using errcode='55000',message='REJECTED_REVIEW_REQUIRED';
  end if;
  if v_review.review_evidence ? 'issues'
    and coalesce(p_requirements,'{}'::jsonb)->'issues' is distinct from v_review.review_evidence->'issues' then
    raise exception using errcode='22023',message='FIX_REQUIREMENTS_MUST_MATCH_REVIEW_ISSUES';
  end if;
  if not exists(select 1 from public.workers where id=p_worker_id and project_id=v_original.project_id and status='active') then
    raise exception using errcode='42501',message='WORKER_PROJECT_MISMATCH';
  end if;
  insert into public.tasks(project_id,parent_task_id,fixes_task_id,task_type,title,description,requirements,
    requires_review,status,created_by_worker_id)
  values(v_original.project_id,p_original_task_id,p_original_task_id,'fix',p_title,p_description,
    coalesce(p_requirements,'{}'::jsonb),true,'pending',p_worker_id)
  returning id into v_fix_id;
  perform private.add_event(v_original.project_id,v_fix_id,null,p_worker_id,'fix_task_created',
    jsonb_build_object('original_task_id',p_original_task_id,'review_task_id',p_review_task_id));
  v_response:=jsonb_build_object('success',true,'data',(select to_jsonb(t) from public.tasks t where t.id=v_fix_id));
  perform private.idempotency_put(v_original.project_id,'create_fix_task',p_idempotency_key,v_hash,v_response);
  return v_response;
end;
$function$
;