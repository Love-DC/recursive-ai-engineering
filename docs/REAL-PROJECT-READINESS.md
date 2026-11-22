# Pilot Readiness and Deferred Production Gates

## Current decision

The shared-owner Supabase MCP pilot is ready to begin for this repository under the user's already-authorized ChatGPT connections.

This is deliberately narrower than a public or independently authenticated multi-user deployment. Do not confuse the deferred production gates below with prerequisites for the pilot.

## Pilot conditions

- Use the single project `recursive-ai-engineering`.
- Use the single shared Worker row with key `shared-executor`; it is a routing reference, not a session identity.
- All ChatGPT conversations use the user's existing authorized Supabase MCP connection.
- Do not provision separate Worker Auth users or track individual sessions.
- Keep pilot tasks to implementation work with `requires_review=false`.
- Use Supabase task state for handoff and GitHub commits/files for durable work.
- A new conversation must be able to continue from task records and repository files alone.
- The create → claim → complete RPC smoke test passed and was rolled back. No smoke-test task remains.

## Deferred—not pilot blockers

These items are required only before expanding beyond the trusted owner-MCP pilot to independent/untrusted clients or more complex workflows:

- Browser-based Owner Console acceptance.
- Separate Auth-user identity isolation and cross-identity tests.
- Autonomous Coordinator review/fix authorization.
- Full A01–A63 edge-case suite.
- Leaked-password protection review for end-user Auth.
- SECURITY DEFINER RPC review for exposure to non-owner clients.
- Disposable-database migration snapshot verification.
- Backup/restore and rollback exercise.

## Pilot stop conditions

Pause the affected task—not the whole project—if:
- a task cannot be read or claimed through the connected MCP tools;
- a task's current execution has expired or been superseded;
- required code changes cannot be verified;
- a requested action would deploy, merge, or cause an external side effect without explicit user authorization.

## Expansion boundary

The pilot assumes participating conversations have the user's trusted Supabase MCP access. Do not expose this operating model to untrusted users or public clients. Before doing so, implement and verify a proper non-owner authentication and authorization boundary.

Vercel and the Owner Console remain optional. They are not required to start the shared MCP pilot.
