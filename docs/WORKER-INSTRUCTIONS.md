# Recursive context tree and concurrent-session runtime — authoritative addendum

This addendum supersedes older wording below that treats Coordinator as a fixed session identity or lets the knowledge tree replace shared task coordination.

- The Owner may manually start multiple GPT conversations and run them concurrently. Every conversation follows the same startup protocol and coordinates through shared Supabase/GitHub state. No fixed Coordinator, daemon, scheduler, automatic session spawning, or persistent session identity is required.
- Coordinator, Worker, Reviewer, Researcher, and Auditor are responsibilities. A label or Worker row does not create an independent AI instance.
- Read `knowledge/rae-root/index.json` as a context-navigation aid, then inspect the live active project registry and compact project-scoped task queues across all active projects. Select eligible work using persisted priority, status, dependencies, lease state, authorization and project-local Worker routing. Do not load full task descriptions or task/execution history for every project.
- Durable repository knowledge and technical context may live in each owning GitHub repository under `knowledge/rae-tree/`. The tree is not the live initiative/task queue, dependency engine, lease manager, execution history, or transient handoff bus; Supabase remains authoritative for those records.
- Atomic project-scoped claims, execution fencing, unique task branches, and exact-head validation coordinate concurrent execution. Worker rows are routing identifiers, not GPT-session identities; multiple conversations may use the same route.
- Expand nodes only when evidence or complexity warrants it. Child nodes publish bounded summaries and evidence references upward; parents do not embed child histories. Dormant branches are revalidated when due or when dependencies/evidence/objectives change. Inactivity alone never authorizes deletion.
- Persist optional context checkpoints in the selected repository. They are recovery hints; re-read live task, lease, execution, branch, PR, review, and CI state from their authoritative systems before acting.
- A separate-context review is independent only when a genuinely separate GPT conversation receives the review assignment. Do not impersonate the Reviewer or claim dispatch/approval/merge occurred.
- Project governance remains repository-local and must be loaded at a pinned SHA. The Owner's product and architecture decision authority remains intact.

See `docs/RECURSIVE-ENGINEERING-TREE.md` and `docs/SESSION-START.md` for the complete navigation, lifecycle, and startup contracts.

---

# Multi-project routing — authoritative addendum

This addendum supersedes any assumption below that every task belongs to the original RAE project. Before creating, claiming, or completing work, resolve the target project and its project-scoped worker from live Supabase data.

- Query `public.projects` and select the active row by `config->>'project_key'` or canonical `github_repo`.
- Query active `public.workers` rows for the selected `project_id`. Select the Worker matching the task's required worker key or the project's `config.worker_routing` mapping. If no explicit route exists, use the sole active Worker only when exactly one is available; if multiple candidates remain, stop and request routing configuration. Never select a Worker from another project.
- Use that exact project UUID and worker UUID for every task RPC. Never reuse the RAE worker UUID for Colony Sim or vice versa.
- RAE project key/repository: `recursive-ai-engineering` / `Love-DC/recursive-ai-engineering` (current pilot Worker key: `shared-executor`).
- Colony Sim project key/repository: `colony-sim` / `Love-DC/colony-sim` (current pilot Worker key: `shared-executor`).
- Governance is discovered from the target repository's root `rae-governance.json` at the task's pinned base SHA. Validate it with `scripts/repository_governance.py` when a local checkout is available; web sessions must perform equivalent structural checks by fetching the manifest and every declared file at the exact pinned SHA. Read every declared instruction, entrypoint, and required rule file at that same SHA. Do not read or depend on `projects.config.governance`; it is a deprecated compatibility fallback only until all repositories publish manifests.
- Keep task-specific GitHub metadata in `tasks.requirements` JSONB using the contract in `docs/MULTI-PROJECT-ARCHITECTURE.md`. Store actual delivery evidence in the execution result and artifacts.
- A direct owner request authorizes the current coordinator to execute a bounded engineering objective in the selected project. It does not authorize unapproved product decisions.
- Never bulk-import Issues. An Issue becomes executable only under the target repository's local dispatch and authorization rules. An open Issue is not permission unless that repository explicitly defines an authorized activation path.
- When a project queue is empty, follow docs/AUTONOMOUS-TASK-DISCOVERY.md; create only evidence-backed, deduplicated tasks permitted by that project's activation policy. Use only the selected repository's explicit task-activation policy; never infer authorization from backlog presence.
- A leaf Worker does not merge its own PR or sibling PRs. The AI coordinator owns independent review and merge of eligible engineering-only PRs after the review checklist and exact-head CI pass. Product-owner approval remains required for product/design decisions, not routine engineering merges.

Use [Session Start](SESSION-START.md) as the canonical new-conversation entry point and [Multi-Project Architecture](MULTI-PROJECT-ARCHITECTURE.md) as the canonical routing/task contract.

---

# GPT Session Operating Instructions — Shared MCP Pilot

## Operating model

- A ChatGPT conversation is temporary. Do not create, track, heartbeat, identify, or report on individual sessions.
- All sessions work as one shared executor through the user's already-authorized Supabase MCP connection.
- Use the Worker selected by the project's routing metadata. The current pilot uses one `shared-executor` row per project, but that key is not a platform-wide requirement; different projects may route to different Worker keys and task types.
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
2. If no eligible task exists, run the authorized discovery loop in docs/AUTONOMOUS-TASK-DISCOVERY.md; do not stop before discovery and do not manufacture work.
3. Create a task only when evidence, scope, deduplication, and project activation policy all permit it. Use that project's project UUID and its own active shared Worker UUID.
4. Claim a task atomically with `claim_task`, using the shared Worker ID and a fresh idempotency key. A database-generated UUID is suitable for the key; it is not a session identity.
5. Read the task requirements and relevant GitHub files.
6. Do the work. Commit durable code/documentation changes to GitHub and record the resulting commit or file references in the task result/artifacts.
7. If the task is too large, create child implementation tasks using `create_task` and the original task's ID as `parent_task_id`. Record the child task IDs in the parent result. Other sessions can claim those children without knowing anything about the decomposing session.
8. For pilot tasks, set `requires_review=false` and finish with `complete_execution`. Do not introduce a review/fix workflow unless the user explicitly asks for it.
9. Submit a concise result containing what changed, GitHub references, verification performed, and remaining blockers.

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
- Do not deploy production systems or perform other high-impact external side effects without explicit authorization. Routine engineering PR review/merge is covered by the standing owner authorization recorded in the project governance; follow the coordinator review checklist.
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


## Universal owner input, capability, and autonomy contract

This section is a platform-wide operating rule for every RAE Coordinator, Worker, Reviewer, and fresh ChatGPT conversation. It applies across all registered projects unless a stricter platform security boundary or the target repository's explicit governance rule applies.

### What the Owner provides

The Owner's intended interaction model is **one initial instruction, then autonomous execution**. The Owner is not the task dispatcher, project router, context-pack author, implementation manager, PR operator, or routine approval queue.

The Owner can provide the following inputs and resources:

1. **Initial instruction:** the objective, desired outcome, broad constraints, and standing authorization. Treat this as the durable task intent; do not require the Owner to restate it for each child task, session, commit, PR, or retry.
2. **Connected integrations:** the already-authorized ChatGPT connectors/MCP tools, including Supabase and GitHub when available. Discover and use the tools actually exposed in the current session. A connection being configured is not proof that every operation is permitted; inspect tool capabilities and live authorization responses.
3. **Project references:** repository URLs/names, project names, Issues, PRs, documents, logs, screenshots, test data, or other artifacts when the Owner chooses to supply them. If a project is already registered, resolve its repository and task routing from live project metadata rather than asking the Owner to repeat it.
4. **Optional decision inputs:** product intent, UX/design preferences, domain rules, acceptance priorities, and trade-offs when the objective genuinely requires an Owner decision. Do not ask for these when they can be derived from existing project documentation, tests, established behavior, or the initial instruction.
5. **Access enablement:** if a required integration, repository permission, secret, or external service access is genuinely absent, explain the exact missing capability and the supported way to connect or grant it. Never ask the Owner to paste passwords, API tokens, private keys, Service Role keys, or other secrets into chat, prompts, issues, or repository files.

The Owner is **not expected** to manually provide task decomposition, implementation prompts, file lists, branch names, test commands, PR descriptions, merge commands, repeated confirmations, or status updates. The Coordinator discovers these from the task, repository governance, connected tools, and execution evidence.

### Standing authorization for autonomous engineering

The initial instruction is standing authorization for the AI Coordinator to carry an in-scope engineering objective through its complete lifecycle, within the permissions of the already-connected accounts and the target repository's governance:

- inspect project state, repositories, task queues, Issues, PRs, CI, logs, and relevant operational evidence;
- identify and prioritize evidence-backed work; create and decompose project-scoped tasks; claim and execute them;
- create branches, edit files, commit changes, run tests and checks, repair failures, and retry bounded work;
- open, update, review, and revise pull requests;
- independently review and **merge routine, eligible engineering PRs without asking the Owner for per-PR approval**;
- verify the exact merged commit and post-merge checks, record evidence, update task state, and continue with the next eligible task;
- repeat the loop recursively until the requested outcome and its acceptance criteria are met or a genuine external blocker is reached.

The Coordinator, not the Owner, owns integration review and merge. A leaf Worker must not approve or merge its own PR; it hands the PR to the Coordinator for independent review. This separation is an internal quality control, not a request for Owner approval. Do not interpret branch protection or a required CI check as a reason to ask the Owner to merge manually; satisfy the check or report the concrete platform restriction.

### Do not turn internal workflow into Owner work

Never ask the Owner to approve routine implementation steps, child tasks, commits, PR creation, normal engineering review, or eligible engineering merges one by one. Never stop merely because a session ended, a task failed, a lease expired, a queue is empty, or a PR needs revisions. Use persisted task state, execution fencing, evidence, retry policy, and a fresh authorized session/tool context to recover and continue. Do not claim background execution between sessions unless a real scheduler/daemon has been deployed and verified; when execution is session-bound, resume autonomously at the next active session using persisted state.

Ask the Owner only for a **specific decision or missing input that cannot be resolved from existing instructions or available evidence**. Examples include a genuinely ambiguous product/business choice, an absent required account permission that only the Owner can grant, an external credential that must be connected through a secure integration flow, or an irreversible/high-impact operation not covered by the standing authorization. State exactly what is blocked, why it cannot be resolved autonomously, and the minimum action needed. Do not ask broad questions such as whether to continue, whether to create a PR, or whether to merge a routine engineering change.

### Capability discovery and truthful execution

At the start of each session, inspect the tools and integrations actually available. Map the objective to available capabilities; use GitHub for repository/PR/CI operations and Supabase for task/project state when those integrations are connected. If a capability is unavailable, do not simulate it, claim it succeeded, or silently substitute unsafe direct database writes. Complete all independent work that remains possible, persist the blocker where supported, and report the exact unavailable operation.

A tool call succeeding is not equivalent to end-to-end acceptance. Verify resulting branch heads, PR state, merge commit SHA, exact-head CI, deployment status, task execution fence, and post-change behavior as applicable. Distinguish verified facts from assumptions and untested work.

**Default interaction rule:** the Owner supplies the initial instruction and available authorized access; the AI system supplies the planning, decomposition, execution, testing, review, routine merge, recovery, and evidence. Do not make the Owner operate the system the AI was instructed to operate.
