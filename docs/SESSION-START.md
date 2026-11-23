# Session Start — Recursive AI Engineering

This is the only RAE conversation entrypoint. Read it first. The Owner manually starts one GPT conversation at a time; RAE must not depend on a fixed Coordinator, another GPT session, a daemon, or background scheduling.

## Universal initial instruction

> Act as the RAE engineering system through the current GPT conversation. Read `docs/SESSION-START.md`, restore the compact root index at `knowledge/rae-root/index.json`, and follow `docs/RECURSIVE-ENGINEERING-TREE.md`. Determine the current objective and select only the relevant project/branch. Load that branch's local governance and context at pinned revisions. Perform the responsibilities required by the work in this conversation; Coordinator, Worker, Reviewer and Auditor are responsibilities, not fixed session identities or guaranteed separate agents. Use Supabase only for project routing and project-scoped task/execution state; use each GitHub repository for its own knowledge tree and governance. Expand the tree only when evidence or complexity requires it, update bounded summaries upward, and persist a checkpoint before ending. Do not enumerate all projects' task queues, load all descendants/history, invent a background process, or claim another GPT session was launched. Preserve the Owner's product/architecture decision authority and ask only for genuinely missing decisions, permissions, or external inputs.

## Bootstrap: bounded reads only

1. Read this entrypoint and the platform security rules referenced by the RAE governance manifest.
2. Read `knowledge/rae-root/index.json`. It is a navigation index, not a full project context dump.
3. Resolve the current objective:
   - If the Owner named a project or supplied an artifact/goal that maps unambiguously to a project, resolve only that active `public.projects` row and follow its tree pointer.
   - Otherwise, select from the root's compact global attention list (resumable checkpoints, due wake-ups, blockers, and highest-priority active branches).
   - If the root pointer is missing or stale, reconcile the root index against the live project registry. Do not enumerate all project queues or rebuild all trees.
4. Load only the selected project's `knowledge/rae-tree/index.json`, selected node, ancestor summaries, and the exact context/dependency references needed for the next action.
5. Load the selected repository's `rae-governance.json` and every declared instruction, entrypoint, required file, and applicable rule set at one pinned SHA before changing that repository.
6. Read only the specific Supabase task, execution, artifact, or event records referenced by the selected node/checkpoint or needed to select eligible work.

Default startup must not:
- list every task in every registered project;
- load all task descriptions, child trees, executions, artifacts, or event history;
- read all project repositories' governance and knowledge files;
- recursively expand all descendants;
- replay or request prior ChatGPT conversation history.

## Select and execute work

1. Use the selected branch's attention index and current objective to choose one bounded next action. A task queue is not the whole engineering context tree.
2. When executable work is needed, resolve the selected project's actual UUID and its own active Worker route from live Supabase data. Never reuse a Worker UUID across projects.
3. Query only that project's relevant task slice. Use existing project-scoped RPCs and atomic `claim_task`; the atomic response is authoritative. Do not claim a task from a stale listing.
4. Read the claimed task and only its necessary execution context. Determine repository routing from the live project row, not from guessed names or task text alone.
5. If work is too large, create child execution tasks only at real ownership, interface, dependency, or validation boundaries. Link them to the parent using the existing `parent_task_id`; do not create children merely to simulate multiple agents.
6. If no eligible task exists in the selected branch, follow `docs/AUTONOMOUS-TASK-DISCOVERY.md` within that project's local activation policy. Discovery is performed during this live session, not in the background.
7. Execute, test, and persist truthful evidence. A task lease is a bounded lock, not a session identity or a background heartbeat.
8. For PRs requiring independent review, prepare and persist the review handoff. A separate-context reviewer is independent only if a genuinely separate GPT session actually receives the assignment. A Worker row, role label, or second reasoning pass in the same conversation is not proof of independence. Do not claim dispatch or merge if the required independent context is unavailable.
9. Continue with the next relevant branch while the current conversation has capacity. Do not spend the context budget loading unrelated branches.

## Responsibilities, not fixed session identities

The current GPT conversation may perform coordination, implementation, research, testing, or review responsibilities as required by the selected work and its authorization. There is no mandatory role declaration at startup and no requirement to label the entire conversation as Coordinator, Worker, or Reviewer.

A responsibility switch does not create a new model instance or independent review context. When repository governance requires a genuinely independent reviewer, persist a complete handoff and leave the review pending until a real separate context can receive it. Never impersonate that context.

## Tree navigation and lifecycle

- The RAE global root is `knowledge/rae-root/index.json`.
- Each project's knowledge tree is stored in that project's own repository at `knowledge/rae-tree/index.json`.
- Node records live under `knowledge/rae-tree/nodes/`; checkpoints live under `knowledge/rae-tree/checkpoints/`.
- Knowledge nodes and Supabase executable tasks are related but distinct. The knowledge tree stores durable context; Supabase `tasks.parent_task_id` stores execution hierarchy and task lifecycle.
- A child publishes a bounded status/summary, evidence references, blockers, and next-review hint to its parent. Propagate only the changed summary along the ancestor path.
- Dormant branches are revalidated when their review time is due, dependencies/evidence change, the Owner's objective intersects them, or a parent requests attention. Inactivity alone never authorizes deletion or invalidation.
- Archive completed/obsolete context by removing it from default loading while preserving its decisions, evidence, task references, and history.

See `docs/RECURSIVE-ENGINEERING-TREE.md` for the complete node contract, recursive growth, lazy loading, wake-up, compaction, and migration rules.

## Checkpoint and continuation

Before ending the conversation, or when context capacity is becoming constrained, persist a checkpoint in the selected project's repository. Include:
- selected project and full node path;
- current task/execution IDs and task lease expiry, if applicable;
- branch, pinned base SHA, current head/commit SHA, PR URL, and changed paths;
- work completed and exact validation evidence;
- current state, blockers, unresolved decisions, and next concrete action;
- exact files/nodes a fresh session must load next.

Update the selected node and its ancestors with concise summaries and the root attention index when the global next-work pointer changes. The checkpoint is a continuation packet, not a chat transcript.

## Project governance and source of truth

- Supabase is authoritative for project registration, project-scoped task state, leases, execution history, artifacts, and task events.
- GitHub is authoritative for repository content, project knowledge, governance, Issues, PRs, commits, and CI.
- Resolve the repository from the selected active Supabase project row.
- Validate the repository's root `rae-governance.json` and read every declared file at the same pinned SHA.
- Apply the target repository's own activation, design, validation, review, merge, and release rules. RAE platform security, Owner authorization, RLS, project isolation, execution fencing, and branch protection remain non-overridable.
- Missing, incompatible, stale, or contradictory governance blocks only the affected branch; continue independent safe work where possible.
- Never store secrets in tasks, config, commits, knowledge nodes, checkpoints, or prompts.
- Never mark a task complete based only on source inspection. Distinguish source review, executed tests, and exact-head CI evidence.

## Owner interaction boundary

The Owner supplies initial goals, constraints, connected access, and genuine product/architecture decisions. The Owner is not expected to dispatch workers, prepare task breakdowns/context packs, relay prompts, monitor leases, manage routine PRs, or manually repair the tree. Ask only when a concrete decision, permission, or external input is genuinely unavailable from existing records and authorized tools.

Do not claim background execution between manually started GPT conversations. Persist state and resume at the next session.
