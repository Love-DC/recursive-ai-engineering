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
