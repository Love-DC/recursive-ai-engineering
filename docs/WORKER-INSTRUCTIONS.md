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
- Supabase is the source of truth for project/task state and the cross-session Problem Inbox. GitHub is the source of truth for code, Issues, PRs, and durable repository documents. Read `docs/PROBLEM-INBOX.md` at startup.

## Project references

- Supabase project: `recursive-ai-engineering`
- GitHub repository: `Love-DC/recursive-ai-engineering`
- Shared Worker key: `shared-executor`
- Shared Worker ID: `78953b49-db9d-4fbc-9d3c-be3421a1c975`
- Project ID: `61e32c05-39b7-47a6-ab5c-592c8e37d72d`

## Mandatory production claim-safety gate

Before any task-pool write, follow the database-wide gate in `docs/SESSION-START.md`. The live RAE database also contains the deployed PR #66 repository-authoritative guard (`20261124192533`), trusted Owner-MCP execution context (`20261124200149`), and Owner-MCP project registration (`20261124202438`). The database-wide migration gate is open, but this RAE project's own `autonomy.paused=true` switch blocks new RAE task creation and claims. See SESSION-START for the current live state and supported RPC boundaries.

This is a dated snapshot, not a permanent permission. Re-check the live migration registry, RPC definitions, project/Worker mapping, and selected project's activation policy at each session start. Use only the correct project UUID and that project's active Worker ID. Claim only real eligible work through the atomic `claim_task` RPC, only after the mandatory production claim-safety gate in `docs/SESSION-START.md` has been re-verified open; never use a dummy claim or failed probe to test health.

The PR #66 repository-authoritative guard is deployed as migration `20261124192533`. The legacy `projects.config.task_activation` key and owner setter have been removed. Every task creation/claim path now requires a valid `autonomy.paused=false` and `autonomy.max_active_executions` between one and two.

The live 2026-11-25 project controls were rechecked: Colony Sim and Hexa Game Kernel are unpaused with a two-execution cap; RAE and Lambent remain paused with the same cap. Colony Sim's repository-local `AUTONOMY_POLICY.md` authorizes bounded active-session engineering tasks and already-approved designs. Do not change gameplay, balance, design, map, UX, or player experience.

PR #60's `public.reconcile_submitted_task` is deployed and available, subject to its owner authorization, evidence, and state-fencing rules. It does not authorize direct edits to historical task or execution rows.

The database claim-safety gate and a project's own repository activation policy are separate requirements. A paused project remains read-only for new autonomous task creation/claiming. Never bypass pause, Worker routing, dependencies, leases, branch exclusion, concurrency, review, or product decision gates.

If any live check is closed, stale, contradictory, or unavailable, Do not call `claim_task`, task creation/reassignment/requeue/cancel/review RPCs, execution mutation RPCs, or Initiative/Problem Inbox mutation RPCs. Continue only read-only inspection and repository-only maintenance. The deployed claim function can expire stale executions, so it is not a safe health probe.

## How to work

1. Read the task queue and current task details from Supabase before acting. Never rely on another conversation's memory.
2. If no eligible task exists, run the authorized discovery loop in docs/AUTONOMOUS-TASK-DISCOVERY.md; do not stop before discovery and do not manufacture work.
3. Create a task only when evidence, scope, deduplication, and project activation policy all permit it. Use that project's project UUID and its own active shared Worker UUID.
4. Claim a task atomically with `claim_task` only after the mandatory production claim-safety gate in `docs/SESSION-START.md` is verified open for that database. If closed or uncertain, do not call any task-lifecycle write RPC and stay read-only; a failed `claim_task` probe is not safe because the deployed function may mutate expired executions before returning.
5. Read the task requirements and relevant GitHub files.
6. Do the work. Commit durable code/documentation changes to GitHub and record the resulting commit or file references in the task result/artifacts.
7. If the task is too large, create child implementation tasks using `create_task` and the original task's ID as `parent_task_id`. Record the child task IDs in the parent result. Other sessions can claim those children without knowing anything about the decomposing session.
8. For pilot tasks, set `requires_review=false` only when the task-level pilot contract permits it; this disables a separate Supabase task-level review task, **not** the Coordinator's independent PR-level review and merge gate. A leaf Worker must never approve or merge its own PR. The Coordinator must inspect the exact PR head, require the target repository's CI to pass on that exact revision, resolve blocking review findings, and merge only under `docs/COORDINATOR-PR-REVIEW-AND-MERGE.md`. Then finish the task with `complete_execution` and record the PR/commit and validation evidence.
9. Update linked Problem Inbox records, resolve only with verified evidence, and submit a concise result containing what changed, GitHub references, verification performed, and remaining blockers.

## Lease behavior

- Claim with a lease of up to 600 seconds.
- Do not send session heartbeats or activity telemetry.
- If work may exceed the lease, renew only to prevent another session from reclaiming the same task. This is task-lock maintenance, not session monitoring.
- If the session disappears, another session may reclaim the task after lease expiry. The previous execution is fenced and must not write further.

## Supabase MCP execution context

The existing authorized Supabase MCP database-management connection is the trusted Owner-MCP channel for this single-owner pilot. Its SQL connection runs as `postgres` and does not carry a Supabase Auth JWT (`auth.uid()` is null). Do **not** manufacture a JWT by setting `request.jwt.claim.sub`; that is not authentication and is not the supported Owner-MCP path.

The deployed RAE migration `20261124200149_trusted_owner_mcp_execution_context` provides the private, transaction-scoped entry point `private.begin_owner_mcp_context(project_id, owner_id)`. It accepts only the original `postgres` database session, verifies that the supplied Owner UUID exactly matches the selected project's live `public.projects.owner_id`, and records an audit row. The context binds to one project and automatically clears on COMMIT or ROLLBACK. Migration `20261124202438_owner_mcp_project_registration` is also present. The Owner-MCP context does not imply that every owner-protected RPC supports it: `public.list_problem_reports` still returns `UNAUTHENTICATED`, and `get_problem_report`/`update_problem_report` contain JWT-only row filters. The repository migration `20261125120000_owner_mcp_problem_inbox_context.sql` adds a project-bound Owner-MCP path with isolated regression coverage, but it is not deployed to production.

Use the same transaction for context initialization and the protected RPC calls:

```sql
BEGIN;

-- Resolve the live Owner UUID from the project row; do not assume it is static.
SELECT private.begin_owner_mcp_context(p.id, p.owner_id)
FROM public.projects AS p
WHERE p.id = 'PROJECT_UUID'::uuid
  AND p.status = 'active';

-- Use the project's own Worker UUID and existing task RPCs.
SELECT public.list_tasks(
  'PROJECT_UUID'::uuid,
  NULL,
  NULL,
  100,
  NULL
);

-- Or call create_task / claim_task / heartbeat_execution /
-- submit_result / complete_execution / review_result as required.
COMMIT;
```

For a task claim, call `claim_task(project_id, that_project_worker_id, lease_seconds, fresh_idempotency_key)` inside the same transaction. Use the Worker key selected by the project's `worker_routing` for the task type. The returned execution ID and lease are authoritative. For multiple projects, use a separate transaction and a separately resolved project Owner UUID for each project.

The helper does not create a Worker session identity, set `auth.uid()`, change public PostgREST/JWT authentication, grant private-schema access to `anon` or `authenticated`, or bypass project routing, activation pause, dependencies, branch exclusion, execution leases, retry limits, or the two-execution cap. Ordinary JWT-authenticated callers continue to use the existing `auth.uid()` owner/Worker checks. Never expose the database admin connection or this private helper to external clients.

## Boundaries

- Do not add Worker identity systems, session tracking, heartbeat monitoring, multi-account provisioning, or complex orchestration.
- Do not add a second Supabase Auth identity or bind Worker rows to an artificial user.
- Do not set `request.jwt.claim.sub` to simulate an Owner JWT.
- Do not use Service Role keys, secret keys, database passwords, or privileged connection strings outside the connected Supabase MCP tool.
- Do not deploy game builds, production releases, or perform unrelated destructive actions. Routine RAE database migrations required to restore the already-authorized Owner-MCP task lifecycle are in scope for this integration work.
- Keep Colony Sim changes inside its approved engineering boundary. Gameplay, balance, design, map, UX, and player-experience decisions remain Owner-reserved.
- If a task cannot be completed safely, persist the blocker in the Problem Inbox and never invent progress.



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

The initial instruction is standing authorization for the AI Coordinator to carry an in-scope engineering objective through its complete lifecycle, within the permissions of the already-connected accounts and the target repository's governance. All task-pool writes remain conditional on the mandatory production claim-safety gate in `docs/SESSION-START.md`; this standing authorization does not open that gate or authorize production migration deployment:

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
