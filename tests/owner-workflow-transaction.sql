-- Transactional end-to-end RPC acceptance test.
-- Requires at least one existing Supabase Auth user.
-- All business records are rolled back; this does not seed live project data.

begin;
select set_config(
  'request.jwt.claim.sub',
  (select id::text from auth.users where deleted_at is null order by created_at limit 1),
  true
);
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', current_setting('request.jwt.claim.sub'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

do $mvp$
declare
  v_key text := 'acceptance-' || gen_random_uuid()::text;
  v_project jsonb; v_project_replay jsonb; v_project_read jsonb;
  v_owner_worker jsonb; v_reviewer_worker jsonb;
  v_task jsonb; v_claim jsonb; v_submit jsonb; v_artifact jsonb;
  v_review_task jsonb; v_review_claim jsonb; v_reject jsonb;
  v_fix jsonb; v_fix_claim jsonb; v_fix_submit jsonb; v_resubmit jsonb;
  v_review2 jsonb; v_review_claim2 jsonb; v_accept jsonb;
  v_noreview jsonb; v_noreview_claim jsonb; v_complete jsonb;
  v_cancel_task jsonb; v_cancel_claim jsonb; v_cancel_result jsonb; v_cancel_read jsonb;
  v_workers_read jsonb; v_tasks_read jsonb; v_task_read jsonb; v_heartbeat jsonb;
  v_project_id uuid; v_owner_id uuid; v_owner_worker_id uuid; v_reviewer_worker_id uuid;
  v_task_id uuid; v_exec_id uuid; v_review_id uuid; v_review_exec_id uuid;
  v_fix_id uuid; v_fix_exec_id uuid; v_review2_id uuid; v_review2_exec_id uuid;
  v_noreview_id uuid; v_noreview_exec_id uuid;
  v_cancel_id uuid; v_cancel_exec_id uuid;
  v_issues jsonb := '[{"id":"I1","description":"Add missing validation"}]'::jsonb;
begin
  v_owner_id := auth.uid();
  if v_owner_id is null then raise exception 'FAIL: test requires authenticated Owner JWT'; end if;
  v_project := public.register_project(
    'MVP rollback acceptance', 'transactional test only', null, '{}'::jsonb, v_key
  );
  v_project_replay := public.register_project(
    'MVP rollback acceptance', 'transactional test only', null, '{}'::jsonb, v_key
  );
  if (v_project->'data'->>'id') is distinct from (v_project_replay->'data'->>'id') then
    raise exception 'FAIL: register_project idempotent replay';
  end if;
  begin
    perform public.register_project('different payload','transactional test only',null,'{}'::jsonb,v_key);
    raise exception 'FAIL: idempotency conflict was not rejected';
  exception when others then
    if sqlerrm not like '%IDEMPOTENCY_CONFLICT%' then raise; end if;
  end;
  v_project_id := (v_project->'data'->>'id')::uuid;

  v_owner_worker := public.register_worker(v_project_id,'coordinator','Coordinator','acceptance');
  v_reviewer_worker := public.register_worker(v_project_id,'reviewer','Reviewer','acceptance');
  v_owner_worker_id := (v_owner_worker->'data'->>'id')::uuid;
  v_reviewer_worker_id := (v_reviewer_worker->'data'->>'id')::uuid;
  perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('request.jwt.claim.sub'),'role','authenticated')::text,true);
  begin
    perform public.get_project(v_project_id);
    raise exception 'FAIL: cross-owner project read was not denied';
  exception when others then
    if sqlerrm not like '%PROJECT_FORBIDDEN%' then raise; end if;
  end;
  perform set_config('request.jwt.claim.sub',v_owner_id::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_owner_id::text,'role','authenticated')::text,true);
  v_project_read := public.get_project(v_project_id);
  v_workers_read := public.list_workers(v_project_id);
  if v_project_read->'data'->>'id' <> v_project_id::text or jsonb_array_length(v_workers_read->'data') <> 2 then
    raise exception 'FAIL: project/worker read RPCs';
  end if;

  v_task := public.create_task(
    v_project_id,v_owner_worker_id,'implementation','Acceptance implementation',
    'test implementation','{}'::jsonb,100,true,null,null,v_key||'-task'
  );
  v_task_id := (v_task->'data'->>'id')::uuid;

  v_claim := public.claim_task(v_project_id,v_owner_worker_id,300,v_key||'-claim');
  v_exec_id := (v_claim->'data'->>'execution_id')::uuid;
  if (v_claim->'data'->>'task_id')::uuid <> v_task_id then
    raise exception 'FAIL: initial claim';
  end if;
  v_heartbeat := public.heartbeat_execution(v_task_id,v_exec_id,v_owner_worker_id,v_key||'-heartbeat');

  v_artifact := public.add_artifact(
    v_task_id,v_exec_id,v_owner_worker_id,'report','acceptance artifact',
    null,null,null,null,null,'{"test":true}'::jsonb,v_key||'-artifact'
  );
  v_submit := public.submit_result(
    v_task_id,v_exec_id,v_owner_worker_id,'{"summary":"initial delivery"}'::jsonb,v_key||'-submit'
  );
  if v_submit->'data'->>'status' <> 'submitted' then
    raise exception 'FAIL: submit_result';
  end if;
  v_tasks_read := public.list_tasks(v_project_id,null,null,100,null);
  v_task_read := public.get_task(v_task_id);
  if jsonb_array_length(v_tasks_read->'data') <> 1 or v_task_read->'data'->'task'->>'id' <> v_task_id::text then
    raise exception 'FAIL: task read RPCs';
  end if;

  begin
    perform public.create_review_task(v_task_id,v_task_id,v_exec_id,v_owner_worker_id,v_key||'-self-review');
    raise exception 'FAIL: self-review was not rejected';
  exception when others then
    if sqlerrm not like '%REVIEWER_CANNOT_REVIEW_OWN_EXECUTION%' then raise; end if;
  end;
  v_review_task := public.create_review_task(
    v_task_id,v_task_id,v_exec_id,v_reviewer_worker_id,v_key||'-review1'
  );
  v_review_id := (v_review_task->'data'->>'id')::uuid;
  begin
    perform public.create_review_task(v_task_id,v_task_id,v_exec_id,v_reviewer_worker_id,v_key||'-duplicate-review');
    raise exception 'FAIL: duplicate review was not rejected';
  exception when others then
    if sqlerrm not like '%REVIEW_ALREADY_EXISTS%' then raise; end if;
  end;
  v_review_claim := public.claim_task(v_project_id,v_reviewer_worker_id,300,v_key||'-review-claim1');
  v_review_exec_id := (v_review_claim->'data'->>'execution_id')::uuid;
  if (v_review_claim->'data'->>'task_id')::uuid <> v_review_id then
    raise exception 'FAIL: reviewer claim';
  end if;
  v_reject := public.review_result(
    v_review_id,v_review_exec_id,v_reviewer_worker_id,'rejected',
    jsonb_build_object('issues',v_issues),v_key||'-reject'
  );
  if v_reject->'data'->>'decision' <> 'rejected' then
    raise exception 'FAIL: review reject';
  end if;

  v_fix := public.create_fix_task(
    v_task_id,v_review_id,'Fix acceptance issue','apply reviewer feedback',
    jsonb_build_object('issues',v_issues),v_owner_worker_id,v_key||'-fix'
  );
  v_fix_id := (v_fix->'data'->>'id')::uuid;
  v_fix_claim := public.claim_task(v_project_id,v_owner_worker_id,300,v_key||'-fix-claim');
  v_fix_exec_id := (v_fix_claim->'data'->>'execution_id')::uuid;
  if (v_fix_claim->'data'->>'task_id')::uuid <> v_fix_id then
    raise exception 'FAIL: fix claim';
  end if;
  v_fix_submit := public.submit_result(
    v_fix_id,v_fix_exec_id,v_owner_worker_id,'{"summary":"fixed"}'::jsonb,v_key||'-fix-submit'
  );
  v_resubmit := public.resubmit_after_fix(
    v_task_id,v_fix_id,v_fix_exec_id,v_owner_worker_id,v_key||'-resubmit'
  );
  if v_resubmit->'data'->>'status' <> 'submitted' then
    raise exception 'FAIL: resubmit_after_fix';
  end if;

  v_review2 := public.create_review_task(
    v_task_id,v_fix_id,v_fix_exec_id,v_reviewer_worker_id,v_key||'-review2'
  );
  v_review2_id := (v_review2->'data'->>'id')::uuid;
  v_review_claim2 := public.claim_task(v_project_id,v_reviewer_worker_id,300,v_key||'-review-claim2');
  v_review2_exec_id := (v_review_claim2->'data'->>'execution_id')::uuid;
  if (v_review_claim2->'data'->>'task_id')::uuid <> v_review2_id then
    raise exception 'FAIL: second reviewer claim';
  end if;
  v_accept := public.review_result(
    v_review2_id,v_review2_exec_id,v_reviewer_worker_id,'accepted',
    '{"summary":"approved"}'::jsonb,v_key||'-accept'
  );
  if v_accept->'data'->>'decision' <> 'accepted' then
    raise exception 'FAIL: review accept';
  end if;

  v_noreview := public.create_task(
    v_project_id,v_owner_worker_id,'implementation','No-review acceptance',
    'test no-review path','{}'::jsonb,100,false,null,null,v_key||'-noreview'
  );
  v_noreview_id := (v_noreview->'data'->>'id')::uuid;
  v_noreview_claim := public.claim_task(v_project_id,v_owner_worker_id,300,v_key||'-noreview-claim');
  v_noreview_exec_id := (v_noreview_claim->'data'->>'execution_id')::uuid;
  if (v_noreview_claim->'data'->>'task_id')::uuid <> v_noreview_id then
    raise exception 'FAIL: no-review claim';
  end if;
  v_complete := public.complete_execution(
    v_noreview_id,v_noreview_exec_id,v_owner_worker_id,
    '{"summary":"completed"}'::jsonb,v_key||'-complete'
  );
  if v_complete->'data'->>'status' <> 'accepted' then
    raise exception 'FAIL: complete_execution';
  end if;

  v_cancel_task := public.create_task(
    v_project_id,v_owner_worker_id,'implementation','Cancel running acceptance',
    'test cancellation','{}'::jsonb,100,true,null,null,v_key||'-cancel-task'
  );
  v_cancel_id := (v_cancel_task->'data'->>'id')::uuid;
  v_cancel_claim := public.claim_task(v_project_id,v_owner_worker_id,300,v_key||'-cancel-claim');
  v_cancel_exec_id := (v_cancel_claim->'data'->>'execution_id')::uuid;
  v_cancel_result := public.cancel_task(v_cancel_id,v_owner_worker_id,'acceptance cancellation',v_key||'-cancel');
  v_cancel_read := public.get_task(v_cancel_id);
  if v_cancel_result->'data'->>'status' <> 'cancelled'
    or v_cancel_read->'data'->'task'->>'status' <> 'cancelled'
    or v_cancel_read->'data'->'executions'->0->>'status' <> 'failed' then
    raise exception 'FAIL: cancel running task must fail Execution and clear lease';
  end if;

  raise notice 'PASS: project/Worker/Task reads; idempotency replay/conflict; claim/heartbeat; artifact; submit; self-review/duplicate-review guards; Reviewer rejection; Fix/resubmit; Reviewer acceptance; no-review completion; cancel-running';
end
$mvp$;

rollback;
