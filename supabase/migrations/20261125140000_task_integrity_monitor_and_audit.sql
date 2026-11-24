-- Project-scoped task/execution integrity scan and durable destructive-operation audit.
-- This migration is repository-only until separately reviewed and deployed.
BEGIN;

CREATE TABLE private.task_destructive_audit (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transaction_id bigint NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  operation text NOT NULL CHECK (operation IN ('DELETE','TRUNCATE')),
  relation_name text NOT NULL CHECK (relation_name IN ('tasks','executions')),
  project_id uuid,
  task_id uuid,
  execution_id uuid,
  parent_task_id uuid,
  worker_id uuid,
  task_type text,
  task_status text,
  execution_status text,
  attempt integer,
  session_user_name name NOT NULL,
  database_user_name name NOT NULL,
  authenticated_user_id uuid,
  system_principal_id uuid,
  owner_mcp_owner_id uuid,
  backend_pid integer NOT NULL,
  application_name text NOT NULL DEFAULT '',
  client_addr inet,
  trigger_depth smallint NOT NULL
);

COMMENT ON TABLE private.task_destructive_audit IS
  'Private metadata-only audit of committed DELETE and TRUNCATE operations on public.tasks and public.executions. No FK references mutable project/task/execution rows so records survive cascades. Not tamper-proof against a postgres superuser disabling triggers.';
COMMENT ON COLUMN private.task_destructive_audit.authenticated_user_id IS
  'auth.uid() at operation time; NULL for trusted postgres MCP sessions without a JWT.';
COMMENT ON COLUMN private.task_destructive_audit.system_principal_id IS
  'Transaction-bound RAE system principal, when present.';
COMMENT ON COLUMN private.task_destructive_audit.owner_mcp_owner_id IS
  'Transaction-bound human Owner-MCP principal, when present.';

ALTER TABLE private.task_destructive_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.task_destructive_audit FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.task_destructive_audit FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE private.task_destructive_audit_id_seq FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.prevent_task_destructive_audit_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog','private'
AS $function$
BEGIN
  RAISE EXCEPTION USING
    errcode='55000',
    message='TASK_DESTRUCTIVE_AUDIT_APPEND_ONLY';
END;
$function$;

REVOKE ALL ON FUNCTION private.prevent_task_destructive_audit_mutation()
  FROM PUBLIC, anon, authenticated;

CREATE TRIGGER task_destructive_audit_append_only_row
BEFORE UPDATE OR DELETE ON private.task_destructive_audit
FOR EACH ROW EXECUTE FUNCTION private.prevent_task_destructive_audit_mutation();

CREATE TRIGGER task_destructive_audit_append_only_truncate
BEFORE TRUNCATE ON private.task_destructive_audit
FOR EACH STATEMENT EXECUTE FUNCTION private.prevent_task_destructive_audit_mutation();

ALTER TABLE private.task_destructive_audit
  ENABLE ALWAYS TRIGGER task_destructive_audit_append_only_row;
ALTER TABLE private.task_destructive_audit
  ENABLE ALWAYS TRIGGER task_destructive_audit_append_only_truncate;

CREATE OR REPLACE FUNCTION private.capture_task_destructive_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog','public','auth','private'
AS $function$
DECLARE
  v_row jsonb;
  v_project_id uuid;
  v_task_id uuid;
  v_execution_id uuid;
  v_parent_task_id uuid;
  v_worker_id uuid;
  v_task_type text;
  v_task_status text;
  v_execution_status text;
  v_attempt integer;
  v_system_principal_id uuid;
  v_owner_mcp_owner_id uuid;
BEGIN
  IF TG_OP='TRUNCATE' THEN
    INSERT INTO private.task_destructive_audit(
      transaction_id,operation,relation_name,
      session_user_name,database_user_name,authenticated_user_id,
      system_principal_id,owner_mcp_owner_id,backend_pid,
      application_name,client_addr,trigger_depth
    )
    VALUES(
      txid_current(),TG_OP,TG_TABLE_NAME,
      session_user,current_user,auth.uid(),
      nullif(current_setting('rae.system_principal_id',true),'')::uuid,
      nullif(current_setting('rae.owner_mcp_owner_id',true),'')::uuid,
      pg_backend_pid(),coalesce(current_setting('application_name',true),''),
      inet_client_addr(),pg_trigger_depth()
    );
    RETURN NULL;
  END IF;

  v_row := to_jsonb(OLD);

  IF TG_TABLE_NAME='tasks' THEN
    v_project_id := nullif(v_row->>'project_id','')::uuid;
    v_task_id := nullif(v_row->>'id','')::uuid;
    v_parent_task_id := nullif(v_row->>'parent_task_id','')::uuid;
    v_worker_id := nullif(v_row->>'assigned_worker_id','')::uuid;
    v_task_type := v_row->>'task_type';
    v_task_status := v_row->>'status';
    v_execution_id := nullif(v_row->>'current_execution_id','')::uuid;
  ELSIF TG_TABLE_NAME='executions' THEN
    v_execution_id := nullif(v_row->>'id','')::uuid;
    v_task_id := nullif(v_row->>'task_id','')::uuid;
    v_worker_id := nullif(v_row->>'worker_id','')::uuid;
    v_execution_status := v_row->>'status';
    v_attempt := nullif(v_row->>'attempt','')::integer;

    SELECT t.project_id,t.parent_task_id,t.task_type,t.status
    INTO v_project_id,v_parent_task_id,v_task_type,v_task_status
    FROM public.tasks t
    WHERE t.id=v_task_id;

    IF v_project_id IS NULL AND v_worker_id IS NOT NULL THEN
      SELECT w.project_id INTO v_project_id
      FROM public.workers w
      WHERE w.id=v_worker_id;
    END IF;
  ELSE
    RAISE EXCEPTION 'Unsupported task destructive audit relation: %',TG_TABLE_NAME;
  END IF;

  INSERT INTO private.task_destructive_audit(
    transaction_id,operation,relation_name,project_id,task_id,
    execution_id,parent_task_id,worker_id,task_type,task_status,
    execution_status,attempt,session_user_name,database_user_name,
    authenticated_user_id,system_principal_id,owner_mcp_owner_id,
    backend_pid,application_name,client_addr,trigger_depth
  )
  VALUES(
    txid_current(),TG_OP,TG_TABLE_NAME,v_project_id,v_task_id,
    v_execution_id,v_parent_task_id,v_worker_id,v_task_type,v_task_status,
    v_execution_status,v_attempt,session_user,current_user,auth.uid(),
    nullif(current_setting('rae.system_principal_id',true),'')::uuid,
    nullif(current_setting('rae.owner_mcp_owner_id',true),'')::uuid,
    pg_backend_pid(),coalesce(current_setting('application_name',true),''),
    inet_client_addr(),pg_trigger_depth()
  );

  RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION private.capture_task_destructive_audit()
  FROM PUBLIC, anon, authenticated;

CREATE TRIGGER tasks_destructive_audit_delete
AFTER DELETE ON public.tasks
FOR EACH ROW EXECUTE FUNCTION private.capture_task_destructive_audit();

CREATE TRIGGER tasks_destructive_audit_truncate
AFTER TRUNCATE ON public.tasks
FOR EACH STATEMENT EXECUTE FUNCTION private.capture_task_destructive_audit();

CREATE TRIGGER executions_destructive_audit_delete
AFTER DELETE ON public.executions
FOR EACH ROW EXECUTE FUNCTION private.capture_task_destructive_audit();

CREATE TRIGGER executions_destructive_audit_truncate
AFTER TRUNCATE ON public.executions
FOR EACH STATEMENT EXECUTE FUNCTION private.capture_task_destructive_audit();

ALTER TABLE public.tasks ENABLE ALWAYS TRIGGER tasks_destructive_audit_delete;
ALTER TABLE public.tasks ENABLE ALWAYS TRIGGER tasks_destructive_audit_truncate;
ALTER TABLE public.executions ENABLE ALWAYS TRIGGER executions_destructive_audit_delete;
ALTER TABLE public.executions ENABLE ALWAYS TRIGGER executions_destructive_audit_truncate;

-- Pure edge validator: accepts a JSON snapshot and returns missing/cross-project
-- references. Keeping this pure makes impossible states testable without
-- disabling or weakening any foreign-key constraints.
CREATE OR REPLACE FUNCTION private.task_integrity_findings_from_edges(p_edges jsonb)
RETURNS TABLE(
  finding_code text,
  source_relation text,
  row_id text,
  reference_name text,
  referenced_id uuid,
  source_project_id uuid,
  target_project_id uuid
)
LANGUAGE sql
IMMUTABLE
SET search_path TO 'pg_catalog'
AS $function$
  SELECT
    CASE
      WHEN NOT coalesce(edge.target_found,false) THEN 'missing_reference'
      ELSE 'cross_project_reference'
    END,
    edge.source_relation,
    edge.row_id,
    edge.reference_name,
    edge.referenced_id,
    edge.source_project_id,
    edge.target_project_id
  FROM jsonb_to_recordset(coalesce(p_edges,'[]'::jsonb)) AS edge(
    source_relation text,
    row_id text,
    reference_name text,
    referenced_id uuid,
    source_project_id uuid,
    target_found boolean,
    target_project_id uuid
  )
  WHERE edge.referenced_id IS NOT NULL
    AND (
      NOT coalesce(edge.target_found,false)
      OR edge.target_project_id IS DISTINCT FROM edge.source_project_id
    );
$function$;

REVOKE ALL ON FUNCTION private.task_integrity_findings_from_edges(jsonb)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.task_integrity_findings(p_project_id uuid)
RETURNS TABLE(
  finding_code text,
  source_relation text,
  row_id text,
  reference_name text,
  referenced_id uuid,
  source_project_id uuid,
  target_project_id uuid
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog','public','auth','private'
AS $function$
DECLARE
  v_edges jsonb;
BEGIN
  PERFORM private.assert_owner(p_project_id);

  IF p_project_id IS NULL THEN
    RAISE EXCEPTION USING errcode='22023',message='PROJECT_ID_REQUIRED';
  END IF;

  WITH edges AS (
    -- Task hierarchy, repair target and Worker ownership.
    SELECT 'tasks'::text AS source_relation,t.id::text AS row_id,
      'parent_task_id'::text AS reference_name,t.parent_task_id AS referenced_id,
      t.project_id AS source_project_id,(target.id IS NOT NULL) AS target_found,
      target.project_id AS target_project_id
    FROM public.tasks t
    LEFT JOIN public.tasks target
      ON target.id=t.parent_task_id
    WHERE t.project_id=p_project_id AND t.parent_task_id IS NOT NULL

    UNION ALL
    SELECT 'tasks',t.id::text,'fixes_task_id',t.fixes_task_id,t.project_id,
      target.id IS NOT NULL,target.project_id
    FROM public.tasks t
    LEFT JOIN public.tasks target ON target.id=t.fixes_task_id
    WHERE t.project_id=p_project_id AND t.fixes_task_id IS NOT NULL

    UNION ALL
    SELECT 'tasks',t.id::text,'assigned_worker_id',t.assigned_worker_id,t.project_id,
      target.id IS NOT NULL,target.project_id
    FROM public.tasks t
    LEFT JOIN public.workers target ON target.id=t.assigned_worker_id
    WHERE t.project_id=p_project_id AND t.assigned_worker_id IS NOT NULL

    UNION ALL
    SELECT 'tasks',t.id::text,'created_by_worker_id',t.created_by_worker_id,t.project_id,
      target.id IS NOT NULL,target.project_id
    FROM public.tasks t
    LEFT JOIN public.workers target ON target.id=t.created_by_worker_id
    WHERE t.project_id=p_project_id AND t.created_by_worker_id IS NOT NULL

    UNION ALL
    -- Execution owner and task references. Worker project scope lets the
    -- monitor attribute an execution even when its task reference is missing.
    SELECT 'executions',e.id::text,'task_id',e.task_id,
      coalesce(t.project_id,w.project_id),t.id IS NOT NULL,t.project_id
    FROM public.executions e
    LEFT JOIN public.tasks t ON t.id=e.task_id
    LEFT JOIN public.workers w ON w.id=e.worker_id
    WHERE coalesce(t.project_id,w.project_id)=p_project_id

    UNION ALL
    SELECT 'executions',e.id::text,'worker_id',e.worker_id,t.project_id,
      w.id IS NOT NULL,w.project_id
    FROM public.executions e
    JOIN public.tasks t ON t.id=e.task_id AND t.project_id=p_project_id
    LEFT JOIN public.workers w ON w.id=e.worker_id
    WHERE e.worker_id IS NOT NULL

    UNION ALL
    -- Task execution pointers must identify an execution for that same task.
    SELECT 'tasks',t.id::text,'current_execution_id',t.current_execution_id,t.project_id,
      e.id IS NOT NULL,CASE WHEN e.id IS NOT NULL THEN t.project_id END
    FROM public.tasks t
    LEFT JOIN public.executions e
      ON e.id=t.current_execution_id AND e.task_id=t.id
    WHERE t.project_id=p_project_id AND t.current_execution_id IS NOT NULL

    UNION ALL
    SELECT 'tasks',t.id::text,'latest_delivery_task_id',t.latest_delivery_task_id,t.project_id,
      d.id IS NOT NULL,d.project_id
    FROM public.tasks t
    LEFT JOIN public.tasks d ON d.id=t.latest_delivery_task_id
    WHERE t.project_id=p_project_id AND t.latest_delivery_task_id IS NOT NULL

    UNION ALL
    SELECT 'tasks',t.id::text,'latest_delivery_execution_id',t.latest_delivery_execution_id,t.project_id,
      e.id IS NOT NULL,CASE WHEN e.id IS NOT NULL THEN t.project_id END
    FROM public.tasks t
    LEFT JOIN public.executions e
      ON e.id=t.latest_delivery_execution_id
     AND e.task_id=t.latest_delivery_task_id
    WHERE t.project_id=p_project_id AND (
      t.latest_delivery_execution_id IS NOT NULL
      OR t.latest_delivery_task_id IS NOT NULL
    )

    UNION ALL
    SELECT 'tasks',t.id::text,'latest_review_task_id',t.latest_review_task_id,t.project_id,
      r.id IS NOT NULL AND r.task_type='review',r.project_id
    FROM public.tasks t
    LEFT JOIN public.tasks r ON r.id=t.latest_review_task_id
    WHERE t.project_id=p_project_id AND t.latest_review_task_id IS NOT NULL

    UNION ALL
    SELECT 'tasks',t.id::text,'review_target_original_task_id',
      t.review_target_original_task_id,t.project_id,
      original.id IS NOT NULL,original.project_id
    FROM public.tasks t
    LEFT JOIN public.tasks original ON original.id=t.review_target_original_task_id
    WHERE t.project_id=p_project_id AND t.review_target_original_task_id IS NOT NULL

    UNION ALL
    SELECT 'tasks',t.id::text,'review_target_delivery_task_id',
      t.review_target_delivery_task_id,t.project_id,
      delivery.id IS NOT NULL,delivery.project_id
    FROM public.tasks t
    LEFT JOIN public.tasks delivery ON delivery.id=t.review_target_delivery_task_id
    WHERE t.project_id=p_project_id AND t.review_target_delivery_task_id IS NOT NULL

    UNION ALL
    SELECT 'tasks',t.id::text,'review_target_execution_id',
      t.review_target_execution_id,t.project_id,
      e.id IS NOT NULL,CASE WHEN e.id IS NOT NULL THEN t.project_id END
    FROM public.tasks t
    LEFT JOIN public.executions e
      ON e.id=t.review_target_execution_id
     AND e.task_id=t.review_target_delivery_task_id
    WHERE t.project_id=p_project_id AND t.review_target_execution_id IS NOT NULL

    UNION ALL
    -- Durable task events and artifact metadata must remain project/task aligned.
    SELECT 'task_events',ev.id::text,'task_id',ev.task_id,ev.project_id,
      t.id IS NOT NULL,t.project_id
    FROM public.task_events ev
    LEFT JOIN public.tasks t ON t.id=ev.task_id
    WHERE ev.project_id=p_project_id

    UNION ALL
    SELECT 'task_events',ev.id::text,'execution_id',ev.execution_id,ev.project_id,
      e.id IS NOT NULL,CASE WHEN e.id IS NOT NULL THEN ev.project_id END
    FROM public.task_events ev
    LEFT JOIN public.executions e
      ON e.id=ev.execution_id AND e.task_id=ev.task_id
    WHERE ev.project_id=p_project_id AND ev.execution_id IS NOT NULL

    UNION ALL
    SELECT 'task_events',ev.id::text,'worker_id',ev.worker_id,ev.project_id,
      w.id IS NOT NULL,w.project_id
    FROM public.task_events ev
    LEFT JOIN public.workers w ON w.id=ev.worker_id
    WHERE ev.project_id=p_project_id AND ev.worker_id IS NOT NULL

    UNION ALL
    SELECT 'artifacts',a.id::text,'task_id',a.task_id,
      coalesce(execution_task.project_id,execution_worker.project_id,t.project_id),
      t.id IS NOT NULL,t.project_id
    FROM public.artifacts a
    LEFT JOIN public.tasks t ON t.id=a.task_id
    LEFT JOIN public.executions e ON e.id=a.execution_id
    LEFT JOIN public.tasks execution_task ON execution_task.id=e.task_id
    LEFT JOIN public.workers execution_worker ON execution_worker.id=e.worker_id
    WHERE coalesce(execution_task.project_id,execution_worker.project_id,t.project_id)=p_project_id

    UNION ALL
    SELECT 'artifacts',a.id::text,'execution_id',a.execution_id,
      coalesce(t.project_id,execution_task.project_id,execution_worker.project_id),
      e.id IS NOT NULL AND e.task_id=a.task_id,
      execution_task.project_id
    FROM public.artifacts a
    LEFT JOIN public.tasks t ON t.id=a.task_id
    LEFT JOIN public.executions e ON e.id=a.execution_id
    LEFT JOIN public.tasks execution_task ON execution_task.id=e.task_id
    LEFT JOIN public.workers execution_worker ON execution_worker.id=e.worker_id
    WHERE a.execution_id IS NOT NULL
      AND coalesce(t.project_id,execution_task.project_id,execution_worker.project_id)=p_project_id
  )
  SELECT coalesce(jsonb_agg(to_jsonb(edges)),'[]'::jsonb)
  INTO v_edges
  FROM edges;

  RETURN QUERY
  SELECT *
  FROM private.task_integrity_findings_from_edges(v_edges);
END;
$function$;

REVOKE ALL ON FUNCTION private.task_integrity_findings(uuid)
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION private.task_integrity_findings(uuid) IS
  'Read-only project-scoped scan of task, execution, Worker, event and artifact references. Requires a trusted Owner/System Owner context and returns only missing or cross-project reference metadata.';

COMMIT;
