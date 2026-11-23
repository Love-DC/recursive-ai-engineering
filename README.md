# Recursive AI Engineering (RAE)

A human–AI engineering collaboration ecosystem. The Owner provides goals, ideas, resources, and constraints; AI participants autonomously discover, organize, execute, and verify work across many temporary GPT conversations. Supabase coordinates shared work; GitHub preserves formal engineering outcomes and repository governance.

## Pilot operating model

- GPT conversations are disposable execution resources, not Worker identities; many may be started and run concurrently.
- All conversations use the user's already-authorized Supabase MCP connection.
- Each project has project-scoped Worker routing rows; worker keys can differ by repository and task type. A Worker row is a routing reference, not an individual session identity.
- Supabase stores project and task state. GitHub stores code, documents and commit history.
- Goals and AI-originated initiatives can be decomposed into bounded child tasks. Any fresh conversation can discover and claim eligible shared work.
- Review and merge requirements come from the target repository's governance. Where independent review is required, a separate GPT conversation/context performs it; no separate account or persistent Reviewer process is required.
- Autonomous discovery runs during an active Coordinator/Worker session. The shared MCP pilot does not depend on a deployed background daemon or scheduled job.

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

- [AI Collaboration Ecosystem](docs/AI-COLLABORATION-ECOSYSTEM.md): human/AI autonomy, many concurrent disposable sessions, shared-state coordination, AI initiatives, resource boundaries, and acceptance milestones.
- [Autonomous Task Discovery & Generation](docs/AUTONOMOUS-TASK-DISCOVERY.md): evidence-based discovery, project authorization, deduplication, and empty-queue behavior.
- [Session entry point](docs/SESSION-START.md): start any number of GPT conversations with the same generic entry instruction; each discovers shared state and selects suitable work.
- [Multi-project architecture](docs/MULTI-PROJECT-ARCHITECTURE.md): project boundaries, Supabase routing, and task metadata.
- [Repository-local governance protocol](docs/REPOSITORY-GOVERNANCE-PROTOCOL.md): pinned-SHA discovery, compatibility checks, conflict handling, and repository-owned CI routing.
- [Shared MCP Pilot Instructions](docs/WORKER-INSTRUCTIONS.md): Supabase task lifecycle and owner-MCP operating details.

The platform currently registers two projects: `recursive-ai-engineering` and `colony-sim` (`Love-DC/colony-sim`). Each has its own Supabase project row and project-scoped Worker routing records (the current pilot uses `shared-executor` for both; this is not a platform-wide requirement). Task state remains isolated by `project_id`; code, Issues, PRs, CI, and project governance remain in the target repository.

Before changing the system, review [Pilot Readiness and Deferred Production Gates](docs/REAL-PROJECT-READINESS.md) for the trusted-pilot boundary and outstanding expansion gates. The [Failure Reporting and Retry Contract](docs/FAILURE-RECOVERY-CONTRACT.md) documents the deployed RPCs, retry semantics, and verified production evidence.

## Not required for the pilot

- Per-session identity or Worker Auth accounts.
- Session heartbeats, presence dashboards or activity tracking.
- Separate Supabase Auth users or dedicated accounts for Coordinator/Implementer/Reviewer responsibilities.
- A permanent background Coordinator daemon or timer.
- Browser console deployment.

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
