# Acceptance Test Results — MVP v1.1

**Target:** Supabase project `recursive-ai-engineering` (`rgztxilqcfuclkekyojl`), PostgreSQL 17, ap-northeast-1  
**Run date:** 2026-11-23  
**GitHub repository:** `Love-DC/recursive-ai-engineering`

## Executive status

The database foundation and all 19 RPC definitions have been deployed. Schema and permission metadata checks passed. The full workflow acceptance suite is **not passed**: the Auth user table currently contains zero users, so authenticated owner-context workflow tests cannot be run without provisioning an owner account. Real concurrent claim/lease races also remain unexecuted and must not be represented as passed.

## Stage results

| Check | Actual result | Status |
|---|---|---|
| Seven core tables exist | Count = 7 | PASS |
| RLS enabled on all core tables | Count = 7 | PASS |
| projects.owner_id NOT NULL | Verified in information_schema | PASS |
| One running Execution partial unique index | Present | PASS |
| Unique Original/Delivery/Execution Review index | Present | PASS |
| current_execution_id + task_id composite FK | Present | PASS |
| Review and latest delivery Execution composite FKs | Present | PASS |
| All 19 RPC definitions installed | Count = 19 | PASS |
| All 19 RPCs SECURITY DEFINER | Count = 19 | PASS |
| All 19 RPCs have fixed search_path | Verified | PASS |
| anon RPC execute privilege | No grants | PASS |
| authenticated RPC execute privilege | All 19 granted | PASS |
| authenticated direct table writes | No INSERT/UPDATE/DELETE grants | PASS |
| operation_requests client table access | No SELECT/INSERT grants | PASS |
| Unauthenticated RPC guard | Transactional role test passed | PASS |
| anon RPC denial | Transactional role test passed | PASS |
| Schema acceptance assertions | Executed, no exceptions | PASS |
| Full authenticated business workflow | No Auth users available | BLOCKED |
| Actual two-session claim race | Not run | NOT RUN |
| Actual lease/reclaim race | Not run | NOT RUN |
| Cross-session Reviewer workflow | Not run | NOT RUN |

## Deployed migrations

1. `mvp_v1_1_core_schema`
2. `mvp_v1_1_fk_covering_indexes`
3. `mvp_v1_1_rpc_registry_and_queries`
4. `mvp_v1_1_execution_review_fix_rpcs`
5. `mvp_v1_1_rpc_correctness_fixes`
6. `mvp_v1_1_remaining_fk_index`

The initial covering-index migration attempt failed because one index already existed; it was corrected with an idempotent migration and the corrected migration succeeded. No schema state was lost.

## Security Advisor notes

- `operation_requests` has RLS enabled and intentionally has no client policy or client table grant. This is default-deny by design.
- Supabase Advisor reports the 19 authenticated SECURITY DEFINER RPCs as warnings because they are callable via the API. This is intentional for the selected RPC-only write model; every public RPC has an auth.uid()/project-owner guard, fixed search_path and exact EXECUTE grants. This warning requires continued manual security review, not blanket suppression.
- Performance Advisor initially found missing foreign-key covering indexes. Covering indexes were added, including the final created_by_worker_id/project_id index. Unused-index notices are expected before workload traffic exists.

## Known implementation limitations requiring follow-up before Worker onboarding

1. Provision an owner Auth user in the Supabase dashboard, then test real JWT-backed calls for all RPCs.
2. Fix and test idempotent replay on `register_project` with an authenticated owner; its deterministic project UUID is derived from owner + idempotency key.
3. Exercise all A01–A63 acceptance cases, especially duplicate review creation, rejected/accepted latest_review_task_id updates, no-review completion, cancel-running behavior, and expired-lease fencing.
4. Run two genuinely independent authenticated sessions for claim_task and lease/reclaim concurrency. Sequential SQL scripts are not substitutes.
5. Review the Review RPC lock acquisition sequence under concurrent activity before production Worker use.
6. Add the complete consolidated migration source to the repository and verify it can recreate an empty disposable Supabase database before calling the repository handoff complete.

## Credential boundary

No Service Role Key, secret key, database password, or privileged database connection string has been added to GitHub or Worker instructions. No Worker was started.
