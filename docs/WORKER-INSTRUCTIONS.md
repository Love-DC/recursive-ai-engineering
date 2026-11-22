# GPT Worker Instructions — MVP v1.1

## Credentials

- Use the Supabase project URL and publishable key with a valid authenticated owner session.
- Never request, store, print, or use a Service Role Key, Supabase secret key, database password, or privileged connection string.
- A logical Worker ID is a routing label, not an authentication credential.
- Do not share credentials in prompts, GitHub files, artifacts, logs, or task results.

## Source of truth

Before acting, call the appropriate RPC and read current Task/Execution state. Do not infer ownership, lease validity, or current delivery from conversation history.

## Task execution

1. Register or identify your Worker using `register_worker`.
2. Claim work through `claim_task` with a fresh idempotency key.
3. Persist the returned Task ID, Execution ID, attempt and lease.
4. Heartbeat using `heartbeat_execution` at approximately 60-second intervals. Server lease duration is fixed at 300 seconds.
5. Register each GitHub commit/PR/file through `add_artifact` while the Execution is current and lease-valid.
6. For tasks requiring review, call `submit_result`.
7. For an implementation Task with `requires_review=false`, call `complete_execution`.
8. Never write business tables directly.

## Fencing and retries

- Reuse the same idempotency key only for retrying the exact same logical request.
- Use a new key for a new operation.
- A changed payload with an existing key must be treated as IDEMPOTENCY_CONFLICT.
- If a call returns EXECUTION_EXPIRED or EXECUTION_SUPERSEDED, stop writing with that Execution. Do not attempt to renew or reuse it.
- Never let an older Execution overwrite a newer Execution's database state.
- A submitted Execution is no longer writable. Missing artifacts require a new valid workflow.

## Review

Review Tasks are assigned to a specific Reviewer Worker. Only that Worker may claim the Review Task. Reviewers must inspect only the fixed Delivery Task and Delivery Execution exposed by `get_task`, including exactly that Execution's artifacts. Do not substitute newer commits or artifacts.

Call `review_result` while the Reviewer Execution is running and its lease is valid. The Reviewer Execution completes as succeeded; the Review Task becomes accepted. The decision is stored separately as accepted or rejected.

## Fix workflow

Fix Tasks are created only by `create_fix_task`. Submit the Fix Execution normally, then have the Coordinator call `resubmit_after_fix` to make that submitted Fix Execution the Original Task's new delivery version. Create a new Review Task for that exact version.

## Cancellation

Use `cancel_task`. A running Execution is marked failed and its Task lease is cleared in the same transaction. Do not directly update statuses.
