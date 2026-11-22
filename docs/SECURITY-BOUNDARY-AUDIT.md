# Supabase Security Boundary Audit

**Inspection date:** 2026-11-23  
**Scope:** Read-only inspection of the live `recursive-ai-engineering` Supabase project and the default branch of this repository. No schema, grants, Auth settings, or deployment state were changed.

## Executive summary

The current shared-owner MCP pilot boundary is consistent with the documented operating model: the owner-MCP connection is trusted, anonymous database/API access is not granted to the inspected application tables or RPCs, and owner/worker authorization is enforced inside the exposed privileged RPCs. This is **not** a production-readiness approval for independent users or public clients.

## Verified database findings

### Positive controls

- All seven application tables in `public` have row-level security enabled.
- `anon` has no SELECT/INSERT/UPDATE/DELETE privileges on the seven application tables.
- `authenticated` has SELECT only on the six owner-readable tables; no direct table writes are granted. `operation_requests` has no table privileges for `anon` or `authenticated`.
- The six read policies scope rows through `projects.owner_id = auth.uid()` (directly or through task/project joins). `operation_requests` has RLS enabled and no policy, and no client table grants.
- The 20 public RPCs are SECURITY DEFINER and have an explicit fixed `search_path=pg_catalog, public, auth, private`. Inspection of function ACLs found zero EXECUTE grants to PUBLIC and zero to `anon`; EXECUTE is granted to `authenticated`.
- Private helper functions inspected are not exposed as client RPCs; their ACLs are restricted to the database owner role. Privileged helpers set an explicit search_path.
- `claim_task` and `complete_execution` use the shared actor/owner authorization path; completion additionally checks the current execution fence and lease.
- GitHub code search on the default branch returned no matches for `SUPABASE_SERVICE_ROLE_KEY` or `service_role`. This is a narrow source scan, not proof that no secret exists in history, Actions settings, external systems, or unindexed files.

### Findings and gates

| Priority | Finding | Impact / required action |
|---|---|---|
| High before non-owner/public exposure | 20 SECURITY DEFINER RPCs are executable by `authenticated`. | Supabase security advisor reports 20 warnings. Each function must be reviewed for authorization and data minimization under real non-owner JWTs; test cross-project and cross-worker IDOR cases. Do not solve this by blindly revoking all RPCs: the pilot intentionally relies on RPC access. |
| High before end-user Auth rollout | Leaked-password protection is disabled. | Enable and verify before accepting user-managed passwords. This does not block the current trusted owner-MCP pilot. |
| Medium / defense in depth | `public.operation_requests` has RLS enabled but no policy. | This is currently fail-closed and client roles have no table privileges. Keep it private; add a narrowly scoped policy only if a documented client access path is introduced. |
| Unverified | Auth provider, MFA, rate-limit, redirect URL, email/phone confirmation, and session settings were not available through the connected project/database inspection tools. | Review in the Supabase Auth dashboard before production exposure. No claim is made that these controls are enabled. |
| Unverified | Full repository history, CI secrets, deployment secrets, and external secret stores were not inspected. | Run dedicated secret scanning and rotation procedures before production exposure. |

## Pilot decision

**No blocker identified for the documented trusted owner-MCP pilot** by this read-only inspection. Continue to use the owner's already-authorized Supabase MCP connection, the shared `shared-executor` row, and owner-scoped task RPCs. Do not issue client credentials or expose the RPC surface to untrusted callers.

## Production expansion gates

Before any independent/non-owner client is admitted:

1. Threat-model all 20 SECURITY DEFINER RPCs and their transitive helpers; prove authorization for owner, worker, project, task, and execution IDs.
2. Add automated negative tests using at least two independent Auth identities, including cross-project and cross-worker access attempts.
3. Decide the intended public API surface and revoke EXECUTE from functions that clients do not need; preserve explicit grants only.
4. Enable leaked-password protection and review MFA, provider, confirmation, rate-limit, redirect, and session settings in Auth.
5. Run Supabase security/performance advisors after any remediation; verify RLS and grants from anon and authenticated roles.
6. Scan complete Git history and CI/deployment secret stores; rotate any exposed credentials.
7. Verify migrations on a disposable database and exercise backup/restore and rollback.

## Evidence and limitations

- Live SQL inspected table RLS flags, policy expressions, client table privileges, public RPC ACLs, SECURITY DEFINER flags, and function search_path settings.
- Supabase security advisor returned: 1 `rls_enabled_no_policy` INFO finding (`operation_requests`); 20 `authenticated_security_definer_function_executable` WARN findings; 1 `auth_leaked_password_protection` WARN finding.
- The advisor remediation references are the Supabase database linter rule 0008, rule 0029, and the Auth password security guide.
- This was a read-only configuration/source audit. It did not attempt exploit tests, inspect provider-specific Auth settings, change grants, or deploy anything.

## Performance advisor baseline

**Observed:** 2026-11-22 19:19:57 UTC (Supabase Performance Advisor); PostgreSQL statistics sampled at 2026-11-22 19:20:30 UTC.

- The Performance Advisor reported **15 unused-index findings** across `public.projects`, `public.tasks`, and `public.task_events`. Representative findings include `idx_projects_owner`, `idx_tasks_worker`, `idx_tasks_lease`, `idx_tasks_parent_project`, `idx_tasks_assigned_project`, `idx_events_task`, `idx_events_project`, `idx_events_worker_project`, and `idx_events_execution_task`.
- A direct read-only query of `pg_stat_user_indexes` returned **19 indexes with `idx_scan = 0`** across the seven public application tables. This broader count also includes primary-key/unique-constraint indexes (for example, `tasks_pkey`, `executions_pkey`, and `operation_requests_project_id_operation_idempotency_key_key`); it is not equivalent to the Advisor's 15 findings and is not a drop list.
- The statistics reset timestamp was **2026-11-13 21:18:31 UTC**, giving approximately **8 days 22 hours** of accumulated statistics at sampling time. The same sample estimated only 2 project rows, 13 task rows, 61 task-event rows, and 2 worker rows. This is a small pilot dataset, not representative production traffic.

### Interpretation and safe follow-up

An unused-index warning is a prompt for workload review, not proof that an index is redundant. Low row counts, limited pilot traffic, infrequent administrative/reporting queries, planner preference for sequential scans, and the statistics-reset window can all produce zero scans. Primary-key and unique-constraint backing indexes must not be treated as ordinary cleanup candidates.

Before proposing any index removal:

1. Capture the relevant query shapes and predicates from representative workload; inspect `pg_stat_user_indexes` again after sustained traffic and record the statistics-reset timestamp.
2. Compare candidate indexes with primary/unique constraints, foreign-key access paths, RLS predicates, task-claim/lease queries, and infrequent operational queries.
3. Use representative `EXPLAIN (ANALYZE, BUFFERS)` plans in a safe test environment to establish whether the index is useful; compare read plans and write overhead.
4. If removal remains justified, prepare a separate reviewed migration, validate it against a disposable database and workload, and obtain explicit authorization before any production DDL.

**Disposition:** No indexes were dropped or altered. These observations are a dated baseline only; repeat the measurement after the pilot has accumulated representative workload. The existing security findings and production-exposure gates above remain unchanged.
