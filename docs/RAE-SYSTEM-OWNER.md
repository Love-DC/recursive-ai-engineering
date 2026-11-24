# RAE System Owner and Human Product Authority

## Purpose

RAE is the engineering-system Owner of registered projects. The human project Owner remains the product decision-maker. These are distinct authorities and must not be represented by one Supabase Auth identity.

## Authority split

| Authority | Holder | Examples |
|---|---|---|
| Engineering-system ownership | Private principal `rae-core` | Inspect and maintain project engineering state, register project-scoped Workers, create and execute authorized tasks, record evidence, manage Problem Inbox reports, review and merge eligible engineering PRs |
| Human product ownership | Existing `public.projects.owner_id` Auth user | Product direction, game design, gameplay/balance/UX decisions, explicit Initiative decisions, resource/support approvals, and execution pause/kill-switch control |
| Worker execution identity | Existing project-scoped `public.workers` row | Atomic task claim, lease, execution and review routing |

The existing `projects.owner_id` column remains a foreign key to `auth.users(id)`. It is retained as the human product-owner reference and for existing human RLS reads. It is **not** the RAE system identity and is no longer the only identity through which trusted engineering RPCs may be used.

RAE does not get a fabricated Auth user, a second human account, a per-conversation identity, or a permanent Worker identity. A Worker row remains a project-scoped route, not the system Owner.

## RAE system principal

The private `private.system_principals` table contains the stable `rae-core` principal. It has no Auth credentials, no Data API exposure, no direct client grants, and no sign-in path.

A trusted Supabase MCP `postgres` transaction establishes the RAE identity with:

```sql
BEGIN;
SELECT private.begin_rae_system_context('<project UUID>'::uuid);

-- Use project-scoped, existing RPCs in this same transaction.
SELECT public.list_tasks(
  '<project UUID>'::uuid,
  NULL,
  '<that project Worker UUID>'::uuid,
  100,
  NULL
);
COMMIT;
```

The context is transaction-local and bound to exactly one active project. Use a separate transaction for another project. Its audit row records the system principal, project, human product-owner reference, database role, backend and transaction. It never sets `auth.uid()` or invents a JWT. The RAE system context and legacy human Owner-MCP context are mutually exclusive in one transaction; use separate transactions, and never use the Owner-MCP context unless the human has explicitly supplied the relevant decision.

The RAE context uses the existing engineering RPCs and preserves their independent project routing, task activation, dependency, concurrency, lease, retry, branch-exclusion, and review checks. A system context cannot be reused for another project.

## Human-only decisions

The following operations remain protected by `private.assert_human_owner` and do not accept the RAE system principal:

- `public.decide_initiative`: approving or rejecting a proposed initiative/work plan.
- `public.decide_initiative_support`: approving or rejecting a resource/capability request.
- `public.abandon_initiative`: human decision to abandon an initiative.
- `private.set_project_execution_controls`: changing the project pause/kill-switch or execution cap.
- `public.bind_worker_identity`: binding a Worker to a real Auth user remains JWT/Owner controlled.

The legacy `private.begin_owner_mcp_context(project_id, owner_id)` remains available for the trusted Owner-MCP route when the human has explicitly supplied the relevant product/Owner decision. It must be anchored to the actual `projects.owner_id`; it is not the RAE system identity.

Important limitation: the connected Supabase MCP SQL connection runs as `postgres`. The database can distinguish the explicit `rae-core` system context from the legacy Owner-MCP context, and the system context is rejected by the human-decision guard. However, the database cannot cryptographically prove that a legacy Owner-MCP call was initiated by a human rather than an AI session using the same privileged connection. That boundary therefore also depends on the Coordinator following the explicit-human-decision rule. A stronger technical separation would require a separate least-privilege authenticated channel or a human-issued approval capability; neither is currently available in this pilot.

An approved Initiative may be decomposed and executed by RAE. RAE cannot approve its own proposal, grant its own resource request, or remove a human pause control through the `rae-core` system context.

## Security interpretation

This context is a scoped, auditable identity for trusted RAE engineering RPC calls. The Supabase MCP connection itself runs as PostgreSQL `session_user=postgres`; that trusted management connection remains a superuser/admin boundary. The context does not make a compromised or unrestricted `postgres` connection harmless, nor does it replace a least-privilege service credential for an independently exposed runtime.

Ordinary `anon` and `authenticated` sessions cannot call the private context entrypoint or forge the context GUCs: the match helper requires the original `postgres` session, an active `rae-core` principal, the exact project binding, and the expected context version. Existing public RPCs continue to enforce project scope and their normal lifecycle fences.

Never expose the Supabase database-management connection or private context functions to public clients. Do not add service-role keys, database credentials, or synthetic JWT claims to prompts, tasks, repository files, or project config.

## Deployment status

The migration and isolated PostgreSQL regression tests are maintained in this repository. A GitHub merge does not deploy production DDL. Until the migration is applied and the live principal, context helper, audit path, engineering RPCs, and human-decision negative tests are verified against the shared Supabase database, sessions must continue using only the previously deployed Owner-MCP context and must not claim that RAE has assumed live system-Owner authority.

The migration intentionally does not change existing projects' `owner_id`, `autonomy.paused`, execution caps, tasks, leases, or project data. It does not authorize production deployment by itself.
