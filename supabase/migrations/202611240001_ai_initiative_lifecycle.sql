-- Durable AI initiative, human-support, work-plan, and learning lifecycle.
-- Candidate migration only. Do not apply to production without separate review and authorization.
-- Dependencies are released in waves: only work items whose predecessors are accepted
-- are materialized into the ordinary claimable task queue.

CREATE TABLE public.initiatives (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  proposed_by_worker_id uuid,
  origin text NOT NULL CHECK (origin IN ('human_goal','ai_initiative','maintenance','collaborative_goal')),
  title text NOT NULL CHECK (length(btrim(title)) BETWEEN 5 AND 200),
  summary text NOT NULL CHECK (length(btrim(summary)) BETWEEN 1 AND 4000),
  rationale text NOT NULL CHECK (length(btrim(rationale)) BETWEEN 1 AND 4000),
  desired_outcome text NOT NULL CHECK (length(btrim(desired_outcome)) BETWEEN 1 AND 2000),
  scope jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(scope)='array'),
  evidence jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(evidence)='array'),
  risk text NOT NULL CHECK (risk IN ('low','medium','high')),
  resource_budget jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(resource_budget)='object'),
  support_needed jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(support_needed)='array'),
  deduplication_fingerprint text NOT NULL CHECK (length(btrim(deduplication_fingerprint)) BETWEEN 3 AND 200),
  status text NOT NULL DEFAULT 'proposed'
    CHECK (status IN ('proposed','approved','in_progress','completed','rejected','abandoned')),
  decision_note text,
  decided_at timestamptz,
  outcome_summary text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  CONSTRAINT initiatives_id_project_key UNIQUE (id,project_id),
  CONSTRAINT initiatives_proposer_same_project_fk
    FOREIGN KEY (proposed_by_worker_id,project_id)
    REFERENCES public.workers(id,project_id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX initiatives_active_fingerprint_uq
  ON public.initiatives(project_id,deduplication_fingerprint)
  WHERE status IN ('proposed','approved','in_progress');
CREATE INDEX initiatives_project_status_created_idx
  ON public.initiatives(project_id,status,created_at DESC);

CREATE TABLE public.initiative_work_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  initiative_id uuid NOT NULL,
  project_id uuid NOT NULL,
  work_key text NOT NULL CHECK (work_key ~ '^[a-z0-9][a-z0-9._-]{0,63}$'),
  title text NOT NULL CHECK (length(btrim(title)) BETWEEN 5 AND 200),
  description text NOT NULL CHECK (length(btrim(description)) BETWEEN 1 AND 4000),
  requirements jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(requirements)='object'),
  priority integer NOT NULL DEFAULT 100 CHECK (priority BETWEEN 0 AND 1000),
  requires_review boolean NOT NULL DEFAULT true,
  depends_on text[] NOT NULL DEFAULT '{}'::text[],
  task_id uuid,
  status text NOT NULL DEFAULT 'planned'
    CHECK (status IN ('planned','materialized','completed','cancelled')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT initiative_work_items_key_uq UNIQUE (initiative_id,work_key),
  CONSTRAINT initiative_work_items_id_initiative_uq UNIQUE (id,initiative_id),
  CONSTRAINT initiative_work_items_initiative_fk
    FOREIGN KEY (initiative_id,project_id)
    REFERENCES public.initiatives(id,project_id) ON DELETE CASCADE,
  CONSTRAINT initiative_work_items_task_fk
    FOREIGN KEY (task_id,project_id)
    REFERENCES public.tasks(id,project_id) ON DELETE RESTRICT,
  CONSTRAINT initiative_work_items_task_state_ck CHECK (
    (status='planned' AND task_id IS NULL) OR
    (status IN ('materialized','completed','cancelled'))
  )
);
CREATE UNIQUE INDEX initiative_work_items_task_uq
  ON public.initiative_work_items(task_id) WHERE task_id IS NOT NULL;
CREATE INDEX initiative_work_items_ready_idx
  ON public.initiative_work_items(initiative_id,status,created_at);

CREATE TABLE public.initiative_support_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  initiative_id uuid NOT NULL,
  project_id uuid NOT NULL,
  requested_by_worker_id uuid,
  request_kind text NOT NULL
    CHECK (request_kind IN ('capability','permission','access','external_service','spending','decision','physical_action','other')),
  capability text NOT NULL CHECK (length(btrim(capability)) BETWEEN 3 AND 300),
  rationale text NOT NULL CHECK (length(btrim(rationale)) BETWEEN 1 AND 3000),
  alternatives_checked jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(alternatives_checked)='array'),
  unlocks text NOT NULL CHECK (length(btrim(unlocks)) BETWEEN 1 AND 2000),
  requested_resources jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(requested_resources)='object'),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','granted','declined','withdrawn')),
  decision_note text,
  granted_scope jsonb,
  decided_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT initiative_support_requests_initiative_fk
    FOREIGN KEY (initiative_id,project_id)
    REFERENCES public.initiatives(id,project_id) ON DELETE CASCADE,
  CONSTRAINT initiative_support_requests_worker_fk
    FOREIGN KEY (requested_by_worker_id,project_id)
    REFERENCES public.workers(id,project_id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX initiative_support_one_pending_kind_uq
  ON public.initiative_support_requests(initiative_id,request_kind,capability)
  WHERE status='pending';
CREATE INDEX initiative_support_project_status_idx
  ON public.initiative_support_requests(project_id,status,created_at DESC);

CREATE TABLE public.initiative_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  initiative_id uuid NOT NULL,
  project_id uuid NOT NULL,
  actor_worker_id uuid,
  event_type text NOT NULL CHECK (length(btrim(event_type)) BETWEEN 1 AND 80),
  payload jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(payload)='object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT initiative_events_initiative_fk
    FOREIGN KEY (initiative_id,project_id)
    REFERENCES public.initiatives(id,project_id) ON DELETE CASCADE,
  CONSTRAINT initiative_events_worker_fk
    FOREIGN KEY (actor_worker_id,project_id)
    REFERENCES public.workers(id,project_id) ON DELETE RESTRICT
);
CREATE INDEX initiative_events_history_idx
  ON public.initiative_events(initiative_id,id);

CREATE TABLE public.initiative_learnings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  initiative_id uuid NOT NULL,
  project_id uuid NOT NULL,
  learning_fingerprint text NOT NULL CHECK (length(btrim(learning_fingerprint)) BETWEEN 3 AND 200),
  category text NOT NULL CHECK (category IN ('success','failure','constraint','architecture','process','discovery','other')),
  lesson text NOT NULL CHECK (length(btrim(lesson)) BETWEEN 1 AND 4000),
  evidence jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(evidence)='array'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT initiative_learnings_initiative_fk
    FOREIGN KEY (initiative_id,project_id)
    REFERENCES public.initiatives(id,project_id) ON DELETE CASCADE,
  CONSTRAINT initiative_learnings_fingerprint_uq UNIQUE (project_id,learning_fingerprint)
);
CREATE INDEX initiative_learnings_project_created_idx
  ON public.initiative_learnings(project_id,created_at DESC);

ALTER TABLE public.initiatives ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.initiative_work_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.initiative_support_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.initiative_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.initiative_learnings ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.initiatives,public.initiative_work_items,
  public.initiative_support_requests,public.initiative_events,public.initiative_learnings
  FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.reject_initiative_event_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'pg_catalog'
AS $function$
BEGIN
  RAISE EXCEPTION USING errcode='55000',message='INITIATIVE_EVENTS_APPEND_ONLY';
END;
$function$;
CREATE TRIGGER initiative_events_append_only
  BEFORE UPDATE OR DELETE ON public.initiative_events
  FOR EACH ROW EXECUTE FUNCTION private.reject_initiative_event_mutation();

CREATE OR REPLACE FUNCTION public.propose_initiative(
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
  v_origin text;
  v_fingerprint text;
  v_hash text;
  v_replay jsonb;
  v_existing public.initiatives%rowtype;
  v_learning public.initiative_learnings%rowtype;
  v_id uuid;
  v_response jsonb;
BEGIN
  PERFORM private.assert_owner(p_project_id);
  IF jsonb_typeof(p_payload)<>'object' THEN
    RAISE EXCEPTION USING errcode='22023',message='INITIATIVE_PAYLOAD_MUST_BE_OBJECT';
  END IF;
  IF p_worker_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.workers WHERE id=p_worker_id AND project_id=p_project_id AND status='active'
  ) THEN
    RAISE EXCEPTION USING errcode='42501',message='WORKER_PROJECT_MISMATCH';
  END IF;

  v_origin:=coalesce(p_payload->>'origin','ai_initiative');
  v_fingerprint:=lower(btrim(coalesce(p_payload->>'deduplication_fingerprint','')));
  IF v_origin NOT IN ('human_goal','ai_initiative','maintenance','collaborative_goal') THEN
    RAISE EXCEPTION USING errcode='22023',message='INVALID_INITIATIVE_ORIGIN';
  END IF;
  IF length(v_fingerprint) NOT BETWEEN 3 AND 200 THEN
    RAISE EXCEPTION USING errcode='22023',message='INITIATIVE_FINGERPRINT_REQUIRED';
  END IF;
  IF length(btrim(coalesce(p_payload->>'title',''))) NOT BETWEEN 5 AND 200
     OR length(btrim(coalesce(p_payload->>'summary',''))) NOT BETWEEN 1 AND 4000
     OR length(btrim(coalesce(p_payload->>'rationale',''))) NOT BETWEEN 1 AND 4000
     OR length(btrim(coalesce(p_payload->>'desired_outcome',''))) NOT BETWEEN 1 AND 2000 THEN
    RAISE EXCEPTION USING errcode='22023',message='INITIATIVE_CONTENT_REQUIRED';
  END IF;
  IF jsonb_typeof(coalesce(p_payload->'scope','[]'::jsonb)) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION USING errcode='22023',message='INITIATIVE_SCOPE_REQUIRED';
  END IF;
  IF jsonb_array_length(coalesce(p_payload->'scope','[]'::jsonb))=0 THEN
    RAISE EXCEPTION USING errcode='22023',message='INITIATIVE_SCOPE_REQUIRED';
  END IF;
  IF jsonb_typeof(coalesce(p_payload->'evidence','[]'::jsonb)) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION USING errcode='22023',message='INITIATIVE_EVIDENCE_REQUIRED';
  END IF;
  IF v_origin IN ('ai_initiative','maintenance')
     AND jsonb_array_length(coalesce(p_payload->'evidence','[]'::jsonb))=0 THEN
    RAISE EXCEPTION USING errcode='22023',message='INITIATIVE_EVIDENCE_REQUIRED';
  END IF;
  IF coalesce(p_payload->>'risk','') NOT IN ('low','medium','high')
     OR jsonb_typeof(coalesce(p_payload->'resource_budget','{}'::jsonb))<>'object'
     OR jsonb_typeof(coalesce(p_payload->'support_needed','[]'::jsonb))<>'array' THEN
    RAISE EXCEPTION USING errcode='22023',message='INVALID_INITIATIVE_RISK_OR_BUDGET';
  END IF;

  v_hash:=private.request_hash(jsonb_build_object(
    'project_id',p_project_id,'worker_id',p_worker_id,'payload',p_payload
  ));
  v_replay:=private.idempotency_get(p_project_id,'propose_initiative',p_idempotency_key,v_hash);
  IF v_replay IS NOT NULL THEN RETURN v_replay; END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_project_id::text||':'||v_fingerprint,0));
  SELECT * INTO v_existing FROM public.initiatives
    WHERE project_id=p_project_id AND deduplication_fingerprint=v_fingerprint
      AND status IN ('proposed','approved','in_progress')
    LIMIT 1;
  IF FOUND THEN
    v_response:=jsonb_build_object('success',true,'data',jsonb_build_object(
      'created',false,'duplicate',true,'initiative_id',v_existing.id,'status',v_existing.status
    ));
    PERFORM private.idempotency_put(p_project_id,'propose_initiative',p_idempotency_key,v_hash,v_response);
    RETURN v_response;
  END IF;

  SELECT * INTO v_learning FROM public.initiative_learnings
    WHERE project_id=p_project_id AND learning_fingerprint=v_fingerprint;
  IF FOUND THEN
    v_response:=jsonb_build_object('success',true,'data',jsonb_build_object(
      'created',false,'known_learning',true,'learning_id',v_learning.id,
      'lesson',v_learning.lesson,'initiative_id',v_learning.initiative_id
    ));
    PERFORM private.idempotency_put(p_project_id,'propose_initiative',p_idempotency_key,v_hash,v_response);
    RETURN v_response;
  END IF;

  INSERT INTO public.initiatives(
    project_id,proposed_by_worker_id,origin,title,summary,rationale,desired_outcome,
    scope,evidence,risk,resource_budget,support_needed,deduplication_fingerprint
  ) VALUES (
    p_project_id,p_worker_id,v_origin,btrim(p_payload->>'title'),btrim(p_payload->>'summary'),
    btrim(p_payload->>'rationale'),btrim(p_payload->>'desired_outcome'),
    coalesce(p_payload->'scope','[]'::jsonb),coalesce(p_payload->'evidence','[]'::jsonb),
    p_payload->>'risk',coalesce(p_payload->'resource_budget','{}'::jsonb),
    coalesce(p_payload->'support_needed','[]'::jsonb),v_fingerprint
  ) RETURNING id INTO v_id;

  INSERT INTO public.initiative_events(initiative_id,project_id,actor_worker_id,event_type,payload)
  VALUES (v_id,p_project_id,p_worker_id,'initiative_proposed',
    jsonb_build_object('origin',v_origin,'risk',p_payload->>'risk','fingerprint',v_fingerprint));
  v_response:=jsonb_build_object('success',true,'data',jsonb_build_object(
    'created',true,'duplicate',false,'initiative_id',v_id,'status','proposed'
  ));
  PERFORM private.idempotency_put(p_project_id,'propose_initiative',p_idempotency_key,v_hash,v_response);
  RETURN v_response;
END;
$function$;

CREATE OR REPLACE FUNCTION public.decide_initiative(
  p_initiative_id uuid,
  p_decision text,
  p_decision_note text,
  p_work_plan jsonb,
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog','public','auth','private'
AS $function$
DECLARE
  v_initiative public.initiatives%rowtype;
  v_hash text;
  v_replay jsonb;
  v_response jsonb;
  v_count integer;
  v_distinct integer;
  v_cycle boolean;
  v_item jsonb;
  v_key text;
  v_dep text;
BEGIN
  SELECT * INTO v_initiative FROM public.initiatives WHERE id=p_initiative_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING errcode='P0002',message='INITIATIVE_NOT_FOUND'; END IF;
  PERFORM private.assert_owner(v_initiative.project_id);
  v_hash:=private.request_hash(jsonb_build_object(
    'initiative_id',p_initiative_id,'decision',p_decision,'note',p_decision_note,'work_plan',p_work_plan
  ));
  v_replay:=private.idempotency_get(v_initiative.project_id,'decide_initiative',p_idempotency_key,v_hash);
  IF v_replay IS NOT NULL THEN RETURN v_replay; END IF;

  SELECT * INTO v_initiative FROM public.initiatives WHERE id=p_initiative_id FOR UPDATE;
  IF v_initiative.status<>'proposed' THEN
    RAISE EXCEPTION USING errcode='55000',message='INITIATIVE_NOT_AWAITING_DECISION';
  END IF;
  IF p_decision IS NULL OR p_decision NOT IN ('approve','reject') THEN
    RAISE EXCEPTION USING errcode='22023',message='INVALID_INITIATIVE_DECISION';
  END IF;

  IF p_decision='approve' THEN
    IF p_work_plan IS NULL OR jsonb_typeof(p_work_plan) IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION USING errcode='22023',message='APPROVED_INITIATIVE_REQUIRES_WORK_PLAN';
    END IF;
    IF jsonb_array_length(p_work_plan) NOT BETWEEN 1 AND 100 THEN
      RAISE EXCEPTION USING errcode='22023',message='APPROVED_INITIATIVE_REQUIRES_WORK_PLAN';
    END IF;
    SELECT count(*),count(DISTINCT item->>'work_key')
      INTO v_count,v_distinct FROM jsonb_array_elements(p_work_plan) item;
    IF v_count<>v_distinct THEN RAISE EXCEPTION USING errcode='22023',message='DUPLICATE_WORK_KEY'; END IF;

    FOR v_item IN SELECT value FROM jsonb_array_elements(p_work_plan)
    LOOP
      v_key:=v_item->>'work_key';
      IF v_key IS NULL OR v_key !~ '^[a-z0-9][a-z0-9._-]{0,63}$'
         OR length(btrim(coalesce(v_item->>'title',''))) NOT BETWEEN 5 AND 200
         OR length(btrim(coalesce(v_item->>'description',''))) NOT BETWEEN 1 AND 4000
         OR jsonb_typeof(coalesce(v_item->'requirements','{}'::jsonb))<>'object'
         OR jsonb_typeof(coalesce(v_item->'depends_on','[]'::jsonb))<>'array' THEN
        RAISE EXCEPTION USING errcode='22023',message='INVALID_WORK_PLAN_ITEM';
      END IF;
      IF coalesce(v_item->>'requires_review','true') NOT IN ('true','false')
         OR coalesce(v_item->>'priority','100') !~ '^[0-9]{1,4}$'
         OR coalesce((v_item->>'priority')::integer,100) NOT BETWEEN 0 AND 1000 THEN
        RAISE EXCEPTION USING errcode='22023',message='INVALID_WORK_PLAN_POLICY';
      END IF;
      FOR v_dep IN SELECT jsonb_array_elements_text(coalesce(v_item->'depends_on','[]'::jsonb))
      LOOP
        IF v_dep=v_key OR NOT EXISTS (
          SELECT 1 FROM jsonb_array_elements(p_work_plan) other_item
          WHERE other_item->>'work_key'=v_dep
        ) THEN
          RAISE EXCEPTION USING errcode='22023',message='INVALID_WORK_PLAN_DEPENDENCY';
        END IF;
      END LOOP;
    END LOOP;

    WITH RECURSIVE edges(source_key,target_key) AS (
      SELECT item->>'work_key',dep.value
      FROM jsonb_array_elements(p_work_plan) item
      CROSS JOIN LATERAL jsonb_array_elements_text(coalesce(item->'depends_on','[]'::jsonb)) dep(value)
    ), walk(start_key,node_key,path,cycle) AS (
      SELECT source_key,target_key,ARRAY[source_key,target_key],source_key=target_key FROM edges
      UNION ALL
      SELECT w.start_key,e.target_key,w.path||e.target_key,e.target_key=ANY(w.path)
      FROM walk w JOIN edges e ON e.source_key=w.node_key
      WHERE NOT w.cycle AND cardinality(w.path)<101
    )
    SELECT coalesce(bool_or(cycle),false) INTO v_cycle FROM walk;
    IF v_cycle THEN RAISE EXCEPTION USING errcode='22023',message='WORK_PLAN_DEPENDENCY_CYCLE'; END IF;

    INSERT INTO public.initiative_work_items(
      initiative_id,project_id,work_key,title,description,requirements,priority,requires_review,depends_on
    )
    SELECT p_initiative_id,v_initiative.project_id,item->>'work_key',
      btrim(item->>'title'),btrim(item->>'description'),
      coalesce(item->'requirements','{}'::jsonb),
      coalesce((item->>'priority')::integer,100),
      coalesce((item->>'requires_review')::boolean,true),
      ARRAY(SELECT jsonb_array_elements_text(coalesce(item->'depends_on','[]'::jsonb)))
    FROM jsonb_array_elements(p_work_plan) item;

    UPDATE public.initiatives SET status='approved',decision_note=left(coalesce(p_decision_note,''),2000),
      decided_at=clock_timestamp(),updated_at=clock_timestamp()
      WHERE id=p_initiative_id;
  ELSE
    IF jsonb_typeof(coalesce(p_work_plan,'[]'::jsonb))<>'array'
       OR jsonb_array_length(coalesce(p_work_plan,'[]'::jsonb))<>0 THEN
      RAISE EXCEPTION USING errcode='22023',message='REJECTED_INITIATIVE_CANNOT_HAVE_WORK_PLAN';
    END IF;
    UPDATE public.initiatives SET status='rejected',decision_note=left(coalesce(p_decision_note,''),2000),
      decided_at=clock_timestamp(),updated_at=clock_timestamp()
      WHERE id=p_initiative_id;
  END IF;

  INSERT INTO public.initiative_events(initiative_id,project_id,event_type,payload)
  VALUES (p_initiative_id,v_initiative.project_id,'initiative_'||p_decision,
    jsonb_build_object('decision_note',left(coalesce(p_decision_note,''),1000),'work_item_count',
      CASE WHEN p_decision='approve' THEN jsonb_array_length(p_work_plan) ELSE 0 END));
  v_response:=jsonb_build_object('success',true,'data',jsonb_build_object(
    'initiative_id',p_initiative_id,'status',CASE WHEN p_decision='approve' THEN 'approved' ELSE 'rejected' END,
    'work_item_count',CASE WHEN p_decision='approve' THEN jsonb_array_length(p_work_plan) ELSE 0 END
  ));
  PERFORM private.idempotency_put(v_initiative.project_id,'decide_initiative',p_idempotency_key,v_hash,v_response);
  RETURN v_response;
END;
$function$;

CREATE OR REPLACE FUNCTION public.request_initiative_support(
  p_initiative_id uuid,
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
  v_initiative public.initiatives%rowtype;
  v_hash text;
  v_replay jsonb;
  v_id uuid;
  v_existing_id uuid;
  v_response jsonb;
BEGIN
  SELECT * INTO v_initiative FROM public.initiatives WHERE id=p_initiative_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING errcode='P0002',message='INITIATIVE_NOT_FOUND'; END IF;
  PERFORM private.assert_owner(v_initiative.project_id);
  IF v_initiative.status IN ('completed','rejected','abandoned') THEN
    RAISE EXCEPTION USING errcode='55000',message='INITIATIVE_TERMINAL';
  END IF;
  IF p_worker_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.workers WHERE id=p_worker_id AND project_id=v_initiative.project_id AND status='active'
  ) THEN RAISE EXCEPTION USING errcode='42501',message='WORKER_PROJECT_MISMATCH'; END IF;
  IF jsonb_typeof(p_payload)<>'object'
     OR coalesce(p_payload->>'request_kind','') NOT IN
       ('capability','permission','access','external_service','spending','decision','physical_action','other')
     OR length(btrim(coalesce(p_payload->>'capability',''))) NOT BETWEEN 3 AND 300
     OR length(btrim(coalesce(p_payload->>'rationale',''))) NOT BETWEEN 1 AND 3000
     OR length(btrim(coalesce(p_payload->>'unlocks',''))) NOT BETWEEN 1 AND 2000
     OR jsonb_typeof(coalesce(p_payload->'alternatives_checked','[]'::jsonb))<>'array'
     OR jsonb_typeof(coalesce(p_payload->'requested_resources','{}'::jsonb))<>'object' THEN
    RAISE EXCEPTION USING errcode='22023',message='INVALID_SUPPORT_REQUEST';
  END IF;
  v_hash:=private.request_hash(jsonb_build_object('initiative_id',p_initiative_id,'worker_id',p_worker_id,'payload',p_payload));
  v_replay:=private.idempotency_get(v_initiative.project_id,'request_initiative_support',p_idempotency_key,v_hash);
  IF v_replay IS NOT NULL THEN RETURN v_replay; END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_initiative_id::text||':'||(p_payload->>'request_kind')||':'||lower(btrim(p_payload->>'capability')),0
  ));
  SELECT id INTO v_existing_id FROM public.initiative_support_requests
    WHERE initiative_id=p_initiative_id AND request_kind=p_payload->>'request_kind'
      AND lower(capability)=lower(btrim(p_payload->>'capability')) AND status='pending'
    LIMIT 1;
  IF v_existing_id IS NOT NULL THEN
    v_response:=jsonb_build_object('success',true,'data',jsonb_build_object(
      'support_request_id',v_existing_id,'initiative_id',p_initiative_id,'status','pending','duplicate',true
    ));
    PERFORM private.idempotency_put(v_initiative.project_id,'request_initiative_support',p_idempotency_key,v_hash,v_response);
    RETURN v_response;
  END IF;

  INSERT INTO public.initiative_support_requests(
    initiative_id,project_id,requested_by_worker_id,request_kind,capability,rationale,
    alternatives_checked,unlocks,requested_resources
  ) VALUES (
    p_initiative_id,v_initiative.project_id,p_worker_id,p_payload->>'request_kind',
    btrim(p_payload->>'capability'),btrim(p_payload->>'rationale'),
    coalesce(p_payload->'alternatives_checked','[]'::jsonb),btrim(p_payload->>'unlocks'),
    coalesce(p_payload->'requested_resources','{}'::jsonb)
  ) RETURNING id INTO v_id;

  INSERT INTO public.initiative_events(initiative_id,project_id,actor_worker_id,event_type,payload)
  VALUES (p_initiative_id,v_initiative.project_id,p_worker_id,'support_requested',
    jsonb_build_object('support_request_id',v_id,'request_kind',p_payload->>'request_kind',
      'capability',p_payload->>'capability'));
  v_response:=jsonb_build_object('success',true,'data',jsonb_build_object(
    'support_request_id',v_id,'initiative_id',p_initiative_id,'status','pending'
  ));
  PERFORM private.idempotency_put(v_initiative.project_id,'request_initiative_support',p_idempotency_key,v_hash,v_response);
  RETURN v_response;
END;
$function$;

CREATE OR REPLACE FUNCTION public.decide_initiative_support(
  p_support_request_id uuid,
  p_decision text,
  p_decision_note text,
  p_granted_scope jsonb,
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog','public','auth','private'
AS $function$
DECLARE
  v_request public.initiative_support_requests%rowtype;
  v_hash text;
  v_replay jsonb;
  v_response jsonb;
BEGIN
  SELECT * INTO v_request FROM public.initiative_support_requests WHERE id=p_support_request_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING errcode='P0002',message='SUPPORT_REQUEST_NOT_FOUND'; END IF;
  PERFORM private.assert_owner(v_request.project_id);
  v_hash:=private.request_hash(jsonb_build_object(
    'support_request_id',p_support_request_id,'decision',p_decision,
    'note',p_decision_note,'granted_scope',p_granted_scope
  ));
  v_replay:=private.idempotency_get(v_request.project_id,'decide_initiative_support',p_idempotency_key,v_hash);
  IF v_replay IS NOT NULL THEN RETURN v_replay; END IF;
  SELECT * INTO v_request FROM public.initiative_support_requests WHERE id=p_support_request_id FOR UPDATE;
  IF v_request.status<>'pending' THEN
    RAISE EXCEPTION USING errcode='55000',message='SUPPORT_REQUEST_NOT_PENDING';
  END IF;
  IF p_decision IS NULL OR p_decision NOT IN ('grant','decline') OR jsonb_typeof(coalesce(p_granted_scope,'{}'::jsonb))<>'object' THEN
    RAISE EXCEPTION USING errcode='22023',message='INVALID_SUPPORT_DECISION';
  END IF;
  UPDATE public.initiative_support_requests
    SET status=CASE WHEN p_decision='grant' THEN 'granted' ELSE 'declined' END,
      decision_note=left(coalesce(p_decision_note,''),2000),
      granted_scope=CASE WHEN p_decision='grant' THEN coalesce(p_granted_scope,'{}'::jsonb) ELSE NULL END,
      decided_at=clock_timestamp(),updated_at=clock_timestamp()
    WHERE id=p_support_request_id;
  INSERT INTO public.initiative_events(initiative_id,project_id,event_type,payload)
  VALUES (v_request.initiative_id,v_request.project_id,'support_'||p_decision,
    jsonb_build_object('support_request_id',p_support_request_id,'decision_note',left(coalesce(p_decision_note,''),1000)));
  v_response:=jsonb_build_object('success',true,'data',jsonb_build_object(
    'support_request_id',p_support_request_id,'status',CASE WHEN p_decision='grant' THEN 'granted' ELSE 'declined' END
  ));
  PERFORM private.idempotency_put(v_request.project_id,'decide_initiative_support',p_idempotency_key,v_hash,v_response);
  RETURN v_response;
END;
$function$;

CREATE OR REPLACE FUNCTION public.advance_initiative(
  p_initiative_id uuid,
  p_worker_id uuid,
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog','public','auth','private'
AS $function$
DECLARE
  v_initiative public.initiatives%rowtype;
  v_item public.initiative_work_items%rowtype;
  v_hash text;
  v_replay jsonb;
  v_task_response jsonb;
  v_task_id uuid;
  v_created jsonb:='[]'::jsonb;
  v_created_count integer:=0;
  v_remaining integer;
  v_response jsonb;
  v_requirements jsonb;
BEGIN
  SELECT * INTO v_initiative FROM public.initiatives WHERE id=p_initiative_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING errcode='P0002',message='INITIATIVE_NOT_FOUND'; END IF;
  PERFORM private.assert_owner(v_initiative.project_id);
  IF p_worker_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.workers WHERE id=p_worker_id AND project_id=v_initiative.project_id AND status='active'
  ) THEN RAISE EXCEPTION USING errcode='42501',message='WORKER_PROJECT_MISMATCH'; END IF;
  v_hash:=private.request_hash(jsonb_build_object('initiative_id',p_initiative_id,'worker_id',p_worker_id));
  v_replay:=private.idempotency_get(v_initiative.project_id,'advance_initiative',p_idempotency_key,v_hash);
  IF v_replay IS NOT NULL THEN RETURN v_replay; END IF;

  SELECT * INTO v_initiative FROM public.initiatives WHERE id=p_initiative_id FOR UPDATE;
  IF v_initiative.status NOT IN ('approved','in_progress') THEN
    RAISE EXCEPTION USING errcode='55000',message='INITIATIVE_NOT_EXECUTABLE';
  END IF;

  UPDATE public.initiative_work_items w SET status='completed',updated_at=clock_timestamp()
    FROM public.tasks t
    WHERE w.initiative_id=p_initiative_id AND w.task_id=t.id
      AND w.status='materialized' AND t.status='accepted';

  FOR v_item IN
    SELECT w.* FROM public.initiative_work_items w
    WHERE w.initiative_id=p_initiative_id AND w.status='planned'
      AND NOT EXISTS (
        SELECT 1 FROM unnest(w.depends_on) dep(work_key)
        LEFT JOIN public.initiative_work_items d
          ON d.initiative_id=w.initiative_id AND d.work_key=dep.work_key
        WHERE d.id IS NULL OR d.status<>'completed'
      )
    ORDER BY w.priority,w.created_at,w.work_key
    FOR UPDATE
  LOOP
    v_requirements:=v_item.requirements || jsonb_build_object('initiative',jsonb_build_object(
      'initiative_id',p_initiative_id,'work_item_id',v_item.id,'work_key',v_item.work_key,
      'depends_on',to_jsonb(v_item.depends_on),'origin',v_initiative.origin
    ));
    v_task_response:=public.create_task(
      v_initiative.project_id,p_worker_id,'implementation',v_item.title,v_item.description,
      v_requirements,v_item.priority,v_item.requires_review,NULL,NULL,
      'initiative:'||p_initiative_id::text||':'||v_item.work_key
    );
    IF coalesce((v_task_response->>'success')::boolean,false)=false THEN
      RAISE EXCEPTION USING errcode='55000',message='INITIATIVE_TASK_MATERIALIZATION_FAILED';
    END IF;
    v_task_id:=(v_task_response->'data'->>'id')::uuid;
    UPDATE public.initiative_work_items SET task_id=v_task_id,status='materialized',updated_at=clock_timestamp()
      WHERE id=v_item.id;
    v_created:=v_created||jsonb_build_array(jsonb_build_object('work_key',v_item.work_key,'task_id',v_task_id));
    v_created_count:=v_created_count+1;
  END LOOP;

  UPDATE public.initiatives SET status='in_progress',updated_at=clock_timestamp()
    WHERE id=p_initiative_id AND status='approved'
      AND EXISTS (SELECT 1 FROM public.initiative_work_items WHERE initiative_id=p_initiative_id AND status<>'planned');

  SELECT count(*) INTO v_remaining FROM public.initiative_work_items
    WHERE initiative_id=p_initiative_id AND status<>'completed' AND status<>'cancelled';
  IF v_remaining=0 THEN
    UPDATE public.initiatives SET status='completed',completed_at=clock_timestamp(),updated_at=clock_timestamp()
      WHERE id=p_initiative_id;
  END IF;

  INSERT INTO public.initiative_events(initiative_id,project_id,actor_worker_id,event_type,payload)
  VALUES (p_initiative_id,v_initiative.project_id,p_worker_id,'initiative_advanced',
    jsonb_build_object('materialized_count',v_created_count,'created_tasks',v_created,'remaining_work_items',v_remaining));
  v_response:=jsonb_build_object('success',true,'data',jsonb_build_object(
    'initiative_id',p_initiative_id,'status',(SELECT status FROM public.initiatives WHERE id=p_initiative_id),
    'materialized_count',v_created_count,'created_tasks',v_created,'remaining_work_items',v_remaining
  ));
  PERFORM private.idempotency_put(v_initiative.project_id,'advance_initiative',p_idempotency_key,v_hash,v_response);
  RETURN v_response;
END;
$function$;

CREATE OR REPLACE FUNCTION public.abandon_initiative(
  p_initiative_id uuid,
  p_reason text,
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog','public','auth','private'
AS $function$
DECLARE
  v_initiative public.initiatives%rowtype;
  v_hash text;
  v_replay jsonb;
  v_response jsonb;
  v_task record;
BEGIN
  SELECT * INTO v_initiative FROM public.initiatives WHERE id=p_initiative_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING errcode='P0002',message='INITIATIVE_NOT_FOUND'; END IF;
  PERFORM private.assert_owner(v_initiative.project_id);
  IF length(btrim(coalesce(p_reason,''))) NOT BETWEEN 1 AND 2000 THEN
    RAISE EXCEPTION USING errcode='22023',message='ABANDON_REASON_REQUIRED';
  END IF;
  v_hash:=private.request_hash(jsonb_build_object('initiative_id',p_initiative_id,'reason',p_reason));
  v_replay:=private.idempotency_get(v_initiative.project_id,'abandon_initiative',p_idempotency_key,v_hash);
  IF v_replay IS NOT NULL THEN RETURN v_replay; END IF;
  SELECT * INTO v_initiative FROM public.initiatives WHERE id=p_initiative_id FOR UPDATE;
  IF v_initiative.status IN ('completed','rejected','abandoned') THEN
    RAISE EXCEPTION USING errcode='55000',message='INITIATIVE_TERMINAL';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.initiative_work_items w JOIN public.tasks t ON t.id=w.task_id
    WHERE w.initiative_id=p_initiative_id AND t.status IN ('running','submitted')
  ) THEN
    RAISE EXCEPTION USING errcode='55000',message='INITIATIVE_HAS_ACTIVE_TASKS';
  END IF;
  FOR v_task IN
    SELECT t.id,t.project_id,t.created_by_worker_id
    FROM public.initiative_work_items w JOIN public.tasks t ON t.id=w.task_id
    WHERE w.initiative_id=p_initiative_id AND t.status='pending'
    FOR UPDATE OF t
  LOOP
    UPDATE public.tasks SET status='cancelled',result=jsonb_build_object('reason',left(p_reason,1000)),
      completed_at=clock_timestamp(),updated_at=clock_timestamp() WHERE id=v_task.id;
    PERFORM private.add_event(v_task.project_id,v_task.id,NULL,v_task.created_by_worker_id,
      'task_cancelled',jsonb_build_object('reason',left(p_reason,500),'source','initiative_abandoned'));
  END LOOP;
  UPDATE public.initiative_work_items SET status='cancelled',updated_at=clock_timestamp()
    WHERE initiative_id=p_initiative_id AND status='planned';
  UPDATE public.initiatives SET status='abandoned',decision_note=left(p_reason,2000),
    completed_at=clock_timestamp(),updated_at=clock_timestamp() WHERE id=p_initiative_id;
  INSERT INTO public.initiative_events(initiative_id,project_id,event_type,payload)
  VALUES (p_initiative_id,v_initiative.project_id,'initiative_abandoned',
    jsonb_build_object('reason',left(p_reason,1000)));
  v_response:=jsonb_build_object('success',true,'data',jsonb_build_object(
    'initiative_id',p_initiative_id,'status','abandoned'
  ));
  PERFORM private.idempotency_put(v_initiative.project_id,'abandon_initiative',p_idempotency_key,v_hash,v_response);
  RETURN v_response;
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_initiative_learning(
  p_initiative_id uuid,
  p_learning_fingerprint text,
  p_category text,
  p_lesson text,
  p_evidence jsonb,
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog','public','auth','private'
AS $function$
DECLARE
  v_initiative public.initiatives%rowtype;
  v_hash text;
  v_replay jsonb;
  v_id uuid;
  v_existing public.initiative_learnings%rowtype;
  v_response jsonb;
BEGIN
  SELECT * INTO v_initiative FROM public.initiatives WHERE id=p_initiative_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING errcode='P0002',message='INITIATIVE_NOT_FOUND'; END IF;
  PERFORM private.assert_owner(v_initiative.project_id);
  IF v_initiative.status NOT IN ('completed','rejected','abandoned') THEN
    RAISE EXCEPTION USING errcode='55000',message='INITIATIVE_NOT_TERMINAL_FOR_LEARNING';
  END IF;
  IF length(btrim(coalesce(p_learning_fingerprint,''))) NOT BETWEEN 3 AND 200
     OR p_category NOT IN ('success','failure','constraint','architecture','process','discovery','other')
     OR length(btrim(coalesce(p_lesson,''))) NOT BETWEEN 1 AND 4000
     OR jsonb_typeof(coalesce(p_evidence,'[]'::jsonb))<>'array' THEN
    RAISE EXCEPTION USING errcode='22023',message='INVALID_INITIATIVE_LEARNING';
  END IF;
  v_hash:=private.request_hash(jsonb_build_object(
    'initiative_id',p_initiative_id,'fingerprint',lower(btrim(p_learning_fingerprint)),
    'category',p_category,'lesson',p_lesson,'evidence',coalesce(p_evidence,'[]'::jsonb)
  ));
  v_replay:=private.idempotency_get(v_initiative.project_id,'record_initiative_learning',p_idempotency_key,v_hash);
  IF v_replay IS NOT NULL THEN RETURN v_replay; END IF;

  INSERT INTO public.initiative_learnings(
    initiative_id,project_id,learning_fingerprint,category,lesson,evidence
  ) VALUES (
    p_initiative_id,v_initiative.project_id,lower(btrim(p_learning_fingerprint)),
    p_category,btrim(p_lesson),coalesce(p_evidence,'[]'::jsonb)
  ) ON CONFLICT (project_id,learning_fingerprint) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT * INTO v_existing FROM public.initiative_learnings
      WHERE project_id=v_initiative.project_id
        AND learning_fingerprint=lower(btrim(p_learning_fingerprint));
    v_id:=v_existing.id;
  END IF;
  INSERT INTO public.initiative_events(initiative_id,project_id,event_type,payload)
  VALUES (p_initiative_id,v_initiative.project_id,'initiative_learning_recorded',
    jsonb_build_object('learning_id',v_id,'fingerprint',lower(btrim(p_learning_fingerprint))));
  v_response:=jsonb_build_object('success',true,'data',jsonb_build_object(
    'learning_id',v_id,'duplicate',v_existing.id IS NOT NULL
  ));
  PERFORM private.idempotency_put(v_initiative.project_id,'record_initiative_learning',p_idempotency_key,v_hash,v_response);
  RETURN v_response;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_initiative(p_initiative_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog','public','auth','private'
AS $function$
DECLARE v_project_id uuid; v_result jsonb;
BEGIN
  SELECT project_id INTO v_project_id FROM public.initiatives WHERE id=p_initiative_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING errcode='P0002',message='INITIATIVE_NOT_FOUND'; END IF;
  PERFORM private.assert_owner(v_project_id);
  SELECT jsonb_build_object(
    'initiative',to_jsonb(i),
    'work_items',coalesce((SELECT jsonb_agg(to_jsonb(w) ORDER BY w.created_at,w.work_key)
      FROM public.initiative_work_items w WHERE w.initiative_id=i.id),'[]'::jsonb),
    'support_requests',coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.created_at)
      FROM public.initiative_support_requests s WHERE s.initiative_id=i.id),'[]'::jsonb),
    'events',coalesce((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id)
      FROM public.initiative_events e WHERE e.initiative_id=i.id),'[]'::jsonb),
    'learnings',coalesce((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.created_at)
      FROM public.initiative_learnings l WHERE l.initiative_id=i.id),'[]'::jsonb)
  ) INTO v_result FROM public.initiatives i WHERE i.id=p_initiative_id;
  RETURN jsonb_build_object('success',true,'data',v_result);
END;
$function$;

CREATE OR REPLACE FUNCTION public.list_initiatives(
  p_project_id uuid,
  p_status text DEFAULT NULL,
  p_limit integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog','public','auth','private'
AS $function$
DECLARE v_items jsonb;
BEGIN
  PERFORM private.assert_owner(p_project_id);
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION USING errcode='22023',message='INITIATIVE_LIMIT_OUT_OF_RANGE';
  END IF;
  IF p_status IS NOT NULL AND p_status NOT IN
    ('proposed','approved','in_progress','completed','rejected','abandoned') THEN
    RAISE EXCEPTION USING errcode='22023',message='INVALID_INITIATIVE_STATUS';
  END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY i.created_at DESC),'[]'::jsonb)
    INTO v_items FROM (
      SELECT * FROM public.initiatives
      WHERE project_id=p_project_id AND (p_status IS NULL OR status=p_status)
      ORDER BY created_at DESC LIMIT p_limit
    ) i;
  RETURN jsonb_build_object('success',true,'data',v_items);
END;
$function$;

REVOKE ALL ON FUNCTION public.propose_initiative(uuid,uuid,jsonb,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.propose_initiative(uuid,uuid,jsonb,text) TO authenticated;
REVOKE ALL ON FUNCTION public.decide_initiative(uuid,text,text,jsonb,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.decide_initiative(uuid,text,text,jsonb,text) TO authenticated;
REVOKE ALL ON FUNCTION public.request_initiative_support(uuid,uuid,jsonb,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.request_initiative_support(uuid,uuid,jsonb,text) TO authenticated;
REVOKE ALL ON FUNCTION public.decide_initiative_support(uuid,text,text,jsonb,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.decide_initiative_support(uuid,text,text,jsonb,text) TO authenticated;
REVOKE ALL ON FUNCTION public.advance_initiative(uuid,uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.advance_initiative(uuid,uuid,text) TO authenticated;
REVOKE ALL ON FUNCTION public.abandon_initiative(uuid,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.abandon_initiative(uuid,text,text) TO authenticated;
REVOKE ALL ON FUNCTION public.record_initiative_learning(uuid,text,text,text,jsonb,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.record_initiative_learning(uuid,text,text,text,jsonb,text) TO authenticated;
REVOKE ALL ON FUNCTION public.get_initiative(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_initiative(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.list_initiatives(uuid,text,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.list_initiatives(uuid,text,integer) TO authenticated;
