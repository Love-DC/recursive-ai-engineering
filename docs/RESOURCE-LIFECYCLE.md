# Cross-project resource inventory and lifecycle center

This is a read-only inventory and preview entrypoint, not a background service.
A live inventory snapshot is collected by the RAE Coordinator from the connected,
authorized Supabase and GitHub integrations. The snapshot and consolidated report
are persisted under `reports/resource-inventory/` and normalized by
`scripts/resource_inventory.py`. Do not substitute repository names or project IDs:
the source is the active `public.projects` registry and each row's canonical
`github_repo`.

## Inventory contract

The snapshot contains a timezone-aware `generated_at`, `registered_projects`,
and `supabase_projects`. Each registered project contains its project ID/key,
canonical repository, default branch, GitHub branches and open PR references, plus
Supabase development-branch and Edge Function metadata. The normalizer produces
one deterministic JSON/Markdown report with resource identity, platform, state,
dependency evidence, risk class, recommended action and reason.

Risk classes:
- `eligible_batch`: a verified, merged, unprotected, unused branch in this
  RAE repository, with an exact 40-character SHA. This is a preview classification,
  not deletion authorization.
- `owner_decision_required`: incomplete protection/ancestry evidence or a branch
  in another repository for which no scoped mutation credential exists.
- `preserve_or_blocked`: default/protected/open-PR/unmerged branches and all
  Supabase projects, development branches and Edge Functions.

ChatGPT conversation history is not accessible to RAE and is not inventoried.

## Safety boundary

The GitHub workflow and `scripts/cleanup_branches.py` are read-only. They can
inspect branch state, exact SHAs, protection, ancestry and open PR references,
then produce a preview. Open PR enumeration uses all GitHub API pages.

**Deletion is disabled.** The connected workflow has no authorized live Supabase
task-reference provider. A caller-supplied manifest or a committed snapshot can
be stale or fabricated and cannot prove that a branch is not referenced by an
active/submitted task. Therefore neither the workflow nor the script may delete
branches based on that evidence. The deprecated `--execute` flag fails closed.

Re-enabling deletion requires an authorized, live task-reference lookup at
execution time, complete open-PR pagination, exact target revalidation, and a
separately reviewed authorization design. Do not add a PAT, GitHub App, Supabase
service-role key, or other credential to bypass this boundary.

## Permissions and operating limits

- The workflow requests only `contents: read` and `pull-requests: read`.
- Supabase projects, development branches and Edge Functions remain inventory-only.
- Cross-repository mutation remains disabled.
- No resource is deleted by implementation, tests, dry-runs, or PR review.
- No GitHub App, PAT, Supabase service-role key, Edge Function, schema or
  production infrastructure is created or changed.

## Running tests

```sh
python -m py_compile scripts/resource_inventory.py scripts/cleanup_branches.py
python -m unittest scripts.test_resource_inventory scripts.test_cleanup_branches -v
```
