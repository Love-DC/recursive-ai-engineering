# Failure Reporting and Retry Contract

**Status:** Deployed to the production Supabase project for the trusted owner-MCP pilot.  
**Source migration:** `supabase/migrations/20261123000300_failure_reporting_retry.sql`  
**Applied migration history version:** `20261122221942_failure_reporting_retry`  
**Deployment PR:** [RAE #8](https://github.com/Love-DC/recursive-ai-engineering/pull/8), merged as `801a651434a76e8ab52776f0685ddb2e0b11bd37`.

## Deployed scope

The migration is function-only. It adds `fail_execution` and `requeue_failed_task`, and replaces `claim_task` with bounded lease-expiry recovery. It does not alter table definitions or RLS policies.

The new RPCs are `SECURITY DEFINER` functions with a fixed search path. Execute is revoked from `PUBLIC` and `anon`, and granted to `authenticated`. The functions enforce the existing owner/worker/project/task/execution checks. `requeue_failed_task` is owner-only. The current supported deployment boundary remains the trusted owner-MCP pilot; do not expose these RPCs to untrusted or non-owner clients without a separate authorization review.

## State transitions

| Condition | Execution state | Task state | Meaning / recovery |
|---|---|---|---|
| Claimed and active | `running` | `running` | One current execution ID and a live lease are required. |
| Worker reports a current execution failure | `failed` | `failed` | `fail_execution` checks the current execution fence, worker/project relationship and lease; persists a bounded error payload and failure events atomically. |
| Explicit retry | Previous attempt remains `failed` | `pending` | Owner calls `requeue_failed_task`; prior execution rows/events remain as history. |
| Retry claimed | New execution `running` | `running` | `claim_task` creates a new execution ID and increments the attempt number. |
| Lease expires before retry cap | Old execution `expired` | `running`, then a new running attempt | A later `claim_task` expires/fences the old execution and creates a new attempt after configured backoff. |
| Lease expires at retry cap | Old execution `expired` | `failed` | `claim_task` terminally fails the task when the configured attempt cap is reached. |
| Explicit cancellation | Active execution `failed` | `cancelled` | `cancel_task` remains terminal; cancellation is not retryable failure. |
| Review workflow handoff | `submitted` | `submitted` | Separate review route; not a failure or final acceptance. |
| Successful pilot implementation completion | `succeeded` | `accepted` | `complete_execution` requires the current execution fence and lease and is limited to implementation tasks with `requires_review=false`. |

## RPC behavior

### `fail_execution(p_task_id, p_execution_id, p_worker_id, p_error_code, p_error_message, p_idempotency_key)`

- Validates the task, Worker actor, task/execution relationship, current execution ID, running state and unexpired lease.
- Rejects stale, superseded, expired, mismatched and non-running executions.
- Sanitizes control characters and common bearer/API-key/token/secret/password patterns; limits stored error text to 2,000 characters.
- Atomically updates execution/task to `failed`, clears the current execution and lease, records bounded failure events and stores an idempotent response.
- A repeated request with the same idempotency key and payload replays the original response; key reuse with different arguments conflicts.

### `requeue_failed_task(p_task_id, p_worker_id, p_reason, p_idempotency_key)`

- Requires project-owner authorization and an active Worker belonging to the same project.
- Accepts only `failed` tasks with no current execution or lease.
- Preserves prior execution history and appends a `task_requeued` event.
- Reads `requirements.retry.max_attempts` (default 3, allowed 1–10) and `requirements.retry.backoff_seconds` (default 0, allowed 0–86,400).
- Rejects retries after the cap or before backoff elapses; idempotency is enforced.

### Repair-child handoff after a failure

The Coordinator can create or link a repair child using the existing `create_task` contract; a new RPC is not required. Set `parent_task_id` to the failed task, include `source_failure_execution_id` and `error_code` in `requirements`, and derive the idempotency key from the source execution ID (for example, `repair-child-for-failure-<execution-uuid>`). Repeating the same call returns the same child task ID. The integration harness verifies exactly one child exists, claims it, completes it, and preserves the failed source execution as history. This is a task-discovery/handoff operation, not an automatic production Worker or daemon.

### `claim_task(p_project_id, p_worker_id, p_lease_seconds, p_idempotency_key)`

- Requires an active Worker in the selected project and a lease between 60 and 600 seconds.
- Claims atomically using `FOR UPDATE SKIP LOCKED`.
- Reclaims expired leases after `requirements.retry.backoff_seconds`; the old execution is marked `expired` and fenced.
- When an expired execution has reached `max_attempts`, marks the task `failed` rather than creating an unbounded new attempt.
- A failed task is not silently selected again; an owner must explicitly requeue it.

## Verification evidence

### Isolated CI

- PostgreSQL 17 lifecycle/failure-recovery integration: [run 45076451313](https://github.com/Love-DC/recursive-ai-engineering/actions/runs/45076451313) — success on exact head `88d55ed25809f7263f31fef93c91e563e5957502`. It exercised failure persistence/atomic rollback, wrong-Worker fencing, idempotency replay/conflict, retry history/cap/backoff, lease-expiry fencing/reclaim, cancellation separation, two-session fail-vs-reclaim race, lifecycle harness and two-session claim race.
- Shell static checks: [run 45076451262](https://github.com/Love-DC/recursive-ai-engineering/actions/runs/45076451262) — success on the same exact head.

### Production verification

- Supabase migration history contains `20261122221942_failure_reporting_retry`.
- Live RPC inventory confirms `fail_execution` and `requeue_failed_task` are installed alongside the existing claim/heartbeat/complete RPCs.
- A transaction-scoped production smoke test executed heartbeat → fail → owner requeue → retry claim (attempt 2, new execution ID) → complete. The transaction was rolled back; a follow-up query confirmed zero persisted smoke-test tasks.
- A real project task was also failed through `fail_execution` with `OWNER_APPROVAL_REQUIRED`; the task and execution both persisted as failed. It was not requeued because the remaining production data cleanup requires separate Owner authorization.
- A previously expired root task at attempt 6 was terminally failed by `claim_task` under the default three-attempt cap. This verifies bounded recovery, not a successful retry of that old task.

### Post-deployment advisor findings

- Security Advisor reports 22 authenticated SECURITY DEFINER function warnings, compared with 20 before deployment. The two additional findings are the new failure/requeue RPCs. They are revoked from `PUBLIC` and `anon`; owner/worker checks remain mandatory. This is acceptable only within the documented trusted owner-MCP pilot and remains a gate before non-owner/public exposure.
- The existing `operation_requests` RLS-without-policy INFO finding remains fail-closed.
- Leaked-password protection remains disabled and must be reviewed before end-user password Auth rollout.
- Performance Advisor reports unused-index INFO findings; no indexes were changed.

## Operational boundaries

- No table schema, RLS policy, project registration, Worker identity, or Auth configuration was changed by this migration.
- No Edge Function, background daemon, or scheduled job was deployed. The shared MCP pilot uses active ChatGPT Coordinator/Executor sessions; discovery runs during an active session. A persistent background service is not a prerequisite for this pilot.
- `fail_execution` and `requeue_failed_task` do not themselves create an always-running Worker. They provide durable, fenced state transitions to the existing shared executor model.
- The production project-config cleanup is tracked separately. Do not remove legacy governance/task-activation/merge-authority keys until the reversible cleanup is separately authorized and its before/after evidence and rollback are recorded.
