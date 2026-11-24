# RAE Problem Inbox

## Purpose and source of truth

The problem inbox is the durable cross-session register for defects, blockers, risks, security findings, operational failures, owner decisions, and improvement opportunities across all active registered projects.

- Supabase `public.problem_reports` is the source of truth for reports, status, evidence, deduplication, and report history.
- Supabase `public.tasks` remains the executable work queue. A report is not claimable work.
- GitHub remains authoritative for code, Issues, PRs, commits, and CI. Store links to those records in the report.
- Do not leave a material finding only in a ChatGPT transcript, task description, or PR comment.

The additive migration `20261124000400_problem_inbox.sql` is a candidate until merged, independently reviewed, and separately deployed. Do not claim the inbox is live until the migration is present in the deployed Supabase schema and the RPC smoke test passes.

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

After the migration is deployed, use these owner-authorized RPCs through the connected Supabase MCP context:

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
5. If the RPC is not deployed, do not fabricate success or write directly around the missing authorization boundary. Use the documented temporary GitHub intake fallback and keep the deployment blocker visible.

During execution:
1. Record material findings promptly, not only at session end.
2. If a report is actionable under repository governance, create/claim the normal project-scoped task and link it to the report.
3. If it requires Owner input, preserve it as `owner_input_required`; do not put it in the claimable task queue.
4. Update the report as work progresses and resolve only with verified evidence.
5. If a session cannot finish, leave the report and task state truthful so another fresh session can continue.

## Transitional fallback before deployment

The transitional inbox fallback does not override the database-wide production claim-safety gate in `docs/SESSION-START.md`. That gate must be verified open before any task or execution lifecycle write in any project sharing the database. If the gate is closed or cannot be proven open, do not create, claim, reassign, requeue, cancel, review, heartbeat, submit, fail, complete, or otherwise mutate task/execution state. In that case, record material findings only as comments on the single temporary intake issue below and continue with read-only inspection/discovery and repository-only maintenance.

Until the migration is deployed, the `problem_reports` table and RPCs do not exist in production. In that interval:

- Only after the production claim-safety gate is verified open, record bounded, authorized implementation work in the existing project-scoped task queue with evidence and a stable fingerprint. The target repository's own task-activation policy still applies.
- Record all material findings (including Owner decisions) as comments on the single temporary intake issue: https://github.com/Love-DC/recursive-ai-engineering/issues/42. Include the project/repository, category, severity, exact evidence links, stable fingerprint, recommended action, and whether Owner input is required. Do not create parallel intake issues.
- Do not claim cross-session Supabase inbox availability until the migration and RPCs are deployed and verified.
- After deployment, migrate any still-open transitional records into the Supabase inbox and close the temporary intake issue with a pointer to the live query.

This is session-driven coordination. No background daemon, external messaging integration, or automatic ChatGPT notification is implied.
