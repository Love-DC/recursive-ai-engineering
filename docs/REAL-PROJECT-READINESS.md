# Pilot Readiness and Deferred Production Gates

## Current decision

The shared-owner Supabase MCP pilot is ready to operate for this repository under the user's already-authorized ChatGPT connections.

This is deliberately narrower than a public or independently authenticated multi-user deployment. Do not confuse the deferred production gates below with prerequisites for the pilot.

## Pilot conditions

- Use the active `recursive-ai-engineering` project row and its project-scoped Worker routing.
- The current pilot uses the `shared-executor` Worker row as a routing reference, not a session identity.
- All ChatGPT conversations use the user's existing authorized Supabase MCP connection.
- Do not provision separate Worker Auth users or track individual sessions.
- Keep pilot implementation tasks to `requires_review=false` unless an explicitly approved review route is configured.
- Use Supabase task state for handoff and GitHub commits/files for durable work.
- A new conversation must be able to continue from task records and repository files alone.
- The create → claim → complete RPC smoke test passed and was rolled back.
- The production failure/retry migration is now deployed. The failure → owner requeue → retry claim → complete transaction smoke test passed and was rolled back; no smoke-test task remains.

## Deployed failure/retry API

The production database now exposes:

- `fail_execution`: fenced, idempotent failure reporting for the current execution; error text is bounded and sanitized.
- `requeue_failed_task`: owner-authorized retry of failed tasks, preserving execution history and enforcing attempt caps/backoff.
- Updated `claim_task`: atomic claim with `FOR UPDATE SKIP LOCKED`, lease-expiry recovery, backoff, and a terminal failed state when the configured attempt cap is reached.

The migration is function-only. It did not change table definitions or RLS policies. The trusted owner-MCP pilot is the supported caller boundary; this does not authorize exposing these SECURITY DEFINER RPCs to untrusted or non-owner clients.

See [Failure Reporting and Retry Contract](FAILURE-RECOVERY-CONTRACT.md) for signatures, state transitions, migration version, CI runs, and production verification evidence.

## Deferred—not pilot blockers

These items are required only before expanding beyond the trusted owner-MCP pilot to independent/untrusted clients or more complex workflows:

- Browser-based Owner Console acceptance.
- Separate Auth-user identity isolation and cross-identity tests.
- Autonomous Coordinator review/fix authorization.
- Full A01–A63 edge-case suite.
- Leaked-password protection review for end-user Auth.
- SECURITY DEFINER RPC review for exposure to non-owner clients.
- Backup/restore and rollback exercise.

## Pilot stop conditions

Pause the affected task—not the whole project—if:
- a task cannot be read or claimed through the connected MCP tools;
- a task's current execution has expired or been superseded;
- required code changes cannot be verified;
- a requested action would deploy, merge, or cause an external side effect without explicit user authorization.

## Expansion boundary

The pilot assumes participating conversations have the user's trusted Supabase MCP access. Do not expose this operating model to untrusted users or public clients. Before doing so, implement and verify a proper non-owner authentication and authorization boundary.

Vercel and the Owner Console remain optional. They are not required to operate the shared MCP pilot.

## Live security audit

A read-only audit of the connected Supabase project was recorded on 2026-11-23: [Security Boundary Audit](SECURITY-BOUNDARY-AUDIT.md). It confirms no pilot blocker was found in the inspected owner-MCP boundary. After the failure/retry migration, Supabase Security Advisor reports 22 authenticated SECURITY DEFINER RPC warnings (up from 20 before deployment), one fail-closed `operation_requests` RLS-without-policy INFO finding, and leaked-password protection disabled. The two added RPCs are executable by `authenticated`, revoked from `PUBLIC` and `anon`, and enforce owner/worker/task checks. These findings do not authorize public exposure.

## Project configuration compatibility

Repository-local manifests are now merged and validated for RAE, Colony Sim, and the independent Colony Sim CI repository. Legacy repository policy keys remain in Supabase project config as compatibility data pending a separate reversible cleanup task and Owner authorization. Do not treat those keys as the policy source of truth; the target repository's manifest and declared governance files are authoritative.
