# RAE Problem Inbox

## Purpose and source of truth

The problem inbox is the durable cross-session register for defects, blockers, risks, security findings, operational failures, owner decisions, and improvement opportunities across all active registered projects.

- Supabase `public.problem_reports` is the source of truth for reports, status, evidence, deduplication, and report history.
- Supabase `public.tasks` remains the executable work queue. A report is not claimable work.
- GitHub remains authoritative for code, Issues, PRs, commits, and CI. Store links to those records in the report.
- Do not leave a material finding only in a ChatGPT transcript, task description, or PR comment.

The additive migration `20261124000400_problem_inbox.sql` is deployed in the shared RAE Supabase database. The tables and original RPCs exist, but the live trusted Owner-MCP read test on 2026-11-25 showed that `list_problem_reports('unresolved', null, 200)` returns `UNAUTHENTICATED`: the original function still requires `auth.uid()`, which the verified MCP `postgres` session intentionally does not synthesize. Source inspection found the same JWT-only row lookup in `get_problem_report` and `update_problem_report`. The repository now contains a narrowly scoped repair migration, `20261125120000_owner_mcp_problem_inbox_context.sql`, and isolated PostgreSQL regression tests for list/get/update, Owner-wide listing, project-bound detail/update, and the unchanged no-JWT rejection boundary. **The repair migration is not deployed to production.** Until production deployment and a successful live RPC read/write verification, the Problem Inbox must be treated as unavailable through Owner-MCP.

PR #66's repository-authoritative activation migration is deployed as live migration `20261124192533`; the legacy `projects.config.task_activation` guard is removed. The live controls were rechecked on 2026-11-25: Colony Sim and Hexa Game Kernel are `autonomy.paused=false`/max 2; RAE and Lambent are `autonomy.paused=true`/max 2. Colony Sim's repository-owned bounded active-session engineering policy and activation gates are approved. The trusted Owner-MCP execution-context migration `20261124200149` and project registration migration `20261124202438` are deployed and bind the verified Owner/project in the `postgres` session without fabricating `auth.uid()`. However, the Problem Inbox RPCs were not updated for that context: the live `list_problem_reports` call fails with `UNAUTHENTICATED`, and `get_problem_report`/`update_problem_report` still contain JWT-only owner filters. The new repair migration `20261125120000_owner_mcp_problem_inbox_context.sql` is repository code only and is not deployed. Do not write task or Problem Inbox tables directly; do not claim inbox reads or updates work until the migration is deployed and all three RPCs are tested live.

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

The following owner-authorized RPCs are deployed and should be used through the connected Supabase MCP context after the live database gate and selected project scope are re-verified:

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

Use a stable idempotency key derived from project + fingerprint. The RPC also serializes concurrent reports by project/fingerprint and returns the existing active report rather than creating a duplicate.

### Owner decisions

When a concrete Owner decision is required, create the report with:
- `status: "owner_input_required"`
- a precise `owner_question`
- evidence and impact
- the alternatives and their consequences in the summary/recommended action

This state is deliberately separate from the executable task queue. Do not create a pending implementation task for work that cannot proceed without the decision.

### Link and resolve work

Use `update_problem_report(report_id, status, note, linked_task_id, linked_pr_url, idempotency_key)` to:
- move a report through `open`, `triaged`, `in_progress`, and `owner_input_required`;
- link the actual project-scoped task and PR;
- mark it `resolved` only after verifying the fix or decision outcome;
- mark it `wont_fix` only with a concise rationale.

Terminal reports can be reopened explicitly to `open` or `triaged`. Every state transition is appended to `problem_report_events`; event history is immutable.

### Read the Owner's inbox

`list_problem_reports(status, severity, limit)` returns reports across all active projects owned by the authenticated Owner, including project name and repository. Pass `unresolved` to return only open, triaged, in-progress, and Owner-input-required reports. The default status filter is null; the Owner's main digest should normally include unresolved states:
- `open`
- `triaged`
- `in_progress`
- `owner_input_required`

Use `get_problem_report(report_id)` for full evidence and event history.

The expected Owner query is:

```sql
select public.list_problem_reports('unresolved', null, 200);
```

The function itself enforces Owner scope using the authenticated project-owner context. Do not query or expose another project's reports.

## Required session behavior

At session start:
1. Read this contract.
2. Query the cross-project inbox and inspect unresolved high/critical reports and all `owner_input_required` reports.
3. Continue existing reports before creating overlapping work.
4. Check whether the report already has a linked task or PR.
5. If the live RPC cannot be verified or is unavailable, do not fabricate success or write directly to the tables. Use only the exceptional fallback below and keep the availability blocker visible.

During execution:
1. Record material findings promptly, not only at session end.
2. If a report is actionable under repository governance, create/claim the normal project-scoped task and link it to the report.
3. If it requires Owner input, preserve it as `owner_input_required`; do not put it in the claimable task queue.
4. Update the report as work progresses and resolve only with verified evidence.
5. If a session cannot finish, leave the report and task state truthful so another fresh session can continue.

## Current live state — 2026-11-25

The owner-scoped Problem Inbox list RPC currently fails in the trusted Owner-MCP context. Do not treat the historical report IDs/statuses in older conversation notes or repository snapshots as a live inbox digest. Do not query or mutate the protected tables directly to work around the RPC. After the repair migration is deployed, re-run the owner-scoped list/get/update RPC tests and only then refresh the unresolved report digest from the live result.

## Unavailable inbox behavior

The temporary [Issue #42](https://github.com/Love-DC/recursive-ai-engineering/issues/42) intake record is closed and is not a writable fallback. Do not reopen it, add comments, or create a replacement intake issue merely because the live RPC is unavailable.

- When the live Problem Inbox RPCs are verified, record findings through the owner-scoped RPCs.
- Until the Owner-MCP repair migration is deployed and list/get/update are verified live, remain read-only for Problem Inbox records. Do not write directly to `problem_reports` or `problem_report_events`.
- Do not infer current report IDs, statuses, or event history from dated snapshots.
- A closed or uncertain database gate independently prohibits task/execution/Initiative/Problem Inbox mutation RPCs. Continue only read-only inspection and repository-only maintenance.

