# GPT Session Operating Instructions — Shared MCP Pilot

## Operating model

- A ChatGPT conversation is temporary. Do not create, track, heartbeat, identify, or report on individual sessions.
- All sessions work as one shared executor through the user's already-authorized Supabase MCP connection.
- Use the single project Worker record with key `shared-executor`. Its UUID is a stable database routing reference, not a session ID or identity credential.
- Do not create separate Supabase Auth users or bind Worker identities for this pilot.
- Supabase is the source of truth for task state. GitHub is the source of truth for code and durable project documents.

## Project references

- Supabase project: `recursive-ai-engineering`
- GitHub repository: `Love-DC/recursive-ai-engineering`
- Shared Worker key: `shared-executor`
- Shared Worker ID: `78953b49-db9d-4fbc-9d3c-be3421a1c975`
- Project ID: `61e32c05-39b7-47a6-ab5c-592c8e37d72d`

## How to work

1. Read the task queue and current task details from Supabase before acting. Never rely on another conversation's memory.
2. If the queue is empty and the user has provided an engineering objective, create an implementation task with `create_task`, the shared Worker ID, and `requires_review=false`. If no objective was provided, ask the user what should be worked on.
3. Claim a task atomically with `claim_task`, using the shared Worker ID and a fresh idempotency key. A database-generated UUID is suitable for the key; it is not a session identity.
4. Read the task requirements and relevant GitHub files.
5. Do the work. Commit durable code/documentation changes to GitHub and record the resulting commit or file references in the task result/artifacts.
6. If the task is too large, create child implementation tasks using `create_task` and the original task's ID as `parent_task_id`. Record the child task IDs in the parent result. Other sessions can claim those children without knowing anything about the decomposing session.
7. For pilot tasks, set `requires_review=false` and finish with `complete_execution`. Do not introduce a review/fix workflow unless the user explicitly asks for it.
8. Submit a concise result containing what changed, GitHub references, verification performed, and remaining blockers.

## Lease behavior

- Claim with a lease of up to 600 seconds.
- Do not send session heartbeats or activity telemetry.
- If work may exceed the lease, renew only to prevent another session from reclaiming the same task. This is task-lock maintenance, not session monitoring.
- If the session disappears, another session may reclaim the task after lease expiry. The previous execution is fenced and must not write further.

## Supabase MCP execution context

The pilot uses the already-authorized project-owner MCP connection; it does not provision per-session credentials. When calling owner-protected RPCs through the privileged SQL MCP tool, set the existing project's `owner_id` as `request.jwt.claim.sub` in the same SQL transaction before invoking the RPC. Keep this confined to the authenticated Supabase MCP connection; never copy credentials or privileged keys into prompts, GitHub, task results, or external clients.

## Boundaries

- Do not add Worker identity systems, session tracking, heartbeat monitoring, multi-account provisioning, or complex orchestration.
- Do not create or modify Supabase schema unless the task specifically requires it.
- Do not use Service Role keys, secret keys, database passwords, or privileged connection strings outside the connected Supabase MCP tool.
- Do not deploy, merge, or perform external side effects without explicit user authorization.
- If a task cannot be completed safely, persist the blocker and create a smaller actionable task rather than inventing progress.
