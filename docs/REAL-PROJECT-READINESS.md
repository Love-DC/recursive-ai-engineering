# Real-Project Readiness Gate

This document separates the MVP v1.1 database workflow from production onboarding. Passing the database RPC tests alone is not permission to connect real project repositories or start autonomous Workers.

## Verified so far

- Seven core tables and nineteen public RPCs are deployed.
- All nineteen public RPCs have fixed search_path; anon and PUBLIC have no EXECUTE grants.
- A rollback-safe authenticated RPC suite passes project/Worker/Task reads, owner-boundary denial, idempotency replay/conflict, claim/heartbeat, artifact registration, submit, review rejection, Fix/resubmit, review acceptance, no-review completion and running-task cancellation.
- Two concurrent database connections produced exactly one successful claim for the same Task.
- Expired lease reclaim advanced to attempt 2; the previous Execution was fenced with EXECUTION_SUPERSEDED.
- Test projects and transactional test records were removed; the live project has no business records.

## No-go items

- [x] Owner Console production build verified by CI (GitHub Actions run 45052216112).
- [ ] Real browser sign-in, project creation and task creation verified with the provisioned Owner account.
- [ ] Distinct Auth-user identities provisioned for Workers; logical Worker IDs must no longer be treated as authentication.
- [ ] Worker RPC authorization must bind the authenticated subject to the exact Worker ID. An Owner may administer all Workers; a Worker session must not impersonate another Worker.
- [ ] Claim/reclaim and Reviewer workflow tested with genuinely independent Auth-user identities.
- [ ] Remaining A01–A63 edge cases completed, including cross-project denial, idempotency conflict, lease fencing, cancellation and review-lock contention.
- [ ] Supabase leaked-password protection enabled.
- [ ] Security Advisor warnings reviewed after the identity changes; no broad grant or RLS weakening.
- [ ] Consolidated schema snapshot applied to a disposable empty PostgreSQL 17 database and compared with the live schema.
- [ ] Backup/restore and rollback procedure documented and tested.

## Pilot rollout

Only after every no-go item passes:

1. Create a dedicated pilot project, not a production-critical repository.
2. Use separate Auth identities for Coordinator, Implementer, Reviewer and Fixer.
3. Limit the pilot to one low-risk task at a time.
4. Require human approval for repository writes, merges, deployment and external side effects.
5. Review event history, artifacts, execution fencing and rejected deliveries after every task.
6. Expand concurrency only after repeated successful pilot runs.

## Hosting

Vercel is optional. The Owner Console can remain local during MVP validation. Hosting choice does not solve Worker authentication or execution isolation.
