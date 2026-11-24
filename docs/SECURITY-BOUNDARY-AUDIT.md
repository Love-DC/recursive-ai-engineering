# Supabase Security Boundary Audit

**Initial inspection date:** 2026-11-23 (historical baseline); **Live database/RPC/advisor refresh:** 2026-11-24 19:09 UTC (2026-11-25 JST)  
**Scope:** Read-only inspection of the live `recursive-ai-engineering` Supabase project and the default branch of this repository. No schema, grants, Auth settings, or deployment state were changed.

## Executive summary

The shared-owner MCP pilot remains restricted to the already-authorized trusted `postgres` connection. Its transaction-scoped Owner context is deployed, and selected task/initiative RPC reads work in that context. The Problem Inbox listing RPC is a known exception: it still requires `auth.uid()` and rejects the non-JWT Owner-MCP context with `UNAUTHENTICATED`; `get_problem_report` and `update_problem_report` also contain JWT-only row filters. Repository migration `20261125120000_owner_mcp_problem_inbox_context.sql` adds verified project-bound Owner-MCP authorization and isolated regression coverage, but it is not deployed. Until deployed and live-verified, these RPCs remain unavailable through the Owner-MCP connection. This is **not** a production-readiness approval for independent users or public clients.

## Verified database findings

### Verified controls and live RPC/advisor refresh (2026-11-24 19:09 UTC)

Read-only queries against the live Supabase project (`rgztxilqcfuclkekyojl`) verified the following:

- All **14 public tables** have row-level security enabled.
- The `anon` role has no SELECT/INSERT/UPDATE/DELETE privileges on any of the 14 public tables.
- The `authenticated` role has SELECT only on the six core owner-readable tables (`projects`, `workers`, `tasks`, `executions`, `artifacts`, `task_events`); it has no direct table write privileges. The other eight tables (the five Initiative tables, two Problem Inbox tables, and `operation_requests`) have no `anon` or `authenticated` table privileges.
- All **39 public functions** are SECURITY DEFINER, all use the fixed `search_path=pg_catalog, public, auth, private`, effective EXECUTE for `anon` is **0**, and effective EXECUTE for `authenticated` is **39**. This connected owner-MCP pilot intentionally calls owner/Worker-authorized RPCs; the grants do not approve independent/non-owner client access.
- The six authenticated read policies scope their rows through `projects.owner_id = auth.uid()` directly or through task/project joins. The eight RLS-enabled/no-policy tables remain fail-closed and have no client table grants.
- Inspected privileged helpers and lifecycle functions enforce owner/Worker/project identity, current execution and lease fencing, task-type Worker routing, dependency eligibility, bounded retry, pending-only task reassignment, routed independent review, and repository/branch exclusion.
- The eight foundational claim-safety migrations, PR #59 session guard (`20261124181019`), PR #60 submitted-task reconciliation (`20261124182111`), and PR #64 owner-scoped activation control (`20261124183449`) remain deployed. PR #66's repository-authoritative operational guard is also deployed as `20261124192533`; it removes `projects.config.task_activation` as a policy source and enforces the fail-closed `autonomy.paused` switch plus a bounded 1–2 execution cap. The trusted Owner-MCP context migration `20261124200149` and project registration migration `20261124202438` are present in the live registry. Current project controls are Colony Sim and Hexa Game Kernel unpaused/max 2; RAE and Lambent paused/max 2. The context binds a verified Owner/project inside one transaction and does not create an Auth JWT. The deployed Problem Inbox listing RPC remains incompatible with this context: `list_problem_reports` returns `UNAUTHENTICATED` because it requires `auth.uid()`. Keep the audit's historical 2026-11-24 RLS/grant and Security Advisor counts distinct from this 2026-11-25 operational update.
- GitHub source search on the default branch previously returned no matches for `SUPABASE_SERVICE_ROLE_KEY` or `service_role`. This remains a narrow source scan, not proof that no secret exists in history, Actions settings, external systems, or unindexed files.

The Security Advisor observed at 2026-11-24 19:09:55 UTC reported **39** `authenticated_security_definer_function_executable` WARN findings, **8** `rls_enabled_no_policy` INFO findings (the five Initiative tables, two Problem Inbox tables, and `operation_requests`), and **1** `auth_leaked_password_protection` WARN finding. The 39 authenticated EXECUTE warnings are not an authorization test against independent Auth identities. Cross-project/cross-worker negative tests and Auth-provider review remain production-expansion gates.


### Findings and gates

| Priority | Finding | Impact / required action |
|---|---|---|
| High before non-owner/public exposure | 39 current SECURITY DEFINER RPCs are executable by `authenticated`. | The 2026-11-24 19:09 UTC Supabase security advisor reports 39 warnings. Each function must be reviewed for authorization and data minimization under real non-owner JWTs; test cross-project and cross-worker IDOR cases. Do not solve this by blindly revoking all RPCs: the pilot intentionally relies on RPC access. |
| High before end-user Auth rollout | Leaked-password protection is disabled. | Enable and verify before accepting user-managed passwords. This does not block the current trusted owner-MCP pilot. |
| Medium / defense in depth | `public.operation_requests` has RLS enabled but no policy. | This is currently fail-closed and client roles have no table privileges. Keep it private; add a narrowly scoped policy only if a documented client access path is introduced. |
| Unverified | Auth provider, MFA, rate-limit, redirect URL, email/phone confirmation, and session settings were not available through the connected project/database inspection tools. | Review in the Supabase Auth dashboard before production exposure. No claim is made that these controls are enabled. |
| Unverified | Full repository history, CI secrets, deployment secrets, and external secret stores were not inspected. | Run dedicated secret scanning and rotation procedures before production exposure. |

## Pilot decision

**No blocker identified for the documented trusted owner-MCP pilot** by this read-only inspection. Continue to use the owner's already-authorized Supabase MCP connection, the shared `shared-executor` row, and owner-scoped task RPCs. Do not issue client credentials or expose the RPC surface to untrusted callers.

## Production expansion gates

Before any independent/non-owner client is admitted:

1. Threat-model all 39 current SECURITY DEFINER RPCs and their transitive helpers; prove authorization for owner, worker, project, task, and execution IDs.
2. Add automated negative tests using at least two independent Auth identities, including cross-project and cross-worker access attempts.
3. Decide the intended public API surface and revoke EXECUTE from functions that clients do not need; preserve explicit grants only.
4. Enable leaked-password protection and review MFA, provider, confirmation, rate-limit, redirect, and session settings in Auth.
5. Run Supabase security/performance advisors after any remediation; verify RLS and grants from anon and authenticated roles.
6. Scan complete Git history and CI/deployment secret stores; rotate any exposed credentials.
7. Verify migrations on a disposable database and exercise backup/restore and rollback.

## Evidence and limitations

- Live SQL inspected table RLS flags, policy expressions, client table privileges, public RPC ACLs, SECURITY DEFINER flags, and function search_path settings.
- The 2026-11-23 and 2026-11-24 morning observations are historical baselines (20 and 22 authenticated SECURITY DEFINER warnings, respectively). The latest 2026-11-24 19:09 UTC refresh reported 8 `rls_enabled_no_policy` INFO findings, 39 `authenticated_security_definer_function_executable` WARN findings, and 1 `auth_leaked_password_protection` WARN finding.
- The advisor remediation references are the Supabase database linter rule 0008, rule 0029, and the Auth password security guide.
- This was a read-only configuration/source audit. It did not attempt exploit tests, inspect provider-specific Auth settings, change grants, or deploy anything.

## Performance advisor baseline

**Observed:** 2026-11-22 19:19:57 UTC (Supabase Performance Advisor); PostgreSQL statistics sampled at 2026-11-22 19:20:30 UTC.

- The Performance Advisor reported **15 unused-index findings** across `public.projects`, `public.tasks`, and `public.task_events`. Representative findings include `idx_projects_owner`, `idx_tasks_worker`, `idx_tasks_lease`, `idx_tasks_parent_project`, `idx_tasks_assigned_project`, `idx_events_task`, `idx_events_project`, `idx_events_worker_project`, and `idx_events_execution_task`.
- A direct read-only query of `pg_stat_user_indexes` returned **19 indexes with `idx_scan = 0`** across the seven public application tables. This broader count also includes primary-key/unique-constraint indexes (for example, `tasks_pkey`, `executions_pkey`, and `operation_requests_project_id_operation_idempotency_key_key`); it is not equivalent to the Advisor's 15 findings and is not a drop list.
- The statistics reset timestamp was **2026-11-13 21:18:31 UTC**, giving approximately **8 days 22 hours** of accumulated statistics at sampling time. The same sample estimated only 2 project rows, 13 task rows, 61 task-event rows, and 2 worker rows. This is a small pilot dataset, not representative production traffic.

### Live performance advisor snapshot (2026-11-24 19:09:54 UTC)

The latest read-only Performance Advisor response at 2026-11-24 19:09:54 UTC reported **12 unindexed foreign-key findings** across `initiative_events`, `initiative_learnings`, `initiative_support_requests`, `initiative_work_items`, `initiatives`, `problem_report_events`, and `problem_reports`. It also reported **5 unused-index INFO findings**, including indexes on task events and Initiative tables. These are investigation signals only; no index was dropped or changed. Do not treat a low-traffic unused-index warning as a deletion instruction.

### Interpretation and safe follow-up

An unused-index warning is a prompt for workload review, not proof that an index is redundant. Low row counts, limited pilot traffic, infrequent administrative/reporting queries, planner preference for sequential scans, and the statistics-reset window can all produce zero scans. Primary-key and unique-constraint backing indexes must not be treated as ordinary cleanup candidates.

Before proposing any index removal:

1. Capture the relevant query shapes and predicates from representative workload; inspect `pg_stat_user_indexes` again after sustained traffic and record the statistics-reset timestamp.
2. Compare candidate indexes with primary/unique constraints, foreign-key access paths, RLS predicates, task-claim/lease queries, and infrequent operational queries.
3. Use representative `EXPLAIN (ANALYZE, BUFFERS)` plans in a safe test environment to establish whether the index is useful; compare read plans and write overhead.
4. If removal remains justified, prepare a separate reviewed migration, validate it against a disposable database and workload, and obtain explicit authorization before any production DDL.

**Disposition:** No indexes were dropped or altered. These observations are a dated baseline only; repeat the measurement after the pilot has accumulated representative workload. The existing security findings and production-exposure gates above remain unchanged.
