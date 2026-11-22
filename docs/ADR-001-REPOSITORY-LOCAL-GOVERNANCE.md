# ADR-001: Repository-local engineering governance

- **Status:** Accepted for implementation under the Owner's repository-local governance directive.
- **Date:** 2026-11-23
- **Decision owners:** RAE platform Owner; each repository Owner retains its own product and engineering authority.
- **Scope:** RAE multi-repository coordination, Colony Sim and its independent CI repository.

## Context

RAE currently routes work through project-scoped Supabase rows, but projects.config.governance also stores repository-specific file paths and policy values. RAE session instructions additionally name Colony Sim files and its activation policy directly. This couples RAE core to one project's layout and CI arrangement, making a new repository require central changes.

Colony Sim already owns substantial local governance in AGENTS.md and docs/ai/*. Its CI runner is a separate public repository, Love-DC/colony-sim-ci, which validates private source PRs by exact HEAD SHA. Treating that runner as a Colony Sim subdirectory or assuming a universal CI provider would be incorrect.

## Decision

1. **Repository is the source of truth for project engineering governance.** Each managed repository publishes a root rae-governance.json and owns its AI instructions, engineering standards, task activation rules, review process, CI workflow, release process and acceptance criteria.
2. **Supabase is a coordination registry, not a policy registry.** public.projects.github_repo, project identity/default-branch routing metadata, project-scoped Workers and task lifecycle data remain in Supabase. Repository-specific governance paths, task activation policy, review/merge policy, CI workflow names and product decisions do not.
3. **Coordinator discovery is revision-pinned.** Resolve repository from the task's project row, pin the authorized base SHA, fetch the manifest and every referenced file at that same SHA, validate protocol compatibility and file presence, then read and obey the repository's rules before planning or dispatching.
4. **Conflicts fail closed.** Missing or malformed manifests, unsupported protocol versions, insufficient Coordinator versions, unsafe paths, conflicting rule declarations, unresolved semantic conflicts and stale SHAs block implementation. The Coordinator reports source paths and asks the Owner where resolution requires a decision.
5. **Platform security is non-delegable.** Authentication, Owner authorization, RLS, project isolation, task execution fencing, branch protection and existing merge permissions remain enforced by RAE/platform configuration. Repository text cannot override them.
6. **Workers do not self-review or self-merge.** Workers deliver PRs. The Coordinator performs independent review and validates the exact PR HEAD against the repository-declared CI route. Product decisions remain with the relevant product Owner.
7. **CI is repository-specific.** The Colony Sim manifest points to Love-DC/colony-sim-ci and its owner-controlled issue-comment trigger. This is one adapter example, not a universal RAE CI assumption.

## Governance precedence

Apply the following order:

1. RAE platform security, authentication, Owner authorization and isolation controls (non-overridable).
2. The target repository's latest explicit Owner decisions and repository governance, using its declared precedence.
3. The task's authorized scope and acceptance criteria, which may narrow but never weaken levels 1–2.
4. Implementation details and existing code/tests as evidence, not as authority to invent product behavior.

If two applicable repository rules conflict and no explicit compatible precedence resolves them, stop and request Owner resolution. A numeric priority is only an ordering hint; it is not permission to silently override product decisions or safety constraints.

## Migration plan

### Phase 1 — Compatibility protocol and repository manifests

- Add the versioned manifest contract and structural validator to RAE.
- Publish manifests in RAE, Colony Sim and colony-sim-ci.
- Replace hardcoded Colony Sim paths and activation rules in RAE session instructions with manifest discovery.
- Keep the old Supabase governance keys intact during this PR-only rollout.

### Phase 2 — Exact-SHA validation and coordinator adoption

- Validate RAE manifests and tests in RAE GitHub Actions.
- Validate Colony Sim's manifest and required files in its repository CI.
- Validate colony-sim-ci's own manifest and workflow in its CI configuration check.
- Use the existing public runner for Colony Sim's private source PRs; require the current full 40-character HEAD SHA and both exact-SHA status contexts where relevant.
- Confirm the Coordinator fetches all governance files at the same pinned SHA. Web-only sessions must use GitHub file APIs with the pinned ref; a local checkout is optional.

### Phase 3 — Supabase policy cleanup

Only after Phase 2 is merged and the Coordinator compatibility reader is deployed:

- Back up each active project's exact config JSON.
- Remove repository-owned keys such as governance, task_source, task_activation, delivery and merge_authority.
- Preserve canonical repository routing and platform fields such as project_key, default_branch, execution_mode and session-identity configuration.
- Make the cleanup a reversible data-only update; do not introduce a destructive schema migration.
- Verify project routing, Worker associations, task counts, queue operations and RLS are unchanged. Keep rollback JSON/SQL with the change record.

### Phase 4 — Remove legacy fallback

Remove the deprecated projects.config.governance fallback only after every active registered repository publishes a valid manifest and exact-SHA validation is proven. New repositories must onboard by adding their own manifest and local CI rules, not by editing RAE core.

## Consequences

- New repositories can declare different Workers, task activation rules, CI providers, test suites, review gates and release processes without adding project-name branches to RAE core.
- Supabase remains the source of truth for coordination state and auditability, not engineering policy.
- Governance rollout is deliberately staged: legacy configuration is not removed before compatible discovery is available and validated.
- A production Coordinator daemon is not present in the current RAE repository; the current web-session Coordinator must follow the session-entry discovery contract. Any future daemon must implement this ADR before it dispatches work.

## Rejected alternatives

- **Keep per-project governance in Supabase:** rejected because it centralizes policy and couples database state to repository file layout.
- **Hardcode a Colony Sim adapter in RAE core:** rejected because it makes every new repository require a core code change.
- **Assume all repositories use the same CI workflow:** rejected because Colony Sim already uses a separate public CI runner for private source.
- **Delete legacy config immediately:** rejected because it would break compatibility before the manifest discovery contract is deployed and validated.
