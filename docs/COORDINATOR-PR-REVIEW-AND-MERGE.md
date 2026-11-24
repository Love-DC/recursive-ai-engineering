# Coordinator PR Review and Merge Protocol

**Authority:** The Owner has delegated routine engineering PR review and merge to the RAE Coordinator. This is standing authorization for eligible engineering changes, not a per-PR approval queue.

## Role separation

- A leaf implementation Worker may create/update its PR and provide exact-head evidence. It must not merge its own PR or sibling PRs.
- The Coordinator performs an independent integration review in a separate execution context from implementation. The reviewer need not have a different human GitHub account; the independent execution context and durable review evidence are the quality boundary.
- A task's Supabase requires_review=false setting only disables a separate task-level review task. It never waives the Coordinator's PR-level review before merge.
- Routine engineering merges do not require a fresh Owner confirmation. Product/design decisions, production deployment, destructive data operations, and other reserved boundaries remain separate.

## Merge eligibility checklist

The Coordinator may merge only when every applicable item is true:

1. **Scope and authority**
   - The PR belongs to an authorized engineering task or approved maintenance objective.
   - The change does not silently decide product behavior, game design, spending, external commitments, production deployment, destructive data changes, or another reserved Owner decision.
   - The target repository's rae-governance.json and declared review/release rules have been read at the relevant pinned SHA.

2. **Exact revision**
   - Record the current PR base SHA and head SHA.
   - Inspect the complete diff, changed paths, and any relevant base changes.
   - Compare every changed path against the exact task `requirements.allowed_paths` and any separately recorded maintenance authorization. The PR's changed-path set must be a subset of the authorized set; do not retroactively widen an existing task allowlist. Put out-of-scope changes in a separately authorized task/PR.
   - The review result must name the exact head SHA. If the head moves after review, review the new head again.

3. **Independent review**
   - Review implementation correctness, requirements, edge cases, authorization/security boundaries, migration/rollback implications, and test adequacy.
   - Record an explicit decision: accepted, or changes required. Include evidence and blocking findings.
   - The latest review disposition for the exact current head is authoritative. A later `CHANGES_REQUIRED` finding supersedes any earlier acceptance/comment until the finding is fixed and a fresh review explicitly accepts the new exact head.
   - Treat the semantic disposition in review evidence as authoritative even when GitHub records the review event as `COMMENTED`; never merge while the latest review says changes are required or any blocking finding remains.
   - A blocking finding creates or updates a bounded fix task. The Coordinator tracks the repair and performs a fresh review; do not ask the Owner to coordinate routine fixes.
   - Resolve blocking review threads before merge.

4. **Exact-head validation**
   - Every required CI check must complete successfully for the current PR head / current PR merge candidate, according to repository governance.
   - Do not reuse success from an older SHA, another stacked PR, or a different branch target.
   - A test must exercise the actual behavior it claims to validate. Distinguish isolated CI coverage from production integration or deployment evidence.
   - If code or workflow changes after validation, rerun the affected checks.

5. **GitHub readiness**
   - Confirm there are no merge conflicts and GitHub reports the PR as mergeable.
   - A Draft PR is not an approval gate. Once review and validation pass, the Coordinator marks it Ready for Review.
   - A formal GitHub APPROVE is not inherently required. If the connected GitHub identity is also the PR author, record the separate review context as a COMMENT review and persist the review evidence in the PR/task record.
   - If the target repository explicitly requires a distinct formal approval, treat that as a concrete repository-policy restriction. Do not create/request a second human account by default and do not ask the Owner to perform routine manual merge work.

6. **Merge**
   - Use the merge method allowed by repository governance.
   - Supply the exact reviewed head SHA as the expected-head guard. Abort and re-review if GitHub reports that the head moved.
   - Do not merge while any applicable checklist item is false.

7. **Post-merge verification**
   - Verify GitHub reports merged=true and record the actual merge commit SHA.
   - Inspect post-merge checks on the main branch. If the connector does not expose a post-merge run/status, state that it is unavailable; do not claim it passed.
   - Persist the PR URL, reviewed head SHA, review decision, CI run IDs, merge commit SHA, and any remaining deployment boundary in the task result/artifacts.

## Stacked PRs and branch integration

The synchronous merge path must not be assumed to support merging a PR into another open PR's head branch.

When a delivery is stacked:

1. Identify the complete dependency chain and inspect the cumulative diff.
2. Prefer consolidating the required changes onto a fresh branch from the current target base, or use a GitHub-supported stacked-merge mechanism when it is actually available.
3. Preserve all required changes from the stack, resolve overlapping workflow/document changes, and verify the resulting cumulative diff.
4. Retarget/open one main-target PR, run exact-head CI against the current base, and independently review the consolidated head.
5. After the replacement PR is merged, close superseded predecessor PRs with a comment linking the replacement and merge SHA.

Never merge a partial lower layer merely to make a stacked PR appear mergeable. Never force-push or discard another Worker's changes without verifying branch ownership and the expected current head.

## Failure and escalation rules

- **Review finding:** create a bounded repair task, revise, rerun checks, and re-review.
- **Stale CI:** rerun checks against the current exact head.
- **Merge conflict / stacked limitation:** consolidate or resolve the stack; do not request a second account.
- **Permission or branch-rule rejection:** inspect the exact GitHub error and repository rule. Continue autonomously when the existing authorized identity can satisfy it. Ask the Owner only if a permission or policy change is genuinely unavailable to the Coordinator.
- **Production boundary:** merging a migration file is not deploying it. Production migration, RLS/grant changes, credentials, destructive data changes, and release operations require their own authorization and verification.

## Completion definition

A PR is complete only when the merge commit is verified and the result is recorded. A review comment, successful CI run, or successful merge API response alone is not sufficient to claim end-to-end completion.
