# Multi-project routing — authoritative addendum

This addendum supersedes any assumption below that every task belongs to the original RAE project. Before creating, claiming, or completing work, resolve the target project and its project-scoped worker from live Supabase data.

- Query `public.projects` and select the active row by `config->>'project_key'` or canonical `github_repo`.
- Query `public.workers` for `project_id = <selected project UUID>`, `worker_key = 'shared-executor'`, and `status = 'active'`.
- Use that exact project UUID and worker UUID for every task RPC. Never reuse the RAE worker UUID for Colony Sim or vice versa.
- RAE project key/repository: `recursive-ai-engineering` / `Love-DC/recursive-ai-engineering`.
- Colony Sim project key/repository: `colony-sim` / `Love-DC/colony-sim`.
- Colony Sim governance is loaded from the repository paths in its `projects.config.governance` object. At minimum read `AGENTS.md`, `docs/ai/AI_START_HERE.md`, and `docs/ai/WEB_GITHUB_WORKFLOW.md`.
- Keep task-specific GitHub metadata in `tasks.requirements` JSONB using the contract in `docs/MULTI-PROJECT-ARCHITECTURE.md`. Store actual delivery evidence in the execution result and artifacts.
- A direct owner request authorizes the current coordinator to execute a bounded engineering objective in the selected project. It does not authorize unapproved product decisions.
- Never bulk-import Issues. For Colony Sim, an Issue becomes executable only under its explicit owner/coordinator dispatch rules. An open Issue is not permission.
- Do not merge PRs. Colony Sim's product owner retains final merge approval.

Use [Session Start](SESSION-START.md) as the canonical new-conversation entry point and [Multi-Project Architecture](MULTI-PROJECT-ARCHITECTURE.md) as the canonical routing/task contract.

---

# GPT Session Operating Instructions — Shared MCP Pilot

## Operating model

- A ChatGPT conversation is temporary. Do not create, track, heartbeat, identify, or report on individual sessions.
- All sessions work as one shared executor through the user's already-authorized Supabase MCP connection.
- Use the single project Worker record with key `shared-executor`. Its UUID is a stable database routing reference, not a session ID or identity credential.
- Do not create separate Supabase Auth users or bind Worker identities for this pilot.
- Supabase is the source of truth for task state. GitHub is the source of truth for code and durable project documents.

## Project references

- Supabase project: `recursive-ai-engineering`
- GitHub repository: `Love-DC/recursive-ai-engineering`
- Shared Worker key: `shared-executor`
- Shared Worker ID: `78953b49-db9d-4fbc-9d3c-be3421a1c975`
- Project ID: `61e32c05-39b7-47a6-ab5c-592c8e37d72d`

## How to work

1. Read the task queue and current task details from Supabase before acting. Never rely on another conversation's memory.
2. If the queue is empty and the user has provided an engineering objective, create an implementation task with `create_task`, the shared Worker ID, and `requires_review=false`. If no objective was provided, ask the user what should be worked on.
3. Claim a task atomically with `claim_task`, using the shared Worker ID and a fresh idempotency key. A database-generated UUID is suitable for the key; it is not a session identity.
4. Read the task requirements and relevant GitHub files.
5. Do the work. Commit durable code/documentation changes to GitHub and record the resulting commit or file references in the task result/artifacts.
6. If the task is too large, create child implementation tasks using `create_task` and the original task's ID as `parent_task_id`. Record the child task IDs in the parent result. Other sessions can claim those children without knowing anything about the decomposing session.
7. For pilot tasks, set `requires_review=false` and finish with `complete_execution`. Do not introduce a review/fix workflow unless the user explicitly asks for it.
8. Submit a concise result containing what changed, GitHub references, verification performed, and remaining blockers.

## Lease behavior

- Claim with a lease of up to 600 seconds.
- Do not send session heartbeats or activity telemetry.
- If work may exceed the lease, renew only to prevent another session from reclaiming the same task. This is task-lock maintenance, not session monitoring.
- If the session disappears, another session may reclaim the task after lease expiry. The previous execution is fenced and must not write further.

## Supabase MCP execution context

The pilot uses the already-authorized project-owner MCP connection; it does not provision per-session credentials. When calling owner-protected RPCs through the privileged SQL MCP tool, set the existing project's `owner_id` as `request.jwt.claim.sub` in the same SQL transaction before invoking the RPC. Keep this confined to the authenticated Supabase MCP connection; never copy credentials or privileged keys into prompts, GitHub, task results, or external clients.

## Boundaries

- Do not add Worker identity systems, session tracking, heartbeat monitoring, multi-account provisioning, or complex orchestration.
- Do not create or modify Supabase schema unless the task specifically requires it.
- Do not use Service Role keys, secret keys, database passwords, or privileged connection strings outside the connected Supabase MCP tool.
- Do not deploy, merge, or perform external side effects without explicit user authorization.
- If a task cannot be completed safely, persist the blocker and create a smaller actionable task rather than inventing progress.


## Verified Supabase MCP recipe (2026-11-23)

### Project identifiers

Do not confuse these two identifiers:

- Supabase MCP project ref (used as the `project_id` argument to MCP tools): `rgztxilqcfuclkekyojl`.
- Database `public.projects.id` (UUID passed to task RPCs): `61e32c05-39b7-47a6-ab5c-592c8e37d72d`.

The project-owner UUID currently stored in `public.projects.owner_id` is `343781b2-5552-4d49-a52e-9f9dca7c802a`. It is an authorization claim value, not a secret. Resolve these values from the live project/database rather than assuming they never change.

### Owner context and task creation

For owner-protected RPCs called through the already-authorized Supabase MCP `execute_sql` tool, set the existing owner claim and invoke the RPC in the same SQL statement/transaction. Example (use a new idempotency key for each distinct create operation):

```sql
with auth as (
  select set_config('request.jwt.claim.sub',
    '343781b2-5552-4d49-a52e-9f9dca7c802a', true)
)
select public.create_task(
  '61e32c05-39b7-47a6-ab5c-592c8e37d72d',
  '78953b49-db9d-4fbc-9d3c-be3421a1c975',
  'implementation',
  'Task title',
  'Bounded task description',
  '{"acceptance":["observable condition"]}'::jsonb,
  10, false, null, null,
  'fresh-unique-create-key'
) from auth;
```

For a child task, pass the parent task UUID as the ninth argument (`p_parent_task_id`). Keep pilot tasks as `implementation` with `requires_review=false`.

### Atomic claim and completion

Claim from the shared pool with a fresh idempotency key; valid lease duration is 60–600 seconds:

```sql
with auth as (
  select set_config('request.jwt.claim.sub',
    '343781b2-5552-4d49-a52e-9f9dca7c802a', true)
)
select public.claim_task(
  '61e32c05-39b7-47a6-ab5c-592c8e37d72d',
  '78953b49-db9d-4fbc-9d3c-be3421a1c975',
  600,
  'fresh-unique-claim-key'
) from auth;
```

Read `data.task_id` and `data.execution_id` from the response. After work and GitHub commit verification, persist the result with:

```sql
with auth as (
  select set_config('request.jwt.claim.sub',
    '343781b2-5552-4d49-a52e-9f9dca7c802a', true)
)
select public.complete_execution(
  'TASK_UUID', 'EXECUTION_UUID',
  '78953b49-db9d-4fbc-9d3c-be3421a1c975',
  '{"summary":"...","github_commit":"...","verification":["..."],"blockers":[]}'::jsonb,
  'fresh-unique-completion-key'
) from auth;
```

Do not call `complete_execution` for review-required work; pilot work should set `requires_review=false`. Do not reuse an idempotency key with different arguments.

### Querying handoff and project progress

```sql
with auth as (
  select set_config('request.jwt.claim.sub',
    '343781b2-5552-4d49-a52e-9f9dca7c802a', true)
)
select public.get_task('TASK_UUID') from auth;

with auth as (
  select set_config('request.jwt.claim.sub',
    '343781b2-5552-4d49-a52e-9f9dca7c802a', true)
)
select public.list_tasks(
  '61e32c05-39b7-47a6-ab5c-592c8e37d72d',
  null, null, 100, null
) from auth;
```

`get_task` returns the task, execution history, artifacts, and review/fix context. `list_tasks` with null status and worker filters lists the project task queue (up to 100 rows). For a root task's direct children, query `public.tasks` by `parent_task_id` through the authorized SQL tool; aggregate statuses to report progress. Task state remains authoritative in Supabase; cite GitHub commit SHA/path in the result.

### Verified implementation details

Live inspection of `claim_task` confirms row-level `FOR UPDATE SKIP LOCKED`, deterministic priority/creation ordering, expired-lease recovery, and operation idempotency. `complete_execution` verifies the current execution fence and persists the execution result, accepted task status, and task events. A sequential create → claim → complete run has passed in this project. A truly simultaneous multi-client race was not run in this session; the locking guarantee is supported by the deployed function definition, not claimed as a live race-test result.

A completed child task and three child tasks (all three were subsequently completed in this run) were persisted under root task `dedafaf5-6abb-4d66-9c0d-7622cebfcb2f` on 2026-11-23. Query Supabase for current state; do not rely on this snapshot.
