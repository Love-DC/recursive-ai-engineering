#!/usr/bin/env python3
"""Credential-free structural and context-budget checks for the RAE tree."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STATUSES = {"active", "dormant", "blocked", "completed", "archived"}
REQUIRED_NODE_FIELDS = {
    "schema_version", "node_id", "node_type", "project_key", "title", "goal",
    "status", "summary", "parent_node_id", "children_index", "context_refs",
    "evidence_refs", "dependency_refs", "task_refs", "wake_conditions",
    "last_activity_at", "last_reviewed_at", "next_review_at",
}


def load_json(relative: str) -> dict:
    path = ROOT / relative
    if not path.is_file():
        raise AssertionError(f"missing JSON file: {relative}")
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    root = load_json("knowledge/rae-root/index.json")
    schema = load_json("knowledge/rae-tree/node.schema.json")
    index = load_json("knowledge/rae-tree/index.json")
    attention = load_json("knowledge/rae-tree/attention.json")
    node = load_json("knowledge/rae-tree/nodes/project.json")

    assert root["schema_version"] == schema["properties"]["schema_version"]["const"]
    assert index["schema_version"] == node["schema_version"] == "1.0"
    assert root["root_node_id"] == "rae:root"
    assert index["root_node_id"] == node["node_id"] == "project:recursive-ai-engineering"
    assert node["node_type"] == "project" and node["status"] in STATUSES
    assert REQUIRED_NODE_FIELDS.issubset(node), REQUIRED_NODE_FIELDS - set(node)
    assert len(node["summary"]) <= 1200
    assert node["children_index"] == index["attention_index"]
    assert node["children_index"] == "knowledge/rae-tree/attention.json"

    project_keys = [p["project_key"] for p in root["projects"]]
    assert len(project_keys) == len(set(project_keys)), "duplicate project key in root index"
    rae = next(p for p in root["projects"] if p["project_key"] == "recursive-ai-engineering")
    assert rae["state"] == "initialized"
    assert rae["tree_index"] == "knowledge/rae-tree/index.json"
    assert (ROOT / rae["tree_index"]).is_file()

    for project in root["projects"]:
        if project["state"] == "pending_bootstrap":
            # A pointer to an uninitialized external repository is not a claim that
            # its target file exists in this repository.
            continue
        assert project["state"] == "initialized"
        assert project["repository"] and project["tree_index"]

    for ref in node["context_refs"]:
        assert (ROOT / ref).is_file(), f"missing context reference: {ref}"
    for task_id in node["task_refs"]:
        assert re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", task_id)

    assert attention["schema_version"] == "1.0"
    assert attention["project_key"] == "recursive-ai-engineering"
    assert len(attention["items"]) <= attention["pagination"]["max_items_per_shard"]
    for item in attention["items"]:
        assert (ROOT / item["node_path"]).is_file(), f"missing attention node: {item['node_path']}"
        assert item["node_id"] == node["node_id"]

    # Default startup must be a bounded index/branch read, never a full-tree scan.
    startup = (ROOT / "docs/SESSION-START.md").read_text(encoding="utf-8")
    assert "knowledge/rae-root/index.json" in startup
    assert "Default startup must not:" in startup
    assert "list every task in every registered project" in startup
    assert "recursively expand all descendants" in startup
    assert "There is no mandatory role declaration at startup" in startup
    assert "No daemon, scheduler, automatic GPT-session launch" in startup

    # Keep the always-loaded root/index records deliberately small.
    for relative in (
        "knowledge/rae-root/index.json",
        "knowledge/rae-tree/index.json",
        "knowledge/rae-tree/attention.json",
        "knowledge/rae-tree/nodes/project.json",
    ):
        size = (ROOT / relative).stat().st_size
        assert size <= 12_000, f"{relative} exceeds 12 KB ({size} bytes)"

    print("Recursive tree structural checks passed.")
    print("Default startup loads root + selected branch; descendants remain lazy.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, KeyError, StopIteration, json.JSONDecodeError) as exc:
        print(f"recursive tree check failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
