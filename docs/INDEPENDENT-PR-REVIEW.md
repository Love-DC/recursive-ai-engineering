# Independent AI PR Reviewer and Merge Protocol

**Status:** Mandatory for every RAE-managed repository unless the target repository defines a stricter review gate.

## Role separation

Every implementation PR has three distinct responsibilities:

1. **Worker / Implementer**
   - Owns implementation, tests, commits, and PR creation.
   - Supplies the task objective, acceptance criteria, changed paths, exact PR head SHA, test commands/results, CI links, risk notes, and rollback information.
   - Must not approve or merge its own PR.
2. **Coordinator**
   - Owns project routing, task orchestration, scope tracking, evidence collection, and reviewer dispatch.
   - Prepares a neutral review packet and assigns an independent Reviewer AI.
   - May relay review findings and route requested changes back to the Worker.
   - Must not substitute its own review for the independent Reviewer and must not merge the PR.
3. **Independent Reviewer AI**
   - Must be a separate AI agent/session/context that did not implement the change, author its commits, or direct its implementation details.
   - Independently inspects the task requirements, repository governance, complete diff, relevant surrounding code, tests, CI evidence, security impact, and rollback implications.
   - Issues a formal approve/request-changes/block verdict against one exact PR head SHA.
   - Is the **only AI role authorized by this protocol to execute the routine engineering PR merge** after approval and all merge gates pass.
   - Rechecks the current PR head immediately before merge. If the head changed after review, the approval is stale and review must restart.

A second self-review pass by the Worker, a role label change in the same conversation, or a Coordinator checklist is not an independent review.

## Required review sequence

1. Worker opens or updates the PR and reports the exact head SHA and evidence.
2. Coordinator verifies the PR belongs to the authorized task/project, assembles the review packet, and dispatches an independent Reviewer AI.
3. Reviewer independently fetches the repository governance and PR diff. It must not rely solely on the Coordinator's summary or the Worker's claims.
4. Reviewer checks:
   - task scope and acceptance criteria;
   - repository rules and applicable design decisions;
   - complete diff, unintended changes, and maintainability;
   - test coverage and actual test execution;
   - CI results for the exact current head SHA;
   - security, permissions, data integrity, migrations, and external side effects;
   - rollback/recovery path and compatibility where applicable.
5. Reviewer records a verdict:
   - **APPROVE** — no blocking findings; exact head SHA recorded.
   - **REQUEST_CHANGES** — actionable findings with file/line references and required outcomes; Worker fixes and Reviewer re-reviews the new head.
   - **BLOCK** — missing authority, unavailable evidence, unresolved design/security decision, or a non-reviewable state; PR remains open and unmerged.
6. Only the Reviewer AI that issued the current APPROVE verdict may execute the merge. It must re-fetch the PR, verify the head SHA has not changed, ensure all required checks are successful for that SHA, confirm no unresolved blocking threads/conflicts, then merge using the repository's allowed method.
7. Coordinator independently verifies the resulting merge commit, merged PR state, and post-merge CI; it records evidence and continues task lifecycle processing.

## Merge gates

The Reviewer may merge only when all are true:

- The PR is within the Owner-authorized task and target repository policy.
- No unapproved product, UX, architecture, security, credential, production, or irreversible data decision is introduced.
- The review verdict is APPROVE for the exact current head SHA.
- All required CI checks for that exact SHA completed successfully.
- No unresolved blocking review threads or merge conflicts remain.
- Branch protection and repository merge requirements are satisfied.
- The selected merge method is permitted by repository policy.
- The Reviewer has the required GitHub permission and can verify the actual merge result.

Routine engineering merge is covered by the standing Owner authorization; no per-PR Owner confirmation is needed when all gates pass.

## Unavailable Reviewer or merge capability

If a separate Reviewer AI cannot be dispatched, cannot independently inspect the change, or lacks merge permission:

- Do not let the Worker or Coordinator self-approve or self-merge.
- Keep the PR open and unmerged.
- Persist the blocker and review packet so another authorized Reviewer can resume.
- Continue unrelated eligible work; do not repeatedly ask the Owner to perform routine review or merge.
- Ask the Owner only if the missing reviewer route/permission requires an Owner-only configuration or decision. State the exact missing capability.

A green CI result is not a review. A Coordinator's own inspection is not independent review. A PR being mergeable is not approval. Never report a PR as reviewed or merged without the corresponding verifiable evidence.

## Task lifecycle distinction

The Supabase task flag `requires_review` controls the task-pool execution lifecycle only. Setting it to false, or completing a task execution, does **not** waive this GitHub PR review and merge protocol. Every PR still requires an independent Reviewer AI before merge.
