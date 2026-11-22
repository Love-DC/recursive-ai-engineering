-- Negative identity-boundary tests. All test records are rolled back.
begin;
do $setup$
declare v_owner uuid; v_project uuid:=gen_random_uuid(); v_bound uuid:=gen_random_uuid(); v_unbound uuid:=gen_random_uuid(); v_fake uuid:=gen_random_uuid();
begin
  select id into v_owner from auth.users where deleted_at is null order by created_at limit 1;
  if v_owner is null then raise exception 'An existing Owner Auth user is required'; end if;
  insert into public.projects(id,name,owner_id) values(v_project,'worker-auth-boundary-test',v_owner);
  insert into public.workers(id,project_id,worker_key,display_name,auth_user_id)
    values(v_bound,v_project,'bound-worker','Bound Worker',v_owner);
  insert into public.workers(id,project_id,worker_key,display_name)
    values(v_unbound,v_project,'unbound-worker','Unbound Worker');
  perform set_config('request.jwt.claim.sub',v_fake::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_fake::text,'role','authenticated')::text,true);
  execute 'set local role authenticated';

  begin
    perform public.claim_task(v_project,v_bound,120,'bound-worker-impersonation');
    raise exception 'FAIL: a different Auth subject impersonated a bound Worker';
  exception when insufficient_privilege then
    if sqlerrm <> 'WORKER_IDENTITY_MISMATCH' then raise; end if;
  end;

  begin
    perform public.claim_task(v_project,v_unbound,120,'unbound-worker-claim');
    raise exception 'FAIL: an unbound Worker claimed a task';
  exception when insufficient_privilege then
    if sqlerrm <> 'WORKER_IDENTITY_MISMATCH' then raise; end if;
  end;

  begin
    perform public.get_worker(v_bound);
    raise exception 'FAIL: a different Auth subject read another Worker identity';
  exception when insufficient_privilege then
    if sqlerrm <> 'WORKER_IDENTITY_MISMATCH' then raise; end if;
  end;
  execute 'reset role';
  raise notice 'PASS: mismatched Auth subject and unbound Worker denied for claim and Worker read';
end;
$setup$;
rollback;
