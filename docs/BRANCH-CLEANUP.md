# Owner-controlled GitHub branch cleanup

The **Owner-controlled branch cleanup** workflow provides a single batch operation for cleaning up remote branches. It is manual-only: it runs only through the GitHub Actions **Run workflow** interface. It never runs on push, pull requests, schedules, or as part of normal CI.

## Run a preview

1. Open **Actions → Owner-controlled branch cleanup → Run workflow**.
2. Enter the exact branch names to inspect, one per line.
3. Leave **confirmation** empty and run the workflow.
4. Review the preview job output. No branch is deleted in preview mode.

## Delete eligible branches

Run the workflow again with the same branch list and enter this exact phrase in **confirmation**:

```text
DELETE MERGED BRANCHES
```

The delete job runs only when that explicit input matches. It re-fetches and revalidates every branch immediately before deletion. The workflow can delete several eligible branches in one run; skipped branches are reported and preserved.

## Mandatory safety checks

A branch is eligible only when all of these conditions hold:

- It is not the repository's current default branch.
- GitHub does not mark it as protected by a branch protection rule or ruleset.
- It is not the head branch of an open pull request in this repository.
- Its current tip commit is an ancestor of the current default branch tip (already merged).

Invalid names, missing branches, inspection errors, unmerged branches, protected branches, and branches used by open PRs are skipped. If the preview or revalidation fails, the workflow does not proceed with that candidate.

## Permissions and operation

- The workflow uses the built-in `GITHUB_TOKEN`; it does not require a PAT or any new secret.
- The preview job has `contents: read`.
- Only the manually gated delete job has `contents: write`.
- If repository Actions settings restrict the token to read-only, an administrator must enable read/write workflow permissions for this repository.
- No branch is selected automatically. The Owner supplies the batch and explicitly confirms the deletion run.
- No existing branch is deleted while developing or testing this workflow.

## Files

- Workflow: `.github/workflows/owner-branch-cleanup.yml`
- Implementation: `scripts/cleanup_branches.py`
- Unit tests: `scripts/test_cleanup_branches.py`
