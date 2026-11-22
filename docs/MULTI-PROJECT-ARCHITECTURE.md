# Multi-Project Execution Architecture

## Purpose

Turn Recursive AI Engineering (RAE) into a multi-project task execution platform. The first registered external project is Colony Sim. A project owner should be able to open one ChatGPT conversation, state an engineering objective and target project, and let that conversation coordinate the work without requiring the owner to prepare task packs, copy prompts between sessions, or manually relay implementation context.

## Responsibilities and sources of truth

| Concern | Authority |
|---|---|
| Cross-project orchestration, decomposition, task leases, execution history | RAE + Supabase |
| Project code, technical rules, design decisions, Issues, branches, PRs, CI | The target GitHub repository |
| Product/game design approval | Colony Sim product owner |\n| Engineering PR review and merge | AI project coordinator after independent review and exact-head validation |
| Durable task execution state | Supabase task pool |
| Durable code and reviewable delivery | GitHub commits and PRs |

RAE does not absorb or replace a project's repository, issue tracker, governance, tests, or approval process. It coordinates execution across repositories.

## Existing database model

The current schema already scopes `projects`, `workers`, `tasks`, `executions`, `artifacts`, `task_events`, and `operation_requests` by `project_id`. The task lifecycle RPCs accept a project ID and worker ID. Multi-project onboarding therefore uses the existing project boundary rather than introducing a second task system or duplicating task tables.

Each registered project has:
- One `public.projects` row with its canonical repository and project-specific configuration.
- One active `shared-executor` worker row in that project. This is a stable database routing record, not a ChatGPT session identity.
- Tasks created and claimed only within that project ID.
- Project-specific rules and GitHub metadata carried in the task's JSON requirements and result/artifact records.

Do not share a Worker UUID across projects. The stable worker key may be the same; the worker row and UUID are project-scoped.

## Project configuration contract

Use `public.projects.github_repo` as the canonical `owner/repository` identifier. Store the following in `public.projects.config`:

```json
{
  "execution_mode": "single_owner_shared_executor",
  "session_identity_tracking": false,
  "project_key": "colony-sim",
  "default_branch": "main",
  "governance": {
    "agent_instructions": "AGENTS.md",
    "ai_entrypoint": "docs/ai/AI_START_HERE.md",
    "web_workflow": "docs/ai/WEB_GITHUB_WORKFLOW.md",
    "issue_dispatch": "docs/ai/ISSUE_BASED_WORKER_DISPATCH.md",
    "product_decisions": "docs/ai/DECISIONS.md",
    "project_state": "docs/ai/PROJECT_STATE.md"
  },
  "task_source": "github_issues",
  "task_activation": "explicit_owner_authorization_only",
  "delivery": "pull_request",
  "merge_authority": "ai_coordinator_after_review"
}
```

Never store credentials, access tokens, database passwords, or privileged connection strings in project config, task requirements, GitHub, or prompts.

## Task metadata contract

Keep the existing task schema stable. Put repository-specific task context in the existing `requirements` JSONB field:

```json
{
  "target": {
    "repository": "Love-DC/colony-sim",
    "issue_number": 123,
    "issue_url": "https://github.com/Love-DC/colony-sim/issues/123",
    "base_branch": "main",
    "base_sha": "<full immutable commit SHA>",
    "worker_branch": "ai/123-short-slug"
  },
  "decision_gate": "engineering_only",
  "owner_authorization": "direct_request | exact_issue_dispatch",
  "allowed_paths": [],
  "excluded_scope": [],
  "dependencies": [],
  "acceptance_criteria": [],
  "validation": [],
  "handoff": "one pull request; do not merge"
}
```

The exact shape may add task-specific fields, but must never weaken project governance. Record actual PR URL, branch, head SHA, commit SHA, changed paths, test evidence, and blockers in the execution result and/or artifacts.

## Colony Sim governance adapter

Every Colony Sim task must load and follow the target repository's current rules at its pinned base SHA. At minimum, inspect `AGENTS.md`, `docs/ai/AI_START_HERE.md`, and `docs/ai/WEB_GITHUB_WORKFLOW.md`; coordinators also read the dispatch and development protocol documents required by those entry points.

Hard boundaries:
- The product owner retains all game-design and player-experience decisions.
- A direct engineering request authorizes the current coordinator conversation to investigate, decompose, and execute within approved scope.
- Worker conversations require a direct coordinator dispatch or an exact Issue with a valid READY activation record, plus the owner's naming of that exact Issue in the Worker conversation.
- Open Issues are backlog, not permission. Never bulk-import or auto-claim the backlog.
- Workers use isolated task branches and deliver PRs. Workers do not merge.
- The product owner retains final merge approval.
- Web sessions validate through GitHub Actions on the exact PR head SHA. Do not claim local Godot commands ran.
- Stop and request a product decision when the correct player-facing behaviour is not already approved.

## Shared task-pool semantics

The user-facing workflow is project-agnostic. A new conversation does not receive a project name or a bespoke objective; it inspects every active registered project's queue. The logical shared pool is the union of project-scoped queues, not a cross-project table that erases ownership boundaries. For each project, the coordinator resolves that project's own active `shared-executor` Worker and calls `list_tasks`/`claim_task` with the matching project and Worker IDs. The claimed task's `project_id` determines repository routing. Atomic claim is authoritative; never infer claim success from a prior queue listing. If a project's queue is empty, run the authorized evidence-based discovery loop in docs/AUTONOMOUS-TASK-DISCOVERY.md. A candidate may be written only to that same project's queue after deduplication and authority checks. If no candidate qualifies, report an empty queue. Never create work from an unapproved Issue or invent a task.

## Autonomous task discovery

Workers inspect their authorized project's code, docs, tests, CI, and read-only operational signals when no eligible work is queued. Findings must include durable evidence, impact, risk, acceptance criteria, validation, and a stable project-scoped deduplication fingerprint. Only findings permitted by the project's task_activation policy may be created as executable tasks. Colony Sim remains explicit_owner_authorization_only; an open Issue is backlog, never authorization. See docs/AUTONOMOUS-TASK-DISCOVERY.md for the candidate contract, noise limits, authority matrix, and pilot limitations.

## Session routing and execution

1. Read the RAE session entry point and inspect registered projects in Supabase.
2. Resolve the user's named target project to exactly one active project record. If the target is omitted and the objective does not identify one unambiguously, ask one short clarification.
3. Read that project's GitHub governance entry points at the current base SHA.
4. For a direct owner objective, create a root task in the target project's task pool. Decompose only at real responsibility, ownership, interface, or validation boundaries.
5. Execute the root task in the current coordinator conversation by default. Additional conversations are optional, not required.
6. Claim and complete tasks using the target project's worker UUID and project UUID. Never use the RAE project/worker IDs for a different repository.
7. Commit to a task branch and open a PR in the target repository. The AI coordinator reviews and merges engineering-only PRs after all checks pass; escalate only product/design or explicitly high-risk decisions.
8. Persist task results and GitHub references in Supabase, then report the PR, exact head SHA, actual CI evidence, and any remaining owner decisions.

## Explicit limitations

- RAE cannot open or launch another ChatGPT conversation. The default workflow therefore uses one coordinator conversation and performs work there; optional workers require the owner to open additional conversations.
- Supabase task records do not themselves grant product approval or authorize an Issue. The owner request and project-specific dispatch protocol remain the authority.
- A green CI result proves only the jobs and steps that actually ran on the exact commit.
