# AI Worker Collaboration System — MVP v1.2

A Supabase/PostgreSQL-backed task coordination system for independent GPT Worker sessions, with GitHub artifacts and a fixed-target review/fix workflow.

## Scope

- Seven core tables: projects, workers, tasks, executions, artifacts, task_events, operation_requests.
- Nineteen authenticated RPCs.
- Owner administration plus per-Worker Supabase Auth identity binding and task-scoped authorization.
- Database-enforced execution fencing, leases, fixed review targets, idempotency, and append-only event history.
- GitHub remains the source of code and documents; Supabase stores task state and artifact references.

## Current implementation status

The target Supabase project is `recursive-ai-engineering` (PostgreSQL 17, ap-northeast-1). Core schema and RPC migrations have been applied. See [implementation report](reports/acceptance-test-results.md) for verified checks and known test blockers.

**Current status:** Worker identity isolation v1.2 and task-scope hardening v1.2.1 are applied. Worker RPCs bind JWT subject to the exact Worker ID; negative tests reject unbound and mismatched identities. The Owner workflow acceptance suite passes after these changes. One Auth user exists, so positive cross-Worker workflows with genuinely separate Auth users remain pending. Browser sign-in/UI acceptance, remaining A01–A63 cases, leaked-password protection and disposable-database snapshot verification remain release gates. No test records remain. No Worker credentials or Service Role Key are included in this repository.

## Real-project release gate

See [Real-Project Readiness](docs/REAL-PROJECT-READINESS.md). Do not onboard real repositories or start autonomous Workers until every no-go item is verified.

## Repository layout

- `console/` — Vite/React Owner console (local run and deployment instructions in `console/README.md`)
- `supabase/migrations/` — database migrations
- `tests/` — schema, security, workflow and concurrency tests
- `docs/MVP-v1.1.md` — implementation baseline and design decisions
- `docs/WORKER-INSTRUCTIONS.md` — Worker operating rules
- `docs/RPC-REFERENCE.md` — RPC interface reference
- `reports/acceptance-test-results.md` — actual verification record

## Security

Workers must use an authenticated user session and publishable client key only. Never distribute a Supabase Service Role Key, secret key, database password, or privileged database connection string to a GPT Worker.

All business writes must go through the explicitly granted RPCs. Direct table INSERT/UPDATE/DELETE is revoked for `anon` and `authenticated`.
