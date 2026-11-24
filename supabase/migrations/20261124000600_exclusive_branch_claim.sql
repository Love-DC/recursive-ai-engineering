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
