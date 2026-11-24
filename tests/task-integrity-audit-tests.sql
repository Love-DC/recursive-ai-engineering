-- Project-scoped task reference monitor and destructive audit integration tests.
-- Runs only in the disposable PostgreSQL 17 CI database. Every fixture/audit row
-- is removed by transaction rollback; no production database is involved.

\set ON_ERROR_STOP on
BEGIN;

SELECT set_config('request.jwt.claim.sub', :'owner_id', true);
SELECT set_config('test.project_id', :'project_id', true);
SELECT set_config('test.worker_id', :'worker_id', true);

DO $clean_integrity_scan$
DECLARE
  v_project uuid := current_setting('test.project_id')::uuid;
  v_findings integer;
BEGIN
  SELECT count(*) INTO v_findings
  FROM private.task_integrity_findings(v_project);

  IF v_findings <> 0 THEN
    RAISE EXCEPTION 'FAIL: clean project fixture returned % integrity findings: %',
      v_findings,
      (SELECT jsonb_agg(to_jsonb(f)) FROM private.task_integrity_findings(v_project) f);
  END IF;
END
$clean_integrity_scan$;

-- Synthetic edge expressions test both detection paths without disabling or
-- bypassing any production foreign-key constraint.
DO $synthetic_edge_findings$
DECLARE
  v_findings jsonb;
BEGIN
  SELECT jsonb_agg(to_jsonb(f) ORDER BY f.finding_code)
  INTO v_findings
  FROM private.task_integrity_findings_from_edges(
    jsonb_build_array(
      jsonb_build_object(
        'source_relation','tasks',
        'row_id','00000000-0000-4000-8000-000000000101',
        'reference_name','parent_task_id',
        'referenced_id','00000000-0000-4000-8000-000000000102',
        'source_project_id','00000000-0000-4000-8000-000000000001',
        'target_found',false,
        'target_project_id',NULL
      ),
      jsonb_build_object(
        'source_relation','tasks',
        'row_id','00000000-0000-4000-8000-000000000103',
        'reference_name','fixes_task_id',
        'referenced_id','00000000-0000-4000-8000-000000000104',
        'source_project_id','00000000-0000-4000-8000-000000000001',
        'target_found',true,
        'target_project_id','00000000-0000-4000-8000-000000000002'
      ),
      jsonb_build_object(
        'source_relation','tasks',
        'row_id','00000000-0000-4000-8000-000000000105',
        'reference_name','assigned_worker_id',
        'referenced_id',NULL,
        'source_project_id','00000000-0000-4000-8000-000000000001',
        'target_found',false,
        'target_project_id',NULL
      )
    )
  ) f;

  IF jsonb_array_length(coalesce(v_findings,'[]'::jsonb)) <> 2 THEN
    RAISE EXCEPTION 'FAIL: synthetic edge validator should report missing and cross-project edges only: %',
      v_findings;
  END IF;

  IF NOT (v_findings @> '[{"finding_code":"missing_reference","reference_name":"parent_task_id"}]'::jsonb)
     OR NOT (v_findings @> '[{"finding_code":"cross_project_reference","reference_name":"fixes_task_id"}]'::jsonb) THEN
    RAISE EXCEPTION 'FAIL: synthetic edge validator returned incorrect finding types: %',
      v_findings;
  END IF;
END
$synthetic_edge_findings$;

-- The audit table deliberately has no FK back to mutable project/task/execution
-- rows and is private/append-only.
DO $audit_table_boundary$
DECLARE
  v_fk_count integer;
BEGIN
  SELECT count(*) INTO v_fk_count
  FROM pg_constraint
  WHERE conrelid='private.task_destructive_audit'::regclass
    AND contype='f';

  IF v_fk_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: destructive audit table must not reference mutable rows';
  END IF;

  IF NOT (
    SELECT relrowsecurity AND relforcerowsecurity
    FROM pg_class WHERE oid='private.task_destructive_audit'::regclass
  ) THEN
    RAISE EXCEPTION 'FAIL: destructive audit table must enable and force RLS';
  END IF;

  IF has_table_privilege('anon','private.task_destructive_audit','SELECT')
     OR has_table_privilege('authenticated','private.task_destructive_audit','SELECT')
     OR has_table_privilege('anon','private.task_destructive_audit','INSERT')
     OR has_table_privilege('authenticated','private.task_destructive_audit','INSERT') THEN
    RAISE EXCEPTION 'FAIL: anon/authenticated must not access destructive audit rows';
  END IF;
END
$audit_table_boundary$;

CREATE TEMP TABLE task_integrity_audit_fixture (
  task_id uuid PRIMARY KEY,
  execution_id uuid UNIQUE
) ON COMMIT DROP;

INSERT INTO task_integrity_audit_fixture(task_id,execution_id)
VALUES (gen_random_uuid(),gen_random_uuid());

INSERT INTO public.tasks(
  id,project_id,task_type,title,description,requirements,
  requires_review,status,priority,created_by_worker_id
)
SELECT
  f.task_id,current_setting('test.project_id')::uuid,
  'implementation','Integrity audit delete fixture',
  'Disposable metadata-only audit test fixture.',
  '{}'::jsonb,false,'pending',-100,
  current_setting('test.worker_id')::uuid
FROM task_integrity_audit_fixture f;

INSERT INTO public.executions(
  id,task_id,worker_id,attempt,status,started_at,finished_at
)
SELECT
  f.execution_id,f.task_id,current_setting('test.worker_id')::uuid,
  1,'expired',clock_timestamp(),clock_timestamp()
FROM task_integrity_audit_fixture f;

SAVEPOINT delete_audit_probe;
DELETE FROM public.tasks
WHERE id=(SELECT task_id FROM task_integrity_audit_fixture);

DO $delete_audit_assertions$
DECLARE
  v_task_id uuid := (SELECT task_id FROM task_integrity_audit_fixture);
  v_execution_id uuid := (SELECT execution_id FROM task_integrity_audit_fixture);
  v_count integer;
BEGIN
  SELECT count(*) INTO v_count
  FROM private.task_destructive_audit
  WHERE operation='DELETE'
    AND relation_name='tasks'
    AND task_id=v_task_id
    AND project_id=current_setting('test.project_id')::uuid;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: expected one task DELETE audit row for %, found %',v_task_id,v_count;
  END IF;

  SELECT count(*) INTO v_count
  FROM private.task_destructive_audit
  WHERE operation='DELETE'
    AND relation_name='executions'
    AND task_id=v_task_id
    AND execution_id=v_execution_id
    AND attempt=1;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: expected one cascaded execution DELETE audit row for %, found %',
      v_execution_id,v_count;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema='private'
      AND table_name='task_destructive_audit'
      AND column_name IN (
        'description','result','error_message','raw_sql',
        'jwt','access_token','refresh_token'
      )
  ) THEN
    RAISE EXCEPTION 'FAIL: audit schema contains a forbidden freeform/secret field';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM private.task_destructive_audit
    WHERE operation='DELETE'
      AND relation_name='tasks'
      AND task_id=v_task_id
      AND session_user_name=session_user
      AND backend_pid=pg_backend_pid()
  ) THEN
    RAISE EXCEPTION 'FAIL: task audit row is missing session/actor metadata';
  END IF;
END
$delete_audit_assertions$;

ROLLBACK TO SAVEPOINT delete_audit_probe;

DO $delete_rollback_assertions$
DECLARE
  v_task_id uuid := (SELECT task_id FROM task_integrity_audit_fixture);
  v_count integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.tasks WHERE id=v_task_id)
     OR NOT EXISTS (SELECT 1 FROM public.executions WHERE task_id=v_task_id) THEN
    RAISE EXCEPTION 'FAIL: rollback did not restore task and cascaded execution fixtures';
  END IF;

  SELECT count(*) INTO v_count
  FROM private.task_destructive_audit WHERE task_id=v_task_id;

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: DELETE audit row survived rollback unexpectedly';
  END IF;
END
$delete_rollback_assertions$;

SAVEPOINT truncate_audit_probe;
TRUNCATE TABLE public.executions CASCADE;

DO $truncate_audit_assertions$
DECLARE
  v_count integer;
BEGIN
  SELECT count(*) INTO v_count
  FROM private.task_destructive_audit
  WHERE operation='TRUNCATE'
    AND relation_name='executions';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: expected one executions TRUNCATE audit row, found %',v_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM private.task_destructive_audit
    WHERE operation='TRUNCATE'
      AND relation_name='tasks'
  ) THEN
    RAISE EXCEPTION 'FAIL: TRUNCATE CASCADE did not audit the cascaded tasks relation';
  END IF;
END
$truncate_audit_assertions$;

ROLLBACK TO SAVEPOINT truncate_audit_probe;

DO $truncate_rollback_assertions$
DECLARE
  v_task_id uuid := (SELECT task_id FROM task_integrity_audit_fixture);
  v_count integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.tasks WHERE id=v_task_id)
     OR NOT EXISTS (SELECT 1 FROM public.executions WHERE task_id=v_task_id) THEN
    RAISE EXCEPTION 'FAIL: rollback did not restore rows after TRUNCATE CASCADE';
  END IF;

  SELECT count(*) INTO v_count
  FROM private.task_destructive_audit
  WHERE operation='TRUNCATE';

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: TRUNCATE audit rows survived rollback unexpectedly';
  END IF;
END
$truncate_rollback_assertions$;

DO $append_only_assertion$
DECLARE
  v_audit_id bigint;
  v_rejected boolean := false;
BEGIN
  INSERT INTO private.task_destructive_audit(
    transaction_id,operation,relation_name,session_user_name,
    database_user_name,backend_pid,trigger_depth
  )
  VALUES(
    txid_current(),'DELETE','tasks',session_user,current_user,
    pg_backend_pid(),0
  )
  RETURNING id INTO v_audit_id;

  BEGIN
    UPDATE private.task_destructive_audit
    SET application_name='tampered'
    WHERE id=v_audit_id;
    RAISE EXCEPTION 'FAIL: audit UPDATE was not rejected';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM <> 'TASK_DESTRUCTIVE_AUDIT_APPEND_ONLY' THEN
      RAISE;
    END IF;
    v_rejected := true;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'FAIL: audit table accepted an UPDATE attempt';
  END IF;
END
$append_only_assertion$;

SET LOCAL ROLE authenticated;
DO $client_privacy_assertions$
BEGIN
  IF has_table_privilege(current_user,'private.task_destructive_audit','SELECT')
     OR has_table_privilege(current_user,'private.task_destructive_audit','INSERT')
     OR has_table_privilege(current_user,'private.task_destructive_audit','UPDATE')
     OR has_table_privilege(current_user,'private.task_destructive_audit','DELETE') THEN
    RAISE EXCEPTION 'FAIL: authenticated role can access the private audit table';
  END IF;

  IF has_function_privilege(
    current_user,
    'private.task_integrity_findings(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated role can execute the private integrity monitor';
  END IF;
END
$client_privacy_assertions$;
RESET ROLE;

ROLLBACK;
