# Fresh-Session Handoff Acceptance

## Purpose

Prove that a completely new ChatGPT conversation can continue project work using only the repository and persisted Supabase state. Chat history from the creating conversation must not be required.

This is an acceptance protocol, not evidence that the test has already passed.

## Roles

- **Session A (coordinator):** creates one bounded probe task and records its task ID.
- **Session B (fresh worker):** a newly opened ChatGPT conversation with no access to Session A's chat history. It uses the same authorized Supabase and GitHub connections and the existing `shared-executor`.
- **Session A (verifier):** queries Supabase after Session B finishes.

No per-session Worker, Auth user, heartbeat, or identity field is permitted.

## Procedure

1. In Session A, verify the project and worker using the live database. Create one small implementation task with `create_task`, `requires_review=false`, and a fresh idempotency key. Its description must contain all requirements needed to finish without private chat context.
2. Record only the task UUID in the test coordination note. Do not send Session A's conversation transcript or hidden context to Session B.
3. Open a genuinely new ChatGPT conversation (Session B). Provide the repository name and ask it to follow `README.md` and `docs/WORKER-INSTRUCTIONS.md`, inspect Supabase's shared queue, and claim the probe task using `claim_task`.
4. Session B must retrieve the task requirements from Supabase, inspect the relevant GitHub files, implement the requested bounded change, and commit it to `Love-DC/recursive-ai-engineering`.
5. Session B must call `complete_execution` with the task UUID, its returned execution UUID, the shared Worker UUID, a result containing the commit SHA and verification evidence, and a fresh completion idempotency key.
6. Back in Session A, call `get_task` (or `list_tasks`) and verify the task status, execution status/result, and GitHub commit reference. Fetch the commit from GitHub and confirm that it exists.
7. Record the outcome, task UUID, execution UUID, commit SHA, and any blockers in the task result or a durable GitHub test report.

## Pass criteria

- Session B is genuinely new and was not given Session A's chat history.
- Session B discovers the task from Supabase, not from a manually copied task description.
- The shared Worker atomically claims the task and receives an execution UUID.
- Session B completes the implementation and creates a verifiable GitHub commit.
- `complete_execution` persists the result and the final task/execution states can be queried by Session A.
- No session identity, heartbeat, or new Worker record is introduced.

## Failures and safe handling

- If Session B cannot see or claim the task, preserve the RPC response and investigate authorization, queue state, or lease behavior. Do not manually change task status.
- If the lease expires or the execution is superseded, stop writes from that execution and let a fresh claim establish a new execution fence.
- If no independent second conversation is available, mark the acceptance **not run / externally blocked**. Repository instructions and a shared queue alone are not a substitute for this test.
- Never put database passwords, secret keys, or Service Role credentials in this repository or in a prompt.

## Current evidence status

The repository contains the operating instructions and the shared task lifecycle has been exercised in the connected owner-MCP environment. A true independent ChatGPT conversation has not been spawned or observed by this execution environment. Therefore this acceptance remains **pending external execution** until all pass criteria above are evidenced.
