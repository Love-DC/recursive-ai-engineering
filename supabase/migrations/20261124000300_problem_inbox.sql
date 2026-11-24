-- Unified, project-scoped problem inbox for cross-session RAE reporting.
-- Additive candidate migration. Apply only after independent review and an authorized rollout.
-- Reports are not claimable tasks; actionable work links to the ordinary task pool.

CREATE TABLE public.problem_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  reported_by_worker_id uuid,
  category text NOT NULL CHECK (category IN
    ('defect','blocker','risk','security','operations','decision','opportunity','other')),
  severity text NOT NULL CHECK (severity IN ('info','low','medium','high','critical')),
  status text NOT NULL DEFAULT 'open' CHECK (status IN
    ('open','triaged','in_progress','owner_input_required','resolved','wont_fix')),
  title text NOT NULL CHECK (length(btrim(title)) BETWEEN 5 AND 200),
  summary text NOT NULL CHECK (length(btrim(summary)) BETWEEN 1 AND 4000),
  impact text NOT NULL CHECK (length(btrim(impact)) BETWEEN 1 AND 2000),
  recommended_action text,
  owner_question text,
  evidence jsonb NOT NULL CHECK (CASE WHEN jsonb_typeof(evidence)='array' THEN jsonb_array_length(evidence)>0 ELSE false END),
  source text NOT NULL CHECK (source IN ('conversation','github','ci','supabase','operations','automated','other')),
  source_ref text,
  fingerprint text NOT NULL CHECK (length(btrim(fingerprint)) BETWEEN 3 AND 200),
  linked_task_id uuid,
  linked_pr_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  CONSTRAINT problem_reports_id_project_uq UNIQUE (id,project_id),
  CONSTRAINT problem_reports_worker_project_fk
    FOREIGN KEY (reported_by_worker_id,project_id)
    REFERENCES public.workers(id,project_id) ON DELETE RESTRICT,
  CONSTRAINT problem_reports_task_project_fk
    FOREIGN KEY (linked_task_id,project_id)
    REFERENCES public.tasks(id,project_id) ON DELETE RESTRICT,
  CONSTRAINT problem_reports_owner_question_ck CHECK (
    (status <> 'owner_input_required') OR
    (owner_question IS NOT NULL AND length(btrim(owner_question)) BETWEEN 1 AND 2000)
  )
);

CREATE UNIQUE INDEX problem_reports_active_fingerprint_uq
  ON public.problem_reports(project_id,fingerprint)
  WHERE status IN ('open','triaged','in_progress','owner_input_required');
CREATE INDEX problem_reports_owner_inbox_idx
  ON public.problem_reports(project_id,status,severity,created_at DESC);
CREATE INDEX problem_reports_unresolved_idx
  ON public.problem_reports(severity,created_at DESC)
  WHERE status IN ('open','triaged','in_progress','owner_input_required');

CREATE TABLE public.problem_report_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  report_id uuid NOT NULL,
  project_id uuid NOT NULL,
  actor_worker_id uuid,
  event_type text NOT NULL CHECK (length(btrim(event_type)) BETWEEN 1 AND 80),
  payload jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(payload)='object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT problem_report_events_report_fk
    FOREIGN KEY (report_id,project_id)
    REFERENCES public.problem_reports(id,project_id) ON DELETE CASCADE,
  CONSTRAINT problem_report_events_worker_fk
    FOREIGN KEY (actor_worker_id,project_id)
    REFERENCES public.workers(id,project_id) ON DELETE RESTRICT
);
CREATE INDEX problem_report_events_history_idx
  ON public.problem_report_events(report_id,id);

ALTER TABLE public.problem_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.problem_report_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.problem_reports,public.problem_report_events FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.reject_problem_report_event_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'pg_catalog'
AS $function$
BEGIN
  RAISE EXCEPTION USING errcode='55000',message='PROBLEM_REPORT_EVENTS_APPEND_ONLY';
END;
$function$;
CREATE TRIGGER problem_report_events_append_only
  BEFORE UPDATE OR DELETE ON public.problem_report_events
  FOR EACH ROW EXECUTE FUNCTION private.reject_problem_report_event_mutation();

CREATE OR REPLACE FUNCTION public.report_problem(
  p_project_id uuid,
  p_worker_id uuid,
  p_payload jsonb,
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog','public','auth','private'
AS $function$
DECLARE
  v_hash text;
  v_replay jsonb;
  v_existing public.problem_reports%rowtype;
  v_id uuid;
  v_fingerprint text;
  v_status text;
  v_response jsonb;
BEGIN
  PERFORM private.assert_owner(p_project_id);
  IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION USING errcode='22023',message='PROBLEM_REPORT_PAYLOAD_MUST_BE_OBJECT';
  END IF;
  IF p_worker_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.workers
    WHERE id=p_worker_id AND project_id=p_project_id AND status='active'
  ) THEN
    RAISE EXCEPTION USING errcode='42501',message='WORKER_PROJECT_MISMATCH';
  END IF;

  v_fingerprint:=lower(btrim(coalesce(p_payload->>'fingerprint','')));
  v_status:=coalesce(p_payload->>'status','open');
  IF length(v_fingerprint) NOT BETWEEN 3 AND 200 THEN
    RAISE EXCEPTION USING errcode='22023',message='PROBLEM_REPORT_FINGERPRINT_REQUIRED';
  END IF;
  IF length(btrim(coalesce(p_payload->>'title',''))) NOT BETWEEN 5 AND 200
     OR length(btrim(coalesce(p_payload->>'summary',''))) NOT BETWEEN 1 AND 4000
     OR length(btrim(coalesce(p_payload->>'impact',''))) NOT BETWEEN 1 AND 2000
     OR coalesce(p_payload->>'category','') NOT IN
       ('defect','blocker','risk','security','operations','decision','opportunity','other')
     OR coalesce(p_payload->>'severity','') NOT IN ('info','low','medium','high','critical')
     OR coalesce(p_payload->>'source','') NOT IN
       ('conversation','github','ci','supabase','operations','automated','other')
     OR v_status NOT IN ('open','owner_input_required') THEN
    RAISE EXCEPTION USING errcode='22023',message='INVALID_PROBLEM_REPORT_FIELDS';
  END IF;
  IF v_status='owner_input_required'
     AND length(btrim(coalesce(p_payload->>'owner_question',''))) NOT BETWEEN 1 AND 2000 THEN
    RAISE EXCEPTION USING errcode='22023',message='OWNER_QUESTION_REQUIRED';
  END IF;
  IF jsonb_typeof(p_payload->'evidence') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION USING errcode='22023',message='PROBLEM_REPORT_EVIDENCE_REQUIRED';
  END IF;
  IF jsonb_array_length(p_payload->'evidence')=0 OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(p_payload->'evidence') AS e(item)
       WHERE jsonb_typeof(e.item) IS DISTINCT FROM 'object'
          OR length(btrim(coalesce(e.item->>'kind','')))=0
          OR length(btrim(coalesce(e.item->>'ref','')))=0
          OR length(btrim(coalesce(e.item->>'observation','')))=0
     ) THEN
    RAISE EXCEPTION USING errcode='22023',message='PROBLEM_REPORT_EVIDENCE_REQUIRED';
  END IF;

  v_hash:=private.request_hash(jsonb_build_object(
    'project_id',p_project_id,'worker_id',p_worker_id,'payload',p_payload
  ));
  v_replay:=private.idempotency_get(p_project_id,'report_problem',p_idempotency_key,v_hash);
  IF v_replay IS NOT NULL THEN RETURN v_replay; END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_project_id::text||':'||v_fingerprint,0));
  SELECT * INTO v_existing FROM public.problem_reports
    WHERE project_id=p_project_id AND fingerprint=v_fingerprint
      AND status IN ('open','triaged','in_progress','owner_input_required')
    LIMIT 1;
  IF FOUND THEN
    v_response:=jsonb_build_object('success',true,'data',jsonb_build_object(
      'created',false,'duplicate',true,'report_id',v_existing.id,'status',v_existing.status
    ));
    PERFORM private.idempotency_put(p_project_id,'report_problem',p_idempotency_key,v_hash,v_response);
    RETURN v_response;
  END IF;

  INSERT INTO public.problem_reports(
    project_id,reported_by_worker_id,category,severity,status,title,summary,impact,
    recommended_action,owner_question,evidence,source,source_ref,fingerprint
  ) VALUES (
    p_project_id,p_worker_id,p_payload->>'category',p_payload->>'severity',v_status,
    btrim(p_payload->>'title'),btrim(p_payload->>'summary'),btrim(p_payload->>'impact'),
    nullif(btrim(coalesce(p_payload->>'recommended_action','')),''),
    nullif(btrim(coalesce(p_payload->>'owner_question','')),''),
    p_payload->'evidence',p_payload->>'source',
    nullif(btrim(coalesce(p_payload->>'source_ref','')),''),v_fingerprint
  ) RETURNING id INTO v_id;

  INSERT INTO public.problem_report_events(report_id,project_id,actor_worker_id,event_type,payload)
  VALUES (v_id,p_project_id,p_worker_id,'reported',
    jsonb_build_object('status',v_status,'severity',p_payload->>'severity','fingerprint',v_fingerprint));
  v_response:=jsonb_build_object('success',true,'data',jsonb_build_object(
    'created',true,'duplicate',false,'report_id',v_id,'status',v_status
  ));
  PERFORM private.idempotency_put(p_project_id,'report_problem',p_idempotency_key,v_hash,v_response);
  RETURN v_response;
END;
$function$;

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
DECLARE v_items jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
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
    WHERE p.owner_id=auth.uid()
      AND p.status='active'
      AND (p_status IS NULL
        OR (p_status='unresolved' AND r.status IN ('open','triaged','in_progress','owner_input_required'))
        OR r.status=p_status)
      AND (p_severity IS NULL OR r.severity=p_severity)
    ORDER BY r.created_at DESC
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
DECLARE v_project_id uuid; v_result jsonb;
BEGIN
  SELECT project_id INTO v_project_id FROM public.problem_reports WHERE id=p_report_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING errcode='P0002',message='PROBLEM_REPORT_NOT_FOUND'; END IF;
  PERFORM private.assert_owner(v_project_id);
  SELECT jsonb_build_object(
    'report',to_jsonb(r),
    'project',jsonb_build_object('name',p.name,'github_repo',p.github_repo),
    'events',coalesce((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id)
      FROM public.problem_report_events e WHERE e.report_id=r.id),'[]'::jsonb)
  ) INTO v_result
  FROM public.problem_reports r JOIN public.projects p ON p.id=r.project_id
  WHERE r.id=p_report_id;
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
  v_hash text;
  v_replay jsonb;
  v_response jsonb;
BEGIN
  SELECT * INTO v_report FROM public.problem_reports WHERE id=p_report_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING errcode='P0002',message='PROBLEM_REPORT_NOT_FOUND'; END IF;
  PERFORM private.assert_owner(v_report.project_id);
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

  SELECT * INTO v_report FROM public.problem_reports WHERE id=p_report_id FOR UPDATE;
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

REVOKE ALL ON FUNCTION public.report_problem(uuid,uuid,jsonb,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.report_problem(uuid,uuid,jsonb,text) TO authenticated;
REVOKE ALL ON FUNCTION public.list_problem_reports(text,text,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.list_problem_reports(text,text,integer) TO authenticated;
REVOKE ALL ON FUNCTION public.get_problem_report(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_problem_report(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.update_problem_report(uuid,text,text,uuid,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.update_problem_report(uuid,text,text,uuid,text,text) TO authenticated;
