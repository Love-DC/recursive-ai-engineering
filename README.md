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

**Current status:** One Auth user exists. The Owner console source is committed; its build and real browser login flow are not yet verified. Rollback-safe authenticated RPC tests pass through initial delivery, Reviewer rejection, Fix/resubmit, Reviewer acceptance, no-review completion and cancellation. A two-connection claim race, lease reclaim and stale-Execution fencing test also pass using the same Owner identity. No test project/Worker/Task records were retained. Distinct Auth-user concurrency remains pending. Logical Worker IDs are not isolated credentials; production multi-GPT use requires a per-Worker authentication boundary. No Worker credentials or Service Role Key are included in this repository.

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
