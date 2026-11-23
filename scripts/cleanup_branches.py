"""Manual-only, dry-run-first cleanup for explicitly selected RAE-local branches."""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote

CONFIRMATION = "DELETE SELECTED RESOURCES"


def run(command, check=True):
    return subprocess.run(command, capture_output=True, text=True, check=check)


def gh_json(endpoint):
    return json.loads(run(["gh", "api", endpoint]).stdout)


def parse_manifest(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(data, dict) or not data:
        raise ValueError("Expected a non-empty branch-to-SHA JSON object.")
    for name, sha in data.items():
        if not isinstance(name, str) or not isinstance(sha, str) or len(sha) != 40:
            raise ValueError("Every target must include its exact 40-character preview SHA.")
        run(["git", "check-ref-format", "--branch", name])
    return data


def inspect_batch(repository, expected):
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
            branch = gh_json(f"repos/{repository}/branches/{quote(name, safe='/')}")
            sha, protected = (branch.get("commit") or {}).get("sha"), branch.get("protected")
            if name == default:
                reason = "default branch"
            elif sha != expected_sha:
                reason = "branch SHA changed since preview"
            elif protected is not False:
                reason = "protected or protection state unknown"
            elif name in open_heads:
                reason = "referenced by open pull request"
            else:
                cmp = gh_json(f"repos/{repository}/compare/{default}...{quote(name, safe='/')}")
                reason = ("eligible after exact-SHA revalidation" if cmp.get("status") in ("ahead", "identical")
                          and cmp.get("ahead_by") == 0 else "not proven merged into default")
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
    if not args.repository or "/" not in args.repository:
        parser.error("--repository must be owner/name")
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
            # Final immediate revalidation; the GitHub REST delete-ref API has no conditional-SHA parameter.
            current = gh_json(f"repos/{args.repository}/branches/{quote(item['branch'], safe='/')}")
            if (current.get("commit") or {}).get("sha") != item["sha"] or current.get("protected") is not False:
                raise RuntimeError(f"Target changed during final revalidation: {item['branch']}")
            run(["gh", "api", "--method", "DELETE",
                 f"repos/{args.repository}/git/refs/heads/{quote(item['branch'], safe='/')}"])
        print(f"Deleted {len(eligible)} explicitly confirmed RAE-local branch(es).")
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
