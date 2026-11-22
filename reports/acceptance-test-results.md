# Acceptance Test Results — MVP v1.2

**Target:** Supabase project `recursive-ai-engineering` (`rgztxilqcfuclkekyojl`), PostgreSQL 17, ap-northeast-1  
**Run date:** 2026-11-23  
**GitHub repository:** `Love-DC/recursive-ai-engineering`

## Executive status

The database foundation and 20 public RPCs (the original 19 plus `bind_worker_identity`) have been deployed. Schema and permission metadata checks passed. A rollback-safe end-to-end RPC workflow test now passes under a simulated authenticated Owner JWT context. The full MVP acceptance suite is still **not passed**: the console build passes in GitHub Actions, but real browser login and live UI workflow are not verified; concurrency across distinct Auth-user identities remains untested. A two-connection database race, lease reclaim and stale-Execution fencing test did pass under the same Owner identity. The live database currently has zero projects, zero Workers and zero Tasks; transactional test data was rolled back, and the temporary concurrency project was deleted after the race/reclaim checks.

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
| Original MVP RPC definitions installed | Count = 19 | PASS |\n| Worker identity binding RPC | `bind_worker_identity(uuid,uuid)` installed; Owner-only binding | PASS |\n| Worker identity column and uniqueness | `workers.auth_user_id` FK to `auth.users`, unique when non-null | PASS |\n| Worker RPC identity authorization | Exact JWT subject-to-Worker checks on claim, heartbeat, artifact, submit, complete, review, resubmit and task reads | PASS (catalog + negative tests) |\n| Worker task-scope restrictions | Worker task reads scoped to own Worker; cancellation scoped to assigned task; Fix orchestration Owner-only | PASS (code/catalog) |\n| Anonymous execution of Worker RPCs | `anon` EXECUTE false; `authenticated` EXECUTE true on all checked RPCs | PASS |
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
| Owner console source committed | `console/` Vite/React app and Supabase RPC integration | IMPLEMENTED |
| Live project/Worker/Task records | Counts = 0 / 0 / 0 | NOT STARTED |
| Transactional authenticated RPC workflow | Project/Worker/Task reads; cross-owner read denial; project idempotency replay/conflict; claim/heartbeat; artifact; submit; self-review, duplicate-review and assigned-Reviewer claim guards; Reviewer reject; Fix/resubmit; Reviewer accept; no-review completion; running-task cancellation. Executed as `authenticated` with an existing Auth user's JWT subject; all writes rolled back. | PASS (RPC-level, not browser UI) |
| Concurrent claim race | Two separate SQL connections called `claim_task` simultaneously with different Worker IDs and the same authenticated Owner JWT. Exactly one claimed the Task; the other received `task: null`. | PASS (separate DB sessions; same Auth identity) |
| Lease expiry/reclaim | Forced the test Task lease into the past; second Worker reclaimed it as attempt 2. | PASS |
| Stale Execution fencing | Heartbeat from attempt 1 after attempt 2 reclaimed the Task was rejected with `EXECUTION_SUPERSEDED`. | PASS |
| Worker identity negative tests | Unbound Worker and mismatched JWT subject denied for claim; mismatched subject denied for Worker read. Bound test Worker was associated with existing Owner Auth UUID, while test JWT used a different subject. All test data rolled back. | PASS (negative) |\n| Independent Auth-user concurrency | Only one Auth user exists; positive claim/review workflows with genuinely separate Auth identities are not yet available. | NOT RUN |
| Cross-identity Reviewer workflow | Reviewer rejection/fix/acceptance passed in the transactional RPC suite; separate Auth-user identity isolation was not tested. | PARTIAL |

## Owner console progress

A Vite/React Owner console is committed under `console/`. It supports password sign-in, project registration, Worker registration, implementation Task creation, task queue listing and `get_task` inspection. It uses only the Supabase publishable key in the browser and existing authenticated RPCs. Live catalog inspection confirmed the console's `get_project`, `list_workers`, `list_tasks`, `create_task`, `register_worker` and `get_task` argument names. A TypeScript task-form reset mismatch was fixed in commit `3ad2ec9`. GitHub Actions build succeeded on commit `89bf5da`; [workflow run](https://github.com/Love-DC/recursive-ai-engineering/actions/runs/45052216112). Browser login and live UI workflow remain unverified. The console does not launch GPT Workers. Vercel remains optional and is not connected.

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
- Supabase Advisor reports 20 authenticated SECURITY DEFINER RPCs as warnings because they are callable via the API. Catalog checks confirm all 19 have fixed `search_path`, `authenticated` grants, and no `anon`/`PUBLIC` EXECUTE grants. Their owner guards were exercised by the transactional workflow test, but they still require ongoing manual security review.
- Supabase Advisor reports leaked-password protection disabled. This setting must be enabled in Supabase Auth password/security settings before real-user rollout.
- Performance Advisor initially found missing foreign-key covering indexes. Covering indexes were added, including the final created_by_worker_id/project_id index. Unused-index notices are expected before workload traffic exists.

The consolidated database snapshot at `supabase/migrations/database-schema.sql` has been refreshed to append the v1.2 and v1.2.1 identity migrations after the MVP v1.1 baseline. It is intended for an EMPTY PostgreSQL 17 database; applying it to a disposable instance and comparing catalogs remains pending.

## Known implementation limitations requiring follow-up before Worker onboarding

1. Complete the real browser login, project creation and task creation flow in the Owner console.
2. Run concurrency and Reviewer tests with genuinely independent Auth-user identities. The claim race has been exercised with two separate database sessions sharing one Owner JWT; it proves the row-lock behavior but not identity isolation.
3. Exercise remaining A01–A63 cases, including cross-project access denial and additional lease/cancellation edge cases.
4. Validate Review RPC lock ordering under independent Auth sessions.
5. Verify the consolidated migration by applying it to an empty disposable PostgreSQL 17 database.
6. Before real multi-GPT deployment, replace shared-owner logical Worker identity with per-Worker authentication or an equivalent isolation boundary. The current schema intentionally does not cryptographically isolate GPT sessions.

## Credential boundary

No Service Role Key, secret key, database password, or privileged database connection string has been added to GitHub or Worker instructions. No Worker was started. No project, Worker or Task records were created during this implementation session.
