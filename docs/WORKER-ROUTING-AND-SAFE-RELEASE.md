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

The migration in `supabase/migrations/20261123000400_worker_task_routing_safe_release.sql` is prepared for review and isolated CI only. It has not been applied to production. Production deployment requires independent review and explicit deployment authorization.

## Validation

The PostgreSQL task lifecycle workflow runs `tests/worker-routing-release-tests.sql` against an isolated PostgreSQL 17 service. It covers reviewer/implementation separation, explicit and default routes, route-safe expired reclaim, review creation/claim routing, ambiguous-route fail-closed behavior, scalar/array whitespace normalization, single-worker compatibility, wrong-owner denial, release idempotency, expired release, retry-cap terminal failure/no-reclaim, and stale-execution fencing.


## Task dependency eligibility

The migration `20261124000100_task_dependency_eligibility.sql` extends `claim_task` without changing table schemas or deploying to the live project.

### Declaring prerequisites

- Legacy `requirements.depends_on` remains supported as an array of external dependency keys (for example, `["recursive-ai-engineering#6 merged"]`). Every entry remains blocked until the Coordinator records verified evidence through `resolve_task_dependency`.
- The preferred `requirements.dependencies` format is an array of typed objects:
  - Internal task: `{"type":"task","task_id":"<same-project-task-uuid>","required_status":"accepted"}`. `required_status` defaults to `accepted`; other states are rejected fail-closed. Cross-project and missing task IDs do not satisfy the prerequisite.
  - External prerequisite: `{"type":"external","key":"<stable-dependency-key>"}`. It uses the same explicit evidence-resolution path as legacy `depends_on`.

An external prerequisite is satisfied only when `requirements.dependency_resolutions[key]` contains `status: "satisfied"` and evidence with non-empty `ref` and `observed_state`. The owner-authorized, idempotent `public.resolve_task_dependency(task_id, dependency_key, state, evidence, idempotency_key)` RPC accepts only keys already declared on that task. Use `state="unresolved"` with a `reason` to reopen a prerequisite. It updates the task requirements and appends an audit event; do not edit dependency metadata directly.

### Claim behavior

`claim_task` applies dependency eligibility consistently to pending claims, expired-lease reclaim, and the expired retry-cap sweep.

- A pending task with an unmet prerequisite stays `pending` and creates no execution.
- An expired-running task with an unmet prerequisite keeps its existing execution/audit state; it is not terminally failed or given another attempt until the dependency clears.
- The claim response includes a bounded `dependency_blockers` summary. The Coordinator can continue to claim unrelated eligible work even when a higher-priority task is blocked.
- `dependency_blocked`, `dependency_unblocked`, `dependency_resolved`, and `dependency_reopened` events preserve the blocker and resolution history. Repeated scans with the same blocker set do not emit duplicate blocked events.
- Malformed dependency metadata, missing/cross-project task references, unsupported dependency types, and absent external evidence fail closed.

External state is not fetched from GitHub by SQL. The Coordinator must verify the cited PR/commit/Issue state from GitHub before recording a `satisfied` resolution; the database RPC enforces that the key was declared, evidence fields are present, the owner is authorized, and the update is idempotent.

## Dependency validation and deployment boundary

The PostgreSQL lifecycle workflow applies this function-only migration to an isolated PostgreSQL 17 fixture and runs `tests/task-dependency-eligibility-tests.sql` inside a transaction that rolls back. It covers external evidence/idempotency, same-project task prerequisites, independent-work selection, expired-lease behavior and retry-cap handling.

The migration is a candidate only. It has **not** been applied to production. Independent review of the exact stacked PR HEAD, required exact-head CI, and the separately authorized production deployment gate are still required.
