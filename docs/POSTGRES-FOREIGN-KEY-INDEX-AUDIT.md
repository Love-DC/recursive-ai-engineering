# PostgreSQL foreign-key index audit

**Live observation:** 2026-11-24 23:44:04.504 UTC  
**Repository baseline:** main at cc38035e75963f2bf20fede4b95a92d2e2987fdb  
**Scope:** read-only live inspection plus a repository-only additive migration proposal. No live DDL, data mutation, grant, RLS, Auth, or migration-registry change was performed.

## Decision

The Supabase Performance Advisor reported 14 unindexed foreign keys: 12 public composite relationships in Initiative/Problem Inbox tables and two private references from system_actor_audit. The live catalog contains 17 target foreign keys overall. Three are already covered by valid, ready, non-partial indexes. Four more advisor findings have useful existing leading-key indexes. Eight public relationships have no adequate leading-key index and are covered by the additive migration proposed in this PR.

The two remaining private system_actor_audit findings are deliberately deferred. That table contains 318 rows (about 192 KiB), and deleting the referenced system principal or product owner is a rare, RESTRICTed operation. One principal_id reporting query shape exists, but observed usage is low and there is no measured performance problem. Adding two indexes would add write and storage cost to every system-context audit insertion without demonstrated benefit. Revisit after table growth or a representative workload/plan shows a need.

## Live catalog classification

### Three already covered foreign keys

| Relation / FK | Existing valid index | Reason |
|---|---|---|
| private.system_actor_audit.project_id | idx_system_actor_audit_project_created (project_id, created_at DESC) | Full leading-key coverage |
| public.initiatives.project_id | initiatives_project_status_created_idx (project_id, status, created_at DESC) | Full leading-key coverage |
| public.problem_reports.project_id | problem_reports_owner_inbox_idx (project_id, status, severity, created_at DESC) | Full leading-key coverage |

### Four composite warnings with useful leading-key paths

| Relation / FK | Existing index | Assessment |
|---|---|---|
| public.initiative_events.initiative_id, project_id | initiative_events_history_idx (initiative_id, id) | initiative_id is the leading key and the target initiative id is unique; also supports initiative event history reads |
| public.initiative_work_items.initiative_id, project_id | initiative_work_items_key_uq (initiative_id, work_key); initiative_work_items_ready_idx (initiative_id, status, created_at) | Both provide the initiative_id leading key used for parent-side checks and initiative work-item lookups |
| public.initiative_work_items.task_id, project_id | initiative_work_items_task_uq (task_id) WHERE task_id IS NOT NULL | The FK is nullable; rows participating in the FK have non-null task_id, exactly matching the partial-index predicate |
| public.problem_report_events.report_id, project_id | problem_report_events_history_idx (report_id, id) | report_id is the leading key and the target report id is unique; also supports event-history reads |

The Supabase lint reports these composite relationships because the indexes do not contain the complete FK column set. They nevertheless provide a usable leading key for the child-side equality probe; adding duplicate composite indexes solely to silence the lint would increase write amplification without a demonstrated query benefit. The nullable task_id case is covered only for non-null values by its existing predicate, which is the relevant set for FK checks.

### Eight justified public indexes added in this PR

| New index | Foreign-key columns | Rationale |
|---|---|---|
| idx_initiative_events_worker_fk | initiative_events(actor_worker_id, project_id) | No actor-worker leading index; supports RESTRICT parent checks for event actors |
| idx_initiative_learnings_initiative_fk | initiative_learnings(initiative_id, project_id) | get_initiative reads learnings by initiative_id; no initiative_id leading index exists |
| idx_initiative_support_requests_initiative_fk | initiative_support_requests(initiative_id, project_id) | get_initiative reads every support state by initiative_id; the existing initiative_id index is partial to pending rows |
| idx_initiative_support_requests_worker_fk | initiative_support_requests(requested_by_worker_id, project_id) | No requester-worker leading index; supports RESTRICT parent checks |
| idx_initiatives_proposer_fk | initiatives(proposed_by_worker_id, project_id) | No proposer-worker leading index; supports RESTRICT parent checks |
| idx_problem_report_events_worker_fk | problem_report_events(actor_worker_id, project_id) | No actor-worker leading index; supports RESTRICT parent checks |
| idx_problem_reports_task_fk | problem_reports(linked_task_id, project_id) | No linked-task leading index; supports task relationship checks |
| idx_problem_reports_worker_fk | problem_reports(reported_by_worker_id, project_id) | No reporting-worker leading index; supports RESTRICT parent checks |

The new indexes are ordinary, non-partial B-tree indexes in FK column order. The migration is additive and does not alter constraints, data, table grants, RLS, or audit controls.

## Workload and size evidence

Live row counts and table sizes at inspection:

| Table | Rows | Total size |
|---|---:|---:|
| public.initiative_events | 0 | 24 KiB |
| public.initiative_learnings | 0 | 32 KiB |
| public.initiative_support_requests | 0 | 32 KiB |
| public.initiative_work_items | 0 | 48 KiB |
| public.initiatives | 0 | 40 KiB |
| public.problem_report_events | 73 | 128 KiB |
| public.problem_reports | 11 | 224 KiB |
| private.system_actor_audit | 318 | 192 KiB |

PostgreSQL statistics had last reset at 2026-11-13 21:18:31 UTC. The current Problem Inbox workload includes 33 calls to list_problem_reports with a mean observed time of about 5.6 ms; the project/status filtering is already supported by problem_reports_owner_inbox_idx. The get_initiative function reads events, work items, support requests, and learnings by initiative_id. Existing indexes support events and work items; the proposed initiative_id indexes close the gaps for all-state support-request reads and learnings. The Initiative tables currently contain no rows, so this is preventative FK/read-path coverage rather than a current incident.

The principal audit report query has appeared twice in pg_stat_statements with low observed latency; system_actor_audit has only 318 rows. No index is added for product_owner_id without a demonstrated query or parent-maintenance need.

## Unused-index findings

The same Advisor snapshot reported seven unused indexes: idx_system_actor_audit_project_created, idx_events_worker_project, idx_events_execution_task, initiative_work_items_ready_idx, initiative_events_history_idx, initiative_learnings_project_created_idx, and idx_owner_mcp_audit_project_created. These are low-traffic pilot/audit/event paths, not a removal list. This PR drops or changes none of them.

## Validation and deployment boundary

The companion PostgreSQL 17 CI test verifies all eight new index definitions and exact key order, rejects duplicate exact-key indexes, preserves the 17 target FK constraints, checks RLS and anon/authenticated table grants, preserves the existing useful leading-key indexes and the separate private task destructive-audit controls.

The migration is applied only to the disposable PostgreSQL service used by GitHub Actions. It has **not** been applied to the live Supabase project; the live migration registry is unchanged. Merge and production deployment are separate lifecycle stages and are not performed by this PR.
