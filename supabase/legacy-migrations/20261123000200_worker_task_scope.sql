-- ARCHIVED: Historical change already incorporated into supabase/migrations/database-schema.sql.
-- Do not apply this file after the current baseline schema snapshot.

-- Worker identity isolation hardening v1.2.1
-- Restrict worker reads and task-scoped operations to the authenticated Worker.

do $migration$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='cancel_task';
  v_new:=replace(v_def,
    'perform private.assert_worker_actor(v_task.project_id,p_worker_id);',
    'perform private.assert_worker_actor(v_task.project_id,p_worker_id);' || E'\n  if not exists(select 1 from public.projects where id=v_task.project_id and owner_id=auth.uid())\n    and v_task.assigned_worker_id is distinct from p_worker_id then\n    raise exception using errcode=''42501'',message=''TASK_NOT_ASSIGNED_TO_WORKER'';\n  end if;');
  if v_new=v_def then raise exception 'cancel_task actor check not found'; end if;
  execute v_new;

  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='create_fix_task';
  v_new:=replace(v_def,'perform private.assert_worker_actor(v_original.project_id,p_worker_id);',
    'perform private.assert_owner(v_original.project_id);');
  if v_new=v_def then raise exception 'create_fix_task actor check not found'; end if;
  execute v_new;

  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='resubmit_after_fix';
  v_new:=replace(v_def,
    'if not exists(select 1 from public.workers where id=p_worker_id and project_id=v_original.project_id and status=''active'') then',
    'if v_exec.worker_id is distinct from p_worker_id then raise exception using errcode=''42501'',message=''FIX_EXECUTION_NOT_OWNED''; end if;' || E'\n  if not exists(select 1 from public.workers where id=p_worker_id and project_id=v_original.project_id and status=''active'') then');
  if v_new=v_def then raise exception 'resubmit_after_fix worker check not found'; end if;
  execute v_new;
end;
$migration$;

-- Assigned Workers may inspect only their own tasks and Worker record.
do $migration$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='get_task';
  if position('assert_worker_actor' in v_def)=0 then
    v_new:=replace(v_def,'perform private.assert_owner(v_task.project_id);',
      'perform private.assert_worker_actor(v_task.project_id,v_task.assigned_worker_id);');
    if v_new=v_def then raise exception 'get_task owner check not found'; end if;
    execute v_new;
  end if;

  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='get_worker';
  if position('assert_worker_actor' in v_def)=0 then
    v_new:=replace(v_def,'perform private.assert_owner(v_row.project_id);',
      'perform private.assert_worker_actor(v_row.project_id,p_worker_id);');
    if v_new=v_def then raise exception 'get_worker owner check not found'; end if;
    execute v_new;
  end if;

  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='list_tasks';
  if position('assert_worker_actor' in v_def)=0 then
    v_new:=replace(v_def,'perform private.assert_owner(p_project_id);',
      'perform private.assert_worker_actor(p_project_id,p_worker_id);');
    if v_new=v_def then raise exception 'list_tasks owner check not found'; end if;
    execute v_new;
  end if;
end;
$migration$;
