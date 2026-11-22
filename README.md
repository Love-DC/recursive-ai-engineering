# AI Worker Collaboration System — MVP v1.1

A Supabase/PostgreSQL-backed task coordination system for independent GPT Worker sessions, with GitHub artifacts and a fixed-target review/fix workflow.

## Scope

- Seven core tables: projects, workers, tasks, executions, artifacts, task_events, operation_requests.
- Nineteen authenticated RPCs.
- One project owner authorization model with logical Worker identities.
- Database-enforced execution fencing, leases, fixed review targets, idempotency, and append-only event history.
- GitHub remains the source of code and documents; Supabase stores task state and artifact references.

## Current implementation status

The target Supabase project is `recursive-ai-engineering` (PostgreSQL 17, ap-northeast-1). Core schema and RPC migrations have been applied. See [implementation report](reports/acceptance-test-results.md) for verified checks and known test blockers.

**Important:** The current Supabase project has zero Auth users. End-to-end authenticated workflow and multi-session concurrency acceptance tests are therefore pending. No Worker credentials or Service Role Key are included in this repository.

## Repository layout

- `supabase/migrations/` — database migrations
- `tests/` — schema, security, workflow and concurrency tests
- `docs/MVP-v1.1.md` — implementation baseline and design decisions
- `docs/WORKER-INSTRUCTIONS.md` — Worker operating rules
- `docs/RPC-REFERENCE.md` — RPC interface reference
- `reports/acceptance-test-results.md` — actual verification record

## Security

Workers must use an authenticated user session and publishable client key only. Never distribute a Supabase Service Role Key, secret key, database password, or privileged database connection string to a GPT Worker.

All business writes must go through the explicitly granted RPCs. Direct table INSERT/UPDATE/DELETE is revoked for `anon` and `authenticated`.
