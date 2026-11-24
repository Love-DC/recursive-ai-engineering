# Autonomous Task Discovery & Generation

**Status:** Worker operating contract for the trusted owner-MCP pilot. It does not install a background scheduler, change database schema, or grant new production permissions.

## Goal

A Worker must not treat an empty queue as the end of useful work. It should inspect the project it is authorized to work on, identify evidence-backed engineering opportunities, turn eligible findings into bounded tasks in that same project's Supabase queue, and then return to the normal atomic claim/execute/verify workflow.

Autonomy means initiative within a declared project boundary—not authority to make product decisions, bypass risk gates, deploy production systems, or turn arbitrary backlog into permission. The AI coordinator is authorized to independently review and merge eligible engineering PRs under the project's review checklist; leaf Workers hand off PRs and do not merge their own work.

## Discovery loop

Run this loop at session start when no eligible task exists, and after completing a task when the current objective permits continued work:

1. **Resolve scope.** Read the active project row, its repository, project-scoped active Worker selected by routing metadata, and repository governance manifest at the pinned SHA. Never infer or reuse another project's IDs.
2. **Inspect evidence.** Review configured project-state and architecture docs, recent relevant commits/PR/CI results, test coverage, TODO/FIXME markers with context, dependency/security reports where available, and read-only operational health. Inspect only sources allowed by project policy.
3. **Form candidates.** Each candidate must name a concrete observed condition, exact evidence (file/line, commit, CI run, or query result), project impact, bounded proposed change, risk class, acceptance criteria, and validation plan. Do not create speculative tasks from vague preferences.
4. **Classify authority.** Apply task activation and governance rules from the repository's manifest and referenced documents before creating anything. Never infer a permissive default. If the finding needs product, security, data, or production approval, record it as a proposal/report and stop at the decision gate.
5. **Deduplicate.** For direct executable tasks, compare the candidate fingerprint and affected scope against all non-terminal tasks and recent task events; reuse an existing task where found. Use a stable fingerprint across scans (project key + normalized issue signature + affected paths or failing check). Derive the idempotency key from the project and fingerprint only—not from scan, run, or session identity. This protects exact request retries, but task creation does not yet enforce atomic fingerprint uniqueness: two conversations can still race between the lookup and insert. Treat direct-task deduplication as best-effort and do not claim a cross-session no-duplicates guarantee. For durable proposals/goals, use `propose_initiative`, whose project-scoped fingerprint deduplication is atomic.
6. **Control noise.** Create at most three new discovery tasks per project per scan, one per distinct root cause. Skip low-impact style-only churn, unsupported claims, already-fixed findings, and candidates without reproducible evidence. If no candidate passes, leave the queue empty and report what was inspected.
7. **Publish.** For an eligible candidate, call the project's create_task using that project's UUID and its own active Worker UUID. Store discovery source, evidence references, fingerprint, risk/authority classification, impact, acceptance criteria, validation plan, and originating scan timestamp in requirements. Use an idempotency key derived from project + stable candidate fingerprint, not scan/session identity; never reuse a key for different arguments. Idempotency protects replay of the same request and is not a substitute for an atomic task-fingerprint uniqueness constraint.
8. **Execute.** Newly created tasks are ordinary project-scoped tasks. Claim them only through claim_task; the atomic response is authoritative. Follow normal branch, test, PR, and evidence rules. Do not silently self-approve tasks that require review.

## Cross-session deduplication guarantees and limits

- **AI Initiative proposals:** `propose_initiative` uses a project-scoped fingerprint lock and uniqueness constraint. This is the atomic deduplication path for durable goals/proposals.
- **Direct executable tasks:** discovery currently uses a read-before-create check plus the shared idempotency ledger. A stable project/fingerprint idempotency key makes identical request retries replay-safe, but there is no task-level unique fingerprint or atomic create-or-reuse RPC. Two conversations using different request keys can still race. Treat this path as best-effort only.
- Do not represent a Worker row, a shared idempotency key, or a successful sequential test as proof of cross-session uniqueness.
- A future task-level no-duplicate guarantee requires a project-scoped atomic create-or-reuse RPC/constraint and a deterministic two-connection race test before the guarantee can be enabled.

## Authority matrix

| Finding / action | RAE project (recursive-ai-engineering) | External project (example: Colony Sim) |
|---|---|---|
| Documented bug, failing test/CI, broken internal workflow | May create a bounded implementation task when evidence and acceptance criteria are clear | May create only if that project's activation policy explicitly authorizes autonomous task creation; otherwise propose only |
| Documentation drift or missing regression test | May create low-risk task; batch only when tightly related | Follow the external project's own dispatch/approval contract |
| Refactor, performance or architecture proposal | Create an investigation/proposal task; implementation needs an explicit bounded engineering basis | Proposal only unless explicitly authorized |
| Product behavior, game design, UX, business rules | Proposal only; owner decision required | Proposal only; product owner decision required |
| Security policy, credentials, RLS/auth, data deletion/migration, production deploy | Report and request explicit authorization | Report and request explicit authorization |
| GitHub Issue/backlog item | An Issue is evidence/input, not by itself an authorization token; apply this repository's local activation policy | An Issue is evidence/input, not by itself an authorization token; apply that repository's local activation policy |

No discovery scan may bulk-import, auto-claim, or execute Issues unless the target repository's own governance explicitly authorizes that action. The repository's own governance is authoritative for project-level activation.

## Candidate record

Store an auditable object in tasks.requirements, for example:

    {
      "discovery": {
        "source": "ci | repository_review | test_gap | operations | dependency_audit",
        "scan_id": "stable-scan-identifier",
        "fingerprint": "stable-project-scoped-fingerprint",
        "observed_at": "ISO-8601 timestamp",
        "evidence": [
          {"kind": "file | commit | ci_run | query", "ref": "durable-reference", "observation": "specific fact"}
        ],
        "impact": "who or what is affected",
        "risk": "low | medium | high | decision_required",
        "authority": "autonomous_task | owner_approval_required",
        "acceptance_criteria": ["observable result"],
        "validation": ["repeatable check"]
      }
    }

Do not put secrets, raw credentials, personal data, or unbounded environment dumps in task metadata.

## Empty-queue behavior

An empty queue triggers discovery, not immediate termination:

- If an eligible task is found, create it in the correct project queue and attempt a normal atomic claim.
- If only approval-gated proposals are found, report the decision needed; do not create executable tasks.
- If no defensible candidate is found, report the inspected sources and leave the queue empty. Never invent work merely to keep a Worker busy.

## Pilot limitations and future automation

This contract makes discovery an explicit Worker responsibility during a live session. It is not a daemon and cannot make progress between conversations. A scheduled scanner, event-triggered scanner, cross-project policy editor, or automatic production mutation requires a separate design, security review, explicit owner authorization, and an approved deployment task. Do not claim background autonomy until such a trigger is actually deployed and verified.

## Acceptance checklist

- [ ] Empty queue causes a scoped discovery pass rather than immediate stop.
- [ ] Candidate requires concrete evidence, impact, risk, acceptance criteria, and validation.
- [ ] Initiative proposal fingerprints are atomically deduplicated by `propose_initiative`.
- [ ] Direct task fingerprint deduplication is explicitly best-effort until an atomic create-or-reuse RPC and two-session race test exist; no stronger guarantee is claimed.
- [ ] Per-scan task creation is capped and low-value findings are skipped.
- [ ] Project routing uses that project's own project UUID and Worker UUID.
- [ ] The repository-local project activation policy gates task creation.
- [ ] Approval-gated work is reported, not silently converted to executable tasks.
- [ ] Created tasks are claimed atomically and completed with normal execution evidence.
- [ ] No scheduler, schema change, or production deployment is implied by this discovery pilot. Engineering PR review and merge are handled by the AI coordinator under the standing project authorization.

## Repeatable pilot acceptance procedure

Run these cases against a disposable or transaction-rolled-back task fixture where possible. Do not mutate production state merely to demonstrate the negative cases.

| Scenario | Input | Expected result |
|---|---|---|
| Evidence-backed RAE defect | A current failing RAE CI check with exact run URL, affected path, and reproducible failure | One bounded RAE task is created with evidence, acceptance criteria, validation, and a stable fingerprint |
| Duplicate direct-task scan | Repeat the same finding with the same stable fingerprint/idempotency key while its task is non-terminal | Exact retries return the prior idempotent result; a separate concurrent create with a different key is not guaranteed to deduplicate until atomic create-or-reuse is implemented |
| Duplicate initiative proposal | Publish the same initiative fingerprint concurrently | The atomic proposal RPC returns the existing initiative/learning record rather than creating another root |
| Unsupported candidate | A vague TODO or speculative refactor with no demonstrated impact or validation | No task is created; finding is omitted or recorded as a proposal |
| Approval-gated change | A candidate requires product, security, auth/RLS, data migration, or production approval | No executable task is created; report the specific owner decision required |
| External backlog | An open Issue without the authorization required by that repository's governance | No task is created or claimed |
| Project routing | An authorized candidate belongs to another project whose policy permits creation | Task is written only with that project's project UUID and matching active Worker UUID |

For a positive RAE case, verify the new row with project-scoped list_tasks/get_task, then claim it through claim_task and confirm the returned task_id/project_id and execution_id. Do not complete a fixture task unless the test is explicitly intended to exercise the full lifecycle. For negative cases, verify that task counts and existing task states remain unchanged. Record inspected sources, candidate fingerprints, created task IDs, and any skipped approval-gated proposals in the run result.

## AI engineering PR review and merge authority

The project owner has delegated routine engineering PR review and merge to the AI project coordinator. This is a standing project-level authorization, not a per-PR approval request.

The leaf Worker opens a PR and reports exact head SHA, changed paths, acceptance evidence, and CI. The coordinator performs an independent review pass (separate from implementation) and owns requested changes, re-review, merge, and post-merge verification.

The coordinator may merge when all of the following are true:

- The PR is within an authorized engineering task and does not introduce an unapproved product/design decision.
- The PR targets the configured integration branch and the current head SHA is verified.
- All required checks for that exact head SHA have completed successfully.
- The diff, tests, scope, security-sensitive changes, and rollback implications have been reviewed.
- No unresolved blocking review threads or merge conflicts remain.
- The resulting merge commit and post-merge CI are verified and recorded.

If a check fails, request changes or repair within scope, then review the new head. If the change crosses a product, security, credential, production deployment, or irreversible data boundary, stop only at that boundary and create a specific decision request. Do not ask the owner to approve routine engineering PRs one by one.

## Durable AI initiative lifecycle

When the discovery pass finds an opportunity that should be preserved as a goal/proposal rather than immediately entering the executable task queue, use the dedicated AI Initiative lifecycle in [AI Initiative Lifecycle](AI-INITIATIVE-LIFECYCLE.md). This is especially important when a candidate needs an Owner decision, a missing capability, or a resource request. Do not leave such findings only in chat, and do not put them in `operation_requests`.

At the start of a session, for each active project:

1. Call `list_initiatives(project_id, status, limit)` to discover proposed, approved, in-progress, ready-to-close, completed, rejected, and abandoned initiatives. Inspect pending support requests and durable handoffs with `get_initiative`.
2. Continue an existing approved/in-progress initiative before proposing overlapping work. After one or more tasks become `accepted` (including required independent review), call `advance_initiative` with a fresh idempotency key. It marks accepted work items complete and materializes only the next dependency-ready wave.
3. When a new evidence-backed opportunity needs a durable Owner decision, call `propose_initiative` with its origin, desired outcome, scope, evidence, impact rationale, risk, priority, resource budget, support needs, and stable project-scoped fingerprint. The RPC atomically deduplicates active proposals and returns a prior learning record for already-closed root causes.
4. If blocked by a concrete missing capability/resource, first search connected integrations and repository evidence. Then call `request_initiative_support` with the exact capability, alternatives checked, rationale, what it unlocks, and requested resources. Do not create a claimable task for the blocked action.
5. Wait for the Owner's persisted decision. `decide_initiative` must approve with a bounded acyclic work plan or reject. Approval creates the work-plan DAG, not claimable tasks. Call `advance_initiative` to materialize the initial ready wave.
6. Execute materialized tasks through the existing task lifecycle. Do not bypass leases, review, or acceptance. A dependent work item is materialized only after all its predecessor tasks reach `accepted`.
7. When `advance_initiative` returns `ready_to_close`, record a concise lesson and evidence with `record_initiative_learning`; that operation closes the initiative as `completed`. The learning fingerprint must match the proposal fingerprint and suppresses rediscovery of the same resolved root cause. Rejected or abandoned initiatives cannot create fingerprint-suppressing learning in the current lifecycle; non-suppressing lessons for those outcomes require a separate model and are not yet implemented. Use `abandon_initiative` when the Owner or valid project decision stops the initiative; it refuses to cancel work while tasks are running or submitted.

### Candidate routing

- **Low-risk bounded implementation with explicit autonomous activation:** use the existing discovery-task path when it is truly a direct executable defect and no reserved decision/resource is needed.
- **A worthwhile goal requiring Owner approval or prioritization:** create an Initiative proposal; do not make it claimable before approval.
- **A missing resource, permission, access path, paid service, or physical-world action:** create an Initiative support request and keep the blocked action out of the task queue.
- **A product/security/production/destructive decision:** preserve evidence in the Initiative and wait at the decision boundary.
- **A duplicate active proposal or a known completed lesson:** reuse the returned initiative/learning record instead of creating another root.

This is session-driven coordination. A temporary GPT conversation can continue an initiative by reading its Supabase records; no permanent Coordinator, session identity, background daemon, or automatic GPT launcher is implied.
