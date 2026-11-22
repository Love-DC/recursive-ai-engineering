-- Run with a privileged test connection; all checks are read-only/transactional.
begin;
set local role authenticated;
do $$
declare v_ok boolean := false;
begin
  begin
    perform public.get_project('00000000-0000-4000-8000-000000000001'::uuid);
  exception when others then
    if sqlerrm='UNAUTHENTICATED' then v_ok:=true; else raise; end if;
  end;
  if not v_ok then raise exception 'Missing auth.uid() guard'; end if;
  if has_table_privilege(current_user,'public.tasks','INSERT')
    or has_table_privilege(current_user,'public.tasks','UPDATE')
    or has_table_privilege(current_user,'public.tasks','DELETE') then
    raise exception 'Authenticated role can directly write tasks';
  end if;
  if has_table_privilege(current_user,'public.operation_requests','SELECT')
    or has_table_privilege(current_user,'public.operation_requests','INSERT') then
    raise exception 'Authenticated role can access idempotency table';
  end if;
end $$;
reset role;
set local role anon;
do $$
declare v_ok boolean:=false;
begin
  begin
    perform public.get_project('00000000-0000-4000-8000-000000000001'::uuid);
  exception when insufficient_privilege then v_ok:=true;
  end;
  if not v_ok then raise exception 'anon can execute authenticated RPC'; end if;
end $$;
rollback;
