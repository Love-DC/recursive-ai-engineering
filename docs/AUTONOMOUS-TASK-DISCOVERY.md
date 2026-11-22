# Autonomous Task Discovery & Generation

**Status:** Worker operating contract for the trusted owner-MCP pilot. It does not install a background scheduler, change database schema, or grant new production permissions.

## Goal

A Worker must not treat an empty queue as the end of useful work. It should inspect the project it is authorized to work on, identify evidence-backed engineering opportunities, turn eligible findings into bounded tasks in that same project's Supabase queue, and then return to the normal atomic claim/execute/verify workflow.

Autonomy means initiative within a declared project boundary—not authority to make product decisions, bypass approvals, deploy, merge, or turn arbitrary backlog into permission.

## Discovery loop

Run this loop at session start when no eligible task exists, and after completing a task when the current objective permits continued work:

1. **Resolve scope.** Read the active project row, its repository, project-scoped active shared-executor Worker, governance config, and task activation policy. Never infer or reuse another project's IDs.
2. **Inspect evidence.** Review configured project-state and architecture docs, recent relevant commits/PR/CI results, test coverage, TODO/FIXME markers with context, dependency/security reports where available, and read-only operational health. Inspect only sources allowed by project policy.
3. **Form candidates.** Each candidate must name a concrete observed condition, exact evidence (file/line, commit, CI run, or query result), project impact, bounded proposed change, risk class, acceptance criteria, and validation plan. Do not create speculative tasks from vague preferences.
4. **Classify authority.** Apply the project's task_activation and governance rules before creating anything. If a project has no explicit task_activation config, use its repository's documented governance contract; never infer a permissive default for an external project. If the finding needs product, security, data, or production approval, record it as a proposal/report and stop at the decision gate.
5. **Deduplicate.** Compare candidate fingerprint and affected scope against all non-terminal tasks and recent task events in that project. Reuse/update an existing task where supported; never create a second active task for the same root cause. A fingerprint should be stable across scans (project key + normalized issue signature + affected paths or failing check).
6. **Control noise.** Create at most three new discovery tasks per project per scan, one per distinct root cause. Skip low-impact style-only churn, unsupported claims, already-fixed findings, and candidates without reproducible evidence. If no candidate passes, leave the queue empty and report what was inspected.
7. **Publish.** For an eligible candidate, call the project's create_task using that project's UUID and its own active Worker UUID. Store discovery source, evidence references, fingerprint, risk/authority classification, impact, acceptance criteria, validation plan, and originating scan timestamp in requirements. Use an idempotency key derived from scan/candidate identity; never reuse a key for different arguments.
8. **Execute.** Newly created tasks are ordinary project-scoped tasks. Claim them only through claim_task; the atomic response is authoritative. Follow normal branch, test, PR, and evidence rules. Do not silently self-approve tasks that require review.

## Authority matrix

| Finding / action | RAE project (recursive-ai-engineering) | External project (example: Colony Sim) |
|---|---|---|
| Documented bug, failing test/CI, broken internal workflow | May create a bounded implementation task when evidence and acceptance criteria are clear | May create only if that project's activation policy explicitly authorizes autonomous task creation; otherwise propose only |
| Documentation drift or missing regression test | May create low-risk task; batch only when tightly related | Follow the external project's own dispatch/approval contract |
| Refactor, performance or architecture proposal | Create an investigation/proposal task; implementation needs an explicit bounded engineering basis | Proposal only unless explicitly authorized |
| Product behavior, game design, UX, business rules | Proposal only; owner decision required | Proposal only; product owner decision required |
| Security policy, credentials, RLS/auth, data deletion/migration, production deploy | Report and request explicit authorization | Report and request explicit authorization |
| GitHub Issue/backlog item | An Issue is evidence/input, not by itself an authorization token; apply RAE project policy | Open Issue is backlog, not permission; Colony Sim requires exact owner/coordinator dispatch and READY activation as documented |

**Colony Sim remains explicit_owner_authorization_only.** No discovery scan may bulk-import, auto-claim, or execute Colony Sim Issues. The project's own governance always overrides this generic loop.

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
- [ ] Duplicate active/recent root causes are suppressed using a stable project-scoped fingerprint.
- [ ] Per-scan task creation is capped and low-value findings are skipped.
- [ ] Project routing uses that project's own project UUID and Worker UUID.
- [ ] Project activation policy gates task creation; Colony Sim backlog remains owner-authorized only.
- [ ] Approval-gated work is reported, not silently converted to executable tasks.
- [ ] Created tasks are claimed atomically and completed with normal execution evidence.
- [ ] No scheduler, schema change, deployment, or merge is implied by this pilot contract.

## Repeatable pilot acceptance procedure

Run these cases against a disposable or transaction-rolled-back task fixture where possible. Do not mutate production state merely to demonstrate the negative cases.

| Scenario | Input | Expected result |
|---|---|---|
| Evidence-backed RAE defect | A current failing RAE CI check with exact run URL, affected path, and reproducible failure | One bounded RAE task is created with evidence, acceptance criteria, validation, and a stable fingerprint |
| Duplicate scan | Repeat the same finding with the same fingerprint while its task is non-terminal | No second active task is created; report the existing task ID |
| Unsupported candidate | A vague TODO or speculative refactor with no demonstrated impact or validation | No task is created; finding is omitted or recorded as a proposal |
| Approval-gated change | A candidate requires product, security, auth/RLS, data migration, or production approval | No executable task is created; report the specific owner decision required |
| External backlog | An open Colony Sim Issue without an exact owner/coordinator dispatch and valid READY activation | No Colony Sim task is created or claimed |
| Project routing | An authorized candidate belongs to another project whose policy permits creation | Task is written only with that project's project UUID and matching active Worker UUID |

For a positive RAE case, verify the new row with project-scoped list_tasks/get_task, then claim it through claim_task and confirm the returned task_id/project_id and execution_id. Do not complete a fixture task unless the test is explicitly intended to exercise the full lifecycle. For negative cases, verify that task counts and existing task states remain unchanged. Record inspected sources, candidate fingerprints, created task IDs, and any skipped approval-gated proposals in the run result.
