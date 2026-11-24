# RAE Problem Inbox

## Purpose and source of truth

The problem inbox is the durable cross-session register for defects, blockers, risks, security findings, operational failures, owner decisions, and improvement opportunities across all active registered projects.

- Supabase `public.problem_reports` is the source of truth for reports, status, evidence, deduplication, and report history.
- Supabase `public.tasks` remains the executable work queue. A report is not claimable work.
- GitHub remains authoritative for code, Issues, PRs, commits, and CI. Store links to those records in the report.
- Do not leave a material finding only in a ChatGPT transcript, task description, or PR comment.

The additive migration `20261124000400_problem_inbox.sql` and its tables/RPCs are deployed in the shared RAE Supabase database. The repository-only migration `20261125130000_rae_system_owner_authority.sql` extends these scoped RPC checks to the RAE system principal, but it is not deployed to production; until live deployment is separately authorized and verified, continue to treat the existing Owner-MCP limitation described below as authoritative. **Deployment of the schema is not proof that every RPC works through every authorized connection.** On 2026-11-25, this session established `private.begin_owner_mcp_context(project_id, owner_id)` in the supported `postgres` SQL-MCP transaction (`auth.uid()` remains NULL). `list_tasks` and `list_initiatives` succeeded, but `public.list_problem_reports('unresolved', NULL, 200)` failed with SQLSTATE `28000`, `UNAUTHENTICATED`, because the function requires non-NULL `auth.uid()` and scopes by `projects.owner_id=auth.uid()`. The Problem Inbox cannot currently be enumerated through this Owner-MCP connection. The repository migration `20261125120000_owner_mcp_problem_inbox_context.sql` adds Owner-MCP-aware authorization to list/get/update while preserving JWT checks and exact project binding; isolated PostgreSQL regression tests cover same-Owner cross-project listing and reject cross-project detail/update. The migration is code only and is not deployed to production. Re-check all three RPCs against the live database after a separately authorized deployment; never represent an unavailable read as an empty inbox.

PR #66's repository-authoritative activation migration is deployed as `20261124192533`. The trusted Owner-MCP execution-context migration `20261124200149` and project-registration migration `20261124202438` are also deployed. Current live controls rechecked on 2026-11-25: Colony Sim and Hexa Game Kernel `autonomy.paused=false`/max 2; RAE and Lambent `autonomy.paused=true`/max 2. RAE remains paused, so this session performs repository-only RAE maintenance rather than creating or claiming RAE tasks. The deployed Owner-MCP context supports selected task/initiative RPCs, but it does **not** synthesize a JWT or make all Problem Inbox RPCs compatible. The list/detail/update RPCs that directly depend on `auth.uid()` remain unavailable through this connection until the repair migration is deployed. The migration does not change table grants, RLS, or production state. Do not write Problem Inbox tables directly and do not claim a report status is current unless it was obtained through a successful authorized read.

## What to report

Create a report when a session discovers a concrete, material item that needs tracking:

- A reproducible defect or failing check.
- A blocked task, missing capability, broken integration, or workflow gap.
- A security, reliability, data-integrity, or operational risk.
- A decision that only the Owner can make.
- An evidence-backed improvement opportunity that should not be silently lost.

Do not report speculative concerns, style-only preferences, or already-resolved root causes. Link related findings to one stable root-cause fingerprint rather than creating repeated reports.

Every report must include:
- Project UUID resolved from the live `public.projects` row.
- Category: `defect | blocker | risk | security | operations | decision | opportunity | other`.
- Severity: `info | low | medium | high | critical`.
- A concise title, summary, and impact.
- At least one evidence object with non-empty `kind`, `ref`, and `observation`.
- Source and a stable fingerprint: project key + normalized root cause + affected path/check.
- A recommended action when one is known.

Never include credentials, secrets, personal data, or unbounded environment dumps.

## RPC contract

The RPCs are deployed, but compatibility with the trusted Owner-MCP context is function-specific. The live function bodies were inspected on 2026-11-25; the following restrictions apply until a reviewed fix is separately authorized and deployed:

### Report a finding

`report_problem(project_id, worker_id, payload, idempotency_key)`

Payload example:

```json
{
  "category": "blocker",
  "severity": "high",
  "status": "open",
  "title": "Task handoff evidence is missing",
  "summary": "The expected handoff record is absent after execution submission.",
  "impact": "The delivery cannot be independently verified.",
  "recommended_action": "Inspect the exact execution and restore the missing evidence.",
  "evidence": [
    {
      "kind": "execution",
      "ref": "https://github.com/owner/repo/actions/runs/123",
      "observation": "The expected handoff artifact was not produced."
    }
  ],
  "source": "ci",
  "source_ref": "https://github.com/owner/repo/actions/runs/123",
  "fingerprint": "rae:handoff-artifact-missing:scripts/submit.sh"
}
```

Use a stable idempotency key derived from project + fingerprint. The function body delegates owner authorization to `private.assert_owner`, which recognizes the transaction-scoped Owner-MCP context for task RPCs; however, this session did not execute this mutating RPC and has not verified that `report_problem` succeeds end-to-end through Owner-MCP. Do not use a production mutation as a health probe. Treat Owner-MCP write compatibility as unverified until covered by isolated tests and an explicitly authorized end-to-end check.

### Owner decisions

When a concrete Owner decision is required, create the report with:
- `status: "owner_input_required"`
- a precise `owner_question`
- evidence and impact
- the alternatives and their consequences in the summary/recommended action

This state is deliberately separate from the executable task queue. Do not create a pending implementation task for work that cannot proceed without the decision.

### Link and resolve work

**Owner-MCP limitation:** `update_problem_report` first filters the report by `projects.owner_id=auth.uid()` before calling `private.assert_owner`. With `auth.uid()` NULL, this path cannot resolve the report. Do not call it through the current Owner-MCP connection and do not update the tables directly. Production repair of this authorization path requires a reviewed security change and separate deployment authorization.

When a supported authenticated Owner context is available and the RPC has been live-verified, use `update_problem_report(report_id, status, note, linked_task_id, linked_pr_url, idempotency_key)` to:
- move a report through `open`, `triaged`, `in_progress`, and `owner_input_required`;
- link the actual project-scoped task and PR;
- mark it `resolved` only after verifying the fix or decision outcome;
- mark it `wont_fix` only with a concise rationale.

Terminal reports can be reopened explicitly to `open` or `triaged`. Every state transition is appended to `problem_report_events`; event history is immutable.

### Read the Owner's inbox

**Currently unavailable through the connected Owner-MCP session:** `list_problem_reports(status, severity, limit)` raises `UNAUTHENTICATED` when `auth.uid()` is NULL. Its owner filter also uses `p.owner_id=auth.uid()`. Do not call it repeatedly expecting the private Owner context to change `auth.uid()`, and do not treat a failure as an empty inbox. The same direct `auth.uid()` lookup is present in `get_problem_report(report_id)`, so report detail/event history is likewise unavailable through this connection.

When using a genuine authenticated Owner context (or after a reviewed Owner-MCP compatibility fix is separately deployed), and after a successful live check, `list_problem_reports(status, severity, limit)` is intended to return reports across all active projects owned by the authenticated Owner, including project name and repository. Pass `unresolved` to return only open, triaged, in-progress, and Owner-input-required reports. The default status filter is null; the Owner's main digest should normally include unresolved states:
- `open`
- `triaged`
- `in_progress`
- `owner_input_required`

Use `get_problem_report(report_id)` for full evidence and event history.

The expected query in a supported authenticated Owner context is:

```sql
select public.list_problem_reports('unresolved', null, 200);
```

The function itself enforces Owner scope using the authenticated project-owner context. Do not query or expose another project's reports.

## Required session behavior

At session start:
1. Read this contract.
2. Attempt the owner-scoped inbox read only after verifying the live connection context and RPC behavior. On success, inspect unresolved high/critical reports and all `owner_input_required` reports.
3. If `list_problem_reports` returns `UNAUTHENTICATED` under Owner-MCP, treat the inbox status as unknown—not empty—and stop attempts to enumerate individual reports through that path.
4. Continue existing reports before creating overlapping work only when their current status and links were retrieved through an authorized read.
5. If a required read/update RPC is unavailable, do not fabricate success or write directly to tables. Use only the exceptional Issue #42 fallback below and keep the exact availability blocker visible.

During execution:
1. Record material findings promptly, not only at session end.
2. If a report is actionable under repository governance, create/claim the normal project-scoped task and link it to the report.
3. If it requires Owner input, preserve it as `owner_input_required`; do not put it in the claimable task queue.
4. Update the report as work progresses and resolve only with verified evidence.
5. If a session cannot finish, leave the report and task state truthful so another fresh session can continue.

## Last recorded Problem Inbox digest — historical, not a live status view

The following entries were recorded in the prior PR #67 snapshot on 2026-11-24/25. The Owner-MCP listing RPC has since been verified to fail with `UNAUTHENTICATED`; **none of these statuses or current report links have been re-read in this session**. Preserve these IDs as historical references only. Do not infer that a report is still open, in progress, resolved, or actionable from this list.

- **RAE — medium defect (last recorded as in progress):** `adc5c02c-d9ce-4850-9181-0c137317f7ae`, “RAE startup and inbox governance snapshots contradict live deployment”. Linked task: `34e01a68-244a-4832-87c3-ce86536a3a49`. PR #66/#67 corrected the cited startup and governance documents. The task record was reported as `failed`; neither that task state nor the Problem Inbox report's current status was changed or revalidated by this documentation update.
- **RAE — high risk (last recorded as in progress):** `e70803f3-57d4-402c-9823-a38a8a7ef59f`, “Repository-local activation policy conflicts with deployed database task_activation guard”. Linked task: `a16f1098-80e3-4ad6-a4f8-029e2849be4f`. PR #66's guard is now deployed, but no current report status is asserted here.
- **Colony Sim — high blocker (last recorded as in progress):** `84eeb1f9-4c09-4890-abb2-e5955f898577`, “Colony Sim activation remains gated by policy/runtime boundary reconciliation”. PR #433 is recorded as merged at `5f3cc67d65da584db3640948ee37828104003fea`; the current project is unpaused/max 2 and PR #438 has refreshed its activation documentation. No current Problem Inbox status is asserted here. No gameplay changes are authorized by this infrastructure work.
- **RAE — medium opportunity (last recorded as triaged):** `5dc26ae9-b877-47ed-a2fc-1036ff6fbe8b`, “Initiative and Problem Inbox tables have unindexed foreign keys”. The prior Performance Advisor snapshot reported 12 unindexed foreign-key findings and 5 unused-index findings as of 2026-11-24 19:09:54 UTC. This is historical evidence, not current measurement or authorization to add/drop production indexes.

A prior Issue #42 comment recorded the Owner-MCP Problem Inbox defect with fingerprint `rae:owner-mcp-problem-inbox-auth-uid-prefilters:20261125` and mentioned report ID `eca33e89-85e3-4beb-af95-82eabc247cc1`. This session did not re-read that report record or verify its current status. See the supplemental verification [Issue #42 comment](https://github.com/Love-DC/recursive-ai-engineering/issues/42#issuecomment-7144406870); do not create a duplicate report or treat the quoted ID/status as a live query result.

## Exceptional fallback when the live inbox RPC is unavailable

The Problem Inbox schema and RPCs are deployed, but the current trusted Owner-MCP connection cannot enumerate or update reports through the RPCs that require `auth.uid()`. This fallback is exceptional; it is not the normal intake workflow. The database-wide claim-safety gate in `docs/SESSION-START.md` remains a separate prerequisite for every task/execution lifecycle write.

- If a live Problem Inbox RPC is proven available for the exact connection/context and the required project scope, use only that RPC with its declared authorization contract. `list_problem_reports`, `get_problem_report`, and `update_problem_report` are currently incompatible with Owner-MCP because they filter directly on `auth.uid()`. `report_problem` delegates to `private.assert_owner`, but its end-to-end Owner-MCP write path remains unverified; do not test it by creating a production record.
- Issue #42 is the closed historical transitional-intake record. On 2026-11-25 it was confirmed closed but unlocked/writable. Use it only as the documented no-write fallback while the live inbox cannot be verified; add a comment only if it remains writable. Include project/repository, category, severity, exact evidence links, stable fingerprint, recommended action, and whether Owner input is required. Do not create a replacement intake issue.
- Never write directly to `problem_reports` or `problem_report_events`, bypass owner-scoped RPCs, or claim cross-session inbox availability without a successful live read.
- If Issue #42 is locked or otherwise unavailable, remain read-only and surface the exact blocker; do not invent another intake location.
- A closed/uncertain database gate prohibits task, execution, Initiative, and Problem Inbox mutation RPCs. Continue only read-only discovery and repository-only maintenance.


This is session-driven coordination. No background daemon, external messaging integration, or automatic ChatGPT notification is implied.
