# AI Initiative Lifecycle

**Status:** Implementation candidate; migration is not deployed.  
**Migration source:** `supabase/migrations/202611240002_ai_initiative_lifecycle.sql` (applied only in isolated CI fixtures; not deployed to the live Supabase project).  
**Scope:** Durable AI-originated proposals, Owner decisions, human-support requests, dependency-aware task materialization, and reusable learning.

## Design boundary

An Initiative is a durable goal/proposal, not an executable task and not an idempotency record. The implementation adds dedicated tables:

- `initiatives`: proposal, origin, evidence, impact/risk, resource budget, decision and lifecycle state.
- `initiative_work_items`: approved decomposition plan and dependency DAG. These rows are not claimable tasks.
- `initiative_support_requests`: specific missing capability/resource requests and Owner grant/decline decisions.
- `initiative_events`: append-only lifecycle audit.
- `initiative_learnings`: reusable outcomes keyed by a project-scoped learning fingerprint.

The existing `operation_requests` table remains exclusively the RPC idempotency ledger. The existing `tasks` table remains the execution queue.

All new tables have RLS enabled and direct table privileges revoked. The public RPCs are `SECURITY DEFINER` and enforce project ownership through the existing `private.assert_owner` helper. No session identity, heartbeat, or permanent Coordinator is introduced.

## Lifecycle

1. **Discover and propose.** A temporary GPT conversation records a structured, evidence-backed proposal with `propose_initiative`. AI-originated initiatives and maintenance proposals require at least one evidence item. The proposer may attach the project's logical Worker route, but no GPT session identity is stored.
2. **Deduplicate atomically.** The RPC takes a project/fingerprint advisory transaction lock. It returns an existing active initiative for the same fingerprint, or a prior learning record when that root cause was already closed and learned. A partial unique index is the database backstop.
3. **Request support when blocked.** `request_initiative_support` stores the missing capability, why it is needed, alternatives already checked, what it unlocks, and the exact requested resources. It locks the same initiative row used by `advance_initiative` and rechecks lifecycle state before inserting. This serializes request creation with task-wave materialization: either advancement observes the pending request and blocks, or the request waits until the current advancement transaction commits and blocks subsequent waves. The Owner resolves it with `decide_initiative_support` (`grant`, `decline`, or `withdraw` while pending). Any pending or declined support request blocks further task materialization until it is resolved; withdraw a request if it is no longer needed. A grant records its scope; it does not itself grant a GitHub/Supabase permission or authorize spending outside the stated grant.
4. **Approve or reject.** `decide_initiative` is the human decision gate. Approval must include a bounded work plan of 1–100 uniquely keyed items. Rejection cannot carry an executable plan.
5. **Validate the DAG.** The approval RPC validates work keys, dependency references, item bounds, and cycles before persisting the plan. The work plan is immutable through the public API after the decision.
6. **Materialize only ready work.** `advance_initiative` creates ordinary project-scoped tasks only for planned items whose dependencies have all reached task status `accepted`. It creates every currently-ready item in one transaction, allowing independent items in the same wave to run in parallel. A dependent item does not enter `public.tasks` while any prerequisite remains incomplete, so the existing `claim_task` does not need to interpret initiative metadata.
7. **Advance between waves.** After task acceptance/review, a live coordinator calls `advance_initiative` again with a fresh idempotency key. It marks accepted work items complete and releases the next ready wave. This is session-driven coordination, not a daemon or background scheduler.
8. **Close and learn.** When all work items are accepted, `advance_initiative` moves the initiative to `ready_to_close`. Only a fully executed `ready_to_close` initiative may create a fingerprint-suppressing learning; rejected and abandoned proposals cannot suppress future proposals. Learning evidence must be a non-empty array of objects with non-empty `kind`, `ref`, and `observation` fields. `record_initiative_learning` persists the lesson, evidence and the same stable fingerprint; that transaction moves the initiative to `completed`. Future proposals with that fingerprint are surfaced as known learning rather than duplicated. `abandon_initiative` cancels its still-pending tasks; it refuses to abandon while an initiative task is running or submitted.

Tasks created from a work item carry `requirements.initiative` with initiative ID, work item ID/key, dependency keys and origin. Existing task execution, lease fencing, review, artifact, and event mechanisms remain authoritative.

## RPC surface

| RPC | Purpose |
|---|---|
| `propose_initiative(project_id, worker_id, payload, idempotency_key)` | Create or deduplicate a proposal |
| `decide_initiative(initiative_id, decision, note, work_plan, idempotency_key)` | Owner approves with DAG or rejects |
| `request_initiative_support(initiative_id, worker_id, payload, idempotency_key)` | Record a durable human-support request |
| `decide_initiative_support(request_id, decision, note, granted_scope, idempotency_key)` | Owner grants, declines, or withdraws pending support |
| `advance_initiative(initiative_id, worker_id, idempotency_key)` | Release ready task wave and update initiative state |
| `abandon_initiative(initiative_id, reason, idempotency_key)` | Stop a non-running initiative and cancel pending work |
| `record_initiative_learning(initiative_id, fingerprint, category, lesson, evidence, idempotency_key)` | Persist reusable experience |
| `get_initiative(initiative_id)` | Read proposal, work plan, support, events and learning |
| `list_initiatives(project_id, status, limit)` | Discover project initiatives |

Every mutating RPC is project-owner authorized and idempotent. Use a fresh idempotency key for each distinct invocation. Reusing a key with changed arguments is rejected by the existing idempotency contract.

## Payload examples

Proposal:

```json
{
  "origin": "ai_initiative",
  "title": "Close a reproducible task lifecycle gap",
  "summary": "The current workflow loses a specific durable state transition.",
  "rationale": "The exact CI run and code path show the failure.",
  "desired_outcome": "The transition is persisted and covered by a regression test.",
  "scope": ["Love-DC/recursive-ai-engineering"],
  "evidence": [
    {"kind": "ci_run", "ref": "https://github.com/.../actions/runs/123", "observation": "Exact failing assertion"}
  ],
  "risk": "low",
  "priority": 10,
  "resource_budget": {"external_spend_allowed": false, "bounded_execution": true},
  "support_needed": [],
  "deduplication_fingerprint": "task-lifecycle:stale-transition:tasks"
}
```

Approved work plan:

```json
[
  {"work_key":"inspect","title":"Inspect the failing transition","description":"Confirm the root cause and exact acceptance behavior.","priority":10,"requires_review":true,"depends_on":[]},
  {"work_key":"implement","title":"Implement the bounded correction","description":"Apply the correction and add regression coverage.","priority":20,"requires_review":true,"depends_on":["inspect"]},
  {"work_key":"verify","title":"Verify the exact delivery","description":"Run exact-head CI and record evidence.","priority":30,"requires_review":true,"depends_on":["implement"]}
]
```

Support request:

```json
{
  "request_kind": "permission",
  "capability": "Read access to the named external repository",
  "rationale": "The evidence cannot be verified from currently connected sources.",
  "alternatives_checked": ["Registered project metadata", "Existing GitHub connection"],
  "unlocks": "Independent verification of the dependency and a bounded implementation plan.",
  "requested_resources": {"repository": "owner/repository", "access": "read"}
}
```

## Operational rules

- Resolve project and Worker IDs from live Supabase rows; never copy IDs from another project.
- Do not store secrets, credentials, private data, or raw tokens in proposals, work plans, support requests, events, or learning.
- Treat high-risk work, external spending, external commitments, production deployment, destructive data changes, and reserved product decisions as explicit decision boundaries.
- A support grant is a durable decision record, not a mechanism for changing external permissions. Pending/declined support blocks all task materialization; a declined request requires abandoning/re-proposing the initiative with a revised path.
- A work item becomes claimable only after all prerequisite work items are accepted. Parallelism is limited to the currently ready wave.
- An initiative is not marked `completed` until its terminal learning record is persisted with the same fingerprint used for proposal deduplication.
- For tasks requiring review, the existing independent review lifecycle must accept the delivery before its work item unlocks dependents.
- If a task fails or is rejected, repair/retry it through the existing task lifecycle; do not mark its work item complete.
- A fresh GPT conversation can continue by calling `list_initiatives`, `get_initiative`, and then the relevant RPC. No originating transcript is required.
- This migration is a candidate only. CI and independent review must pass before any separate production deployment decision.

## Known limits

- The current implementation uses the existing project-owner MCP authorization context. It does not add per-session authentication or identity.
- Initiative advancement is invoked by an active session after task/review state changes. There is no background worker, event trigger, or automatic GPT session launcher.
- The approved DAG is immutable after approval in this version; changes require a new initiative or a future explicit revision protocol.
- Support is initiative-scoped in this version: any pending or declined support request pauses all task materialization, rather than selectively blocking only one work item.
- The RPC records support grants but cannot provision external account permissions or execute external resource acquisition.
- The migration does not alter the existing `claim_task` function. It avoids dependency bypass by materializing only the currently-ready wave into the task queue.
