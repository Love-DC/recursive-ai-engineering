# Autonomous Task Discovery & Generation

**Status:** Worker operating contract for the trusted owner-MCP pilot. It does not install a background scheduler, change database schema, or grant new production permissions.

## Goal

A Worker must not treat an empty queue as the end of useful work. It should inspect the project it is authorized to work on, identify evidence-backed engineering opportunities, turn eligible findings into bounded tasks in that same project's Supabase queue, and then return to the normal atomic claim/execute/verify workflow.

Autonomy means initiative within a declared project boundary—not authority to make product decisions, bypass risk gates, deploy production systems, or turn arbitrary backlog into permission. The AI coordinator is authorized to independently review and merge eligible engineering PRs under the project's review checklist; leaf Workers hand off PRs and do not merge their own work.

## RAE repository-local activation policy

**RAE policy mode: `active_session_autonomy`.** This policy is owned by this repository and this document is a manifest-required governance rule. It is registered in `rae-governance.json` as `autonomous-task-activation-policy` and must be read before any RAE task-pool write. The Coordinator may autonomously discover, create, claim, execute, verify, review, repair, and complete eligible engineering tasks when the shared database migration gate is open and the project's operational controls permit it. This does not create a background scheduler; active AI sessions must run the workflow.

Supabase is not the authority for repository policy decisions. The deployed PR #66 migration removes `projects.config.task_activation` and retains only operational controls: `autonomy.paused` (fail-closed kill switch) and `autonomy.max_active_executions` (bounded concurrency cap). A project's own manifest-referenced policy file determines whether autonomous task creation/claiming is authorized; external projects must be evaluated against their own repository-local governance, never inferred from RAE's policy. **Live activation state (2026-11-25):** Colony Sim and Hexa Game Kernel are `autonomy.paused=false`, max 2; RAE and Lambent are `autonomy.paused=true`, max 2. Colony's bounded active-session engineering policy and activation gates are approved. RAE's repository-local policy is `active_session_autonomy`, but its operational switch remains paused. The deployed trusted Owner-MCP context migration is `20261124200149_trusted_owner_mcp_execution_context`, with project registration `20261124202438_owner_mcp_project_registration`; it binds a verified Owner/project in the trusted `postgres` session without synthesizing `auth.uid()`. `list_tasks` and `list_initiatives` succeeded in this context, while `list_problem_reports` returned `UNAUTHENTICATED` because it still requires `auth.uid()`. The RPC failure is recorded in the documented no-write fallback, [Issue #42](https://github.com/Love-DC/recursive-ai-engineering/issues/42#issuecomment-7144406870). Do not infer current Problem Inbox report IDs or statuses while the listing RPC is unavailable. Keep the Inbox on the documented Issue #42 no-write fallback until the RPC is repaired. Do not change production configuration or treat code merge as deployment.

## Production task-pool write gate

Autonomous discovery and repository inspection remain subject to the database-wide production claim-safety gate in `docs/SESSION-START.md`. **Live state rechecked on 2026-11-25: OPEN** for the shared Supabase project `rgztxilqcfuclkekyojl`.

The eight required safety/lifecycle migrations are present in the live migration registry in dependency order:

1. `20261124112550` — `20261123000300_failure_reporting_retry`
2. `20261124112600` — `20261123000400_worker_task_routing_safe_release`
3. `20261124112606` — `20261124000100_task_dependency_eligibility`
4. `20261124112609` — `20261124000200_ai_initiative_lifecycle`
5. `20261124112613` — `20261124000300_task_worker_routing_safe_reassignment`
6. `20261124112617` — `20261124000400_problem_inbox`
7. `20261124112624` — `20261124000500_review_task_cancellation_recovery`
8. `20261124112627` — `20261124000600_exclusive_branch_claim`

This session also re-read the deployed claim, review-routing, reassignment, execution-fencing and retry function definitions; verified project-scoped Worker routing, dependency checks, reviewer separation and repository/branch exclusion; and successfully called the owner-scoped `list_tasks` and `list_initiatives` read RPCs. The `list_problem_reports` call was separately tested inside the trusted Owner-MCP transaction and returned `UNAUTHENTICATED`; see SESSION-START.md and the documented [Issue #42 no-write fallback](https://github.com/Love-DC/recursive-ai-engineering/issues/42#issuecomment-7144406870). The isolated PostgreSQL lifecycle suite passed on PR #60's exact head (`d9b39dd2d81c397c4d41835f98d98d48787b3036`, run `45449618863`); the Initiative integration and shell-static workflows also passed on that exact head (runs `45449618986` and `45449618919`). These are repository/fixture checks, not production mutation tests.

The database gate allows the normal project-scoped task and execution lifecycle only when the current live checks remain valid. It does **not** authorize arbitrary production DDL, deployment, destructive operations, product decisions, or policy changes. Before any lifecycle write in a new session, re-check the live migration registry, deployed RPC behavior, project/Worker mapping and the selected project's activation policy. Never rely on this dated snapshot or a GitHub merge alone.

If the gate is closed, stale, contradictory or cannot be proven open, keep discovery read-only. Do not call `create_task`, `claim_task`, task reassignment/requeue/cancel/review RPCs, execution heartbeat/submit/fail/complete RPCs, or Initiative/Problem Inbox mutation RPCs; do not directly modify production tables. Do not probe `claim_task` with a dummy task, invalid Worker or replay key. keep all Supabase task state unchanged, continue repository-only inspection and maintenance, and use only the exceptional no-write fallback documented in `docs/SESSION-START.md` and `docs/PROBLEM-INBOX.md`.

**Currently deployed project execution guard:** PR #66's repository-authoritative migration is deployed in the live registry as `20261124192533`; it enforces `autonomy.paused` and a one-or-two execution cap in `claim_task`. The original eight-migration claim-safety gate plus PRs #59 and #60 remain prerequisites and were verified live. The trusted Owner-MCP context (`20261124200149`) and project registration (`20261124202438`) are also deployed. Do not assume all RPCs support this context: `public.list_problem_reports` currently returns `UNAUTHENTICATED` because it requires `auth.uid()`. Do not fake JWT claims or write tables directly.

The gate is database-scoped and applies to all registered projects sharing the database. A project's own activation policy is an additional requirement, never a substitute for the platform gate. In particular, Colony Sim remains subject to its repository and project activation policy; do not turn its Issue backlog into claimable tasks without the required project authorization.

## Discovery loop

Run this loop at session start when no eligible task exists, and after completing a task when the current objective permits continued work:

1. **Resolve scope.** Read the active project row, its repository, project-scoped active Worker selected by routing metadata, and repository governance manifest at the pinned SHA. Never infer or reuse another project's IDs.
2. **Inspect evidence.** Review configured project-state and architecture docs, recent relevant commits/PR/CI results, test coverage, TODO/FIXME markers with context, dependency/security reports where available, and read-only operational health. Inspect only sources allowed by project policy.
3. **Form candidates.** Each candidate must name a concrete observed condition, exact evidence (file/line, commit, CI run, or query result), project impact, bounded proposed change, risk class, acceptance criteria, and validation plan. Do not create speculative tasks from vague preferences.
4. **Classify authority.** Apply repository activation and governance rules before task creation. When the live Problem Inbox is available and the database gate is open, record material findings with `report_problem` using the correct project UUID, Worker route and stable fingerprint; use `owner_input_required` for decisions reserved to the Owner. If a finding needs product, security, data, or production approval, stop at that decision gate. When the database gate is closed or the inbox RPC is unavailable, follow only the exceptional no-write fallback in `docs/PROBLEM-INBOX.md` and `docs/SESSION-START.md`; never write directly to inbox tables or create parallel intake issues.
5. **Deduplicate.** For direct executable tasks, compare the candidate fingerprint and affected scope against all non-terminal tasks and recent task events; reuse an existing task where found. Use a stable fingerprint across scans (project key + normalized issue signature + affected paths or failing check). Derive the idempotency key from the project and fingerprint only—not from scan, run, or session identity. This protects exact request retries, but task creation does not yet enforce atomic fingerprint uniqueness: two conversations can still race between the lookup and insert. Treat direct-task deduplication as best-effort and do not claim a cross-session no-duplicates guarantee. For durable proposals/goals, use `propose_initiative`, whose project-scoped fingerprint deduplication is atomic.
6. **Control noise.** Create at most three new discovery tasks per project per scan, one per distinct root cause. Skip low-impact style-only churn, unsupported claims, already-fixed findings, and candidates without reproducible evidence. If no candidate passes, leave the queue empty and report what was inspected.
7. **Publish.** For a material finding, first create or update the live Problem Inbox report with `report_problem`, using the project's UUID, its project-scoped Worker UUID and a stable fingerprint. Confirm the RPC is live and the database gate is open before writing; otherwise follow only the exceptional no-write fallback in `docs/PROBLEM-INBOX.md`. For an eligible executable candidate, call `create_task` using that project's UUID and its own active Worker UUID, but only when both the database gate and that repository's activation policy permit it. Store discovery source, evidence references, fingerprint, risk/authority classification, impact, acceptance criteria, validation plan, and originating scan timestamp in requirements. Use an idempotency key derived from project + stable candidate fingerprint, not scan/session identity; never reuse a key for different arguments. Idempotency protects replay of the same request and is not a substitute for an atomic task-fingerprint uniqueness constraint.
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

The leaf Worker opens a PR and reports exact head SHA, changed paths, acceptance evidence, and CI. The coordinator follows `docs/COORDINATOR-PR-REVIEW-AND-MERGE.md` for an independent review pass (separate from implementation), requested changes, re-review, Draft-to-ready transition, merge, and post-merge verification.

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
