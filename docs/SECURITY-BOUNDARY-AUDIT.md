# Supabase Security Boundary Audit

**Initial inspection date:** 2026-11-23 (historical baseline); **Live database/RPC/advisor refresh:** 2026-11-24 19:09 UTC (2026-11-25 JST)  
**Scope:** Read-only inspection of the live `recursive-ai-engineering` Supabase project and the default branch of this repository. No schema, grants, Auth settings, or deployment state were changed.

## Executive summary

The shared-owner MCP pilot remains restricted to the already-authorized trusted `postgres` connection. Its transaction-scoped Owner context is deployed, and selected task/initiative RPC reads work in that context. The Problem Inbox listing RPC is a known exception: it still requires `auth.uid()` and rejects the non-JWT Owner-MCP context with `UNAUTHENTICATED`; `get_problem_report` and `update_problem_report` also contain JWT-only row filters. Repository migration `20261125120000_owner_mcp_problem_inbox_context.sql` adds verified project-bound Owner-MCP authorization and isolated regression coverage, but it is not deployed. Until deployed and live-verified, these RPCs remain unavailable through the Owner-MCP connection. This is **not** a production-readiness approval for independent users or public clients.

## RAE system Owner architecture change (repository-only, not deployed)

The migration `20261125130000_rae_system_owner_authority.sql` introduces a private `rae-core` principal and a transaction-local project-scoped engineering context. It preserves `projects.owner_id` as the human product-owner reference, logs system actor context, and keeps initiative decisions, support/resource approvals, project pause/kill-switch control, and Worker/Auth identity binding on the human-owner assertion path. The isolated regression suite is `tests/rae-system-owner-context-tests.sql`. This is not part of the live database baseline in this audit and must not be treated as deployed or active.

The trusted MCP SQL connection remains a `postgres` administrator boundary. The system-principal context provides scoped RPC semantics and audit, not least-privilege protection against a compromised postgres connection. The legacy Owner-MCP context can still be established on that same privileged connection; it must only be used when the human has explicitly supplied the relevant product/Owner decision. Consequently, the database can reject a direct `rae-core` context from human-decision RPCs, but it cannot cryptographically prove that a legacy Owner-MCP call originated from the human rather than an AI session. Strong technical separation would require a distinct least-privilege authenticated channel or a human-issued approval capability.
