# RAE Problem Inbox

## Purpose and source of truth

The problem inbox is the durable cross-session register for defects, blockers, risks, security findings, operational failures, owner decisions, and improvement opportunities across all active registered projects.

- Supabase `public.problem_reports` is the source of truth for reports, status, evidence, deduplication, and report history.
- Supabase `public.tasks` remains the executable work queue. A report is not claimable work.
- GitHub remains authoritative for code, Issues, PRs, commits, and CI. Store links to those records in the report.
- Do not leave a material finding only in a ChatGPT transcript, task description, or PR comment.

The additive migration `20261124000400_problem_inbox.sql` and the Problem Inbox schema remain deployed. The Owner-MCP compatibility migration `20261125120000_owner_mcp_problem_inbox_context.sql` is deployed as registry version `20261124220548`; the RAE System Owner migration `20261125130000_rae_system_owner_authority.sql` is deployed as `20261124220606`.

The private `rae-core` principal is active for project-scoped engineering and Problem Inbox operations. Live `list_problem_reports`, `get_problem_report`, and `update_problem_report` calls succeeded under `private.begin_rae_system_context(project_id)`, with `auth.uid()` remaining NULL. These calls preserve the JWT Owner path and project isolation. `private.system_principals` and `private.system_actor_audit` have RLS enabled and no direct table privileges for `anon` or `authenticated`. The System Owner cannot change project pause controls; that remains human-only.

Live project controls rechecked on 2026-11-25: RAE, Colony Sim and Hexa Game Kernel are `autonomy.paused=false`/max 2; Lambent is `autonomy.paused=true`/max 2. No registered project retains legacy `config.task_activation`. RAE's engineering queue and Inbox are available to the System Owner through the normal project-bound RPC context; never treat an RPC failure as an empty inbox or write Inbox tables directly.
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

Use the bound RAE System Owner context for normal engineering triage:

```sql
BEGIN;
SELECT private.begin_rae_system_context('<RAE project UUID>'::uuid);
SELECT public.list_problem_reports('unresolved', null, 200);
SELECT public.get_problem_report('<report UUID>'::uuid);
COMMIT;
```

The deployed RPCs enforce project-owner/System Owner scope and preserve the existing JWT Owner path. Pass `unresolved` to return open, triaged, in-progress, and Owner-input-required reports. Verify the live list/get result before updating a report; never treat an RPC failure as an empty inbox.
## Required session behavior

At session start:
1. Read this contract.
2. Attempt the owner-scoped inbox read only after verifying the live connection context and RPC behavior. On success, inspect unresolved high/critical reports and all `owner_input_required` reports.
3. Use the project-bound `rae-core` context for RAE triage. If a live Inbox RPC fails, treat the inbox status as unknown—not empty—and stop attempts to infer individual report states through that path.
4. Continue existing reports before creating overlapping work only when their current status and links were retrieved through an authorized read.
5. If a required read/update RPC is unavailable, do not fabricate success or write directly to tables. Use only the exceptional Issue #42 fallback below and keep the exact availability blocker visible.

During execution:
1. Record material findings promptly, not only at session end.
2. If a report is actionable under repository governance, create/claim the normal project-scoped task and link it to the report.
3. If it requires Owner input, preserve it as `owner_input_required`; do not put it in the claimable task queue.
4. Update the report as work progresses and resolve only with verified evidence.
5. If a session cannot finish, leave the report and task state truthful so another fresh session can continue.

## Last recorded Problem Inbox digest — historical, not a live status view

The following entries were recorded in the prior PR #67 snapshot on 2026-11-24/25. The live list/get RPCs are now verified under the RAE System Owner context. The entries below are a prior snapshot, not a current status digest; re-read each report before acting. The report specifically resolved in this session is identified below.

- **RAE — medium defect (last recorded as in progress):** `adc5c02c-d9ce-4850-9181-0c137317f7ae`, “RAE startup and inbox governance snapshots contradict live deployment”. Linked task: `34e01a68-244a-4832-87c3-ce86536a3a49`. PR #66/#67 corrected the cited startup and governance documents. The task record was reported as `failed`; neither that task state nor the Problem Inbox report's current status was changed or revalidated by this documentation update.
- **RAE — high risk (last recorded as in progress):** `e70803f3-57d4-402c-9823-a38a8a7ef59f`, “Repository-local activation policy conflicts with deployed database task_activation guard”. Linked task: `a16f1098-80e3-4ad6-a4f8-029e2849be4f`. PR #66's guard is now deployed, but no current report status is asserted here.
- **Colony Sim — high blocker (last recorded as in progress):** `84eeb1f9-4c09-4890-abb2-e5955f898577`, “Colony Sim activation remains gated by policy/runtime boundary reconciliation”. PR #433 is recorded as merged at `5f3cc67d65da584db3640948ee37828104003fea`; the current project is unpaused/max 2 and PR #438 has refreshed its activation documentation. No current Problem Inbox status is asserted here. No gameplay changes are authorized by this infrastructure work.
- **RAE — medium opportunity (last recorded as triaged):** `5dc26ae9-b877-47ed-a2fc-1036ff6fbe8b`, “Initiative and Problem Inbox tables have unindexed foreign keys”. The prior Performance Advisor snapshot reported 12 unindexed foreign-key findings and 5 unused-index findings as of 2026-11-24 19:09:54 UTC. This is historical evidence, not current measurement or authorization to add/drop production indexes.

Report `eca33e89-85e3-4beb-af95-82eabc247cc1` (“Owner-MCP Problem Inbox RPCs reject trusted owner context”) was re-read through `get_problem_report`, resolved after PR #74's production migration deployment, and linked to https://github.com/Love-DC/recursive-ai-engineering/pull/74. Do not create a duplicate report.

## Exceptional fallback when the live inbox RPC is unavailable

The normal RAE System Owner Problem Inbox RPCs are currently live and verified. This section applies only if a future live read/update check fails for the exact connection/context. The database-wide claim-safety gate remains a separate prerequisite for task/execution lifecycle writes.

- If a Problem Inbox RPC becomes unavailable, treat the inbox as unknown—not empty. Do not retry indefinitely, fabricate report status, or bypass owner-scoped RPCs with direct table reads/writes.
- Issue #42 is a closed historical transitional-intake record, not the normal intake workflow. Do not create a replacement issue or add comments there unless a future session verifies that the exceptional fallback is explicitly required and writable.
- Never write directly to `problem_reports` or `problem_report_events`, bypass owner-scoped RPCs, or claim cross-session Inbox availability without a successful live read.
- If the Inbox RPC path remains unavailable and the historical fallback is unusable, remain read-only for Inbox state and surface the exact blocker.


This is session-driven coordination. No background daemon, external messaging integration, or automatic ChatGPT notification is implied.
