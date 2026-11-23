"""Manual-only, dry-run-first cleanup for explicitly selected RAE-local branches."""
import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

CONFIRMATION = "DELETE SELECTED RESOURCES"


def run(command, check=True):
    return subprocess.run(command, capture_output=True, text=True, check=check)


def gh_json(endpoint):
    return json.loads(run(["gh", "api", endpoint]).stdout)


def parse_manifest(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(data, dict) or not isinstance(data.get("branches"), dict) or not data["branches"]:
        raise ValueError("Expected a manifest with generated_at and exact branch SHAs.")
    if data.get("task_reference_scan_complete") is not True:
        raise ValueError("Task-reference scan is incomplete; cleanup is blocked.")
    task_references = data.get("task_references")
    if not isinstance(task_references, list) or not all(isinstance(x, str) for x in task_references):
        raise ValueError("Manifest must include a task_references string array.")
    if data.get("repository") not in (None, "Love-DC/recursive-ai-engineering"):
        raise ValueError("Manifest repository does not match the RAE-local cleanup scope.")
    generated_at = data.get("generated_at")
    if not isinstance(generated_at, str):
        raise ValueError("Manifest generated_at timestamp is required.")
    stamp = datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
    if stamp.tzinfo is None:
        raise ValueError("Manifest generated_at must include a timezone.")
    age = (datetime.now(timezone.utc) - stamp.astimezone(timezone.utc)).total_seconds() / 60
    if age < 0 or age > 30:
        raise ValueError("Stale inventory manifest; refresh the inventory and preview again.")
    branches = data["branches"]
    for name, sha in branches.items():
        if not isinstance(name, str) or not isinstance(sha, str) or len(sha) != 40:
            raise ValueError("Every target must include its exact 40-character preview SHA.")
        run(["git", "check-ref-format", "--branch", name])
    return {"branches": branches, "task_references": set(task_references)}


def inspect_batch(repository, manifest):
    expected = manifest["branches"]
    task_references = manifest["task_references"]
    if not os.environ.get("GH_TOKEN"):
        raise RuntimeError("GH_TOKEN is required; use the workflow-provided GITHUB_TOKEN.")
    default = gh_json(f"repos/{repository}").get("default_branch")
    if not default:
        raise RuntimeError("Could not resolve repository default branch.")
    prs = gh_json(f"repos/{repository}/pulls?state=open&per_page=100")
    open_heads = {(p.get("head") or {}).get("ref") for p in prs
                  if ((p.get("head") or {}).get("repo") or {}).get("full_name") == repository}
    results = []
    for name, expected_sha in sorted(expected.items()):
        try:
            branch = gh_json(f"repos/{repository}/branches/{quote(name, safe='')}")
            sha, protected = (branch.get("commit") or {}).get("sha"), branch.get("protected")
            if name == default:
                reason = "default branch"
            elif sha != expected_sha:
                reason = "branch SHA changed since preview"
            elif protected is not False:
                reason = "protected or protection state unknown"
            elif name in open_heads:
                reason = "referenced by open pull request"
            elif name in task_references:
                reason = "referenced by active or submitted task"
            else:
                cmp = gh_json(f"repos/{repository}/compare/{default}...{quote(name, safe='')}")
                reason = ("eligible after exact-SHA revalidation" if cmp.get("ahead_by") == 0
                          else "not proven merged into default")
            results.append({"branch": name, "sha": sha, "eligible": reason.startswith("eligible"), "reason": reason})
        except Exception as exc:
            results.append({"branch": name, "sha": None, "eligible": False, "reason": f"inspection failed: {exc}"})
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--execute", action="store_true", help="Default is dry-run.")
    parser.add_argument("--confirmation", default="")
    args = parser.parse_args()
    if args.repository != "Love-DC/recursive-ai-engineering":
        parser.error("Cleanup is restricted to Love-DC/recursive-ai-engineering; cross-repository mutation is disabled.")
    if args.execute and args.confirmation != CONFIRMATION:
        parser.error(f"Deletion requires exact confirmation {CONFIRMATION!r}")
    try:
        manifest = parse_manifest(args.manifest)
        result = inspect_batch(args.repository, manifest)
        print(json.dumps(result, indent=2))
        eligible = [r for r in result if r["eligible"]]
        if not args.execute:
            print(f"Dry-run only: {len(eligible)} eligible / {len(result)} requested. No resources deleted.")
            return 0
        for item in eligible:
            # Re-read branch, protection, open PR references and ancestry immediately before deletion.
            final = inspect_batch(args.repository, {
                "branches": {item["branch"]: item["sha"]},
                "task_references": manifest["task_references"],
            })[0]
            if not final["eligible"] or final["sha"] != item["sha"]:
                raise RuntimeError(f"Target failed final revalidation: {item['branch']}: {final['reason']}")
            ref = f"refs/heads/{item['branch']}"
            run(["git", "push", f"--force-with-lease={ref}:{item['sha']}",
                 "origin", f":{ref}"])
        print(f"Deleted {len(eligible)} explicitly confirmed RAE-local branch(es).")
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
