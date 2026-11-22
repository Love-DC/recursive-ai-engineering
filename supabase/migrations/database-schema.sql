-- Reproducible consolidated schema snapshot of the deployed MVP v1.1 database.
-- Apply to an EMPTY Supabase PostgreSQL 17 database only.
-- Contains 7 core tables, constraints, indexes, RLS, triggers, 19 RPCs and grants.

create schema if not exists private;

revoke all on schema private from public, anon, authenticated;

create table public.artifacts (id uuid not null default gen_random_uuid(), task_id uuid not null, execution_id uuid not null, artifact_type text not null, name text not null, github_repo text, github_path text, commit_sha text, pr_url text, external_url text, metadata jsonb not null default '{}'::jsonb, created_at timestamp with time zone not null default now());

create table public.executions (id uuid not null default gen_random_uuid(), task_id uuid not null, worker_id uuid not null, attempt integer not null, status text not null, started_at timestamp with time zone not null default now(), heartbeat_at timestamp with time zone, finished_at timestamp with time zone, result jsonb, error_message text);

create table public.operation_requests (id uuid not null default gen_random_uuid(), project_id uuid not null, operation text not null, idempotency_key text not null, request_hash text not null, response jsonb not null, created_at timestamp with time zone not null default now());

create table public.projects (id uuid not null default gen_random_uuid(), name text not null, description text, github_repo text, config jsonb not null default '{}'::jsonb, owner_id uuid not null, status text not null default 'active'::text, created_at timestamp with time zone not null default now(), updated_at timestamp with time zone not null default now());

create table public.task_events (id bigint generated always as identity not null, project_id uuid not null, task_id uuid not null, execution_id uuid, worker_id uuid, event_type text not null, payload jsonb not null default '{}'::jsonb, created_at timestamp with time zone not null default now());

create table public.tasks (id uuid not null default gen_random_uuid(), project_id uuid not null, parent_task_id uuid, fixes_task_id uuid, task_type text not null, title text not null, description text not null, requirements jsonb not null default '{}'::jsonb, requires_review boolean not null default true, status text not null default 'pending'::text, priority integer not null default 100, assigned_worker_id uuid, current_execution_id uuid, lease_until timestamp with time zone, result jsonb, review_target_original_task_id uuid, review_target_delivery_task_id uuid, review_target_execution_id uuid, review_decision text, review_evidence jsonb, latest_delivery_task_id uuid, latest_delivery_execution_id uuid, latest_review_task_id uuid, created_by_worker_id uuid, created_at timestamp with time zone not null default now(), updated_at timestamp with time zone not null default now(), completed_at timestamp with time zone);

create table public.workers (id uuid not null default gen_random_uuid(), project_id uuid not null, worker_key text not null, display_name text not null, description text, status text not null default 'active'::text, last_seen_at timestamp with time zone, created_at timestamp with time zone not null default now());

alter table public.artifacts add constraint artifacts_execution_id_task_id_fkey FOREIGN KEY (execution_id, task_id) REFERENCES executions(id, task_id) ON DELETE RESTRICT;

alter table public.artifacts add constraint artifacts_pkey PRIMARY KEY (id);

alter table public.artifacts add constraint artifacts_task_id_fkey FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE;

alter table public.executions add constraint executions_attempt_check CHECK ((attempt > 0));

alter table public.executions add constraint executions_id_task_id_key UNIQUE (id, task_id);

alter table public.executions add constraint executions_pkey PRIMARY KEY (id);

alter table public.executions add constraint executions_status_check CHECK ((status = ANY (ARRAY['running'::text, 'submitted'::text, 'succeeded'::text, 'failed'::text, 'expired'::text, 'superseded'::text])));

alter table public.executions add constraint executions_task_id_attempt_key UNIQUE (task_id, attempt);

alter table public.executions add constraint executions_task_id_fkey FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE;

alter table public.executions add constraint executions_worker_id_fkey FOREIGN KEY (worker_id) REFERENCES workers(id) ON DELETE RESTRICT;

alter table public.operation_requests add constraint operation_requests_pkey PRIMARY KEY (id);

alter table public.operation_requests add constraint operation_requests_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;

alter table public.operation_requests add constraint operation_requests_project_id_operation_idempotency_key_key UNIQUE (project_id, operation, idempotency_key);

alter table public.projects add constraint projects_id_owner_id_key UNIQUE (id, owner_id);

alter table public.projects add constraint projects_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES auth.users(id) ON DELETE RESTRICT;

alter table public.projects add constraint projects_pkey PRIMARY KEY (id);

alter table public.projects add constraint projects_status_check CHECK ((status = ANY (ARRAY['active'::text, 'archived'::text])));

alter table public.task_events add constraint task_events_execution_id_task_id_fkey FOREIGN KEY (execution_id, task_id) REFERENCES executions(id, task_id) ON DELETE RESTRICT;

alter table public.task_events add constraint task_events_pkey PRIMARY KEY (id);

alter table public.task_events add constraint task_events_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;

alter table public.task_events add constraint task_events_task_id_project_id_fkey FOREIGN KEY (task_id, project_id) REFERENCES tasks(id, project_id) ON DELETE CASCADE;

alter table public.task_events add constraint task_events_worker_id_project_id_fkey FOREIGN KEY (worker_id, project_id) REFERENCES workers(id, project_id) ON DELETE RESTRICT;

alter table public.tasks add constraint fk_tasks_current_execution FOREIGN KEY (current_execution_id, id) REFERENCES executions(id, task_id) DEFERRABLE INITIALLY DEFERRED;

alter table public.tasks add constraint fk_tasks_latest_delivery_execution FOREIGN KEY (latest_delivery_execution_id, latest_delivery_task_id) REFERENCES executions(id, task_id) DEFERRABLE INITIALLY DEFERRED;

alter table public.tasks add constraint fk_tasks_latest_review_same_project FOREIGN KEY (latest_review_task_id, project_id) REFERENCES tasks(id, project_id) DEFERRABLE INITIALLY DEFERRED;

alter table public.tasks add constraint fk_tasks_review_delivery_execution FOREIGN KEY (review_target_execution_id, review_target_delivery_task_id) REFERENCES executions(id, task_id) DEFERRABLE INITIALLY DEFERRED;

alter table public.tasks add constraint fk_tasks_review_delivery_same_project FOREIGN KEY (review_target_delivery_task_id, project_id) REFERENCES tasks(id, project_id) DEFERRABLE INITIALLY DEFERRED;

alter table public.tasks add constraint fk_tasks_review_original_same_project FOREIGN KEY (review_target_original_task_id, project_id) REFERENCES tasks(id, project_id) DEFERRABLE INITIALLY DEFERRED;

alter table public.tasks add constraint tasks_assigned_worker_id_project_id_fkey FOREIGN KEY (assigned_worker_id, project_id) REFERENCES workers(id, project_id) ON DELETE RESTRICT;

alter table public.tasks add constraint tasks_check CHECK ((((status = 'running'::text) AND (assigned_worker_id IS NOT NULL) AND (current_execution_id IS NOT NULL) AND (lease_until IS NOT NULL)) OR ((status <> 'running'::text) AND (current_execution_id IS NULL) AND (lease_until IS NULL))));

alter table public.tasks add constraint tasks_check1 CHECK ((((task_type = 'review'::text) AND (review_target_original_task_id IS NOT NULL) AND (review_target_delivery_task_id IS NOT NULL) AND (review_target_execution_id IS NOT NULL) AND (requires_review = false) AND (fixes_task_id IS NULL)) OR ((task_type <> 'review'::text) AND (review_target_original_task_id IS NULL) AND (review_target_delivery_task_id IS NULL) AND (review_target_execution_id IS NULL) AND (review_decision IS NULL) AND (review_evidence IS NULL))));

alter table public.tasks add constraint tasks_check2 CHECK (((task_type = 'fix'::text) = (fixes_task_id IS NOT NULL)));

alter table public.tasks add constraint tasks_check3 CHECK (((status <> 'accepted'::text) OR (task_type = 'review'::text) OR (latest_review_task_id IS NOT NULL) OR ((task_type = 'implementation'::text) AND (requires_review = false))));

alter table public.tasks add constraint tasks_check4 CHECK (((task_type <> 'review'::text) OR (assigned_worker_id IS NOT NULL)));

alter table public.tasks add constraint tasks_created_by_worker_id_project_id_fkey FOREIGN KEY (created_by_worker_id, project_id) REFERENCES workers(id, project_id) ON DELETE RESTRICT;

alter table public.tasks add constraint tasks_fixes_task_id_project_id_fkey FOREIGN KEY (fixes_task_id, project_id) REFERENCES tasks(id, project_id) ON DELETE RESTRICT;

alter table public.tasks add constraint tasks_id_project_id_key UNIQUE (id, project_id);

alter table public.tasks add constraint tasks_parent_task_id_project_id_fkey FOREIGN KEY (parent_task_id, project_id) REFERENCES tasks(id, project_id) ON DELETE RESTRICT;

alter table public.tasks add constraint tasks_pkey PRIMARY KEY (id);

alter table public.tasks add constraint tasks_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;

alter table public.tasks add constraint tasks_review_decision_check CHECK ((review_decision = ANY (ARRAY['accepted'::text, 'rejected'::text])));

alter table public.tasks add constraint tasks_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'running'::text, 'submitted'::text, 'accepted'::text, 'rejected'::text, 'failed'::text, 'cancelled'::text])));

alter table public.tasks add constraint tasks_task_type_check CHECK ((task_type = ANY (ARRAY['implementation'::text, 'review'::text, 'fix'::text])));

alter table public.workers add constraint workers_id_project_id_key UNIQUE (id, project_id);

alter table public.workers add constraint workers_pkey PRIMARY KEY (id);

alter table public.workers add constraint workers_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;

alter table public.workers add constraint workers_project_id_worker_key_key UNIQUE (project_id, worker_key);

alter table public.workers add constraint workers_status_check CHECK ((status = ANY (ARRAY['active'::text, 'inactive'::text])));

CREATE INDEX idx_artifacts_execution ON public.artifacts USING btree (task_id, execution_id);

CREATE INDEX idx_artifacts_execution_task ON public.artifacts USING btree (execution_id, task_id);

CREATE INDEX idx_events_execution_task ON public.task_events USING btree (execution_id, task_id);

CREATE INDEX idx_events_project ON public.task_events USING btree (project_id);

CREATE INDEX idx_events_task ON public.task_events USING btree (task_id, created_at DESC);

CREATE INDEX idx_events_task_project ON public.task_events USING btree (task_id, project_id);

CREATE INDEX idx_events_worker_project ON public.task_events USING btree (worker_id, project_id);

CREATE INDEX idx_executions_task ON public.executions USING btree (task_id, attempt DESC);

CREATE INDEX idx_executions_worker ON public.executions USING btree (worker_id);

CREATE INDEX idx_operation_requests_project ON public.operation_requests USING btree (project_id, operation);

CREATE INDEX idx_projects_owner ON public.projects USING btree (owner_id);

CREATE INDEX idx_tasks_assigned_project ON public.tasks USING btree (assigned_worker_id, project_id);

CREATE INDEX idx_tasks_claim ON public.tasks USING btree (project_id, status, priority, created_at);

CREATE INDEX idx_tasks_created_by_project ON public.tasks USING btree (created_by_worker_id, project_id);

CREATE INDEX idx_tasks_current_execution ON public.tasks USING btree (current_execution_id, id);

CREATE INDEX idx_tasks_fixes_project ON public.tasks USING btree (fixes_task_id, project_id);

CREATE INDEX idx_tasks_latest_delivery_execution ON public.tasks USING btree (latest_delivery_execution_id, latest_delivery_task_id);

CREATE INDEX idx_tasks_latest_review_project ON public.tasks USING btree (latest_review_task_id, project_id);

CREATE INDEX idx_tasks_lease ON public.tasks USING btree (lease_until) WHERE (status = 'running'::text);

CREATE INDEX idx_tasks_parent_project ON public.tasks USING btree (parent_task_id, project_id);

CREATE INDEX idx_tasks_review_delivery_project ON public.tasks USING btree (review_target_delivery_task_id, project_id);

CREATE INDEX idx_tasks_review_execution_delivery ON public.tasks USING btree (review_target_execution_id, review_target_delivery_task_id) WHERE (task_type = 'review'::text);

CREATE INDEX idx_tasks_review_original_project ON public.tasks USING btree (review_target_original_task_id, project_id);

CREATE INDEX idx_tasks_review_target ON public.tasks USING btree (review_target_original_task_id, review_target_delivery_task_id, review_target_execution_id) WHERE (task_type = 'review'::text);

CREATE INDEX idx_tasks_worker ON public.tasks USING btree (assigned_worker_id, status);

CREATE UNIQUE INDEX uq_executions_one_running_per_task ON public.executions USING btree (task_id) WHERE (status = 'running'::text);

CREATE UNIQUE INDEX uq_review_target_once ON public.tasks USING btree (review_target_original_task_id, review_target_delivery_task_id, review_target_execution_id) WHERE (task_type = 'review'::text);

alter table public.artifacts enable row level security;

alter table public.executions enable row level security;

alter table public.operation_requests enable row level security;

alter table public.projects enable row level security;

alter table public.task_events enable row level security;

alter table public.tasks enable row level security;

alter table public.workers enable row level security;

CREATE OR REPLACE FUNCTION private.add_event(p_project_id uuid, p_task_id uuid, p_execution_id uuid, p_worker_id uuid, p_event_type text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  insert into public.task_events(project_id,task_id,execution_id,worker_id,event_type,payload)
  values (p_project_id,p_task_id,p_execution_id,p_worker_id,p_event_type,coalesce(p_payload,'{}'::jsonb))
$function$


CREATE OR REPLACE FUNCTION private.assert_current_execution(p_task_id uuid, p_execution_id uuid, p_worker_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
declare v_task public.tasks%rowtype; v_exec public.executions%rowtype; v_now timestamptz;
begin
  select * into v_task from public.tasks where id=p_task_id for update;
  if not found then raise exception using errcode='P0002', message='TASK_NOT_FOUND'; end if;
  perform private.assert_owner(v_task.project_id);
  if v_task.current_execution_id is distinct from p_execution_id then
    raise exception using errcode='55000', message='EXECUTION_SUPERSEDED';
  end if;
  v_now := clock_timestamp();
  if v_task.lease_until is null or v_task.lease_until <= v_now then
    raise exception using errcode='55000', message='EXECUTION_EXPIRED';
  end if;
  if v_task.status <> 'running' then
    raise exception using errcode='55000', message='TASK_NOT_RUNNING';
  end if;
  if v_task.assigned_worker_id is distinct from p_worker_id then
    raise exception using errcode='42501', message='TASK_NOT_OWNED';
  end if;
  select * into v_exec from public.executions
  where id=p_execution_id and task_id=p_task_id for update;
  if not found then raise exception using errcode='55000', message='EXECUTION_SUPERSEDED'; end if;
  if v_exec.worker_id is distinct from p_worker_id then
    raise exception using errcode='42501', message='TASK_NOT_OWNED';
  end if;
  if v_exec.status <> 'running' then
    raise exception using errcode='55000', message='EXECUTION_SUPERSEDED';
  end if;
end;
$function$


CREATE OR REPLACE FUNCTION private.assert_owner(p_project_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
begin
  if auth.uid() is null then
    raise exception using errcode='28000', message='UNAUTHENTICATED';
  end if;
  if not exists (
    select 1 from public.projects p
    where p.id=p_project_id and p.owner_id=auth.uid()
  ) then
    raise exception using errcode='42501', message='PROJECT_FORBIDDEN';
  end if;
end;
$function$


CREATE OR REPLACE FUNCTION private.guard_artifact_immutable_fields()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public', 'auth'
AS $function$
begin
  if new.task_id is distinct from old.task_id
    or new.execution_id is distinct from old.execution_id then
    raise exception using errcode = '23514', message = 'ARTIFACT_EXECUTION_IMMUTABLE';
  end if;
  return new;
end;
$function$


CREATE OR REPLACE FUNCTION private.guard_task_immutable_fields()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public', 'auth'
AS $function$
begin
  if old.task_type = 'review' and (
    new.review_target_original_task_id is distinct from old.review_target_original_task_id
    or new.review_target_delivery_task_id is distinct from old.review_target_delivery_task_id
    or new.review_target_execution_id is distinct from old.review_target_execution_id
  ) then
    raise exception using errcode = '23514', message = 'REVIEW_TARGET_IMMUTABLE';
  end if;
  return new;
end;
$function$


CREATE OR REPLACE FUNCTION private.idempotency_get(p_project_id uuid, p_operation text, p_key text, p_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare v_hash text; v_response jsonb;
begin
  if p_key is null or length(btrim(p_key))=0 then
    raise exception using errcode='22023', message='IDEMPOTENCY_KEY_REQUIRED';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    p_project_id::text || ':' || p_operation || ':' || p_key, 0
  ));
  select request_hash, response into v_hash, v_response
  from public.operation_requests
  where project_id=p_project_id and operation=p_operation and idempotency_key=p_key;
  if found then
    if v_hash <> p_hash then
      raise exception using errcode='23505', message='IDEMPOTENCY_CONFLICT';
    end if;
    return v_response;
  end if;
  return null;
end;
$function$


CREATE OR REPLACE FUNCTION private.idempotency_put(p_project_id uuid, p_operation text, p_key text, p_hash text, p_response jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  insert into public.operation_requests(project_id,operation,idempotency_key,request_hash,response)
  values (p_project_id,p_operation,p_key,p_hash,p_response)
$function$


CREATE OR REPLACE FUNCTION private.request_hash(p_payload jsonb)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE STRICT
 SET search_path TO 'pg_catalog'
AS $function$
  select encode(sha256(convert_to(p_payload::text, 'UTF8')), 'hex')
$function$


CREATE OR REPLACE FUNCTION public.add_artifact(p_task_id uuid, p_execution_id uuid, p_worker_id uuid, p_artifact_type text, p_name text, p_github_repo text, p_github_path text, p_commit_sha text, p_pr_url text, p_external_url text, p_metadata jsonb, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
declare v_project uuid; v_hash text; v_replay jsonb; v_response jsonb; v_id uuid;
begin
  select project_id into v_project from public.tasks where id=p_task_id;
  if not found then raise exception using errcode='P0002',message='TASK_NOT_FOUND'; end if;
  perform private.assert_owner(v_project);
  v_hash:=private.request_hash(jsonb_build_object(
    'task_id',p_task_id,'execution_id',p_execution_id,'worker_id',p_worker_id,
    'artifact_type',p_artifact_type,'name',p_name,'github_repo',p_github_repo,
    'github_path',p_github_path,'commit_sha',p_commit_sha,'pr_url',p_pr_url,
    'external_url',p_external_url,'metadata',coalesce(p_metadata,'{}'::jsonb)
  ));
  v_replay:=private.idempotency_get(v_project,'add_artifact',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay; end if;
  perform private.assert_current_execution(p_task_id,p_execution_id,p_worker_id);
  insert into public.artifacts(task_id,execution_id,artifact_type,name,github_repo,github_path,commit_sha,pr_url,external_url,metadata)
  values(p_task_id,p_execution_id,p_artifact_type,p_name,p_github_repo,p_github_path,p_commit_sha,p_pr_url,p_external_url,coalesce(p_metadata,'{}'::jsonb))
  returning id into v_id;
  perform private.add_event(v_project,p_task_id,p_execution_id,p_worker_id,'artifact_registered',jsonb_build_object('artifact_id',v_id));
  v_response:=jsonb_build_object('success',true,'data',(select to_jsonb(a) from public.artifacts a where a.id=v_id));
  perform private.idempotency_put(v_project,'add_artifact',p_idempotency_key,v_hash,v_response);
  return v_response;
end;
$function$


CREATE OR REPLACE FUNCTION public.cancel_task(p_task_id uuid, p_worker_id uuid, p_reason text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
declare v_task public.tasks%rowtype; v_hash text; v_replay jsonb; v_response jsonb; v_now timestamptz;
begin
  select * into v_task from public.tasks where id=p_task_id;
  if not found then raise exception using errcode='P0002',message='TASK_NOT_FOUND'; end if;
  perform private.assert_owner(v_task.project_id);
  if p_worker_id is not null and not exists(select 1 from public.workers where id=p_worker_id and project_id=v_task.project_id and status='active') then
    raise exception using errcode='42501',message='WORKER_PROJECT_MISMATCH';
  end if;
  v_hash:=private.request_hash(jsonb_build_object('task_id',p_task_id,'worker_id',p_worker_id,'reason',p_reason));
  v_replay:=private.idempotency_get(v_task.project_id,'cancel_task',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay; end if;
  select * into v_task from public.tasks where id=p_task_id for update;
  if v_task.status in ('accepted','rejected','failed','cancelled','submitted') then
    raise exception using errcode='55000',message='TASK_CANNOT_BE_CANCELLED';
  end if;
  v_now:=clock_timestamp();
  if v_task.status='running' then
    update public.executions set status='failed',error_message=coalesce(p_reason,'Task cancelled'),finished_at=v_now
      where id=v_task.current_execution_id and task_id=p_task_id and status='running';
  end if;
  update public.tasks set status='cancelled',current_execution_id=null,lease_until=null,
    updated_at=v_now,completed_at=v_now where id=p_task_id;
  perform private.add_event(v_task.project_id,p_task_id,v_task.current_execution_id,p_worker_id,
    'task_cancelled',jsonb_build_object('reason',p_reason));
  v_response:=jsonb_build_object('success',true,'data',jsonb_build_object('task_id',p_task_id,'status','cancelled'));
  perform private.idempotency_put(v_task.project_id,'cancel_task',p_idempotency_key,v_hash,v_response);
  return v_response;
end;
$function$


CREATE OR REPLACE FUNCTION public.claim_task(p_project_id uuid, p_worker_id uuid, p_lease_seconds integer, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
declare v_task public.tasks%rowtype; v_exec_id uuid; v_attempt integer; v_lease timestamptz;
  v_hash text; v_replay jsonb; v_response jsonb; v_now timestamptz;
begin
  perform private.assert_owner(p_project_id);
  if p_lease_seconds < 60 or p_lease_seconds > 600 then
    raise exception using errcode='22023',message='LEASE_SECONDS_OUT_OF_RANGE';
  end if;
  if not exists(select 1 from public.workers where id=p_worker_id and project_id=p_project_id and status='active') then
    raise exception using errcode='42501',message='WORKER_PROJECT_MISMATCH';
  end if;
  v_hash:=private.request_hash(jsonb_build_object('project_id',p_project_id,'worker_id',p_worker_id,'lease_seconds',p_lease_seconds));
  v_replay:=private.idempotency_get(p_project_id,'claim_task',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay; end if;
  v_now:=clock_timestamp();
  select * into v_task from public.tasks t
  where t.project_id=p_project_id
    and (
      (t.status='pending' and (t.assigned_worker_id is null or t.assigned_worker_id=p_worker_id))
      or
      (t.status='running' and t.lease_until < v_now
        and (t.task_type <> 'review' or t.assigned_worker_id=p_worker_id))
    )
    and (t.task_type <> 'review' or t.assigned_worker_id=p_worker_id)
  order by t.priority asc,t.created_at asc
  for update skip locked limit 1;
  if not found then
    v_response:=jsonb_build_object('success',true,'data',jsonb_build_object('task',null));
    perform private.idempotency_put(p_project_id,'claim_task',p_idempotency_key,v_hash,v_response);
    return v_response;
  end if;
  if v_task.status='running' then
    update public.executions set status='expired',finished_at=v_now
      where id=v_task.current_execution_id and task_id=v_task.id and status='running';
    perform private.add_event(p_project_id,v_task.id,v_task.current_execution_id,v_task.assigned_worker_id,'execution_expired','{}'::jsonb);
  end if;
  select coalesce(max(attempt),0)+1 into v_attempt from public.executions where task_id=v_task.id;
  insert into public.executions(task_id,worker_id,attempt,status,heartbeat_at)
  values(v_task.id,p_worker_id,v_attempt,'running',v_now) returning id into v_exec_id;
  v_lease:=v_now+make_interval(secs=>p_lease_seconds);
  update public.tasks set status='running',assigned_worker_id=p_worker_id,
    current_execution_id=v_exec_id,lease_until=v_lease,updated_at=v_now
  where id=v_task.id;
  perform private.add_event(p_project_id,v_task.id,v_exec_id,p_worker_id,'task_claimed',jsonb_build_object('attempt',v_attempt));
  perform private.add_event(p_project_id,v_task.id,v_exec_id,p_worker_id,'execution_started',jsonb_build_object('attempt',v_attempt));
  v_response:=jsonb_build_object('success',true,'data',jsonb_build_object(
    'task_id',v_task.id,'execution_id',v_exec_id,'attempt',v_attempt,
    'lease_until',v_lease,'requirements',v_task.requirements
  ));
  perform private.idempotency_put(p_project_id,'claim_task',p_idempotency_key,v_hash,v_response);
  return v_response;
end;
$function$


CREATE OR REPLACE FUNCTION public.complete_execution(p_task_id uuid, p_execution_id uuid, p_worker_id uuid, p_result jsonb, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
declare v_task public.tasks%rowtype; v_hash text; v_replay jsonb; v_response jsonb; v_now timestamptz;
begin
  select * into v_task from public.tasks where id=p_task_id;
  if not found then raise exception using errcode='P0002',message='TASK_NOT_FOUND'; end if;
  perform private.assert_owner(v_task.project_id);
  v_hash:=private.request_hash(jsonb_build_object('task_id',p_task_id,'execution_id',p_execution_id,'worker_id',p_worker_id,'result',p_result));
  v_replay:=private.idempotency_get(v_task.project_id,'complete_execution',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay; end if;
  perform private.assert_current_execution(p_task_id,p_execution_id,p_worker_id);
  select * into v_task from public.tasks where id=p_task_id;
  if v_task.task_type <> 'implementation' or v_task.requires_review then
    raise exception using errcode='22023',message='COMPLETE_EXECUTION_NOT_ALLOWED';
  end if;
  v_now:=clock_timestamp();
  update public.executions set status='succeeded',result=p_result,finished_at=v_now
  where id=p_execution_id and task_id=p_task_id;
  update public.tasks set status='accepted',result=p_result,current_execution_id=null,lease_until=null,
    updated_at=v_now,completed_at=v_now where id=p_task_id;
  perform private.add_event(v_task.project_id,p_task_id,p_execution_id,p_worker_id,'execution_completed','{}'::jsonb);
  perform private.add_event(v_task.project_id,p_task_id,p_execution_id,p_worker_id,'task_completed','{}'::jsonb);
  v_response:=jsonb_build_object('success',true,'data',jsonb_build_object('task_id',p_task_id,'execution_id',p_execution_id,'status','accepted'));
  perform private.idempotency_put(v_task.project_id,'complete_execution',p_idempotency_key,v_hash,v_response);
  return v_response;
end;
$function$


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


CREATE OR REPLACE FUNCTION public.create_review_task(p_original_task_id uuid, p_delivery_task_id uuid, p_delivery_execution_id uuid, p_reviewer_worker_id uuid, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
declare v_original public.tasks%rowtype; v_delivery public.tasks%rowtype; v_exec public.executions%rowtype;
  v_hash text; v_replay jsonb; v_response jsonb; v_review_id uuid;
begin
  select * into v_original from public.tasks where id=p_original_task_id for update;
  if not found then raise exception using errcode='P0002',message='ORIGINAL_TASK_NOT_FOUND'; end if;
  perform private.assert_owner(v_original.project_id);
  v_hash:=private.request_hash(jsonb_build_object('original_task_id',p_original_task_id,'delivery_task_id',p_delivery_task_id,'delivery_execution_id',p_delivery_execution_id,'reviewer_worker_id',p_reviewer_worker_id));
  v_replay:=private.idempotency_get(v_original.project_id,'create_review_task',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay; end if;
  select * into v_delivery from public.tasks where id=p_delivery_task_id and project_id=v_original.project_id for update;
  if not found then raise exception using errcode='23503',message='DELIVERY_TASK_PROJECT_MISMATCH'; end if;
  select * into v_exec from public.executions where id=p_delivery_execution_id and task_id=p_delivery_task_id for update;
  if not found or v_exec.status <> 'submitted' then
    raise exception using errcode='55000',message='DELIVERY_EXECUTION_NOT_SUBMITTED';
  end if;
  if v_original.status <> 'submitted' then
    raise exception using errcode='55000',message='ORIGINAL_TASK_NOT_SUBMITTED';
  end if;
  if v_delivery.task_type not in ('implementation','fix') then
    raise exception using errcode='22023',message='INVALID_DELIVERY_TASK_TYPE';
  end if;
  if p_delivery_task_id=p_original_task_id then
    if v_original.latest_delivery_task_id is distinct from p_original_task_id
      or v_original.latest_delivery_execution_id is distinct from p_delivery_execution_id then
      raise exception using errcode='55000',message='DELIVERY_VERSION_NOT_CURRENT';
    end if;
  elsif v_delivery.task_type <> 'fix' or v_delivery.fixes_task_id is distinct from p_original_task_id
    or v_original.latest_delivery_task_id is distinct from p_delivery_task_id
    or v_original.latest_delivery_execution_id is distinct from p_delivery_execution_id then
    raise exception using errcode='55000',message='FIX_DELIVERY_NOT_CURRENT';
  end if;
  if not exists(select 1 from public.workers where id=p_reviewer_worker_id and project_id=v_original.project_id and status='active') then
    raise exception using errcode='42501',message='REVIEWER_PROJECT_MISMATCH';
  end if;
  if v_exec.worker_id=p_reviewer_worker_id then
    raise exception using errcode='42501',message='REVIEWER_CANNOT_REVIEW_OWN_EXECUTION';
  end if;
  if exists(select 1 from public.tasks where task_type='review'
    and review_target_original_task_id=p_original_task_id
    and review_target_delivery_task_id=p_delivery_task_id
    and review_target_execution_id=p_delivery_execution_id) then
    raise exception using errcode='23505',message='REVIEW_ALREADY_EXISTS';
  end if;
  insert into public.tasks(project_id,parent_task_id,task_type,title,description,requirements,requires_review,status,
    assigned_worker_id,review_target_original_task_id,review_target_delivery_task_id,review_target_execution_id,created_by_worker_id)
  values(v_original.project_id,p_original_task_id,'review','Review: '||v_original.title,
    'Review fixed delivery execution '||p_delivery_execution_id,
    jsonb_build_object('original_task_id',p_original_task_id,'delivery_task_id',p_delivery_task_id,'delivery_execution_id',p_delivery_execution_id),
    false,'pending',p_reviewer_worker_id,p_original_task_id,p_delivery_task_id,p_delivery_execution_id,null)
  returning id into v_review_id;
  perform private.add_event(v_original.project_id,v_review_id,null,p_reviewer_worker_id,'review_created',
    jsonb_build_object('original_task_id',p_original_task_id,'delivery_task_id',p_delivery_task_id,'delivery_execution_id',p_delivery_execution_id));
  v_response:=jsonb_build_object('success',true,'data',(select to_jsonb(t) from public.tasks t where t.id=v_review_id));
  perform private.idempotency_put(v_original.project_id,'create_review_task',p_idempotency_key,v_hash,v_response);
  return v_response;
end;
$function$


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
  insert into public.tasks(project_id,parent_task_id,task_type,title,description,requirements,priority,requires_review,created_by_worker_id)
  values(p_project_id,p_parent_task_id,'implementation',p_title,p_description,coalesce(p_requirements,'{}'::jsonb),coalesce(p_priority,100),coalesce(p_requires_review,true),p_worker_id)
  returning id into v_id;
  perform private.add_event(p_project_id,v_id,null,p_worker_id,'task_created',jsonb_build_object('task_type','implementation'));
  v_response:=jsonb_build_object('success',true,'data',(select to_jsonb(t) from public.tasks t where t.id=v_id));
  perform private.idempotency_put(p_project_id,'create_task',p_idempotency_key,v_hash,v_response);
  return v_response;
end;
$function$


CREATE OR REPLACE FUNCTION public.get_project(p_project_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
declare v_row public.projects%rowtype;
begin
  perform private.assert_owner(p_project_id);
  select * into v_row from public.projects where id=p_project_id;
  return jsonb_build_object('success',true,'data',to_jsonb(v_row));
end;
$function$


CREATE OR REPLACE FUNCTION public.get_task(p_task_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
declare v_task public.tasks%rowtype; v_project uuid; v_data jsonb;
begin
  select * into v_task from public.tasks where id=p_task_id;
  if not found then raise exception using errcode='P0002',message='TASK_NOT_FOUND'; end if;
  perform private.assert_owner(v_task.project_id);
  select jsonb_build_object(
    'task',to_jsonb(t),
    'executions',coalesce((select jsonb_agg(to_jsonb(e) order by e.attempt) from public.executions e where e.task_id=t.id),'[]'::jsonb),
    'artifacts',case when t.task_type='review' then
      coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at)
        from public.artifacts a where a.task_id=t.review_target_delivery_task_id and a.execution_id=t.review_target_execution_id),'[]'::jsonb)
      else coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at) from public.artifacts a where a.task_id=t.id),'[]'::jsonb) end,
    'review_history',coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at)
      from public.tasks r where r.task_type='review' and r.review_target_original_task_id=t.id),'[]'::jsonb),
    'fix_tasks',coalesce((select jsonb_agg(to_jsonb(f) order by f.created_at)
      from public.tasks f where f.task_type='fix' and f.fixes_task_id=t.id),'[]'::jsonb)
  ) into v_data from public.tasks t where t.id=p_task_id;
  return jsonb_build_object('success',true,'data',v_data);
end;
$function$


CREATE OR REPLACE FUNCTION public.get_worker(p_worker_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
declare v_row public.workers%rowtype;
begin
  select * into v_row from public.workers where id=p_worker_id;
  if not found then raise exception using errcode='P0002',message='WORKER_NOT_FOUND'; end if;
  perform private.assert_owner(v_row.project_id);
  return jsonb_build_object('success',true,'data',to_jsonb(v_row));
end;
$function$


CREATE OR REPLACE FUNCTION public.heartbeat_execution(p_task_id uuid, p_execution_id uuid, p_worker_id uuid, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
declare v_project uuid; v_hash text; v_replay jsonb; v_response jsonb; v_now timestamptz; v_lease timestamptz;
begin
  select project_id into v_project from public.tasks where id=p_task_id;
  if not found then raise exception using errcode='P0002',message='TASK_NOT_FOUND'; end if;
  perform private.assert_owner(v_project);
  v_hash:=private.request_hash(jsonb_build_object('task_id',p_task_id,'execution_id',p_execution_id,'worker_id',p_worker_id));
  v_replay:=private.idempotency_get(v_project,'heartbeat_execution',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay; end if;
  perform private.assert_current_execution(p_task_id,p_execution_id,p_worker_id);
  v_now:=clock_timestamp(); v_lease:=v_now+interval '300 seconds';
  update public.executions set heartbeat_at=v_now where id=p_execution_id and task_id=p_task_id;
  update public.tasks set lease_until=v_lease,updated_at=v_now where id=p_task_id;
  perform private.add_event(v_project,p_task_id,p_execution_id,p_worker_id,'heartbeat_received',jsonb_build_object('lease_until',v_lease));
  v_response:=jsonb_build_object('success',true,'data',jsonb_build_object('lease_until',v_lease));
  perform private.idempotency_put(v_project,'heartbeat_execution',p_idempotency_key,v_hash,v_response);
  return v_response;
end;
$function$


CREATE OR REPLACE FUNCTION public.heartbeat_worker(p_worker_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
declare v_project uuid;
begin
  select project_id into v_project from public.workers where id=p_worker_id;
  if not found then raise exception using errcode='P0002',message='WORKER_NOT_FOUND'; end if;
  perform private.assert_owner(v_project);
  update public.workers set last_seen_at=clock_timestamp()
  where id=p_worker_id and status='active';
  if not found then raise exception using errcode='55000',message='WORKER_INACTIVE'; end if;
  return jsonb_build_object('success',true,'data',jsonb_build_object('worker_id',p_worker_id,'last_seen_at',clock_timestamp()));
end;
$function$


CREATE OR REPLACE FUNCTION public.list_tasks(p_project_id uuid, p_status text, p_worker_id uuid, p_limit integer, p_cursor timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
declare v_data jsonb; v_limit integer;
begin
  perform private.assert_owner(p_project_id);
  if p_worker_id is not null and not exists(select 1 from public.workers where id=p_worker_id and project_id=p_project_id) then
    raise exception using errcode='42501',message='WORKER_PROJECT_MISMATCH';
  end if;
  v_limit:=least(greatest(coalesce(p_limit,20),1),100);
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_data
  from (
    select t.* from public.tasks t
    where t.project_id=p_project_id
      and (p_status is null or t.status=p_status)
      and (p_worker_id is null or t.assigned_worker_id=p_worker_id)
      and (p_cursor is null or t.created_at < p_cursor)
    order by t.created_at desc limit v_limit
  ) x;
  return jsonb_build_object('success',true,'data',v_data);
end;
$function$


CREATE OR REPLACE FUNCTION public.list_workers(p_project_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
declare v_data jsonb;
begin
  perform private.assert_owner(p_project_id);
  select coalesce(jsonb_agg(to_jsonb(w) order by w.created_at), '[]'::jsonb) into v_data
  from public.workers w where w.project_id=p_project_id;
  return jsonb_build_object('success',true,'data',v_data);
end;
$function$


CREATE OR REPLACE FUNCTION public.register_project(p_name text, p_description text, p_github_repo text, p_config jsonb, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
declare
  v_id uuid;
  v_hash text;
  v_response jsonb;
  v_existing_hash text;
  v_existing_response jsonb;
  v_seed text;
begin
  if auth.uid() is null then
    raise exception using errcode='28000', message='UNAUTHENTICATED';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key))=0 then
    raise exception using errcode='22023', message='IDEMPOTENCY_KEY_REQUIRED';
  end if;
  v_hash := private.request_hash(jsonb_build_object(
    'name',p_name,'description',p_description,'github_repo',p_github_repo,
    'config',coalesce(p_config,'{}'::jsonb)
  ));
  v_seed := md5(auth.uid()::text || ':register_project:' || p_idempotency_key);
  v_id := (substr(v_seed,1,8)||'-'||substr(v_seed,9,4)||'-4'||substr(v_seed,14,3)||'-a'||substr(v_seed,18,3)||'-'||substr(v_seed,21,12))::uuid;
  perform pg_advisory_xact_lock(hashtextextended(v_id::text,0));
  select request_hash,response into v_existing_hash,v_existing_response
  from public.operation_requests
  where project_id=v_id and operation='register_project' and idempotency_key=p_idempotency_key;
  if found then
    if v_existing_hash <> v_hash then
      raise exception using errcode='23505', message='IDEMPOTENCY_CONFLICT';
    end if;
    return v_existing_response;
  end if;
  insert into public.projects(id,name,description,github_repo,config,owner_id)
  values(v_id,p_name,p_description,p_github_repo,coalesce(p_config,'{}'::jsonb),auth.uid())
  on conflict(id) do nothing;
  if not exists(select 1 from public.projects where id=v_id and owner_id=auth.uid()) then
    raise exception using errcode='42501', message='PROJECT_FORBIDDEN';
  end if;
  v_response := jsonb_build_object('success',true,'data',(select to_jsonb(p) from public.projects p where p.id=v_id));
  insert into public.operation_requests(project_id,operation,idempotency_key,request_hash,response)
  values(v_id,'register_project',p_idempotency_key,v_hash,v_response);
  return v_response;
end;
$function$


CREATE OR REPLACE FUNCTION public.register_worker(p_project_id uuid, p_worker_key text, p_display_name text, p_description text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
declare v_row public.workers%rowtype;
begin
  perform private.assert_owner(p_project_id);
  insert into public.workers(project_id,worker_key,display_name,description)
  values(p_project_id,p_worker_key,p_display_name,p_description)
  on conflict(project_id,worker_key) do nothing;
  select * into v_row from public.workers where project_id=p_project_id and worker_key=p_worker_key;
  return jsonb_build_object('success',true,'data',to_jsonb(v_row));
end;
$function$


CREATE OR REPLACE FUNCTION public.resubmit_after_fix(p_original_task_id uuid, p_fix_task_id uuid, p_fix_execution_id uuid, p_worker_id uuid, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
declare v_original public.tasks%rowtype; v_fix public.tasks%rowtype; v_exec public.executions%rowtype;
  v_hash text; v_replay jsonb; v_response jsonb; v_now timestamptz;
begin
  select * into v_original from public.tasks where id=p_original_task_id for update;
  if not found then raise exception using errcode='P0002',message='ORIGINAL_TASK_NOT_FOUND'; end if;
  perform private.assert_owner(v_original.project_id);
  v_hash:=private.request_hash(jsonb_build_object('original_task_id',p_original_task_id,'fix_task_id',p_fix_task_id,'fix_execution_id',p_fix_execution_id,'worker_id',p_worker_id));
  v_replay:=private.idempotency_get(v_original.project_id,'resubmit_after_fix',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay; end if;
  select * into v_fix from public.tasks where id=p_fix_task_id and project_id=v_original.project_id for update;
  if not found or v_fix.task_type <> 'fix' or v_fix.fixes_task_id <> p_original_task_id then
    raise exception using errcode='23503',message='FIX_TASK_MISMATCH';
  end if;
  select * into v_exec from public.executions where id=p_fix_execution_id and task_id=p_fix_task_id for update;
  if not found or v_exec.status <> 'submitted' or v_fix.status <> 'submitted' or v_original.status <> 'rejected' then
    raise exception using errcode='55000',message='FIX_EXECUTION_NOT_SUBMITTED';
  end if;
  if not exists(select 1 from public.workers where id=p_worker_id and project_id=v_original.project_id and status='active') then
    raise exception using errcode='42501',message='WORKER_PROJECT_MISMATCH';
  end if;
  v_now:=clock_timestamp();
  update public.tasks set status='submitted',latest_delivery_task_id=p_fix_task_id,
    latest_delivery_execution_id=p_fix_execution_id,current_execution_id=null,lease_until=null,
    updated_at=v_now,completed_at=null where id=p_original_task_id;
  perform private.add_event(v_original.project_id,p_original_task_id,p_fix_execution_id,p_worker_id,
    'original_task_resubmitted',jsonb_build_object('fix_task_id',p_fix_task_id));
  v_response:=jsonb_build_object('success',true,'data',jsonb_build_object('original_task_id',p_original_task_id,'delivery_task_id',p_fix_task_id,'delivery_execution_id',p_fix_execution_id,'status','submitted'));
  perform private.idempotency_put(v_original.project_id,'resubmit_after_fix',p_idempotency_key,v_hash,v_response);
  return v_response;
end;
$function$


CREATE OR REPLACE FUNCTION public.review_result(p_review_task_id uuid, p_execution_id uuid, p_reviewer_worker_id uuid, p_decision text, p_review jsonb, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
declare v_review public.tasks%rowtype; v_original public.tasks%rowtype; v_delivery public.tasks%rowtype;
  v_exec public.executions%rowtype; v_project uuid; v_hash text; v_replay jsonb; v_response jsonb; v_now timestamptz;
begin
  select * into v_review from public.tasks where id=p_review_task_id and task_type='review';
  if not found then raise exception using errcode='P0002',message='REVIEW_TASK_NOT_FOUND'; end if;
  v_project:=v_review.project_id;
  perform private.assert_owner(v_project);
  v_hash:=private.request_hash(jsonb_build_object('review_task_id',p_review_task_id,'execution_id',p_execution_id,'reviewer_worker_id',p_reviewer_worker_id,'decision',p_decision,'review',p_review));
  v_replay:=private.idempotency_get(v_project,'review_result',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay; end if;
  -- Lock order: Original Task, Delivery Task, Review Task, Review Execution.
  select * into v_original from public.tasks where id=v_review.review_target_original_task_id for update;
  select * into v_delivery from public.tasks where id=v_review.review_target_delivery_task_id for update;
  select * into v_review from public.tasks where id=p_review_task_id for update;
  if v_review.current_execution_id is distinct from p_execution_id then
    raise exception using errcode='55000',message='EXECUTION_SUPERSEDED';
  end if;
  v_now:=clock_timestamp();
  if v_review.lease_until is null or v_review.lease_until <= v_now then
    raise exception using errcode='55000',message='EXECUTION_EXPIRED';
  end if;
  if v_review.status <> 'running' then raise exception using errcode='55000',message='TASK_NOT_RUNNING'; end if;
  if v_review.assigned_worker_id is distinct from p_reviewer_worker_id then
    raise exception using errcode='42501',message='REVIEWER_NOT_ASSIGNED';
  end if;
  select * into v_exec from public.executions where id=p_execution_id and task_id=p_review_task_id for update;
  if not found or v_exec.status <> 'running' then
    raise exception using errcode='55000',message='EXECUTION_SUPERSEDED';
  end if;
  if v_exec.worker_id is distinct from p_reviewer_worker_id then
    raise exception using errcode='42501',message='TASK_NOT_OWNED';
  end if;
  if p_decision not in ('accepted','rejected') then
    raise exception using errcode='22023',message='INVALID_REVIEW_DECISION';
  end if;
  if not exists(select 1 from public.executions where id=v_review.review_target_execution_id
    and task_id=v_review.review_target_delivery_task_id and status='submitted') then
    raise exception using errcode='55000',message='DELIVERY_EXECUTION_CHANGED';
  end if;
  v_now:=clock_timestamp();
  update public.executions set status='succeeded',result=p_review,finished_at=v_now
    where id=p_execution_id and task_id=p_review_task_id and status='running';
  update public.tasks set status='accepted',review_decision=p_decision,review_evidence=p_review,
    current_execution_id=null,lease_until=null,updated_at=v_now,completed_at=v_now
    where id=p_review_task_id;
  update public.tasks set status=case when p_decision='accepted' then 'accepted' else 'rejected' end,
    latest_delivery_task_id=v_review.review_target_delivery_task_id,
    latest_delivery_execution_id=v_review.review_target_execution_id,
    latest_review_task_id=p_review_task_id,updated_at=v_now,completed_at=v_now
    where id=v_review.review_target_original_task_id;
  if p_decision='accepted' then
    perform private.add_event(v_project,p_review_task_id,p_execution_id,p_reviewer_worker_id,'review_accepted',coalesce(p_review,'{}'::jsonb));
  else
    perform private.add_event(v_project,p_review_task_id,p_execution_id,p_reviewer_worker_id,'review_rejected',coalesce(p_review,'{}'::jsonb));
  end if;
  v_response:=jsonb_build_object('success',true,'data',jsonb_build_object('review_task_id',p_review_task_id,'decision',p_decision,'original_task_id',v_original.id));
  perform private.idempotency_put(v_project,'review_result',p_idempotency_key,v_hash,v_response);
  return v_response;
end;
$function$


CREATE OR REPLACE FUNCTION public.submit_result(p_task_id uuid, p_execution_id uuid, p_worker_id uuid, p_result jsonb, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'private'
AS $function$
declare v_task public.tasks%rowtype; v_hash text; v_replay jsonb; v_response jsonb; v_now timestamptz;
begin
  select * into v_task from public.tasks where id=p_task_id;
  if not found then raise exception using errcode='P0002',message='TASK_NOT_FOUND'; end if;
  perform private.assert_owner(v_task.project_id);
  v_hash:=private.request_hash(jsonb_build_object('task_id',p_task_id,'execution_id',p_execution_id,'worker_id',p_worker_id,'result',p_result));
  v_replay:=private.idempotency_get(v_task.project_id,'submit_result',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay; end if;
  perform private.assert_current_execution(p_task_id,p_execution_id,p_worker_id);
  select * into v_task from public.tasks where id=p_task_id;
  if v_task.task_type='review' or (v_task.task_type='implementation' and not v_task.requires_review) then
    raise exception using errcode='22023',message='SUBMIT_RESULT_NOT_ALLOWED';
  end if;
  v_now:=clock_timestamp();
  update public.executions set status='submitted',result=p_result,finished_at=v_now
  where id=p_execution_id and task_id=p_task_id;
  update public.tasks set status='submitted',result=p_result,current_execution_id=null,lease_until=null,
    updated_at=v_now,completed_at=v_now
  where id=p_task_id;
  if v_task.task_type='implementation' then
    update public.tasks set latest_delivery_task_id=p_task_id,latest_delivery_execution_id=p_execution_id
    where id=p_task_id;
  end if;
  perform private.add_event(v_task.project_id,p_task_id,p_execution_id,p_worker_id,'result_submitted','{}'::jsonb);
  v_response:=jsonb_build_object('success',true,'data',jsonb_build_object('task_id',p_task_id,'execution_id',p_execution_id,'status','submitted'));
  perform private.idempotency_put(v_task.project_id,'submit_result',p_idempotency_key,v_hash,v_response);
  return v_response;
end;
$function$


CREATE TRIGGER trg_artifact_execution_immutable BEFORE UPDATE ON artifacts FOR EACH ROW EXECUTE FUNCTION private.guard_artifact_immutable_fields();

CREATE TRIGGER trg_review_target_immutable BEFORE UPDATE ON tasks FOR EACH ROW EXECUTE FUNCTION private.guard_task_immutable_fields();

create policy artifacts_owner_read on public.artifacts as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM (tasks t
     JOIN projects p ON ((p.id = t.project_id)))
  WHERE ((t.id = artifacts.task_id) AND (p.owner_id = ( SELECT auth.uid() AS uid))))));

create policy events_owner_read on public.task_events as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM projects p
  WHERE ((p.id = task_events.project_id) AND (p.owner_id = ( SELECT auth.uid() AS uid))))));

create policy executions_owner_read on public.executions as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM (tasks t
     JOIN projects p ON ((p.id = t.project_id)))
  WHERE ((t.id = executions.task_id) AND (p.owner_id = ( SELECT auth.uid() AS uid))))));

create policy projects_owner_read on public.projects as PERMISSIVE for SELECT to authenticated using ((owner_id = ( SELECT auth.uid() AS uid)));

create policy tasks_owner_read on public.tasks as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM projects p
  WHERE ((p.id = tasks.project_id) AND (p.owner_id = ( SELECT auth.uid() AS uid))))));

create policy workers_owner_read on public.workers as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM projects p
  WHERE ((p.id = workers.project_id) AND (p.owner_id = ( SELECT auth.uid() AS uid))))));

revoke all on table public.projects, public.workers, public.tasks, public.executions, public.artifacts, public.task_events, public.operation_requests from anon, authenticated;

grant select on table public.projects, public.workers, public.tasks, public.executions, public.artifacts, public.task_events to authenticated;

revoke all on function public.add_artifact(p_task_id uuid, p_execution_id uuid, p_worker_id uuid, p_artifact_type text, p_name text, p_github_repo text, p_github_path text, p_commit_sha text, p_pr_url text, p_external_url text, p_metadata jsonb, p_idempotency_key text) from public, anon;

revoke all on function public.cancel_task(p_task_id uuid, p_worker_id uuid, p_reason text, p_idempotency_key text) from public, anon;

revoke all on function public.claim_task(p_project_id uuid, p_worker_id uuid, p_lease_seconds integer, p_idempotency_key text) from public, anon;

revoke all on function public.complete_execution(p_task_id uuid, p_execution_id uuid, p_worker_id uuid, p_result jsonb, p_idempotency_key text) from public, anon;

revoke all on function public.create_fix_task(p_original_task_id uuid, p_review_task_id uuid, p_title text, p_description text, p_requirements jsonb, p_worker_id uuid, p_idempotency_key text) from public, anon;

revoke all on function public.create_review_task(p_original_task_id uuid, p_delivery_task_id uuid, p_delivery_execution_id uuid, p_reviewer_worker_id uuid, p_idempotency_key text) from public, anon;

revoke all on function public.create_task(p_project_id uuid, p_worker_id uuid, p_task_type text, p_title text, p_description text, p_requirements jsonb, p_priority integer, p_requires_review boolean, p_parent_task_id uuid, p_fixes_task_id uuid, p_idempotency_key text) from public, anon;

revoke all on function public.get_project(p_project_id uuid) from public, anon;

revoke all on function public.get_task(p_task_id uuid) from public, anon;

revoke all on function public.get_worker(p_worker_id uuid) from public, anon;

revoke all on function public.heartbeat_execution(p_task_id uuid, p_execution_id uuid, p_worker_id uuid, p_idempotency_key text) from public, anon;

revoke all on function public.heartbeat_worker(p_worker_id uuid) from public, anon;

revoke all on function public.list_tasks(p_project_id uuid, p_status text, p_worker_id uuid, p_limit integer, p_cursor timestamp with time zone) from public, anon;

revoke all on function public.list_workers(p_project_id uuid) from public, anon;

revoke all on function public.register_project(p_name text, p_description text, p_github_repo text, p_config jsonb, p_idempotency_key text) from public, anon;

revoke all on function public.register_worker(p_project_id uuid, p_worker_key text, p_display_name text, p_description text) from public, anon;

revoke all on function public.resubmit_after_fix(p_original_task_id uuid, p_fix_task_id uuid, p_fix_execution_id uuid, p_worker_id uuid, p_idempotency_key text) from public, anon;

revoke all on function public.review_result(p_review_task_id uuid, p_execution_id uuid, p_reviewer_worker_id uuid, p_decision text, p_review jsonb, p_idempotency_key text) from public, anon;

revoke all on function public.submit_result(p_task_id uuid, p_execution_id uuid, p_worker_id uuid, p_result jsonb, p_idempotency_key text) from public, anon;

grant execute on function public.add_artifact(p_task_id uuid, p_execution_id uuid, p_worker_id uuid, p_artifact_type text, p_name text, p_github_repo text, p_github_path text, p_commit_sha text, p_pr_url text, p_external_url text, p_metadata jsonb, p_idempotency_key text) to authenticated;

grant execute on function public.cancel_task(p_task_id uuid, p_worker_id uuid, p_reason text, p_idempotency_key text) to authenticated;

grant execute on function public.claim_task(p_project_id uuid, p_worker_id uuid, p_lease_seconds integer, p_idempotency_key text) to authenticated;

grant execute on function public.complete_execution(p_task_id uuid, p_execution_id uuid, p_worker_id uuid, p_result jsonb, p_idempotency_key text) to authenticated;

grant execute on function public.create_fix_task(p_original_task_id uuid, p_review_task_id uuid, p_title text, p_description text, p_requirements jsonb, p_worker_id uuid, p_idempotency_key text) to authenticated;

grant execute on function public.create_review_task(p_original_task_id uuid, p_delivery_task_id uuid, p_delivery_execution_id uuid, p_reviewer_worker_id uuid, p_idempotency_key text) to authenticated;

grant execute on function public.create_task(p_project_id uuid, p_worker_id uuid, p_task_type text, p_title text, p_description text, p_requirements jsonb, p_priority integer, p_requires_review boolean, p_parent_task_id uuid, p_fixes_task_id uuid, p_idempotency_key text) to authenticated;

grant execute on function public.get_project(p_project_id uuid) to authenticated;

grant execute on function public.get_task(p_task_id uuid) to authenticated;

grant execute on function public.get_worker(p_worker_id uuid) to authenticated;

grant execute on function public.heartbeat_execution(p_task_id uuid, p_execution_id uuid, p_worker_id uuid, p_idempotency_key text) to authenticated;

grant execute on function public.heartbeat_worker(p_worker_id uuid) to authenticated;

grant execute on function public.list_tasks(p_project_id uuid, p_status text, p_worker_id uuid, p_limit integer, p_cursor timestamp with time zone) to authenticated;

grant execute on function public.list_workers(p_project_id uuid) to authenticated;

grant execute on function public.register_project(p_name text, p_description text, p_github_repo text, p_config jsonb, p_idempotency_key text) to authenticated;

grant execute on function public.register_worker(p_project_id uuid, p_worker_key text, p_display_name text, p_description text) to authenticated;

grant execute on function public.resubmit_after_fix(p_original_task_id uuid, p_fix_task_id uuid, p_fix_execution_id uuid, p_worker_id uuid, p_idempotency_key text) to authenticated;

grant execute on function public.review_result(p_review_task_id uuid, p_execution_id uuid, p_reviewer_worker_id uuid, p_decision text, p_review jsonb, p_idempotency_key text) to authenticated;

grant execute on function public.submit_result(p_task_id uuid, p_execution_id uuid, p_worker_id uuid, p_result jsonb, p_idempotency_key text) to authenticated;

revoke all on function private.add_event(p_project_id uuid, p_task_id uuid, p_execution_id uuid, p_worker_id uuid, p_event_type text, p_payload jsonb) from public, anon, authenticated;

revoke all on function private.assert_current_execution(p_task_id uuid, p_execution_id uuid, p_worker_id uuid) from public, anon, authenticated;

revoke all on function private.assert_owner(p_project_id uuid) from public, anon, authenticated;

revoke all on function private.guard_artifact_immutable_fields() from public, anon, authenticated;

revoke all on function private.guard_task_immutable_fields() from public, anon, authenticated;

revoke all on function private.idempotency_get(p_project_id uuid, p_operation text, p_key text, p_hash text) from public, anon, authenticated;

revoke all on function private.idempotency_put(p_project_id uuid, p_operation text, p_key text, p_hash text, p_response jsonb) from public, anon, authenticated;

revoke all on function private.request_hash(p_payload jsonb) from public, anon, authenticated;
