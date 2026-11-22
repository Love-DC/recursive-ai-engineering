# AI Worker Collaboration System — Shared MCP Pilot

A Supabase/PostgreSQL-backed shared task pool for short-lived ChatGPT conversations, with GitHub as the durable code and documentation store.

## Pilot operating model

- A conversation is disposable and is not tracked as a Worker identity.
- All conversations use the user's already-authorized Supabase MCP connection.
- One stable `shared-executor` Worker row is used as a database routing reference; it does not identify individual sessions.
- Supabase stores project and task state. GitHub stores code, documents and commit history.
- Large tasks can be decomposed into child tasks. Any fresh conversation can claim the next available task.
- Pilot implementation tasks use `requires_review=false`; the separate Reviewer/Fixer workflow is not a startup requirement.

## Current pilot setup

- Supabase project: `recursive-ai-engineering` (PostgreSQL 17, ap-northeast-1).
- Supabase MCP project ref: `rgztxilqcfuclkekyojl`.
- Database `public.projects.id`: `61e32c05-39b7-47a6-ab5c-592c8e37d72d`.
- Shared Worker ID: `78953b49-db9d-4fbc-9d3c-be3421a1c975`.
- GitHub repository: `Love-DC/recursive-ai-engineering`.
- Seven core tables and 20 public RPCs are deployed.
- The create → claim → complete RPC smoke test passed using the shared Worker and was rolled back.
- The first formal root task (`dedafaf5-6abb-4d66-9c0d-7622cebfcb2f`) has been created and claimed; three bounded child tasks were created and completed in the initial execution run.
- The task lifecycle and owner-MCP SQL examples are documented in `docs/WORKER-INSTRUCTIONS.md`; query Supabase for live task state.

## Start here

- [Autonomous Task Discovery & Generation](docs/AUTONOMOUS-TASK-DISCOVERY.md): evidence-based discovery, project authorization, deduplication, and empty-queue behavior.

- [One-message session entry point](docs/SESSION-START.md): open one ChatGPT conversation, state the objective and target project, and let the coordinator route and execute it.
- [Multi-project architecture](docs/MULTI-PROJECT-ARCHITECTURE.md): project boundaries, Supabase routing, task metadata, and governance adapters.
- [Shared MCP Pilot Instructions](docs/WORKER-INSTRUCTIONS.md): Supabase task lifecycle and owner-MCP operating details.

The platform currently registers two projects: `recursive-ai-engineering` and `colony-sim` (`Love-DC/colony-sim`). Each has its own Supabase project row and project-scoped `shared-executor` worker. Task state remains isolated by `project_id`; code, Issues, PRs, CI, and project governance remain in the target repository.

Before changing the system, review [Pilot Readiness and Deferred Production Gates](docs/REAL-PROJECT-READINESS.md) for the trusted-pilot boundary and outstanding expansion gates. The [Failure Reporting and Retry Contract](docs/FAILURE-RECOVERY-CONTRACT.md) records the current missing failure/requeue API and its proposed safe semantics; it is a design contract, not a deployed feature.

## Not required for the pilot

- Per-session identity or Worker Auth accounts.
- Session heartbeats, presence dashboards or activity tracking.
- Separate Coordinator/Implementer/Reviewer/Fixer accounts.
- Browser console deployment.
- Automated review/fix orchestration.

The Owner console remains available for later use, but the pilot can be operated directly through the connected Supabase MCP and GitHub MCP tools.

## Production hardening deferred

The existing v1.2 database includes identity-isolation and review/fix machinery. Those features are not prerequisites for the shared-owner MCP pilot. Before exposing the system to untrusted users or non-owner clients, separately review RPC authorization, Auth configuration, backup/restore, and independent-identity testing.

## Security boundary

The pilot assumes every participating ChatGPT conversation has the user's authorized Supabase MCP access. That access is the trust boundary. Do not copy Service Role keys, secret keys, database passwords, or privileged connection strings into prompts, GitHub files, or external clients. Do not deploy production systems or perform high-impact external side effects without explicit authorization. Routine engineering PR review/merge is covered by the standing owner authorization and coordinator checklist.

## Verification

- Task lifecycle integration coverage: [docs/TASK-LIFECYCLE-TESTING.md](docs/TASK-LIFECYCLE-TESTING.md)
- Credential-free shell static checks: [.github/workflows/shell-static-checks.yml](.github/workflows/shell-static-checks.yml)
- Fresh-conversation handoff acceptance: [docs/FRESH-SESSION-HANDOFF-ACCEPTANCE.md](docs/FRESH-SESSION-HANDOFF-ACCEPTANCE.md)
- Two-connection claim race harness: [scripts/test-claim-concurrency.sh](scripts/test-claim-concurrency.sh)
- Transactional task lifecycle harness: [scripts/test-task-lifecycle.sh](scripts/test-task-lifecycle.sh)
