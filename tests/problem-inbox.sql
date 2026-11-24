-- Transactional acceptance tests for the unified problem inbox.
-- All projects, reports, events, tasks, and idempotency rows are rolled back.
BEGIN;
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT id::text FROM auth.users WHERE deleted_at IS NULL ORDER BY created_at LIMIT 1),
  true
);
SELECT set_config(
  'request.jwt.claims',
  jsonb_build_object('sub',current_setting('request.jwt.claim.sub'),'role','authenticated')::text,
  true
);

DO $problem_inbox_test$
DECLARE
  v_key text := 'problem-inbox-test-'||gen_random_uuid()::text;
  v_owner uuid := auth.uid();
  v_project jsonb;
  v_worker jsonb;
  v_project_id uuid;
  v_worker_id uuid;
  v_report jsonb;
  v_duplicate jsonb;
  v_report_id uuid;
  v_owner_report jsonb;
  v_owner_report_id uuid;
  v_task jsonb;
  v_task_id uuid;
  v_update jsonb;
  v_state jsonb;
  v_list jsonb;
  v_other_project jsonb;
  v_other_worker jsonb;
  v_other_project_id uuid;
  v_other_worker_id uuid;
  v_other_report jsonb;
  v_other_report_id uuid;
BEGIN
  IF v_owner IS NULL THEN RAISE EXCEPTION 'FAIL: authenticated Owner context is required'; END IF;

  v_project:=public.register_project(
    'Problem inbox test','transactional fixture',NULL,
    jsonb_build_object('worker_routing',jsonb_build_object('default_worker_key','problem-test-worker')),
    v_key||'-project'
  );
  v_project_id:=(v_project->'data'->>'id')::uuid;
  v_worker:=public.register_worker(v_project_id,'problem-test-worker','Problem Test Worker','test');
  v_worker_id:=(v_worker->'data'->>'id')::uuid;

  -- A report is durable, evidence-backed, and deduplicated by project/fingerprint.
  v_report:=public.report_problem(v_project_id,v_worker_id,jsonb_build_object(
    'category','blocker','severity','high','status','open',
    'title','A reproducible task handoff is blocked',
    'summary','The task cannot proceed because the expected handoff evidence is absent.',
    'impact','The affected project cannot complete its authorized delivery.',
    'recommended_action','Inspect the referenced execution and restore the missing handoff.',
    'owner_question','',
    'evidence',jsonb_build_array(jsonb_build_object(
      'kind','execution','ref','fixture:execution-1','observation','The expected handoff record is absent.'
    )),
    'source','conversation','source_ref','fixture:session-start',
    'fingerprint','test:problem-inbox:handoff-gap'
  ),v_key||'-report');
  v_report_id:=(v_report->'data'->>'report_id')::uuid;
  IF v_report->'data'->>'created'<>'true' THEN
    RAISE EXCEPTION 'FAIL: first problem report was not created: %',v_report;
  END IF;

  v_duplicate:=public.report_problem(v_project_id,v_worker_id,jsonb_build_object(
    'category','blocker','severity','medium','status','open',
    'title','Duplicate report for the same handoff gap',
    'summary','A second conversation observed the same root cause.',
    'impact','The same project delivery remains blocked.',
    'evidence',jsonb_build_array(jsonb_build_object(
      'kind','execution','ref','fixture:execution-1','observation','Same missing handoff.'
    )),
    'source','conversation','fingerprint','test:problem-inbox:handoff-gap'
  ),v_key||'-duplicate');
  IF v_duplicate->'data'->>'duplicate'<>'true'
     OR v_duplicate->'data'->>'report_id'<>v_report_id::text THEN
    RAISE EXCEPTION 'FAIL: active fingerprint did not deduplicate: %',v_duplicate;
  END IF;

  -- Owner decisions are inbox records, never claimable tasks.
  v_owner_report:=public.report_problem(v_project_id,v_worker_id,jsonb_build_object(
    'category','decision','severity','medium','status','owner_input_required',
    'title','Choose the supported product behavior',
    'summary','Two documented behaviors remain mutually exclusive.',
    'impact','Implementation cannot safely choose between the alternatives.',
    'owner_question','Should the system preserve behavior A or behavior B?',
    'evidence',jsonb_build_array(jsonb_build_object(
      'kind','document','ref','docs/DECISIONS.md','observation','The two documented rules conflict.'
    )),
    'source','conversation','fingerprint','test:problem-inbox:owner-decision'
  ),v_key||'-owner-report');
  v_owner_report_id:=(v_owner_report->'data'->>'report_id')::uuid;
  IF v_owner_report->'data'->>'status'<>'owner_input_required' THEN
    RAISE EXCEPTION 'FAIL: owner decision was not classified in the inbox';
  END IF;

  -- Actionable work links to the normal task queue; reports remain separate.
  v_task:=public.create_task(
    v_project_id,v_worker_id,'implementation',
    'Fix the reproducible task handoff gap',
    'Restore the missing handoff evidence and add regression coverage.',
    jsonb_build_object('acceptance',jsonb_build_array('The handoff is persisted and tested.')),
    10,false,NULL,NULL,v_key||'-linked-task'
  );
  v_task_id:=(v_task->'data'->>'id')::uuid;
  v_update:=public.update_problem_report(
    v_report_id,'in_progress','Implementation task created and linked.',
    v_task_id,NULL,v_key||'-link-task'
  );
  IF v_update->'data'->>'status'<>'in_progress' THEN
    RAISE EXCEPTION 'FAIL: report did not transition to in_progress';
  END IF;

  v_update:=public.update_problem_report(
    v_report_id,'resolved','Linked task completed in the test fixture.',
    v_task_id,'https://github.com/example/repo/pull/1',v_key||'-resolve'
  );
  IF v_update->'data'->>'status'<>'resolved' THEN
    RAISE EXCEPTION 'FAIL: report did not resolve';
  END IF;
  BEGIN
    PERFORM public.update_problem_report(
      v_report_id,'in_progress','Invalid terminal transition.',
      NULL,NULL,v_key||'-invalid-terminal');
    RAISE EXCEPTION 'FAIL: terminal report reopened without an explicit reopen transition';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM<>'PROBLEM_REPORT_TERMINAL_REOPEN_REQUIRED' THEN RAISE; END IF;
  END;
  PERFORM public.update_problem_report(
    v_report_id,'open','Explicitly reopen after a new regression.',
    NULL,NULL,v_key||'-reopen');

  v_list:=public.list_problem_reports(NULL,NULL,1);
  IF jsonb_array_length(v_list->'data')<>1
     OR v_list->'data'->0->>'id'<>v_report_id::text THEN
    RAISE EXCEPTION 'FAIL: digest limit omitted the older high-severity report: %',v_list;
  END IF;

  v_state:=public.get_problem_report(v_report_id);
  IF jsonb_array_length(v_state->'data'->'events')<4
     OR v_state->'data'->'report'->>'linked_task_id'<>v_task_id::text THEN
    RAISE EXCEPTION 'FAIL: report detail or append-only history is incomplete';
  END IF;
  BEGIN
    UPDATE public.problem_report_events SET payload='{}'::jsonb WHERE report_id=v_report_id;
    RAISE EXCEPTION 'FAIL: append-only report history accepted an update';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM<>'PROBLEM_REPORT_EVENTS_APPEND_ONLY' THEN RAISE; END IF;
  END;

  -- A second project owned by another user must not leak into the Owner's digest.
  INSERT INTO auth.users(id) VALUES ('00000000-0000-4000-8000-000000000099')
  ON CONFLICT (id) DO NOTHING;
  PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000099',true);
  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub',current_setting('request.jwt.claim.sub'),'role','authenticated')::text,true);
  v_other_project:=public.register_project(
    'Other owner problem inbox test','isolation fixture',NULL,'{}'::jsonb,v_key||'-other-project'
  );
  v_other_project_id:=(v_other_project->'data'->>'id')::uuid;
  v_other_worker:=public.register_worker(v_other_project_id,'other-owner-worker','Other Owner Worker','test');
  v_other_worker_id:=(v_other_worker->'data'->>'id')::uuid;
  v_other_report:=public.report_problem(v_other_project_id,v_other_worker_id,jsonb_build_object(
    'category','risk','severity','critical','title','Private project risk',
    'summary','This report belongs to another owner.','impact','Must not appear in the first owner digest.',
    'evidence',jsonb_build_array(jsonb_build_object('kind','test','ref','fixture','observation','private')),
    'source','automated','fingerprint','test:problem-inbox:other-owner'
  ),v_key||'-other-report');
  v_other_report_id:=(v_other_report->'data'->>'report_id')::uuid;

  PERFORM set_config('request.jwt.claim.sub',v_owner::text,true);
  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub',v_owner::text,'role','authenticated')::text,true);
  v_list:=public.list_problem_reports(NULL,NULL,200);
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_list->'data') item
    WHERE item->>'id'=v_report_id::text
  ) OR EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_list->'data') item
    WHERE item->>'id'=v_other_report_id::text
  ) THEN
    RAISE EXCEPTION 'FAIL: cross-project Owner digest has missing or leaked reports: %',v_list;
  END IF;
  BEGIN
    PERFORM public.get_problem_report(v_other_report_id);
    RAISE EXCEPTION 'FAIL: Owner read another project problem report';
  EXCEPTION WHEN SQLSTATE 'P0002' THEN
    IF SQLERRM<>'PROBLEM_REPORT_NOT_FOUND' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'PASS: evidence validation, active-fingerprint deduplication, owner-decision inbox state, task linking, status transitions, append-only audit, cross-project Owner digest, and project isolation';
END
$problem_inbox_test$;
ROLLBACK;
