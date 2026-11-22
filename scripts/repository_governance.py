#!/usr/bin/env python3
"""Discover and validate repository-local RAE governance before task execution.

The coordinator must pin the target repository first, then call this module with
that exact base SHA as both expected_sha and the checked-out actual_sha.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

MANIFEST_NAME = "rae-governance.json"
PROTOCOL = "rae.repository-governance"
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


class GovernanceError(ValueError):
    """Raised when repository governance cannot be trusted for execution."""


def _version(value: str) -> tuple[int, int, int]:
    if not isinstance(value, str) or not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise GovernanceError(f"Invalid semantic version: {value!r}")
    return tuple(int(part) for part in value.split("."))  # type: ignore[return-value]


def _safe_repo_file(root: Path, relative: Any, label: str) -> Path:
    if not isinstance(relative, str) or not relative.strip():
        raise GovernanceError(f"{label} must be a non-empty repository-relative path")
    candidate = Path(relative)
    if candidate.is_absolute() or ".." in candidate.parts:
        raise GovernanceError(f"Unsafe {label} path: {relative}")
    resolved = (root / candidate).resolve()
    try:
        resolved.relative_to(root.resolve())
    except ValueError as exc:
        raise GovernanceError(f"{label} escapes repository root: {relative}") from exc
    if not resolved.is_file():
        raise GovernanceError(f"Missing {label} file: {relative}")
    return resolved


def load_governance(
    repo_root: str | Path,
    *,
    expected_sha: str,
    actual_sha: str,
    coordinator_version: str = "1.0.0",
    expected_project: str | None = None,
) -> dict[str, Any]:
    """Load manifest and verify compatibility, file presence, conflicts and SHA."""
    if not SHA_RE.fullmatch(expected_sha or "") or not SHA_RE.fullmatch(actual_sha or ""):
        raise GovernanceError("Expected and actual repository revisions must be full 40-character SHAs")
    if expected_sha != actual_sha:
        raise GovernanceError(
            f"Stale repository revision: expected {expected_sha}, checked out {actual_sha}"
        )

    root = Path(repo_root).resolve()
    manifest_path = root / MANIFEST_NAME
    if not manifest_path.is_file():
        raise GovernanceError(f"Missing required governance manifest: {MANIFEST_NAME}")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise GovernanceError(f"Cannot read {MANIFEST_NAME}: {exc}") from exc

    if not isinstance(manifest, dict) or manifest.get("protocol") != PROTOCOL:
        raise GovernanceError(f"Unsupported governance protocol; expected {PROTOCOL}")
    if not isinstance(manifest.get("project"), str) or not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", manifest["project"]):
        raise GovernanceError("Manifest project must be a stable lowercase project key")
    if expected_project is not None and manifest["project"] != expected_project:
        raise GovernanceError(
            f"Manifest project mismatch: expected {expected_project}, found {manifest['project']}"
        )
    protocol_version = _version(manifest.get("protocol_version"))
    if protocol_version[0] != 1:
        raise GovernanceError("Incompatible governance protocol major version")
    compatibility = manifest.get("compatibility") or {}
    if not isinstance(compatibility, dict):
        raise GovernanceError("compatibility must be an object")
    minimum = _version(compatibility.get("min_coordinator_version", "1.0.0"))
    if _version(coordinator_version) < minimum:
        raise GovernanceError(
            f"Coordinator {coordinator_version} is older than required {compatibility['min_coordinator_version']}"
        )

    governance = manifest.get("governance")
    if not isinstance(governance, dict):
        raise GovernanceError("Manifest governance section is required")
    paths: list[tuple[str, str]] = []
    for field in ("agent_instructions",):
        paths.append((field, governance.get(field)))
    for field in ("entrypoints", "required"):
        values = governance.get(field, [])
        if not isinstance(values, list):
            raise GovernanceError(f"governance.{field} must be an array")
        paths.extend((f"{field}[{index}]", value) for index, value in enumerate(values))
    for label, relative in paths:
        _safe_repo_file(root, relative, label)

    rule_sets = governance.get("rule_sets", [])
    if not isinstance(rule_sets, list):
        raise GovernanceError("governance.rule_sets must be an array")
    seen: dict[str, tuple[str, int]] = {}
    for index, rule in enumerate(rule_sets):
        if not isinstance(rule, dict) or not isinstance(rule.get("id"), str):
            raise GovernanceError(f"Invalid rule_sets[{index}] declaration")
        rule_id = rule["id"]
        path = rule.get("path")
        priority = rule.get("priority", 0)
        if not isinstance(priority, int):
            raise GovernanceError(f"Rule priority must be an integer: {rule_id}")
        _safe_repo_file(root, path, f"rule_sets[{index}].path")
        signature = (path, priority)
        if rule_id in seen and seen[rule_id] != signature:
            raise GovernanceError(f"Conflicting declarations for governance rule id: {rule_id}")
        seen[rule_id] = signature

    declared_conflicts = manifest.get("conflicts", [])
    if declared_conflicts:
        raise GovernanceError(
            "Governance manifest declares unresolved rule conflicts: "
            + json.dumps(declared_conflicts, ensure_ascii=False)
        )

    validation = manifest.get("validation")
    if validation is not None:
        if not isinstance(validation, dict):
            raise GovernanceError("validation must be an object")
        ci_repo = validation.get("repository")
        workflow = validation.get("workflow")
        if ci_repo is not None and (
            not isinstance(ci_repo, str) or not re.fullmatch(r"[^/\s]+/[^/\s]+", ci_repo)
        ):
            raise GovernanceError("validation.repository must be owner/repository")
        if workflow is not None:
            if ci_repo is None:
                _safe_repo_file(root, workflow, "validation.workflow")
            else:
                candidate = Path(workflow)
                if candidate.is_absolute() or ".." in candidate.parts:
                    raise GovernanceError("validation.workflow must be a safe repository-relative path")

    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", type=Path)
    parser.add_argument("--expected-sha", required=True)
    parser.add_argument("--actual-sha", required=True)
    parser.add_argument("--coordinator-version", default="1.0.0")
    parser.add_argument("--expected-project")
    args = parser.parse_args()
    try:
        manifest = load_governance(
            args.repository,
            expected_sha=args.expected_sha.lower(),
            actual_sha=args.actual_sha.lower(),
            coordinator_version=args.coordinator_version,
            expected_project=args.expected_project,
        )
    except GovernanceError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 2
    print(json.dumps({"ok": True, "manifest": manifest}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
