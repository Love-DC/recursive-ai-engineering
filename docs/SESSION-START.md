# Session Start — Recursive AI Engineering

Use this entry point at the start of every new RAE conversation. The conversation is a temporary coordinator/executor, not a persistent Worker identity.

## Initial instruction

Copy this short instruction into a new ChatGPT conversation:

> Act as the Recursive AI Engineering coordinator. My objective is: **[describe the work]**. Target project: **[colony-sim | recursive-ai-engineering | another registered project]**. Read `docs/SESSION-START.md` and `docs/MULTI-PROJECT-ARCHITECTURE.md`, resolve the target project's live Supabase project/worker records, load that repository's governance rules, then plan and execute the objective within its approval boundaries. Do not ask me to prepare Context Packs, create technical task breakdowns, or relay prompts. Ask only for a genuine product decision or missing access/asset/input. Do not merge any PR.

For Colony Sim, you may shorten the target field to `colony-sim`; the repository mapping and governance are registered in Supabase and documented in the multi-project architecture.

## Required coordinator preflight

1. Read this document and `docs/MULTI-PROJECT-ARCHITECTURE.md`.
2. Query live `public.projects` records and find the active project by `project_key`, canonical GitHub repository, or an unambiguous project name. Do not assume a remembered UUID is current.
3. Resolve the active `shared-executor` worker belonging to that same project. Never use a worker from another project.
4. Read the target repository's `AGENTS.md` and its configured AI entry point. Follow the project's governance and web GitHub workflow at the pinned base SHA.
5. Confirm whether the request is an engineering-only task, an already-approved design implementation, or blocked pending a product decision.
6. Create and execute the task in the selected project's task pool. Keep all task and execution RPC calls scoped to that project's IDs.
7. Use a unique task branch from a pinned base SHA; create/update files only on that branch; inspect the resulting diff; open a PR; do not merge.
8. Persist the execution result and GitHub artifacts in Supabase. Report the PR URL, branch, exact head SHA, changed paths, tests and exact-head CI evidence, and remaining blockers.

## Colony Sim quick reference

- Repository: `Love-DC/colony-sim`
- Default branch: `main`
- Governance: `AGENTS.md`, `docs/ai/AI_START_HERE.md`, `docs/ai/DEVELOPMENT_PROTOCOL.md`, `docs/ai/WEB_GITHUB_WORKFLOW.md`, and `docs/ai/ISSUE_BASED_WORKER_DISPATCH.md`.
- Product decisions belong to the product owner.
- A direct owner request authorizes the current coordinator to execute bounded engineering work; it does not authorize unapproved gameplay/design decisions.
- Do not select work from the Issues backlog. Only create/import a task when the owner directly requests it or explicitly authorizes the exact Issue dispatch.
- Workers do not merge. The owner approves merges.
- For web sessions, GitHub Actions is the execution environment for automated validation; inspect the run attached to the exact PR head SHA.

## Task pool rules

- Supabase is the source of truth for task state, leases, execution history, and task events.
- GitHub is the source of truth for repository content, Issues, PRs, commits, and CI.
- Use the existing `create_task`, `claim_task`, `complete_execution`, and child-task RPCs with the selected project's ID and its project-scoped worker ID.
- Do not add session identities, heartbeats, or per-conversation Worker records.
- Do not store secrets in tasks, config, commits, or prompts.
- Never mark a task complete based only on source inspection; distinguish source review from executed tests and exact-head CI evidence.
