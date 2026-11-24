# Task Lifecycle Test Coverage

## Credential-free static checks (GitHub Actions)

The workflow `.github/workflows/shell-static-checks.yml` runs on every push and pull request. It:

- Runs `bash -n` against lifecycle, failure/retry, and two-connection concurrency scripts.
- Runs ShellCheck at warning severity against those scripts.
- Requires no Supabase credentials, database URL, GitHub secrets, or database access.

These checks validate shell syntax and common shell defects only. They do **not** execute the scripts, validate SQL against a live database, prove transactional behavior, or simulate concurrent PostgreSQL sessions.

## Running the transactional integration harness

The harness is `scripts/test-task-lifecycle.sh`. It requires `psql` and an owner-authorized PostgreSQL connection to the intended Supabase project. Set:

- `SUPABASE_DB_URL`
- `SUPABASE_OWNER_ID`
- `SUPABASE_PROJECT_ID` (the UUID in `public.projects.id`, not the Supabase project ref)
- `SHARED_WORKER_ID`
- `TASK_LIFECYCLE_TEST_ALLOW_MUTATIONS=YES`

Run:

```sh
bash scripts/test-task-lifecycle.sh
```

The script creates temporary fixture tasks, claims them, and updates one fixture lease to a past timestamp to exercise expiry. It wraps all database work in one transaction and ends with `ROLLBACK`; no fixture tasks or idempotency records should remain. Run only against a project where the supplied owner and Worker IDs have been checked. The explicit opt-in prevents accidental execution from an environment with merely configured credentials.

## Two-session atomic claim race

The harness `scripts/test-claim-concurrency.sh` exercises `claim_task` from two independent PostgreSQL client processes using **different active Worker IDs**. Set:

- `SUPABASE_DB_URL` (must point to an isolated disposable PostgreSQL fixture, never production)
- `SUPABASE_OWNER_ID`
- `SUPABASE_PROJECT_ID`
- `SHARED_WORKER_ID`
- `SECOND_WORKER_ID` (must differ from `SHARED_WORKER_ID` and identify another active Worker in the same fixture project)

The isolated PostgreSQL 17 workflow creates both Worker fixtures and supplies both IDs. The script fails closed if either Worker is missing/inactive, the IDs are identical, or pending/expired tasks could be claimed as collateral. It starts both claim sessions behind a barrier, asserts exactly one receives the disposable task, completes using the winning Worker ID, and reads back the task/execution to verify the persisted execution belongs to that Worker.

Run only against the isolated CI fixture. The script intentionally does not register a production Worker or use a production database. The CI workflow is the executable validation path for this test; static shell checks alone do not prove the race behavior.

## State-transition and assertion map

| Behavior | RPC / database operation | Harness assertion |
| --- | --- | --- |
| Create root implementation task | `create_task` | Root record is returned |
| Recursive decomposition | `create_task(parent_task_id)` | Child and grandchild point to their immediate parent |
| Execution heartbeat | `heartbeat_execution` | `heartbeat_at` advances and `lease_until` is renewed beyond the safety margin |
| Failure → repair child | `create_task(parent_task_id)` with a failure-derived idempotency key | Replay returns the same child ID; exactly one child is linked to the failed execution and can be claimed/completed |
| Pending → running | `claim_task` | Priority ordering claims root before child |
| Claim idempotency replay | `claim_task` with same key and arguments | Same execution ID is returned |
| Running → accepted | `complete_execution` | Child and reclaimed root are accepted |
| Running → expired → running | Expire fixture lease, then `claim_task` | Attempt increments and a new execution ID is assigned |
| Execution fencing | `complete_execution` with old execution ID | Stale completion is rejected with SQLSTATE 55000 |
| Progress/readback | `get_task`, `list_tasks` | Final task state, both root attempts, and descendant are visible |
| Concurrent claims | Two sessions call `claim_task` with distinct Worker IDs | Exactly one gets the task; completion and persisted execution use the winning Worker |

The lifecycle harness does not run two simultaneous PostgreSQL clients; use `scripts/test-claim-concurrency.sh` for that separate race test.

## Failure-state coverage and boundaries

The deployed public RPC inventory includes `fail_execution` and `requeue_failed_task` for fenced failure reporting and owner-authorized bounded retry. The separate `scripts/test-failure-recovery.sh` and `scripts/test-fail-reclaim-race.sh` harnesses exercise those behaviors in isolated PostgreSQL CI. Cancellation remains a distinct terminal outcome and must not be conflated with execution failure.

## Verification recorded for this revision

The repository's PostgreSQL 17 GitHub Actions workflow loads the consolidated schema snapshot and the deployed failure/retry migration into an isolated service database, creates two distinct Worker fixtures, then runs the failure/retry, fail-versus-reclaim, lifecycle, and two-session claim-race harnesses. The exact workflow run and head SHA must be checked for each PR; source inspection or static CI alone is not acceptance evidence.

The claim-race test asserts exactly one successful claim across two independent PostgreSQL sessions using different Worker IDs, then verifies that completion and the persisted execution record use the winning Worker. A green run on the exact PR head is required before merge.

Not verified by these CI jobs:
- A real two-client race against production Supabase (intentionally not run).
- A genuinely independent concurrent ChatGPT conversation completing a handoff.
- Production schema, RLS, Worker registration, or deployment changes (none are part of this test).
## Worker-key routing and safe execution release

The worker-routing migration adds database-enforced route selection to `claim_task`:

1. `tasks.requirements.required_worker_key` (string or array) overrides project routing.
2. `projects.config.worker_routing.task_type_worker_keys[task_type]` selects task-type-specific keys.
3. `projects.config.worker_routing.default_worker_key` selects the project default.
4. A project with exactly one active Worker may use that sole Worker as a compatibility fallback. A multi-Worker project with no explicit route fails closed; no arbitrary Worker may claim its tasks.

The same route predicate applies to pending claims, expired-lease reclaim, and retry-limit expiration. Review tasks additionally remain pinned to their exact `assigned_worker_id`. The migration seeds the existing `shared-executor` / `independent-reviewer` pair only when those keys are present and preserves pre-existing explicit routing values. Route values may be a single Worker key or an array of eligible keys.

Use `release_execution(task_id, execution_id, worker_id, reason, idempotency_key)` for an accidental claim or graceful handoff. It verifies the exact current execution fence and requires `worker_id` to match both `tasks.assigned_worker_id` and `executions.worker_id`. Pass the Worker ID recorded on that execution, not the task creator or a different default Worker ID. A mismatch returns `TASK_NOT_OWNED`; a superseded execution returns `EXECUTION_SUPERSEDED`. The operation is idempotent, preserves execution history, returns the task to `pending`, and records the released execution as `superseded` (lease still valid) or `expired` (lease already elapsed). Review tasks retain their reviewer assignment. It does not cancel or delete a task.

Example:

```sql
select public.release_execution(
  'TASK_UUID',
  'CURRENT_EXECUTION_UUID',
  'EXECUTIONS_WORKER_UUID',
  'Accidental route claim; no implementation performed',
  'unique-release-operation-key'
);
```

Do not substitute `fail_execution`, `requeue_failed_task`, direct table updates, or `cancel_task` for an execution release. If the release RPC is not deployed, preserve the audit trail and let the lease expire; do not mutate production task rows directly.

The PostgreSQL integration workflow runs `tests/worker-routing-release-tests.sql` against its isolated PostgreSQL 17 service. It covers reviewer/implementation separation, explicit and default routes, route-safe expired reclaim, review creation/claim routing, ambiguous-route fail-closed behavior, single-worker compatibility, wrong-owner denial, release idempotency, expired release, and stale-execution fencing.


## Same-Worker multi-session concurrency

The PostgreSQL workflow also runs `scripts/test-same-worker-concurrency.sh`. It starts two independent PostgreSQL sessions using the same project-scoped Worker UUID, matching the RAE model where multiple GPT conversations share one logical Worker route. The test verifies:

- With two eligible tasks, the two sessions claim different tasks concurrently.
- With one eligible task, exactly one session receives the lease and the other receives no task.
- Both winning executions can be completed using the shared Worker route.

This is separate from the distinct-Worker claim race. Passing both tests demonstrates task-level concurrency without introducing per-session Worker identities; it does not prove that ChatGPT conversations can be launched automatically.


## Project-scoped task integrity monitoring and destructive-operation audit

The migration `supabase/migrations/20261125140000_task_integrity_monitor_and_audit.sql` adds:

- `private.task_integrity_findings(project_id)`: a read-only, project-scoped scan of task parent/fix/Worker references, execution/task and Worker references, current/latest delivery/review pointers, task-event relationships, and artifact task/execution relationships. It returns only missing or cross-project reference metadata. An empty result means no findings for the selected project's scanned relationships; it is not a proof against unrelated application-level invariants such as dependency cycles.
- `private.task_destructive_audit`: a private metadata-only, append-only record of committed row `DELETE` operations and statement `TRUNCATE` operations on `public.tasks` and `public.executions`. It has no foreign keys back to mutable project/task/execution rows, so records survive parent/project cascades. Transaction rollback also rolls back corresponding audit rows.

### Run a read-only integrity scan

Use the trusted PostgreSQL MCP session. The RAE context binds the session to exactly one active project and writes its normal system-actor context audit record; the script rolls that context record back after the read-only scan:

```sh
psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 \
  -v project_id="$SUPABASE_PROJECT_ID" \
  -f scripts/check-task-integrity.sql
```

Or run the equivalent transaction manually:

```sql
BEGIN;
SELECT private.begin_rae_system_context('<PROJECT_UUID>'::uuid);
SELECT *
FROM private.task_integrity_findings('<PROJECT_UUID>'::uuid)
ORDER BY source_relation, row_id, reference_name;
ROLLBACK;
```

The function requires an authorized project Owner/System Owner context and cannot be executed by `anon` or `authenticated`. Findings contain the relation, row ID, reference name, referenced UUID, and source/target project IDs. Do not reconstruct or delete rows automatically from scan results; first verify authoritative GitHub/Supabase evidence and create a separately authorized repair task.

### Destructive-operation audit semantics and limits

- Row `DELETE` triggers record the minimal task/execution identifiers and status/attempt metadata. Cascaded execution deletes are logged separately.
- Statement `TRUNCATE` triggers record the affected relation and transaction/session actor context; a TRUNCATE does not expose individual deleted row IDs to a statement-level trigger.
- Audit records contain no task descriptions, task/execution result JSON, error text, JWT, credential, or raw SQL. The table is RLS-enabled/forced, has no client-role grants, and rejects normal UPDATE/DELETE/TRUNCATE mutation.
- Audit insertion occurs in the same transaction as the destructive operation. A rolled-back DELETE/TRUNCATE leaves no committed audit entry.
- This trigger-based audit is not tamper-proof against a PostgreSQL superuser: a superuser can alter/disable triggers or change the database schema. Platform-level statement auditing (for example, an appropriately configured `pgaudit`/PostgreSQL log sink) is required to cover trigger bypasses and failed destructive statements. The migration does not install extensions, change platform logging, expand DELETE grants, or alter production configuration.

The PostgreSQL 17 integration workflow applies the migration only to its disposable service database, then runs `tests/task-integrity-audit-tests.sql` to validate clean scans, synthetic missing/cross-project edge detection, cascaded DELETE auditing, TRUNCATE auditing, audit privacy/append-only controls, and transaction rollback. This CI test is not a production deployment.
