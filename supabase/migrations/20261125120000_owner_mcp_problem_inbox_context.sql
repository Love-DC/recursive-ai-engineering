-- Extend the existing Problem Inbox owner RPCs to the trusted Owner-MCP context.
-- This remains a private postgres-session trust path; normal JWT owner checks are unchanged.
BEGIN;

CREATE OR REPLACE FUNCTION private.owner_mcp_context_owner_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
DECLARE
  v_project_id uuid;
  v_owner_id uuid;
BEGIN
  -- A transaction-local GUC alone is never an authenticated identity.
  IF session_user <> 'postgres' OR auth.uid() IS NOT NULL THEN
    RETURN NULL;
  END IF;
  IF current_setting('rae.owner_mcp_version', true) IS DISTINCT FROM 'v1' THEN
    RETURN NULL;
  END IF;

  BEGIN
    v_project_id := nullif(current_setting('rae.owner_mcp_project_id', true), '')::uuid;
    v_owner_id := nullif(current_setting('rae.owner_mcp_owner_id', true), '')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RETURN NULL;
  END;

  IF v_project_id IS NULL
    OR v_owner_id IS NULL
    OR NOT private.owner_mcp_context_matches(v_project_id) THEN
    RETURN NULL;
  END IF;
  RETURN v_owner_id;
END;
$function$;

REVOKE ALL ON FUNCTION private.owner_mcp_context_owner_id()
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION private.owner_mcp_context_owner_id() IS
  'Returns the Owner bound to a validated transaction-local trusted postgres Supabase MCP context. Enables the explicitly cross-project Owner Problem Inbox without exposing the context to JWT clients.';

CREATE OR REPLACE FUNCTION public.list_problem_reports(
  p_status text DEFAULT NULL,
  p_severity text DEFAULT NULL,
  p_limit integer DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog','public','auth','private'
AS $function$
DECLARE
  v_items jsonb;
  v_owner_id uuid;
BEGIN
  v_owner_id := auth.uid();
  IF v_owner_id IS NULL THEN
    v_owner_id := private.owner_mcp_context_owner_id();
  END IF;
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION USING errcode='28000',message='UNAUTHENTICATED';
  END IF;

  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION USING errcode='22023',message='PROBLEM_REPORT_LIMIT_OUT_OF_RANGE';
  END IF;
  IF p_status IS NOT NULL AND p_status NOT IN
    ('unresolved','open','triaged','in_progress','owner_input_required','resolved','wont_fix') THEN
    RAISE EXCEPTION USING errcode='22023',message='INVALID_PROBLEM_REPORT_STATUS';
  END IF;
  IF p_severity IS NOT NULL AND p_severity NOT IN ('info','low','medium','high','critical') THEN
    RAISE EXCEPTION USING errcode='22023',message='INVALID_PROBLEM_REPORT_SEVERITY';
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY
    CASE x.severity WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END,
    x.created_at DESC),'[]'::jsonb)
  INTO v_items
  FROM (
    SELECT r.*,p.name AS project_name,p.github_repo
    FROM public.problem_reports r
    JOIN public.projects p ON p.id=r.project_id
    WHERE p.owner_id=v_owner_id
      AND p.status='active'
      AND (p_status IS NULL
        OR (p_status='unresolved' AND r.status IN ('open','triaged','in_progress','owner_input_required'))
        OR r.status=p_status)
      AND (p_severity IS NULL OR r.severity=p_severity)
    ORDER BY CASE r.severity
      WHEN 'critical' THEN 0
      WHEN 'high' THEN 1
      WHEN 'medium' THEN 2
      WHEN 'low' THEN 3
      ELSE 4
    END, r.created_at DESC
    LIMIT p_limit
  ) x;

  RETURN jsonb_build_object('success',true,'data',v_items);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_problem_report(p_report_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog','public','auth','private'
AS $function$
DECLARE
  v_owner_id uuid;
  v_project_id uuid;
  v_result jsonb;
BEGIN
  v_owner_id := auth.uid();
  IF v_owner_id IS NULL THEN
    v_owner_id := private.owner_mcp_context_owner_id();
  END IF;

  SELECT r.project_id INTO v_project_id
  FROM public.problem_reports r
  JOIN public.projects p ON p.id=r.project_id
  WHERE r.id=p_report_id AND p.owner_id=v_owner_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='P0002',message='PROBLEM_REPORT_NOT_FOUND';
  END IF;

  SELECT jsonb_build_object(
    'report',to_jsonb(r),
    'project',jsonb_build_object('name',p.name,'github_repo',p.github_repo),
    'events',coalesce((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id)
      FROM public.problem_report_events e WHERE e.report_id=r.id),'[]'::jsonb)
  ) INTO v_result
  FROM public.problem_reports r
  JOIN public.projects p ON p.id=r.project_id
  WHERE r.id=p_report_id AND r.project_id=v_project_id AND p.owner_id=v_owner_id;

  RETURN jsonb_build_object('success',true,'data',v_result);
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_problem_report(
  p_report_id uuid,
  p_status text,
  p_note text,
  p_linked_task_id uuid,
  p_linked_pr_url text,
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog','public','auth','private'
AS $function$
DECLARE
  v_report public.problem_reports%rowtype;
  v_owner_id uuid;
  v_hash text;
  v_replay jsonb;
  v_response jsonb;
BEGIN
  v_owner_id := auth.uid();
  IF v_owner_id IS NULL THEN
    v_owner_id := private.owner_mcp_context_owner_id();
  END IF;

  SELECT r.* INTO v_report
  FROM public.problem_reports r
  JOIN public.projects p ON p.id=r.project_id
  WHERE r.id=p_report_id AND p.owner_id=v_owner_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='P0002',message='PROBLEM_REPORT_NOT_FOUND';
  END IF;

  IF p_status IS NULL OR p_status NOT IN ('open','triaged','in_progress','owner_input_required','resolved','wont_fix')
     OR length(btrim(coalesce(p_note,''))) NOT BETWEEN 1 AND 2000 THEN
    RAISE EXCEPTION USING errcode='22023',message='INVALID_PROBLEM_REPORT_UPDATE';
  END IF;
  IF p_status='owner_input_required' AND
     length(btrim(coalesce(v_report.owner_question,'')))=0 THEN
    RAISE EXCEPTION USING errcode='22023',message='OWNER_QUESTION_REQUIRED';
  END IF;

  v_hash:=private.request_hash(jsonb_build_object(
    'report_id',p_report_id,'status',p_status,'note',p_note,
    'linked_task_id',p_linked_task_id,'linked_pr_url',p_linked_pr_url
  ));
  v_replay:=private.idempotency_get(v_report.project_id,'update_problem_report',p_idempotency_key,v_hash);
  IF v_replay IS NOT NULL THEN RETURN v_replay; END IF;

  SELECT * INTO v_report
  FROM public.problem_reports
  WHERE id=p_report_id AND project_id=v_report.project_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode='P0002',message='PROBLEM_REPORT_NOT_FOUND';
  END IF;
  IF v_report.status IN ('resolved','wont_fix') AND p_status NOT IN ('open','triaged') THEN
    RAISE EXCEPTION USING errcode='55000',message='PROBLEM_REPORT_TERMINAL_REOPEN_REQUIRED';
  END IF;
  IF p_linked_task_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.tasks WHERE id=p_linked_task_id AND project_id=v_report.project_id
  ) THEN
    RAISE EXCEPTION USING errcode='23503',message='PROBLEM_REPORT_TASK_PROJECT_MISMATCH';
  END IF;

  UPDATE public.problem_reports SET
    status=p_status,
    linked_task_id=coalesce(p_linked_task_id,linked_task_id),
    linked_pr_url=coalesce(nullif(btrim(coalesce(p_linked_pr_url,'')),''),linked_pr_url),
    resolved_at=CASE WHEN p_status IN ('resolved','wont_fix') THEN clock_timestamp() ELSE NULL END,
    updated_at=clock_timestamp()
  WHERE id=p_report_id;

  INSERT INTO public.problem_report_events(report_id,project_id,event_type,payload)
  VALUES (p_report_id,v_report.project_id,'status_changed',jsonb_build_object(
    'from',v_report.status,'to',p_status,'note',left(p_note,2000),
    'linked_task_id',p_linked_task_id,'linked_pr_url',p_linked_pr_url
  ));

  v_response:=jsonb_build_object('success',true,'data',jsonb_build_object(
    'report_id',p_report_id,'status',p_status
  ));
  PERFORM private.idempotency_put(v_report.project_id,'update_problem_report',p_idempotency_key,v_hash,v_response);
  RETURN v_response;
END;
$function$;

COMMENT ON FUNCTION public.list_problem_reports(text,text,integer) IS
  'Lists active-project Problem Inbox reports for the authenticated Owner or a validated transaction-local trusted Owner-MCP context.';
COMMENT ON FUNCTION public.get_problem_report(uuid) IS
  'Returns one Problem Inbox report and append-only history for the authenticated Owner or a validated transaction-local trusted Owner-MCP context.';
COMMENT ON FUNCTION public.update_problem_report(uuid,text,text,uuid,text,text) IS
  'Updates an Owner-scoped Problem Inbox report and appends its audit event for the authenticated Owner or a validated transaction-local trusted Owner-MCP context.';

COMMIT;
