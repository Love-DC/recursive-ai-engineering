# RPC Reference — MVP v1.1

All functions are in `public`, use SECURITY DEFINER and fixed `search_path=pg_catalog, public, auth, private`. All require an authenticated caller and validate project ownership. Client table writes are prohibited. UUID and JSON arguments below are abbreviated; inspect PostgreSQL function identity arguments for exact deployed signatures.

| RPC | Purpose | Required parameters |
|---|---|---|
| register_project | Create/replay project | name, description, github_repo, config, idempotency_key |
| get_project | Read owned project | project_id |
| register_worker | Register/retrieve Worker | project_id, worker_key, display_name, description |
| get_worker | Read Worker | worker_id |
| list_workers | List project Workers | project_id |
| heartbeat_worker | Update Worker presence | worker_id |
| create_task | Create implementation Task only | project_id, worker_id, task_type, title, description, requirements, priority, requires_review, parent_task_id, fixes_task_id, idempotency_key |
| get_task | Read Task, execution history, artifacts, reviews and fixes | task_id |
| list_tasks | Paginated Task list | project_id, status, worker_id, limit, cursor |
| claim_task | Atomic claim/reclaim | project_id, worker_id, lease_seconds, idempotency_key |
| heartbeat_execution | Renew active Execution lease | task_id, execution_id, worker_id, idempotency_key |
| submit_result | Submit review-required implementation or Fix | task_id, execution_id, worker_id, result, idempotency_key |
| add_artifact | Register immutable execution artifact link | task_id, execution_id, worker_id, artifact_type, name, github_repo, github_path, commit_sha, pr_url, external_url, metadata, idempotency_key |
| complete_execution | Complete no-review implementation | task_id, execution_id, worker_id, result, idempotency_key |
| create_review_task | Create fixed-target Review Task | original_task_id, delivery_task_id, delivery_execution_id, reviewer_worker_id, idempotency_key |
| review_result | Record accepted/rejected decision | review_task_id, execution_id, reviewer_worker_id, decision, review, idempotency_key |
| create_fix_task | Create dedicated Fix Task | original_task_id, review_task_id, title, description, requirements, worker_id, idempotency_key |
| resubmit_after_fix | Set submitted Fix Execution as Original delivery | original_task_id, fix_task_id, fix_execution_id, worker_id, idempotency_key |
| cancel_task | Cancel pending/running Task | task_id, worker_id, reason, idempotency_key |

## get_task review response

For a Review Task, `get_task` includes a `review_target` object with the Original Task (including business requirements), the fixed Delivery Task, the exact Delivery Execution result, and artifacts filtered by both Delivery Task ID and Delivery Execution ID. It does not substitute newer Execution artifacts.

## Important rules

- `claim_task` accepts lease_seconds from 60 through 600. Review Tasks can only be claimed by their assigned Reviewer. Expired ordinary running Tasks can be claimed by another Worker.
- `heartbeat_execution` uses a server-fixed 300-second lease.
- `submit_result` is for implementation Tasks requiring review and Fix Tasks. It is not for Review Tasks.
- `complete_execution` is only for implementation Tasks with `requires_review=false`; it transitions Task to accepted and Execution to succeeded.
- `review_result` checks the Review Worker's current running Execution and valid lease, then transitions that Execution to succeeded and the Review Task to accepted. Decision accepted/rejected is stored in `review_decision`.
- Every side-effecting call requires an idempotency key. Same key + same parameters replays the original response; same key + different parameters is a conflict.
- Query RPCs do not require idempotency keys.
- Review targets and artifact execution associations are immutable.
- Exact SQL types and argument names are available from `pg_get_function_identity_arguments` on the deployed database.
