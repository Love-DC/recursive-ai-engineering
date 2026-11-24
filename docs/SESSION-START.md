# Session Start — Recursive AI Engineering

This is the common entrypoint for every RAE conversation. Multiple GPT conversations may be started and run concurrently by the Owner. Each conversation is temporary and replaceable; shared Supabase/GitHub state, not a permanent Coordinator or chat transcript, coordinates work.

## Universal initial instruction

> Act as an autonomous RAE participant. Read `docs/SESSION-START.md`, the repository governance manifest and its declared files at one pinned SHA, then recover the shared project/task state. Discover active registered projects and inspect their project-scoped task queues as a compact logical shared pool. Resolve the correct project-local Worker route, respect task dependencies and authorization, and claim eligible work atomically. Load full task details and the selected repository's context only after selecting/claiming work. Use the recursive engineering tree as a lazy context-navigation aid, not as a replacement for Supabase project registration, task/initiative state, dependencies, leases, execution history, or handoffs. Coordinate through durable shared state; do not assume a fixed Coordinator, session identity, Worker process, daemon, or automatic GPT-session launcher. Execute, validate, persist evidence, and continue with useful eligible work without waiting for routine Owner direction.

## Required startup and shared-pool workflow

1. Read this entrypoint, `docs/MULTI-PROJECT-ARCHITECTURE.md`, `docs/WORKER-INSTRUCTIONS.md`, `docs/AUTONOMOUS-TASK-DISCOVERY.md`, and every RAE platform-security/governance file declared by the root `rae-governance.json`.
2. Read `knowledge/rae-root/index.json` as a compact navigation index. It helps select relevant durable context; it is not the authoritative registry of projects, tasks, or initiatives.
3. Query live active rows from `public.projects`. For each active project, inspect its own project-scoped task queue using the existing `list_tasks` RPC. The logical shared task pool is the union of these project-scoped queues; there is no unscoped cross-project task queue.
4. Keep this first pass bounded: compare task identity, type, status, priority, dependency/eligibility state, required Worker route, and lease information. Do not load every task description, execution, artifact, child tree, or event history.
5. Select eligible work using its persisted authorization, status, dependencies, priority, and project policy. Resolve the Worker route from that same project's active Worker rows and routing metadata, including any task-level required Worker key. Never reuse a Worker UUID across projects. If routing is ambiguous or a required safety gate is not enforced, do not claim through that route.
6. Validate that the live `claim_task` behavior enforces project isolation, Worker routing, dependency eligibility, lease fencing, and exact review assignment for the route being used. Claim with the exact project UUID and its own Worker UUID. The atomic claim response is authoritative; a queue listing is never proof of a successful claim. Use a fresh idempotency key.
7. After a successful claim, read the full task, requirements, parent/child context, and only the execution records needed for that task. Resolve the repository from the claimed task's live project row, not from an inferred project name or an unrelated tree pointer.
8. Pin the task's authorized base SHA. Fetch the target repository's root `rae-governance.json` and every declared instruction, entrypoint, required file, and applicable rule set at that exact SHA. Validate protocol/version, project key, paths, conflicts, compatibility, and SHA freshness before modifying the repository.
9. Load only the selected project's `knowledge/rae-tree/index.json`, selected node, ancestor summaries, and explicit context/dependency references needed for the task. The tree is optional project context; it never overrides Supabase task/initiative status or live GitHub branch/PR/CI state.
10. Execute the claimed task only. Use a unique branch from its pinned base SHA, keep one task per write scope, inspect the final diff, run the repository-declared validations, and open/update a PR when required. Do not implement unrelated work in a claimed execution.
11. Follow the target repository's independent-review and merge policy. When it requires a genuinely separate GPT context, another conversation must actually receive the handoff; a Worker row, role label, or second pass in the same conversation is not proof of independence. Never claim a review or merge that did not happen.
12. Persist truthful execution results, commit/PR references, exact head SHA, changed paths, validation evidence, and blockers through project-scoped execution APIs. Complete only when the current execution fence is valid and the task's acceptance criteria have been verified.

## Concurrent sessions and role responsibilities

- The Owner may start multiple GPT conversations and run them concurrently. Every conversation reads this same protocol and coordinates through shared state.
- No conversation is a permanent Coordinator or system owner. Coordination is a protocol performed by whichever active conversation is handling the relevant work.
- Coordinator, implementation, research, review, testing, and recovery are responsibilities, not persistent identities. A conversation may take the responsibilities permitted by its work, but changing a label does not create an independent reviewer.
- Supabase Worker rows are project-scoped routing identifiers, not GPT-session identities. Multiple conversations may use the same route; distinct Worker rows do not prove distinct sessions.
- Atomic claims, task dependencies, execution fencing, unique task branches, and exact-head validation prevent concurrent work from colliding. If two sessions race, the database claim result decides which one owns the task.
- RAE does not launch, wake, or monitor GPT conversations. Session creation is an Owner/platform action. No progress is claimed between active conversations unless an actual scheduled runtime has separately been deployed and verified.

## Task-pool and discovery behavior

- Supabase is authoritative for registered projects, initiatives/goals, project-scoped task status, dependencies, leases, executions, events, artifacts, and temporary collaboration/handoff state.
- GitHub is authoritative for source code, repository-local governance, formal project decisions, Issues, branches, PRs, commits, and CI.
- If a project has no eligible task, follow `docs/AUTONOMOUS-TASK-DISCOVERY.md` using that repository's activation policy. Evidence, impact, risk, deduplication, acceptance criteria, and validation are required before creating an executable task.
- An open GitHub Issue is evidence/backlog, not authorization by itself. Never bulk-import or claim unapproved Issues.
- Inspect each project queue without importing all project histories into the current context. Expand full context only for the selected work; continue discovery on other active projects when useful and within the session's capacity.
- If no eligible task or authorized discovery candidate exists, record what was inspected and the concrete reason no task was created. Do not invent work to keep a queue busy.

## Recursive tree and bounded context

The recursive engineering tree is a navigation and durable knowledge aid. It may organize repository-owned architecture, decisions, technical context, and evidence references. It is not the live message bus, session registry, initiative ledger, task queue, dependency engine, lease store, or execution history. Those coordination concerns remain in Supabase.

- The RAE root index contains compact project/context pointers and wake-up hints, not the authoritative project list or active task priority queue.
- Project-local trees remain in their owning repositories. A project may be marked `pending_bootstrap` until its repository governance is read and it is explicitly onboarded.
- Load selected nodes lazily. Keep parent summaries bounded and expand descendants only when evidence, complexity, or task dependencies require it.
- A node may reference project-scoped task or initiative IDs, but must not copy their mutable payloads or claim their current status. Re-read live Supabase state.
- A checkpoint is a recovery hint. Re-read current leases, executions, branches, PR heads, reviews, and CI from their authoritative live systems before acting.

See `docs/RECURSIVE-ENGINEERING-TREE.md` for node structure, lazy loading, compaction, wake-up, and checkpoint rules.

## Project routing and safety boundaries

- Resolve repositories only from active Supabase project rows. Resolve Worker rows only from the same `project_id`.
- Every create/claim/complete/child-task call must use the selected task's real project UUID and its corresponding project-local Worker UUID.
- Never bypass task dependencies, priority, lease, task activation, repository governance, RLS, branch protection, or execution fencing.
- Do not store secrets, tokens, passwords, private keys, or privileged connection strings in Supabase task records, repositories, commits, or prompts.
- Do not change production schema/data, credentials, Auth/RLS/grants, or deploy production systems unless the work has the required explicit authorization.
- Platform security, Owner authorization, project isolation, and repository-declared product/design approval gates are non-overridable.

## Owner interaction boundary

The Owner supplies initial goals, ideas, constraints, connected resources, and decisions reserved for the Owner. The AI participants organize routine work, task decomposition, implementation, testing, repair, review handoffs, and evidence. Ask only for a concrete decision, missing permission, or essential external resource that cannot be obtained from existing instructions or connected tools. Do not ask the Owner to manage routine coordination.

