# Database-enforced Worker routing and safe execution release

This document defines the database-level contract for task routing and accidental-claim recovery. Worker descriptions and prompt instructions are explanatory only; the live database function is the enforcement boundary.

## Route resolution

The claim function resolves eligible Worker keys in this order:

1. Task `requirements.required_worker_key` (one string or an array of keys).
2. Project `config.worker_routing.task_type_worker_keys[task_type]`.
3. Project `config.worker_routing.default_worker_key`.
4. Compatibility fallback only when the project has exactly one active Worker.

A multi-Worker project with no explicit route fails closed. An explicit empty or malformed route also fails closed rather than falling through. Route values are normalized by trimming ASCII whitespace (space, tab, line break, carriage return, form feed, and vertical tab); whitespace-only scalar or array entries invalidate the explicit route. The same route predicate applies to pending claims, expired-lease reclaim, and retry-limit expiry.

Review tasks are additionally pinned to their exact `assigned_worker_id`. The project route for `review` must agree with that Worker's key. The migration seeds missing `shared-executor` / `independent-reviewer` mappings only for projects that already have both active Worker keys and preserves existing explicit config.

## Safe release

Use `public.release_execution(task_id, execution_id, worker_id, reason, idempotency_key)` for an accidental claim or graceful handoff.

The RPC:
- verifies the exact current task/execution fence;
- requires `worker_id` to match both `tasks.assigned_worker_id` and `executions.worker_id`;
- is idempotent and preserves the execution audit record;
- returns the task to `pending` only while the claimed attempt count is below `requirements.retry.max_attempts` (default 3); at the cap it terminally sets the task to `failed` with `LEASE_RETRY_LIMIT_REACHED`;
- marks an execution `superseded` if its lease is still valid, or `expired` if the lease has elapsed;
- preserves a review task's reviewer assignment.

A mismatched Worker ID returns `TASK_NOT_OWNED`; a superseded execution returns `EXECUTION_SUPERSEDED`. Pass the Worker ID stored on the current execution, not the task creator or a different default Worker ID.

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

Do not substitute `fail_execution`, `requeue_failed_task`, direct table updates, or `cancel_task` for an execution release. If the RPC is not deployed, preserve the audit trail and let the lease expire; do not mutate production task rows directly.

## Production deployment gate

The migration in `supabase/migrations/202611230004_worker_task_routing_safe_release.sql` is prepared for review and isolated CI only. It has not been applied to production. Production deployment requires independent review and explicit deployment authorization.

## Validation

The PostgreSQL task lifecycle workflow runs `tests/worker-routing-release-tests.sql` against an isolated PostgreSQL 17 service. It covers reviewer/implementation separation, explicit and default routes, route-safe expired reclaim, review creation/claim routing, ambiguous-route fail-closed behavior, scalar/array whitespace normalization, single-worker compatibility, wrong-owner denial, release idempotency, expired release, retry-cap terminal failure/no-reclaim, and stale-execution fencing.
