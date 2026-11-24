-- Worker identity isolation v1.2
-- Apply after database-schema.sql. Safe for an existing MVP v1.1 database.

alter table public.workers
  add column if not exists auth_user_id uuid null references auth.users(id) on delete restrict;

create unique index if not exists uq_workers_auth_user_id
  on public.workers(auth_user_id) where auth_user_id is not null;

create or replace function private.assert_worker_actor(p_project_id uuid, p_worker_id uuid)
returns void
language plpgsql
security definer
set search_path to 'pg_catalog','public','auth','private'
as $function$
declare v_uid uuid;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception using errcode='28000', message='UNAUTHENTICATED';
  end if;
  if exists (select 1 from public.projects p where p.id=p_project_id and p.owner_id=v_uid) then
    return;
  end if;
  if p_worker_id is null or not exists (
    select 1 from public.workers w
    where w.id=p_worker_id and w.project_id=p_project_id
      and w.auth_user_id=v_uid and w.status='active'
  ) then
    raise exception using errcode='42501', message='WORKER_IDENTITY_MISMATCH';
  end if;
end;
$function$;

create or replace function public.bind_worker_identity(p_worker_id uuid, p_auth_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','auth','private'
as $function$
declare v_worker public.workers%rowtype;
begin
  if auth.uid() is null then
    raise exception using errcode='28000', message='UNAUTHENTICATED';
  end if;
  select * into v_worker from public.workers where id=p_worker_id for update;
  if not found then
    raise exception using errcode='P0002', message='WORKER_NOT_FOUND';
  end if;
  perform private.assert_owner(v_worker.project_id);
  if p_auth_user_id is not null and not exists (select 1 from auth.users u where u.id=p_auth_user_id) then
    raise exception using errcode='23503', message='AUTH_USER_NOT_FOUND';
  end if;
  update public.workers set auth_user_id=p_auth_user_id where id=p_worker_id;
  return jsonb_build_object('success',true,'data',jsonb_build_object(
    'worker_id',p_worker_id,'auth_user_id',p_auth_user_id));
end;
$function$;

-- Replace Owner-only checks with exact Worker identity checks on Worker RPCs.
do $migration$
declare r record; v_def text; v_new text;
begin
  for r in
    select p.oid,p.proname from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in (
      'add_artifact','cancel_task','claim_task','complete_execution',
      'create_fix_task','heartbeat_execution','heartbeat_worker',
      'resubmit_after_fix','review_result','submit_result'
    )
  loop
    v_def:=pg_get_functiondef(r.oid);
    v_new:=v_def;
    if r.proname='claim_task' then
      v_new:=replace(v_new,'perform private.assert_owner(p_project_id);',
        'perform private.assert_worker_actor(p_project_id,p_worker_id);');
    elsif r.proname='heartbeat_worker' then
      v_new:=replace(v_new,'perform private.assert_owner(v_project);',
        'perform private.assert_worker_actor(v_project,p_worker_id);');
    elsif r.proname='review_result' then
      v_new:=replace(v_new,'perform private.assert_owner(v_project);',
        'perform private.assert_worker_actor(v_project,p_reviewer_worker_id);');
    else
      v_new:=replace(v_new,'perform private.assert_owner(v_task.project_id);',
        'perform private.assert_worker_actor(v_task.project_id,p_worker_id);');
      v_new:=replace(v_new,'perform private.assert_owner(v_project);',
        'perform private.assert_worker_actor(v_project,p_worker_id);');
      v_new:=replace(v_new,'perform private.assert_owner(v_original.project_id);',
        'perform private.assert_worker_actor(v_original.project_id,p_worker_id);');
    end if;
    if v_new=v_def then
      raise exception 'Expected authorization expression not found in %',r.proname;
    end if;
    execute v_new;
  end loop;
end;
$migration$;

-- The shared execution guard must enforce the same Worker identity boundary.
do $migration$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='private' and p.proname='assert_current_execution';
  v_new:=replace(v_def,'perform private.assert_owner(v_task.project_id);',
    'perform private.assert_worker_actor(v_task.project_id,p_worker_id);');
  if v_new=v_def then raise exception 'Execution guard authorization expression not found'; end if;
  execute v_new;
end;
$migration$;

revoke all on function public.bind_worker_identity(uuid,uuid) from public,anon;
grant execute on function public.bind_worker_identity(uuid,uuid) to authenticated;
revoke all on function private.assert_worker_actor(uuid,uuid) from public,anon,authenticated;
