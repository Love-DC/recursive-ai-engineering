# Recursive AI Engineering (RAE)

RAE is a lightweight, session-driven engineering coordinator for multiple GitHub repositories. Supabase stores project-scoped task and execution state; GitHub stores source code, governance, Issues, PRs and CI.

## Start here

For every new session, read only:

1. docs/SESSION-START.md — the canonical startup and safety contract.
2. The selected target repository's root rae-governance.json, plus files it declares at the same pinned commit.

Other RAE documents are operation-specific references. The session contract names exactly when to load them; routine sessions should not read the entire documentation set.

## Operating model

- A ChatGPT conversation is temporary. It is not a Worker identity and is not tracked as one.
- Existing project-scoped Worker rows are routing references, not people or session identities.
- Active sessions discover, claim, execute, test and hand off work through the existing project-scoped Supabase RPCs.
- GitHub is the durable delivery and review surface. Eligible routine engineering PRs are reviewed and merged by the Coordinator under repository policy.
- Discovery is session-driven. No persistent Coordinator daemon, scheduled Worker or background execution is implied.
- No second human account, Worker Auth account, session heartbeat, presence system or additional orchestration layer is required for this pilot.

## Registered project snapshot

Verified against Supabase on 2026-11-25. This is an informational snapshot, not live authorization; every session must query the current registry and project controls.

| Project | Repository | Execution state at snapshot |
|---|---|---|
| RAE | Love-DC/recursive-ai-engineering | Unpaused |
| Colony Sim | Love-DC/colony-sim | Unpaused |
| Hexa Game Kernel | Love-DC/Hexa-Game-Kernel | Unpaused |
| Lambent | Love-DC/Lambent | Paused |

Each project has its own UUID and Worker routes. Never reuse a Worker UUID across projects. Project-specific governance, CI and product/design authority remain in the target repository.

## Responsibility split

- Supabase: project registration, routing, task lifecycle, dependencies, leases, execution history, artifacts and audit events.
- Target GitHub repository: project-specific AI instructions, engineering rules, CI, review/release policy and acceptance criteria.
- RAE platform: global authorization, project isolation, task coordination and execution safety.
- Human Owner: product direction, game design, Initiative/resource decisions and pause/kill-switch controls.

## Useful references

Load these only when needed:

- docs/WORKER-INSTRUCTIONS.md — task lifecycle RPC and lease reference.
- docs/RAE-SYSTEM-OWNER.md — System Owner context and authority boundary.
- docs/PROBLEM-INBOX.md — evidence-backed issue intake and resolution.
- docs/AUTONOMOUS-TASK-DISCOVERY.md — task activation, empty-queue discovery and deduplication.
- docs/COORDINATOR-PR-REVIEW-AND-MERGE.md — independent review and merge checklist.
- docs/SECURITY-BOUNDARY-AUDIT.md — Auth, RLS, grants and database-exposure audit.
- docs/MULTI-PROJECT-ARCHITECTURE.md, docs/ADR-001-REPOSITORY-LOCAL-GOVERNANCE.md and docs/REPOSITORY-GOVERNANCE-PROTOCOL.md — project onboarding or cross-project governance changes.
- docs/TASK-LIFECYCLE-TESTING.md and docs/FAILURE-RECOVERY-CONTRACT.md — lifecycle/schema testing and retry semantics.

## Safety and verification

Do not copy secrets into prompts or repositories. Do not write task/execution/lease/event tables directly. Do not alter project controls, game design or production data through routine engineering authority. Verify the exact commit SHA tested, the current PR head, review disposition, merge SHA and available post-merge checks. Never claim background work, independent sessions, tests, reviews or deployments that did not occur.

Historical table/RPC counts and dated setup details are intentionally omitted. Query the live Supabase project when those details matter.
