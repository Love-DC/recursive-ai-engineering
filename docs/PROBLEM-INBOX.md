# RAE Problem Inbox

## Purpose and source of truth

The problem inbox is the durable cross-session register for defects, blockers, risks, security findings, operational failures, owner decisions, and improvement opportunities across all active registered projects.

- Supabase `public.problem_reports` is the source of truth for reports, status, evidence, deduplication, and report history.
- Supabase `public.tasks` remains the executable work queue. A report is not claimable work.
- GitHub remains authoritative for code, Issues, PRs, commits, and CI. Store links to those records in the report.
- Do not leave a material finding only in a ChatGPT transcript, task description, or PR comment.

The additive migration `20261124000400_problem_inbox.sql` is deployed in the shared RAE Supabase database. On 2026-11-25, the live `problem_reports` and `problem_report_events` tables and Problem Inbox RPCs were verified, and the owner-scoped `list_problem_reports('unresolved', null, 200)` read succeeded. The active-session guard (`20261124181019`) and submitted-task reconciliation (`20261124182111`) migrations are also deployed; project activation remains separately controlled by each project's `task_activation` config. Use this Supabase inbox as the normal cross-session source of truth; re-check availability at each session start.

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

## Current unresolved reports — 2026-11-25

- Colony Sim bounded-autonomy activation and paused kill-switch policy: `0e5e40f3-f099-4810-a316-26f5f7e26e79`. The guard and reconciliation migrations are deployed. PR #432's bounded-autonomy policy is merged and independently accepted; follow-up PR #433 clarifies the paused-versus-unverified-gate wording in `AI_START_HERE.md`. Project activation still awaits the corrected owner-scoped config RPC in RAE PR #64.
- RAE startup/live-deployment documentation drift: `adc5c02c-d9ce-4850-9181-0c137317f7ae`. This documentation refresh is the linked work.
- Initiative/Problem Inbox foreign-key index review opportunity: `5dc26ae9-b877-47ed-a2fc-1036ff6fbe8b`.

The legacy submitted-task reconciliation RPC gap (`af8b1fdd-785c-4a07-88a9-1cfbc06388c7`) is resolved by the deployed `reconcile_submitted_task` RPC; deployment did not bulk-mutate historical records.

## Exceptional fallback when the live inbox RPC is unavailable

The Problem Inbox is deployed and was verified live on 2026-11-25. This fallback is exceptional; it is not the normal intake workflow. The database-wide claim-safety gate in `docs/SESSION-START.md` remains a separate prerequisite for every task/execution lifecycle write.

- If the live Problem Inbox RPCs are available, record material findings there. Do not route routine findings to GitHub Issue #42.
- Issue #42 is the closed historical transitional-intake record. Use it only as the documented no-write fallback when the live inbox cannot be verified or the production gate is closed/uncertain; add a comment only if the issue remains writable. Include project/repository, category, severity, exact evidence links, stable fingerprint, recommended action, and whether Owner input is required. Do not create a replacement intake issue.
- Never write directly to `problem_reports` or `problem_report_events`, bypass owner-scoped RPCs, or claim cross-session inbox availability without a successful live read.
- If Issue #42 is locked or otherwise unavailable, remain read-only and surface the exact blocker; do not invent another intake location.
- A closed/uncertain database gate prohibits task, execution, Initiative, and Problem Inbox mutation RPCs. Continue only read-only discovery and repository-only maintenance.


This is session-driven coordination. No background daemon, external messaging integration, or automatic ChatGPT notification is implied.
