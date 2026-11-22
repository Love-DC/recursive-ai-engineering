# Multi-Project Execution Architecture

## Purpose

Turn Recursive AI Engineering (RAE) into a multi-project task execution platform. The first registered external project is Colony Sim. A project owner should be able to open one ChatGPT conversation, state an engineering objective and target project, and let that conversation coordinate the work without requiring the owner to prepare task packs, copy prompts between sessions, or manually relay implementation context.

## Responsibilities and sources of truth

| Concern | Authority |
|---|---|
| Cross-project orchestration, decomposition, task leases, execution history | RAE + Supabase |
| Project code, technical rules, design decisions, Issues, branches, PRs, CI | The target GitHub repository |
| Product/game design approval | Colony Sim product owner |
| Engineering PR review and merge | AI project coordinator after independent review and exact-head validation |
| Durable task execution state | Supabase task pool |
| Durable code and reviewable delivery | GitHub commits and PRs |

RAE does not absorb or replace a project's repository, issue tracker, governance, tests, or approval process. It coordinates execution across repositories.

## Existing database model

The current schema already scopes `projects`, `workers`, `tasks`, `executions`, `artifacts`, `task_events`, and `operation_requests` by `project_id`. The task lifecycle RPCs accept a project ID and worker ID. Multi-project onboarding therefore uses the existing project boundary rather than introducing a second task system or duplicating task tables.

Each registered project has:
- One `public.projects` row with its canonical repository and project-specific configuration.
- One or more active Worker rows in that project. Worker keys and routing may differ by project and task type; a Worker UUID is a project-scoped routing identifier, not a ChatGPT session identity.
- Tasks created and claimed only within that project ID.
- Project-specific rules and GitHub metadata carried in the task's JSON requirements and result/artifact records.

Do not share a Worker UUID across projects. The stable worker key may be the same; the worker row and UUID are project-scoped.

## Project configuration contract

Use `public.projects.github_repo` as the canonical `owner/repository` identifier. Supabase configuration is limited to routing and platform execution metadata, including optional per-project Worker routing, for example:

```json
{
  "project_key": "colony-sim",
  "default_branch": "main",
  "execution_mode": "single_owner_shared_executor",
  "session_identity_tracking": false,
  "worker_routing": {
    "default_worker_key": "shared-executor",
    "task_type_worker_keys": {}
  }
}
```

Do not store governance file paths, CI workflow names, review policy, task activation policy, product decisions, acceptance criteria, or release rules in Supabase. Those belong to the target repository's root `rae-governance.json` and its referenced files. During migration, legacy governance keys may be read only as a deprecated fallback; a valid repository manifest always takes precedence. Remove legacy keys only after the compatibility reader is deployed and all active repositories have passed manifest validation.

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

Worker routing is separate from engineering governance. `worker_routing.default_worker_key` and `worker_routing.task_type_worker_keys` may select active Worker rows within the same project. Different repositories may use different Worker keys and task-type mappings. If routing is absent, the Coordinator may use the only active Worker for that project; ambiguous routing blocks task claim.

## Repository-local governance discovery

Every target repository must publish a root `rae-governance.json`. Before planning or dispatching a task, the Coordinator pins the target repository SHA, discovers and validates that manifest, and reads all declared governance files at the same SHA. The manifest defines the repository's AI instructions, engineering standards, task authorization rules, review process, CI provider/workflow, and acceptance entrypoints. RAE core must not branch on repository names or encode project-specific paths.

Missing manifests/files, incompatible protocol versions, conflicting rule declarations, semantic policy conflicts, or stale SHAs block execution. The Coordinator must report the exact source and ask the Owner when a conflict cannot be resolved by an explicit repository-local precedence rule. See [Repository-local governance discovery protocol](REPOSITORY-GOVERNANCE-PROTOCOL.md).

The Colony Sim manifest identifies `Love-DC/colony-sim-ci` as an independent validation repository. Its workflow is not a Colony Sim subdirectory and must be invoked only through its documented exact-HEAD trigger. Product-owner authority, explicit Worker dispatch, and independent Coordinator review remain enforced by Colony Sim's own repository documents.

## Shared task-pool semantics

The user-facing workflow is project-agnostic. A new conversation does not receive a project name or a bespoke objective; it inspects every active registered project's queue. The logical shared pool is the union of project-scoped queues, not a cross-project table that erases ownership boundaries. For each project, the coordinator resolves an active Worker using that project's Worker routing metadata and the task's requirements, then calls `list_tasks`/`claim_task` with the matching project and Worker IDs. The claimed task's `project_id` determines repository routing. Atomic claim is authoritative; never infer claim success from a prior queue listing. If a project's queue is empty, run the authorized evidence-based discovery loop in docs/AUTONOMOUS-TASK-DISCOVERY.md. A candidate may be written only to that same project's queue after deduplication and authority checks. If no candidate qualifies, report an empty queue. Never create work from an unapproved Issue or invent a task.

## Autonomous task discovery

Workers inspect their authorized project's code, docs, tests, CI, and read-only operational signals when no eligible work is queued. Findings must include durable evidence, impact, risk, acceptance criteria, validation, and a stable project-scoped deduplication fingerprint. Only findings permitted by the target repository's local activation policy may be created as executable tasks. An open Issue is backlog, never authorization unless the repository's own rules define a valid activation path. See docs/AUTONOMOUS-TASK-DISCOVERY.md for the candidate contract, noise limits, authority matrix, and pilot limitations.

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
