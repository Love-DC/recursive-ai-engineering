# Session Start — Recursive AI Engineering

Use this entry point at the start of every new RAE conversation. Every conversation is a temporary coordinator/executor, not a persistent Worker identity.

## Universal initial instruction

Copy this instruction into every new ChatGPT conversation. It is deliberately project-agnostic:

> Act as a Recursive AI Engineering shared-task-pool Worker. Read `docs/SESSION-START.md`, `docs/MULTI-PROJECT-ARCHITECTURE.md`, `docs/WORKER-INSTRUCTIONS.md`, and `docs/AUTONOMOUS-TASK-DISCOVERY.md`. Inspect all active registered projects and their project-scoped task queues in Supabase. Find an eligible unclaimed task, identify its project from the task's `project_id`, resolve that project's own active `shared-executor` Worker, and claim the task atomically. Then load the target repository's governance instructions and execute only the authorized task scope. Do not ask me to specify a project, prepare a Context Pack, decompose the task, or relay prompts. If no eligible task exists, run the authorized evidence-based discovery procedure in docs/AUTONOMOUS-TASK-DISCOVERY.md and create only policy-permitted, deduplicated tasks in that same project queue. Report an empty pool only after discovery finds no defensible candidate. Persist execution evidence and deliver a PR when required. The AI coordinator independently reviews and merges eligible engineering PRs under the repository review policy; workers do not merge their own leaf PRs. Ask me only when an explicit owner/product decision, missing authorization, or essential input blocks safe execution.

No per-session project selection or task objective is required. The task record is the source of the execution objective and project routing.

## Required task-pool workflow

1. Read this document, `docs/MULTI-PROJECT-ARCHITECTURE.md`, and `docs/WORKER-INSTRUCTIONS.md`.
2. Query live active rows from `public.projects`. For each project, resolve its active `shared-executor` Worker using that same `project_id`. Never reuse a Worker UUID across projects.
3. Inspect each active project's task queue using the existing `list_tasks` RPC, scoped to that project's UUID. Treat the union of these project-scoped queues as the logical shared task pool; do not assume there is one global unscoped queue.
4. Select only tasks that are eligible under their persisted status, dependencies, authorization, and project governance. Do not bypass priority, lease, or approval constraints. Claim using `claim_task` with the exact project UUID and its own Worker UUID; the atomic claim response is authoritative. If a claim loses a race or returns no task, continue to another eligible project/task.
5. Once claimed, read the task and execution context. Determine the target repository from the task's project record, not from a user-supplied project name or guessed metadata.
6. Load the target repository's `AGENTS.md` and configured AI entry point and workflow documents at the task's pinned base SHA. Apply the project's own task authorization, design approval, coding, test, and delivery rules.
7. Execute only the claimed task. If it is too large, use the project's supported child-task mechanism and preserve parent/child dependency semantics. Do not create unrelated work.
8. Use a unique task branch from the pinned base SHA. Inspect the final diff, run validations, and open/update a PR when required. The AI coordinator performs a separate integration review and merges only after the merge checklist passes.
9. Persist execution result, commit/PR references, exact head SHA, changed paths, validation evidence, and blockers using the task's project-scoped execution APIs. Complete only after verifying the current execution fence and recording truthful evidence.
10. If no eligible task exists in a project, run the authorized discovery procedure. Create only evidence-backed, deduplicated tasks permitted by that project's activation policy; if none qualify, report the empty queue and what was inspected. Never bulk-import or auto-claim an unapproved Issue.

## Autonomous discovery

When a project queue has no eligible task, follow [Autonomous Task Discovery & Generation](AUTONOMOUS-TASK-DISCOVERY.md). Discovery is a Worker responsibility during a live session; it is not a background scheduler. The project's activation policy is authoritative.

## Project-specific governance

Project routing is automatic; project governance is not flattened into one generic policy. Always load and obey the selected project's current repository instructions.

### Colony Sim

- Repository: `Love-DC/colony-sim`; default branch: `main`.
- Read `AGENTS.md`, `docs/ai/AI_START_HERE.md`, `docs/ai/DEVELOPMENT_PROTOCOL.md`, `docs/ai/WEB_GITHUB_WORKFLOW.md`, and `docs/ai/ISSUE_BASED_WORKER_DISPATCH.md` as applicable.
- Product decisions belong to the product owner.
- An open Issue is backlog, not authorization. Colony Sim work must already have been explicitly authorized and represented by an eligible task/dispatch. Never bulk-import or auto-claim Issues.
- Workers deliver PRs and do not merge their own leaf work. The AI coordinator independently reviews and merges engineering-only PRs when the review and CI gates pass. The product owner retains product/design decisions, not routine engineering PR approval.
- For web sessions, GitHub Actions is the execution environment for automated validation; inspect the run attached to the exact PR head SHA. Do not claim local Godot commands ran if they did not.

## Task pool and source-of-truth rules

- Supabase is the source of truth for project registration, task status, leases, execution history, and task events.
- GitHub is the source of truth for repository content, Issues, PRs, commits, and CI.
- Existing task lifecycle RPCs are project-scoped. Every create/claim/complete/child-task call must use the selected task's actual project UUID and its corresponding Worker UUID.
- Do not add session identities, heartbeats, or per-conversation Worker records.
- Do not store secrets in tasks, config, commits, or prompts.
- Never mark a task complete based only on source inspection; distinguish source review from executed tests and exact-head CI evidence.
- A logical shared pool is the aggregation of eligible tasks across registered project queues; it does not mean tasks or Worker identities are shared across project boundaries.
