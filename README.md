# AI Worker Collaboration System — Shared MCP Pilot

A shared-state recursive engineering system: multiple GPT conversations may run concurrently, using Supabase/PostgreSQL for project-scoped goals, initiatives, task queues, dependencies, leases, executions and handoffs, while GitHub repositories preserve source code, governance, decisions, PRs and CI. Each conversation is temporary; no permanent Coordinator or session identity is required.

## Pilot operating model

- A conversation is disposable and is not tracked as a Worker identity.
- All conversations use the user's already-authorized Supabase MCP connection.
- Each project has project-scoped Worker routing rows; worker keys can differ by repository and task type. A Worker row is a routing reference, not an individual session identity.
- Supabase stores project and task state. GitHub stores code, documents and commit history.
- Large work can grow recursively through repository-local knowledge nodes and, when execution is required, project-scoped child tasks.
- A fresh GPT conversation inspects compact project-scoped queues across active projects, then loads only the selected task and its relevant context. The recursive tree provides lazy navigation, not a substitute for shared task discovery or execution state.
- Roles such as Coordinator, Worker and Reviewer are responsibilities, not fixed session identities or guaranteed separate agents.
- Discovery and repair run only during an active manually started GPT conversation; no daemon or scheduled job is assumed.

## Current pilot setup

- Supabase project: `recursive-ai-engineering` (PostgreSQL 17, ap-northeast-1).
- Supabase MCP project ref: `rgztxilqcfuclkekyojl`.
- Database `public.projects.id`: `61e32c05-39b7-47a6-ab5c-592c8e37d72d`.
- Shared Worker ID: `78953b49-db9d-4fbc-9d3c-be3421a1c975`.
- GitHub repository: `Love-DC/recursive-ai-engineering`.
- Seven core tables and 22 public RPCs are deployed.
- The create → claim → complete RPC smoke test passed using the shared Worker and was rolled back.
- The failure → owner requeue → retry claim → complete transaction smoke test also passed and was rolled back; no smoke-test task remains in the queue.
- The deployed failure/retry migration is recorded as `20261122221942_failure_reporting_retry`; see [Failure Reporting and Retry Contract](docs/FAILURE-RECOVERY-CONTRACT.md) for production behavior and evidence.
- The first formal root task (`dedafaf5-6abb-4d66-9c0d-7622cebfcb2f`) has been created and claimed; three bounded child tasks were created and completed in the initial execution run.
- The task lifecycle and owner-MCP SQL examples are documented in `docs/WORKER-INSTRUCTIONS.md`; query Supabase for live task state.

## Start here

- [Recursive Engineering Tree](docs/RECURSIVE-ENGINEERING-TREE.md): recursive context growth, lazy loading, bounded summaries, branch wake-up, and cross-session checkpoints.
- [RAE global root index](knowledge/rae-root/index.json): compact project pointers and global attention queue.
- [Autonomous Task Discovery & Generation](docs/AUTONOMOUS-TASK-DISCOVERY.md): evidence-based discovery, project authorization, deduplication, and empty-queue behavior.
- [Session entry point](docs/SESSION-START.md): every conversation uses the same generic startup protocol, discovers active project-scoped queues, claims eligible work atomically, and loads only the selected branch context.
- [Multi-project architecture](docs/MULTI-PROJECT-ARCHITECTURE.md): project boundaries, Supabase routing, and task metadata.
- [Repository-local governance protocol](docs/REPOSITORY-GOVERNANCE-PROTOCOL.md): pinned-SHA discovery, compatibility checks, conflict handling, and repository-owned CI routing.
- [Shared MCP Pilot Instructions](docs/WORKER-INSTRUCTIONS.md): Supabase task lifecycle and owner-MCP operating details.

The platform currently registers two projects: `recursive-ai-engineering` and `colony-sim` (`Love-DC/colony-sim`). Each has its own Supabase project row and project-scoped Worker routing records (the current pilot uses `shared-executor` for both; this is not a platform-wide requirement). Task state remains isolated by `project_id`; code, Issues, PRs, CI, and project governance remain in the target repository.

Before changing the system, review [Pilot Readiness and Deferred Production Gates](docs/REAL-PROJECT-READINESS.md) for the trusted-pilot boundary and outstanding expansion gates. The [Failure Reporting and Retry Contract](docs/FAILURE-RECOVERY-CONTRACT.md) documents the deployed RPCs, retry semantics, and verified production evidence.

## Not required for the pilot

- Per-session identity or Worker Auth accounts.
- Session heartbeats, presence dashboards or activity tracking.
- Separate Coordinator/Implementer/Reviewer/Fixer accounts.
- Browser console deployment.
- Automated review/fix orchestration.
- A persistent background Coordinator daemon or timer.
- A fixed Coordinator identity or one-conversation-at-a-time operating constraint.

The Owner console remains available for later use, but the pilot can be operated directly through the connected Supabase MCP and GitHub MCP tools.

## Production hardening deferred

The existing v1.2 database includes identity-isolation and review/fix machinery. Those features are not prerequisites for the shared-owner MCP pilot. Before exposing the system to untrusted users or non-owner clients, separately review RPC authorization, Auth configuration, backup/restore, and independent-identity testing.

## Security boundary

The pilot supports multiple Owner-started conversations using the already-authorized Supabase MCP access. Shared project-scoped task queues and atomic claims coordinate concurrent work; that connected access is the trust boundary. Do not copy Service Role keys, secret keys, database passwords, or privileged connection strings into prompts, GitHub files, or external clients. Do not deploy production systems or perform high-impact external side effects without explicit authorization. Routine engineering PR review/merge is covered by the standing owner authorization and coordinator checklist.

## Verification

- Task lifecycle integration coverage: [docs/TASK-LIFECYCLE-TESTING.md](docs/TASK-LIFECYCLE-TESTING.md)
- Credential-free shell static checks: [.github/workflows/shell-static-checks.yml](.github/workflows/shell-static-checks.yml)
- Fresh-conversation handoff acceptance: [docs/FRESH-SESSION-HANDOFF-ACCEPTANCE.md](docs/FRESH-SESSION-HANDOFF-ACCEPTANCE.md)
- Two-connection claim race harness: [scripts/test-claim-concurrency.sh](scripts/test-claim-concurrency.sh)
- Transactional task lifecycle harness: [scripts/test-task-lifecycle.sh](scripts/test-task-lifecycle.sh)
