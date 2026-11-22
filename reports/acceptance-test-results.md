# Acceptance Test Results — MVP v1.1

**Target:** Supabase project `recursive-ai-engineering` (`rgztxilqcfuclkekyojl`), PostgreSQL 17, ap-northeast-1  
**Run date:** 2026-11-23  
**GitHub repository:** `Love-DC/recursive-ai-engineering`

## Executive status

The database foundation and all 19 RPC definitions have been deployed. Schema and permission metadata checks passed. A rollback-safe end-to-end RPC workflow test now passes under a simulated authenticated Owner JWT context. The full MVP acceptance suite is still **not passed**: the browser console build and real login flow are not verified, and concurrency across distinct Auth-user identities remains untested. A two-connection database race, lease reclaim and stale-Execution fencing test did pass under the same Owner identity. The live database currently has zero projects, zero Workers and zero Tasks; transactional test data was rolled back, and the temporary concurrency project was deleted after the race/reclaim checks.

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
| Auth user provisioned | Count = 1 | PASS |
| Owner console source committed | `console/` Vite/React app and Supabase RPC integration | IMPLEMENTED, BUILD NOT VERIFIED |
| Live project/Worker/Task records | Counts = 0 / 0 / 0 | NOT STARTED |
| Transactional authenticated RPC workflow | Project/Worker/Task reads; cross-owner read denial; project idempotency replay/conflict; claim/heartbeat; artifact; submit; self-review and duplicate-review guards; Reviewer reject; Fix/resubmit; Reviewer accept; no-review completion; running-task cancellation. Executed as `authenticated` with an existing Auth user's JWT subject; all writes rolled back. | PASS (RPC-level, not browser UI) |
| Concurrent claim race | Two separate SQL connections called `claim_task` simultaneously with different Worker IDs and the same authenticated Owner JWT. Exactly one claimed the Task; the other received `task: null`. | PASS (separate DB sessions; same Auth identity) |
| Lease expiry/reclaim | Forced the test Task lease into the past; second Worker reclaimed it as attempt 2. | PASS |
| Stale Execution fencing | Heartbeat from attempt 1 after attempt 2 reclaimed the Task was rejected with `EXECUTION_SUPERSEDED`. | PASS |
| Independent Auth-user concurrency | Only one Auth user exists; distinct authenticated user identities were not available for this test. | NOT RUN |
| Cross-identity Reviewer workflow | Reviewer rejection/fix/acceptance passed in the transactional RPC suite; separate Auth-user identity isolation was not tested. | PARTIAL |

## Owner console progress

A Vite/React Owner console is committed under `console/`. It supports password sign-in, project registration, Worker registration, implementation Task creation, task queue listing and `get_task` inspection. It uses only the Supabase publishable key in the browser and existing authenticated RPCs. Live catalog inspection confirmed the console's `get_project`, `list_workers`, `list_tasks`, `create_task`, `register_worker` and `get_task` argument names. A TypeScript task-form reset mismatch was fixed in commit `3ad2ec9`. The GitHub Actions build workflow exists, but a successful build has not yet been observed. The console does not launch GPT Workers. Vercel remains optional and is not connected.

## Deployed migrations

1. `mvp_v1_1_core_schema`
2. `mvp_v1_1_fk_covering_indexes`
3. `mvp_v1_1_rpc_registry_and_queries`
4. `mvp_v1_1_execution_review_fix_rpcs`
5. `mvp_v1_1_rpc_correctness_fixes`
6. `mvp_v1_1_remaining_fk_index`
7. `mvp_v1_1_idempotency_and_review_lock_fixes`
8. `mvp_v1_1_event_cross_task_execution_reference`
9. `mvp_v1_1_review_context_query`

The initial covering-index migration attempt failed because one index already existed; it was corrected with an idempotent migration and the corrected migration succeeded. No schema state was lost.

## Security Advisor notes

- `operation_requests` has RLS enabled and intentionally has no client policy or client table grant. This is default-deny by design.
- Supabase Advisor reports all 19 authenticated SECURITY DEFINER RPCs as warnings because they are callable via the API. Catalog checks confirm all 19 have fixed `search_path`, `authenticated` grants, and no `anon`/`PUBLIC` EXECUTE grants. Their owner guards were exercised by the transactional workflow test, but they still require ongoing manual security review.
- Supabase Advisor reports leaked-password protection disabled. This setting must be enabled in Supabase Auth password/security settings before real-user rollout.
- Performance Advisor initially found missing foreign-key covering indexes. Covering indexes were added, including the final created_by_worker_id/project_id index. Unused-index notices are expected before workload traffic exists.

A consolidated, current database snapshot is committed at `supabase/migrations/database-schema.sql`. It is generated from the deployed catalog and is intended for an EMPTY PostgreSQL 17 database. The incremental Supabase migration history remains authoritative for the live project.

## Known implementation limitations requiring follow-up before Worker onboarding

1. Run the Owner console build in a verified CI environment and complete the real browser login/project creation flow.
2. Run concurrency and Reviewer tests with genuinely independent Auth-user identities. The claim race has been exercised with two separate database sessions sharing one Owner JWT; it proves the row-lock behavior but not identity isolation.
3. Exercise remaining A01–A63 cases, including cross-project access denial and additional lease/cancellation edge cases.
4. Validate Review RPC lock ordering under independent Auth sessions.
5. Verify the consolidated migration by applying it to an empty disposable PostgreSQL 17 database.
6. Before real multi-GPT deployment, replace shared-owner logical Worker identity with per-Worker authentication or an equivalent isolation boundary. The current schema intentionally does not cryptographically isolate GPT sessions.

## Credential boundary

No Service Role Key, secret key, database password, or privileged database connection string has been added to GitHub or Worker instructions. No Worker was started. No project, Worker or Task records were created during this implementation session.
