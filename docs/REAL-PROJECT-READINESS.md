# Real-Project Readiness Gate

This document separates the MVP v1.2 database workflow from production onboarding. Passing database RPC tests alone is not permission to connect real project repositories or start autonomous Workers.

## Verified so far

- Seven core tables and 20 public RPCs are deployed.
- Catalog audit confirms all 20 public RPCs are SECURITY DEFINER with fixed `search_path=pg_catalog, public, auth, private`; `authenticated` can execute them, while `anon` and `PUBLIC` cannot.
- Direct client table writes are not granted. `operation_requests` has RLS enabled, no client policies, and no client table grants; the Advisor's RLS-without-policy INFO notice is intentional default-deny.
- A rollback-safe authenticated RPC suite passes project/Worker/Task reads, owner-boundary denial, idempotency replay/conflict, claim/heartbeat, artifact registration, submit, review rejection, Fix/resubmit, review acceptance, no-review completion and running-task cancellation.
- Two concurrent database connections produced exactly one successful claim for the same Task.
- Expired lease reclaim advanced to attempt 2; the previous Execution was fenced with `EXECUTION_SUPERSEDED`.
- Worker identity isolation v1.2 and task-scope hardening v1.2.1 are applied and recorded in Supabase migration history.
- Negative identity tests deny an unbound Worker and a JWT subject that does not match the Worker bound to another Auth user.
- Owner workflow tests were rerun successfully after identity changes.
- Current live business data is zero: projects, workers, tasks, executions, artifacts and operation_requests all contain zero rows.

## No-go items

- [x] Owner Console production build verified by GitHub Actions (runs 45053374989 and 45053468980).
- [ ] Real browser sign-in, project creation and task creation verified with the provisioned Owner account.
- [x] Worker RPC authorization binds the authenticated subject to the exact Worker ID; Owner retains administrative override. Negative mismatch and unbound-Worker tests pass.
- [ ] Distinct Auth-user identities provisioned for Coordinator, Implementer, Reviewer and Fixer; positive multi-identity workflows remain untested.
- [ ] Claim/reclaim and Reviewer workflow tested with genuinely independent Auth-user identities.
- [ ] Remaining A01–A63 edge cases completed, including cross-project denial, idempotency edge cases, lease fencing, cancellation and review-lock contention.
- [ ] Coordinator orchestration model finalized. Review/Fix task creation currently remains Owner-only; an autonomous Coordinator Worker cannot yet create these tasks.
- [ ] Supabase leaked-password protection enabled.
- [ ] SECURITY DEFINER RPC design reviewed and accepted for production. The Advisor flags all 20 because authenticated clients can invoke them; catalog checks confirm no anon/PUBLIC EXECUTE and fixed search_path, but function-level authorization still needs continued review.
- [x] Security Advisor rechecked after identity changes; RLS default-deny and SECURITY DEFINER notices documented. Leaked-password protection remains a separate no-go.
- [ ] Consolidated schema snapshot applied to a disposable empty PostgreSQL 17 database and compared against the deployed catalog.
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
