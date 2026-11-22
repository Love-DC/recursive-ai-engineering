# Failure Reporting and Retry Contract

**Status:** Proposed contract only; no production RPC, schema, grant, or deployment change was made.  
**Inspection date:** 2026-11-23

## Current deployed behavior (verified)

The live database currently exposes `claim_task`, `complete_execution`, and `cancel_task`, but no `fail_execution` or general retry/requeue RPC.

The live CHECK constraints permit these task states: `pending`, `running`, `submitted`, `accepted`, `rejected`, `failed`, `cancelled`. Execution states are `running`, `submitted`, `succeeded`, `failed`, `expired`, and `superseded`.

| Condition | Execution state | Task state | Meaning / recovery |
|---|---|---|---|
| Claimed and active | `running` | `running` | One current execution ID and a live lease are required. |
| Worker reports an error today | No general API | No general API | Not currently reportable through a dedicated worker RPC. |
| Lease expires | `expired` on next reclaim | `running`, then a new running attempt | `claim_task` detects an expired lease, marks the old execution expired, and creates a new attempt. This is lease recovery, not a worker-reported failure. |
| Explicit cancellation | `failed` if there was a running execution | `cancelled` | `cancel_task` marks the active execution failed, then the task cancelled. Cancellation is terminal and is not equivalent to execution failure. |
| Review workflow handoff | `submitted` | `submitted` | Work is delivered for review; not a failure or final acceptance. |
| Successful implementation completion | `succeeded` | `accepted` | `complete_execution` requires the current execution fence and lease. |
| Review rejection | Review/fix-specific | `rejected` | A review decision, not an implementation execution failure. |
| Failed task | `failed` | `failed` | Allowed by constraints, but current claim query does not select failed tasks. There is no deployed retry transition. |

The task CHECK constraint requires a running task to have an assigned worker, current execution, and lease; every non-running task must clear current execution and lease. Execution attempts are unique per task and attempt number. Event rows retain task/execution/worker linkage.

## Minimal API proposal (not deployed)

### 1. `fail_execution(p_task_id, p_execution_id, p_worker_id, p_error_code, p_error_message, p_idempotency_key)`

One atomic transaction should:

1. Load the task and resolve its project; authenticate with `private.assert_worker_actor`.
2. Validate the idempotency key and hash all semantic request arguments. Replays with the same key and same hash return the original response; key reuse with different arguments raises `IDEMPOTENCY_CONFLICT`.
3. Call `private.assert_current_execution` before mutation. This must reject a superseded execution, expired lease, non-running task/execution, or wrong worker.
4. Update only the fenced execution from `running` to `failed`, setting `finished_at`, a bounded/sanitized `error_message`, and optionally a structured error payload in `result`.
5. Update the task from `running` to `failed`, clear `current_execution_id` and `lease_until`, and set `completed_at/updated_at`.
6. Append `execution_failed` and `task_failed` events with bounded error metadata (never credentials, tokens, or full environment dumps).
7. Persist the idempotent response in the same transaction.

The RPC must not accept a task ID/execution ID pair unless they belong together. It must not allow a worker to fail another worker's execution. A late failure report after lease expiry/reclaim must fail fencing and must not overwrite the newer attempt.

### 2. `requeue_failed_task(p_task_id, p_worker_id, p_reason, p_idempotency_key)`

Keep retry explicit rather than automatically retrying every failure:

1. Require project-owner authorization (or a separately specified retry permission); verify the worker belongs to the project and is active.
2. Lock the task row and allow only `status='failed'`. Reject cancelled, submitted, accepted, rejected, pending, or running tasks.
3. Apply a configurable retry/attempt limit and optional backoff at the orchestration layer. The database already has monotonically increasing attempt numbers through `max(attempt)+1` in `claim_task`.
4. Set task to `pending`; clear assigned worker, current execution, lease, result, and completed timestamp as appropriate. Preserve all prior execution rows and events as immutable history.
5. Append `task_requeued` with reason and prior attempt count; persist idempotency in the same transaction.
6. A subsequent ordinary `claim_task` creates a fresh execution ID and incremented attempt. Old execution IDs remain fenced.

Do not make `claim_task` silently select all failed tasks: explicit retry is auditable and avoids retry storms.

## Required tests before deployment

- Happy path: claim → fail current execution → assert execution/task are failed and lease/current execution are cleared.
- Idempotency: same key/same payload replays; same key/different payload conflicts.
- Fencing: old execution cannot fail after lease expiry and a new claim; wrong worker, mismatched task/execution, non-running execution, and expired lease are rejected without writes.
- Atomicity: injected event/idempotency write failure rolls back both task and execution state.
- Retry: only failed task can be requeued; old execution history remains; next claim increments attempt and creates a new execution ID.
- Retry idempotency and retry limit/backoff behavior.
- Cancellation remains cancelled even though its active execution is marked failed; submitted/rejected/accepted are not requeued by this API.
- Two-connection race between fail and reclaim must result in exactly one winning transition, enforced by row locks and the current-execution fence.

## Deployment boundary

This contract is documentation for implementation and acceptance planning. The current task explicitly forbids production schema changes or deployment. Implement the RPCs and integration tests in a reviewed migration/isolated database first, run Supabase advisors, and obtain explicit authorization before applying any production migration.
