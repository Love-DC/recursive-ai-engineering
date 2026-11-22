#!/usr/bin/env python3
"""Safely preview or delete a batch of merged, unprotected, unused branches.

Requires GitHub CLI authentication through GH_TOKEN and a full git checkout.
Deletion is intentionally opt-in and is only used by the manual Actions workflow.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import quote

CONFIRMATION = "DELETE MERGED BRANCHES"


@dataclass(frozen=True)
class Candidate:
    branch: str
    eligible: bool
    reason: str
    sha: str | None = None


def parse_branch_names(value: str) -> list[str]:
    """Parse a newline-separated batch, rejecting malformed or duplicate refs."""
    names: list[str] = []
    seen: set[str] = set()
    for raw in value.splitlines():
        name = raw.strip()
        if not name:
            continue
        if name in seen:
            raise ValueError(f"Duplicate branch name: {name}")
        result = subprocess.run(
            ["git", "check-ref-format", "--branch", name],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            raise ValueError(f"Invalid Git branch name: {name}")
        seen.add(name)
        names.append(name)
    if not names:
        raise ValueError("Provide at least one branch name.")
    return names


def evaluate_candidate(
    branch: str,
    *,
    default_branch: str,
    protected: bool,
    has_open_pr: bool,
    merged: bool,
    sha: str | None = None,
) -> Candidate:
    """Apply all deletion guards in a stable, testable order."""
    if branch == default_branch:
        return Candidate(branch, False, "default branch", sha)
    if protected:
        return Candidate(branch, False, "protected by a branch rule", sha)
    if has_open_pr:
        return Candidate(branch, False, "referenced by an open pull request", sha)
    if not merged:
        return Candidate(branch, False, "branch head is not merged into the default branch", sha)
    return Candidate(branch, True, "merged, unprotected, and unused", sha)


def run(command: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, capture_output=True, text=True, check=check)


def gh_json(endpoint: str) -> Any:
    result = run(["gh", "api", endpoint])
    return json.loads(result.stdout)


def list_open_pull_requests(repository: str) -> list[dict[str, Any]]:
    result = run([
        "gh", "api", "--paginate", "--slurp",
        f"repos/{repository}/pulls?state=open&per_page=100",
    ])
    pages = json.loads(result.stdout or "[]")
    return [item for page in pages for item in (page if isinstance(page, list) else [page])]


def is_branch_merged(branch: str, default_branch: str) -> bool:
    remote_ref = f"refs/remotes/cleanup-candidates/{branch}"
    default_ref = f"refs/remotes/origin/{default_branch}"
    run([
        "git", "fetch", "--no-tags", "origin",
        f"+refs/heads/{branch}:{remote_ref}",
    ])
    result = run(["git", "merge-base", "--is-ancestor", remote_ref, default_ref], check=False)
    if result.returncode not in (0, 1):
        raise RuntimeError(result.stderr.strip() or f"Could not compare {branch} with {default_branch}")
    return result.returncode == 0


def inspect_batch(repository: str, branch_names: list[str]) -> list[Candidate]:
    if not os.environ.get("GH_TOKEN"):
        raise RuntimeError("GH_TOKEN is required; use the workflow-provided GITHUB_TOKEN.")
    repo = gh_json(f"repos/{repository}")
    default_branch = repo.get("default_branch")
    if not isinstance(default_branch, str) or not default_branch:
        raise RuntimeError("GitHub did not return a repository default branch.")

    run([
        "git", "fetch", "--no-tags", "origin",
        f"+refs/heads/{default_branch}:refs/remotes/origin/{default_branch}",
    ])
    pull_requests = list_open_pull_requests(repository)
    open_heads = {
        (pr.get("head") or {}).get("ref")
        for pr in pull_requests
        if ((pr.get("head") or {}).get("repo") or {}).get("full_name") == repository
    }

    candidates: list[Candidate] = []
    for branch in branch_names:
        if branch == default_branch:
            candidates.append(evaluate_candidate(
                branch, default_branch=default_branch, protected=False,
                has_open_pr=False, merged=False,
            ))
            continue
        try:
            branch_data = gh_json(
                f"repos/{repository}/branches/{quote(branch, safe='/')}"
            )
            sha = ((branch_data.get("commit") or {}).get("sha"))
            protected = bool(branch_data.get("protected"))
            merged = is_branch_merged(branch, default_branch)
            candidates.append(evaluate_candidate(
                branch,
                default_branch=default_branch,
                protected=protected,
                has_open_pr=branch in open_heads,
                merged=merged,
                sha=sha,
            ))
        except subprocess.CalledProcessError as exc:
            detail = (exc.stderr or exc.stdout or str(exc)).strip()
            candidates.append(Candidate(branch, False, f"GitHub/git inspection failed: {detail}"))
        except (RuntimeError, ValueError) as exc:
            candidates.append(Candidate(branch, False, f"inspection failed: {exc}"))
    return candidates


def delete_branch(repository: str, branch: str) -> None:
    ref = f"heads/{quote(branch, safe='/')}"
    run(["gh", "api", "--method", "DELETE", f"repos/{repository}/git/refs/{ref}"])


def print_report(candidates: list[Candidate], *, execute: bool, repository: str) -> None:
    print("Branch cleanup plan")
    print("===================")
    for item in candidates:
        status = "ELIGIBLE" if item.eligible else "SKIP"
        sha = f" ({item.sha[:12]})" if item.sha else ""
        print(f"{status}: {item.branch}{sha} — {item.reason}")
    eligible = [item for item in candidates if item.eligible]
    print(f"\nEligible: {len(eligible)} / Requested: {len(candidates)}")
    if not execute:
        print("Dry run only. No branches were deleted.")
        return
    for item in eligible:
        delete_branch(repository, item.branch)
    print(f"Deleted: {len(eligible)} branch(es).")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--branches-file", type=Path, required=True)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--confirmation", default="")
    args = parser.parse_args()

    if not args.repository or "/" not in args.repository:
        parser.error("--repository must be owner/name or GITHUB_REPOSITORY must be set")
    if args.execute and args.confirmation != CONFIRMATION:
        parser.error(f"Deletion requires --confirmation {CONFIRMATION!r}")

    try:
        branch_names = parse_branch_names(args.branches_file.read_text(encoding="utf-8"))
        candidates = inspect_batch(args.repository, branch_names)
        print_report(candidates, execute=args.execute, repository=args.repository)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
