-- Run with a privileged test connection against a disposable project.
begin;
do $$
declare v_count int;
begin
  select count(*) into v_count from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind='r'
    and c.relname in ('projects','workers','tasks','executions','artifacts','task_events','operation_requests');
  if v_count <> 7 then raise exception 'Expected seven core tables; got %',v_count; end if;
  if not exists(select 1 from pg_indexes where schemaname='public' and indexname='uq_executions_one_running_per_task') then raise exception 'Missing one-running-execution index'; end if;
  if not exists(select 1 from pg_indexes where schemaname='public' and indexname='uq_review_target_once') then raise exception 'Missing unique review target index'; end if;
  if not exists(select 1 from pg_constraint where conname='fk_tasks_current_execution') then raise exception 'Missing current execution composite FK'; end if;
  if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='projects' and column_name='owner_id' and is_nullable='NO') then raise exception 'projects.owner_id must be NOT NULL'; end if;
  if (select count(*) from pg_tables where schemaname='public' and tablename in ('projects','workers','tasks','executions','artifacts','task_events','operation_requests') and rowsecurity) <> 7 then raise exception 'RLS must be enabled on all core tables'; end if;
end $$;
rollback;
