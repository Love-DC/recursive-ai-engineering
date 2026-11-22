# Task Lifecycle Test Coverage

## Credential-free static checks (GitHub Actions)

The workflow `.github/workflows/shell-static-checks.yml` runs on every push and pull request. It:

- Runs `bash -n` against both lifecycle and two-connection concurrency scripts.
- Runs ShellCheck at warning severity against both scripts.
- Requires no Supabase credentials, database URL, GitHub secrets, or database access.

These checks validate shell syntax and common shell defects only. They do **not** execute either script, validate SQL against a live database, prove transactional behavior, or simulate concurrent PostgreSQL sessions.

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

The script creates temporary fixture tasks, claims them, and updates one fixture lease to a past timestamp to exercise expiry. It wraps all database work in one transaction and ends with `ROLLBACK`; no fixture tasks or idempotency records should remain. Run only against a project where the supplied owner and worker IDs have been checked. The explicit opt-in prevents accidental execution from an environment with merely configured credentials.

## State-transition and assertion map

| Behavior | RPC / database operation | Harness assertion |
| --- | --- | --- |
| Create root implementation task | `create_task` | Root record is returned |
| Recursive decomposition | `create_task(parent_task_id)` | Child and grandchild point to their immediate parent |
| Pending → running | `claim_task` | Priority ordering claims root before child |
| Claim idempotency replay | `claim_task` with same key and arguments | Same execution ID is returned |
| Running → accepted | `complete_execution` | Child and reclaimed root are accepted |
| Running → expired → running | Expire fixture lease, then `claim_task` | Attempt increments and a new execution ID is assigned |
| Execution fencing | `complete_execution` with old execution ID | Stale completion is rejected with SQLSTATE 55000 |
| Progress/readback | `get_task`, `list_tasks` | Final task state, both root attempts, and descendant are visible |

The harness does not run two simultaneous PostgreSQL clients; use `scripts/test-claim-concurrency.sh` for that separate race test. That concurrency harness requires an empty pending queue and must be run separately.

## Failure-state coverage and boundaries

The deployed public RPC inventory currently exposes `cancel_task`, `submit_result`, and `complete_execution`, but no general-purpose `fail_execution` RPC. The lifecycle harness therefore does not fabricate a failure transition by directly editing execution/task status. Failure/retry behavior remains unverified as a supported public operation and should be addressed only after defining the intended API contract. Cancellation is a distinct terminal outcome and must not be conflated with execution failure.

## Verification recorded for this revision

A transactional owner-MCP smoke test exercised recursive parent linkage, priority-ordered claims, claim idempotency replay, child completion, lease expiry and reclaim, stale-execution fencing, final completion, `get_task`, and `list_tasks`. The test intentionally rolled back all fixture writes; a follow-up query confirmed zero leftover lifecycle smoke tasks.

Not verified in this environment:
- Executing the committed shell harness from a separate host with `psql` and the required environment variables.
- A real two-client claim race (covered by the separate harness but not executed here).
- A general failure/retry API, which is not present in the inspected public RPC inventory.
- A genuinely independent ChatGPT conversation completing the handoff acceptance in `docs/FRESH-SESSION-HANDOFF-ACCEPTANCE.md`.
