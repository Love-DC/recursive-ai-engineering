# AI Worker Collaboration System — MVP v1.2

## Status

Implementation baseline: MVP v1.2. The seven-table, 20-RPC baseline now includes per-Worker Supabase Auth identity binding and task-scoped authorization.

## Architecture

Supabase PostgreSQL is authoritative for projects, Workers, Tasks, Execution state, leases, review decisions, artifacts and events. GitHub stores code and deliverables. A GPT conversation's chat history is not authoritative state.

Each Worker may be bound to one distinct `auth.users.id` through the Owner-only `bind_worker_identity` RPC. Worker-facing RPCs validate `auth.uid()` against the exact Worker ID. The project Owner retains administrative override. Unbound Workers and mismatched Auth subjects are denied.

## Seven core tables

1. `projects`
2. `workers`
3. `tasks`
4. `executions`
5. `artifacts`
6. `task_events`
7. `operation_requests`

Reviews are `tasks.task_type='review'`; no eighth table is introduced.

## Mandatory corrections

- `accepted` permits `implementation AND requires_review=false` without a Review Task.
- A partial unique index prevents duplicate Original/Delivery/Execution Review targets.
- `tasks(current_execution_id,id)` references `executions(id,task_id)`.
- Reviewer Execution completes `running -> succeeded` only after current Execution, assigned Reviewer and Lease checks.
- Ordinary expired running Tasks can be reclaimed by another active Worker. Review Tasks remain restricted to the assigned Reviewer.
- Both accepted and rejected review decisions update Original Task `latest_review_task_id`.
- Ordinary `create_task` accepts only implementation Tasks; Review and Fix use dedicated RPCs.
- Cancelling a running Task fails its current Execution and clears the Task lease.
- Function grants are changed per exact signature; unrelated project functions are not globally revoked.
- `projects.owner_id` is NOT NULL.
- Cross-project relationships are protected by composite foreign keys wherever representable.

## State model

Task states: pending, running, submitted, accepted, rejected, failed, cancelled.

Execution states: running, submitted, succeeded, failed, expired, superseded.

A Task in running state has assigned Worker, current Execution and lease. Non-running Tasks have no current Execution or lease. Execution history is retained. Submitted delivery Executions are immutable delivery snapshots and can be reviewed later.

## Review and fix flow

Initial delivery: Original Task submits Execution E1; Review Task binds Original=Original, Delivery=Original, Execution=E1.

After rejection: a dedicated Fix Task references the Original Task through `fixes_task_id`. The Fix Task submits E2. `resubmit_after_fix` updates the Original Task's latest delivery pointers to Fix Task/E2 without re-parenting E2. A new Review Task binds Original, Fix Task, E2. Review acceptance or rejection updates the Original Task, preserving all previous executions, artifacts and reviews.

## Security model

- Public API functions are SECURITY DEFINER with fixed `search_path`.
- Owner-only administrative RPCs validate project ownership. Worker RPCs validate project ownership or exact Worker/Auth binding, depending on the operation.
- Only explicitly granted public RPC signatures are executable by `authenticated`; `anon` and PUBLIC are revoked per function.
- Internal helpers live in the unexposed `private` schema and have no client EXECUTE grants.
- Direct client writes to business tables are revoked.
- RLS is enabled on all seven tables; operation_requests has no client policy or table grants.
- `workers.auth_user_id` is unique and references `auth.users(id)`. Owner binds/unbinds identities via `bind_worker_identity`; credentials are never stored in Worker rows.
- Worker sessions can inspect only their own Worker record and assigned tasks; Worker cancellation is limited to tasks assigned to that Worker. Fix-task and Review-task orchestration remain Owner-only; an autonomous Coordinator Worker cannot currently create those tasks.

## Known limits and outstanding validation

One Auth user has been provisioned. The Owner console source is committed under `console/`, but its real browser login flow remains unverified. Worker identity isolation migrations are deployed and recorded. A rollback-safe RPC-level workflow test passed under a simulated authenticated Owner JWT context, covering ownership denial, idempotency replay/conflict, claim/heartbeat, artifact registration, submit, Reviewer rejection, Fix/resubmit, Reviewer acceptance, no-review completion and running-task cancellation. A two-connection claim race, lease-expiry reclaim and stale-Execution fencing test also passed using the same Owner identity. Test records were rolled back or deleted. Negative tests now prove unbound and mismatched Auth subjects cannot claim or inspect another Worker. Positive end-to-end workflows across genuinely separate Auth users remain untested because only one Auth user exists. See the acceptance report.
