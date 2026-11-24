# Multi-Project Execution Architecture

## Purpose

Turn Recursive AI Engineering (RAE) into a multi-project task execution platform. The first registered external project is Colony Sim. The Owner may start multiple GPT conversations and run them concurrently. Every conversation uses the same startup contract and discovers work from shared project-scoped Supabase state; no permanent Coordinator, fixed session identity, prompt relay, or manual task dispatch is required.

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

The user-facing workflow is a shared protocol used by all active conversations. At startup, each conversation queries live active `public.projects` rows and inspects each active project's compact task queue with the existing project-scoped `list_tasks` RPC. The logical shared pool is the union of these queues, not an unscoped cross-project table. This first pass compares eligibility, status, priority, dependencies, lease state, task type and required Worker route; it does not load every task description, execution, artifact or event history. After selecting a candidate, the conversation resolves the Worker from that same project's active Worker rows and routing metadata, then atomically claims using the exact project and Worker UUIDs. The claim response is authoritative. Only after a successful claim does it load full task details, pin the target repository SHA, and expand the selected knowledge-tree branch. The tree is a context-navigation aid, not the project registry, initiative/task ledger, dependency engine, lease store or execution history. If a project's queue has no eligible work, run its authorized evidence-based discovery loop under that repository's activation policy. Never create work from an unapproved Issue or invent a task.

## Autonomous task discovery

Workers inspect their authorized project's code, docs, tests, CI, and read-only operational signals when no eligible work is queued. Findings must include durable evidence, impact, risk, acceptance criteria, validation, and a stable project-scoped deduplication fingerprint. Only findings permitted by the target repository's local activation policy may be created as executable tasks. An open Issue is backlog, never authorization unless the repository's own rules define a valid activation path. See docs/AUTONOMOUS-TASK-DISCOVERY.md for the candidate contract, noise limits, authority matrix, and pilot limitations.

## Session routing and execution

1. Read the common RAE entrypoint and platform security rules.
2. Inspect the active project registry and each active project's compact, project-scoped task queue. Treat their union as the logical shared pool; do not load full task history.
3. Select eligible work using persisted priority, dependencies, status, leases, task authorization and each repository's activation policy.
4. Resolve an active Worker route within the selected project's own UUID boundary. Validate route/dependency safety, then call atomic `claim_task` with the exact project and Worker UUIDs.
5. After claim succeeds, load the full task/execution context and resolve the canonical repository from the live project row.
6. Pin the authorized base SHA; load the repository manifest and every declared governance file at that exact SHA. Then load only the selected project's relevant tree index, node, ancestors and explicit dependencies.
7. For a direct Owner goal or an AI-originated initiative, persist the durable goal/proposal and executable tasks in the shared coordination system according to the initiative and task lifecycle; do not treat a knowledge node as an executable task.
8. Execute only the claimed task. Decompose only at real ownership, interface, dependency, or validation boundaries. Use unique task branches and execution fencing.
9. Open a PR and follow the repository's independent-review and merge policy. A genuinely separate GPT context is required whenever that policy requires independent review; a role label or Worker row does not prove independence.
10. Persist execution evidence, checkpoints and bounded durable context updates. Verify exact PR/merge SHAs and post-merge CI before reporting acceptance.

## Explicit limitations

- RAE cannot open or launch another ChatGPT conversation. The Owner/platform starts conversations; RAE supports multiple conversations running concurrently through shared project-scoped state and atomic claims. No background progress is implied.
- Supabase task records do not themselves grant product approval or authorize an Issue. The owner request and project-specific dispatch protocol remain the authority.
- A green CI result proves only the jobs and steps that actually ran on the exact commit.


## Recursive context tree and concurrent-session runtime (authoritative)

The platform's context/navigation architecture is defined by [Recursive Engineering Tree](RECURSIVE-ENGINEERING-TREE.md). The RAE global index lives at `knowledge/rae-root/index.json`; each project's durable knowledge tree belongs in that project's own repository at `knowledge/rae-tree/index.json`.

The Owner may start multiple GPT conversations and run them concurrently. All conversations coordinate through shared Supabase task/initiative/execution state and the owning repositories' formal engineering records. There is no permanent Coordinator or per-conversation identity. Coordinator, Worker, Reviewer, Researcher and Auditor describe responsibilities; a Worker row or role label is not proof of a separate GPT context. A genuinely independent review must be performed by a different conversation/context whenever the repository's review policy requires it.

The knowledge tree is a lazy context-navigation aid for repository-owned durable facts, technical context, decisions and evidence. It is not the live coordination message bus, session registry, initiative/task store, dependency engine, lease manager or execution history. Supabase remains authoritative for active goals/initiatives, project registration, task status, dependencies, leases, executions, events, artifacts and handoffs. GitHub remains authoritative for code, repository governance, formal decisions, Issues, PRs, commits and CI.

Startup inspects compact project-scoped queues across active registered projects, but loads full task details and tree descendants only for selected work. No daemon, scheduler or automatic GPT-session launcher is implied.
