# Cross-project resource inventory and lifecycle center

This is a read-only inventory and guarded cleanup entrypoint, not a background service.
A live inventory snapshot is collected by the RAE Coordinator from the connected,
authorized Supabase and GitHub integrations, then normalized by
\`scripts/resource_inventory.py\`. Do not substitute repository names or project IDs:
the source is the active \`public.projects\` registry and each row's canonical
\`github_repo\`.

## Inventory contract

The snapshot contains a timezone-aware \`generated_at\`, \`registered_projects\`,
and \`supabase_projects\`. Each registered project contains its project ID/key,
canonical repository, default branch, GitHub branches and open PR references, plus
Supabase development-branch and Edge Function metadata. The normalizer produces
one deterministic JSON/Markdown report with resource identity, platform, state,
dependency evidence, risk class, recommended action and reason.

Risk classes:
- \`eligible_batch\`: only a verified, merged, unprotected, unused branch in this
  RAE repository, with an exact 40-character SHA.
- \`owner_decision_required\`: incomplete protection/ancestry evidence or a branch
  in another repository for which no scoped mutation credential exists.
- \`preserve_or_blocked\`: default/protected/open-PR/unmerged branches and all
  Supabase projects, development branches and Edge Functions.

ChatGPT conversation history is not accessible to RAE and is not inventoried.

## Batch safety

The cleanup script is dry-run by default. A batch manifest maps exact branch names
to the SHA shown in the preview. Execution requires one exact batch confirmation,
then rechecks branch existence, exact SHA, protection, open PR references and
merged ancestry. The script is restricted to the current RAE repository. It does
not delete Supabase resources or mutate other repositories.

GitHub's delete-ref endpoint does not support an atomic expected-SHA condition;
the implementation revalidates immediately before each delete, but this cannot
eliminate the tiny race between the final read and delete. Treat this limitation
as a residual risk and keep cleanup manual-only.

## Permissions and operating limits

- The manual GitHub Actions workflow uses the repository's built-in
  \`GITHUB_TOKEN\`; only its execute job requests \`contents: write\`.
- Repository Actions settings must permit read/write workflow tokens. This setting
  is not changed by this task and must be verified before first execution.
- No GitHub App, PAT, Supabase service-role key, Edge Function, schema or
  production infrastructure is created or changed.
- Supabase management inventory is supplied by the existing connected Supabase
  integration. The GitHub workflow does not possess Supabase Management API
  credentials and therefore cannot refresh that part of the snapshot itself.
- Cross-repository branch deletion remains disabled until a repository-scoped
  authorized workflow/token is already available. No credential is created here.

## Running tests

\`\`\`sh
python -m py_compile scripts/resource_inventory.py scripts/cleanup_branches.py
python -m unittest scripts.test_resource_inventory scripts.test_cleanup_branches -v
\`\`\`
