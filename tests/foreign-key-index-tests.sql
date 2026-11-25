-- Regression checks for the additive foreign-key index migration.
-- Runs on the disposable PostgreSQL 17 CI database. No fixture data is mutated.
BEGIN;

DO $foreign_key_index_coverage$
DECLARE
  v_expected record;
  v_actual_columns text[];
  v_named_index_count integer;
  v_exact_index_count integer;
  v_fk_names text[];
  v_expected_fk_names text[] := ARRAY[
    'private.system_actor_audit.system_actor_audit_principal_id_fkey',
    'private.system_actor_audit.system_actor_audit_product_owner_id_fkey',
    'private.system_actor_audit.system_actor_audit_project_id_fkey',
    'public.initiative_events.initiative_events_initiative_fk',
    'public.initiative_events.initiative_events_worker_fk',
    'public.initiative_learnings.initiative_learnings_initiative_fk',
    'public.initiative_support_requests.initiative_support_requests_initiative_fk',
    'public.initiative_support_requests.initiative_support_requests_worker_fk',
    'public.initiative_work_items.initiative_work_items_initiative_fk',
    'public.initiative_work_items.initiative_work_items_task_fk',
    'public.initiatives.initiatives_project_id_fkey',
    'public.initiatives.initiatives_proposer_same_project_fk',
    'public.problem_report_events.problem_report_events_report_fk',
    'public.problem_report_events.problem_report_events_worker_fk',
    'public.problem_reports.problem_reports_project_id_fkey',
    'public.problem_reports.problem_reports_task_project_fk',
    'public.problem_reports.problem_reports_worker_project_fk'
  ];
  v_target_tables text[] := ARRAY[
    'public.initiative_events',
    'public.initiative_learnings',
    'public.initiative_support_requests',
    'public.initiative_work_items',
    'public.initiatives',
    'public.problem_report_events',
    'public.problem_reports',
    'private.system_actor_audit'
  ];
  v_table_count integer;
  v_trigger_count integer;
BEGIN
  -- Every planned index must exist with the exact key order and be a usable,
  -- ordinary, non-partial B-tree index. Verify there is no duplicate exact key.
  FOR v_expected IN
    SELECT * FROM (VALUES
      ('public','initiative_events','idx_initiative_events_worker_fk',
        ARRAY['actor_worker_id','project_id']::text[]),
      ('public','initiative_learnings','idx_initiative_learnings_initiative_fk',
        ARRAY['initiative_id','project_id']::text[]),
      ('public','initiative_support_requests','idx_initiative_support_requests_initiative_fk',
        ARRAY['initiative_id','project_id']::text[]),
      ('public','initiative_support_requests','idx_initiative_support_requests_worker_fk',
        ARRAY['requested_by_worker_id','project_id']::text[]),
      ('public','initiatives','idx_initiatives_proposer_fk',
        ARRAY['proposed_by_worker_id','project_id']::text[]),
      ('public','problem_report_events','idx_problem_report_events_worker_fk',
        ARRAY['actor_worker_id','project_id']::text[]),
      ('public','problem_reports','idx_problem_reports_task_fk',
        ARRAY['linked_task_id','project_id']::text[]),
      ('public','problem_reports','idx_problem_reports_worker_fk',
        ARRAY['reported_by_worker_id','project_id']::text[])
    ) AS expected(schema_name,table_name,index_name,key_columns)
  LOOP
    SELECT count(DISTINCT i.indexrelid)::integer,
           (array_agg(a.attname::text ORDER BY k.ord))[1:cardinality(v_expected.key_columns)]
      INTO v_named_index_count,v_actual_columns
    FROM pg_index i
    JOIN pg_class t ON t.oid=i.indrelid
    JOIN pg_namespace n ON n.oid=t.relnamespace
    JOIN pg_class ix ON ix.oid=i.indexrelid
    JOIN pg_am am ON am.oid=ix.relam
    CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum,ord)
    JOIN pg_attribute a ON a.attrelid=t.oid AND a.attnum=k.attnum
    WHERE n.nspname=v_expected.schema_name
      AND t.relname=v_expected.table_name
      AND ix.relname=v_expected.index_name
      AND am.amname='btree'
      AND i.indisvalid AND i.indisready AND i.indislive
      AND i.indpred IS NULL
      AND i.indexprs IS NULL
      AND k.ord<=i.indnkeyatts;

    IF v_named_index_count<>1 OR v_actual_columns IS DISTINCT FROM v_expected.key_columns THEN
      RAISE EXCEPTION
        'FAIL: index %.% must exist exactly once with keys %, found count % and keys %',
        v_expected.schema_name,v_expected.index_name,
        v_expected.key_columns,v_named_index_count,v_actual_columns;
    END IF;

    SELECT count(*)::integer INTO v_exact_index_count
    FROM pg_index i
    JOIN pg_class t ON t.oid=i.indrelid
    JOIN pg_namespace n ON n.oid=t.relnamespace
    JOIN pg_class ix ON ix.oid=i.indexrelid
    JOIN pg_am am ON am.oid=ix.relam
    WHERE n.nspname=v_expected.schema_name
      AND t.relname=v_expected.table_name
      AND am.amname='btree'
      AND i.indisvalid AND i.indisready AND i.indislive
      AND i.indpred IS NULL
      AND i.indexprs IS NULL
      AND (
        SELECT array_agg(a.attname::text ORDER BY k.ord)
        FROM unnest(i.indkey) WITH ORDINALITY AS k(attnum,ord)
        JOIN pg_attribute a ON a.attrelid=t.oid AND a.attnum=k.attnum
        WHERE k.ord<=i.indnkeyatts
      )=v_expected.key_columns;

    IF v_exact_index_count<>1 THEN
      RAISE EXCEPTION
        'FAIL: expected exactly one valid full index for %.% keys %, found %',
        v_expected.schema_name,v_expected.table_name,
        v_expected.key_columns,v_exact_index_count;
    END IF;
  END LOOP;

  SELECT count(*)::integer INTO v_named_index_count
  FROM pg_class ix
  JOIN pg_namespace n ON n.oid=ix.relnamespace
  WHERE n.nspname='public'
    AND ix.relname = ANY(ARRAY[
      'idx_initiative_events_worker_fk',
      'idx_initiative_learnings_initiative_fk',
      'idx_initiative_support_requests_initiative_fk',
      'idx_initiative_support_requests_worker_fk',
      'idx_initiatives_proposer_fk',
      'idx_problem_report_events_worker_fk',
      'idx_problem_reports_task_fk',
      'idx_problem_reports_worker_fk'
    ]);
  IF v_named_index_count<>8 THEN
    RAISE EXCEPTION 'FAIL: expected exactly eight new indexes, found %',v_named_index_count;
  END IF;

  -- Preserve the FK definitions: the migration must not drop or recreate them.
  SELECT array_agg(n.nspname||'.'||t.relname||'.'||c.conname ORDER BY n.nspname,t.relname,c.conname)
    INTO v_fk_names
  FROM pg_constraint c
  JOIN pg_class t ON t.oid=c.conrelid
  JOIN pg_namespace n ON n.oid=t.relnamespace
  WHERE c.contype='f'
    AND (n.nspname||'.'||t.relname)=ANY(v_target_tables);

  IF v_fk_names IS DISTINCT FROM v_expected_fk_names THEN
    RAISE EXCEPTION 'FAIL: target foreign-key constraint inventory changed: %',v_fk_names;
  END IF;

  -- The four already useful leading-key paths must remain intact. The task_id
  -- index is partial on IS NOT NULL; that predicate covers every non-NULL value
  -- participating in that nullable foreign key.
  IF NOT EXISTS (
    SELECT 1 FROM pg_index i
    JOIN pg_class t ON t.oid=i.indrelid
    JOIN pg_class ix ON ix.oid=i.indexrelid
    JOIN pg_namespace n ON n.oid=t.relnamespace
    WHERE n.nspname='public' AND t.relname='initiative_events'
      AND ix.relname='initiative_events_history_idx'
      AND i.indisvalid AND i.indisready AND i.indislive AND i.indpred IS NULL
      AND (SELECT a.attname FROM unnest(i.indkey) WITH ORDINALITY k(attnum,ord)
        JOIN pg_attribute a ON a.attrelid=t.oid AND a.attnum=k.attnum
        WHERE k.ord=1)='initiative_id'
  ) THEN
    RAISE EXCEPTION 'FAIL: initiative_events initiative leading index was changed';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_index i
    JOIN pg_class t ON t.oid=i.indrelid
    JOIN pg_class ix ON ix.oid=i.indexrelid
    JOIN pg_namespace n ON n.oid=t.relnamespace
    WHERE n.nspname='public' AND t.relname='initiative_work_items'
      AND ix.relname='initiative_work_items_key_uq'
      AND i.indisvalid AND i.indisready AND i.indislive AND i.indpred IS NULL
      AND (SELECT a.attname FROM unnest(i.indkey) WITH ORDINALITY k(attnum,ord)
        JOIN pg_attribute a ON a.attrelid=t.oid AND a.attnum=k.attnum
        WHERE k.ord=1)='initiative_id'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_index i
    JOIN pg_class t ON t.oid=i.indrelid
    JOIN pg_class ix ON ix.oid=i.indexrelid
    JOIN pg_namespace n ON n.oid=t.relnamespace
    WHERE n.nspname='public' AND t.relname='initiative_work_items'
      AND ix.relname='initiative_work_items_task_uq'
      AND i.indisvalid AND i.indisready AND i.indislive
      AND i.indpred IS NOT NULL
      AND pg_get_expr(i.indpred,i.indrelid) LIKE '%task_id IS NOT NULL%'
      AND (SELECT a.attname FROM unnest(i.indkey) WITH ORDINALITY k(attnum,ord)
        JOIN pg_attribute a ON a.attrelid=t.oid AND a.attnum=k.attnum
        WHERE k.ord=1)='task_id'
  ) THEN
    RAISE EXCEPTION 'FAIL: initiative_work_items existing leading indexes were changed';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_index i
    JOIN pg_class t ON t.oid=i.indrelid
    JOIN pg_class ix ON ix.oid=i.indexrelid
    JOIN pg_namespace n ON n.oid=t.relnamespace
    WHERE n.nspname='public' AND t.relname='problem_report_events'
      AND ix.relname='problem_report_events_history_idx'
      AND i.indisvalid AND i.indisready AND i.indislive AND i.indpred IS NULL
      AND (SELECT a.attname FROM unnest(i.indkey) WITH ORDINALITY k(attnum,ord)
        JOIN pg_attribute a ON a.attrelid=t.oid AND a.attnum=k.attnum
        WHERE k.ord=1)='report_id'
  ) THEN
    RAISE EXCEPTION 'FAIL: problem_report_events report leading index was changed';
  END IF;

  -- The two private system_actor_audit FK findings are deliberately deferred;
  -- retain the table's existing RLS and client-role privilege boundary.
  SELECT count(*)::integer INTO v_table_count
  FROM pg_class t
  JOIN pg_namespace n ON n.oid=t.relnamespace
  WHERE (n.nspname||'.'||t.relname)=ANY(v_target_tables)
    AND t.relrowsecurity
    AND NOT t.relforcerowsecurity;
  IF v_table_count<>8 THEN
    RAISE EXCEPTION 'FAIL: expected RLS enabled / FORCE unchanged on eight target tables, found %',v_table_count;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_class t
    JOIN pg_namespace n ON n.oid=t.relnamespace
    WHERE (n.nspname||'.'||t.relname)=ANY(v_target_tables)
      AND (
        has_table_privilege('anon',t.oid,'SELECT')
        OR has_table_privilege('anon',t.oid,'INSERT')
        OR has_table_privilege('anon',t.oid,'UPDATE')
        OR has_table_privilege('anon',t.oid,'DELETE')
        OR has_table_privilege('authenticated',t.oid,'SELECT')
        OR has_table_privilege('authenticated',t.oid,'INSERT')
        OR has_table_privilege('authenticated',t.oid,'UPDATE')
        OR has_table_privilege('authenticated',t.oid,'DELETE')
      )
  ) THEN
    RAISE EXCEPTION 'FAIL: anon/authenticated table grants changed on target tables';
  END IF;

  -- Preserve the separate, existing task destructive-audit boundary.
  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='private' AND c.relname='task_destructive_audit'
      AND c.relrowsecurity AND c.relforcerowsecurity
  ) THEN
    RAISE EXCEPTION 'FAIL: private task destructive audit RLS/FORCE boundary changed';
  END IF;

  SELECT count(*)::integer INTO v_trigger_count
  FROM pg_trigger tr
  JOIN pg_class c ON c.oid=tr.tgrelid
  JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='private' AND c.relname='task_destructive_audit'
    AND NOT tr.tgisinternal
    AND tr.tgname IN (
      'task_destructive_audit_append_only_row',
      'task_destructive_audit_append_only_truncate'
    )
    AND tr.tgenabled='A';
  IF v_trigger_count<>2 THEN
    RAISE EXCEPTION 'FAIL: existing append-only destructive-audit triggers changed';
  END IF;

  IF has_table_privilege('anon','private.task_destructive_audit','SELECT')
     OR has_table_privilege('anon','private.task_destructive_audit','INSERT')
     OR has_table_privilege('authenticated','private.task_destructive_audit','SELECT')
     OR has_table_privilege('authenticated','private.task_destructive_audit','INSERT') THEN
    RAISE EXCEPTION 'FAIL: private task destructive audit client privileges changed';
  END IF;
END
$foreign_key_index_coverage$;

ROLLBACK;
