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


def check(label: str, condition: bool) -> None:
    if not condition:
        raise AssertionError(label)


def load_json(relative: str) -> dict:
    path = ROOT / relative
    check(f"missing JSON file: {relative}", path.is_file())
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    root = load_json("knowledge/rae-root/index.json")
    schema = load_json("knowledge/rae-tree/node.schema.json")
    index = load_json("knowledge/rae-tree/index.json")
    attention = load_json("knowledge/rae-tree/attention.json")
    node = load_json("knowledge/rae-tree/nodes/project.json")

    check("root schema version mismatch", root["schema_version"] == schema["properties"]["schema_version"]["const"])
    check("tree/node schema version mismatch", index["schema_version"] == node["schema_version"] == "1.0")
    check("global root ID mismatch", root["root_node_id"] == "rae:root")
    check("project root node ID mismatch", index["root_node_id"] == node["node_id"] == "project:recursive-ai-engineering")
    check("project root node type/status invalid", node["node_type"] == "project" and node["status"] in STATUSES)
    check(f"node required fields missing: {REQUIRED_NODE_FIELDS - set(node)}", REQUIRED_NODE_FIELDS.issubset(node))
    check("node summary exceeds 1200 characters", len(node["summary"]) <= 1200)
    check("node children_index differs from project attention_index", node["children_index"] == index["attention_index"])
    check("unexpected project attention_index path", node["children_index"] == "knowledge/rae-tree/attention.json")

    project_keys = [p["project_key"] for p in root["projects"]]
    check("duplicate project key in root index", len(project_keys) == len(set(project_keys)))
    rae = next(p for p in root["projects"] if p["project_key"] == "recursive-ai-engineering")
    check("RAE project pointer is not initialized", rae["state"] == "initialized")
    check("RAE project tree pointer mismatch", rae["tree_index"] == "knowledge/rae-tree/index.json")
    check("RAE project tree index file missing", (ROOT / rae["tree_index"]).is_file())

    for project in root["projects"]:
        if project["state"] == "pending_bootstrap":
            continue
        check(f"unknown project state: {project['state']}", project["state"] == "initialized")
        check(f"project pointer incomplete: {project['project_key']}", bool(project["repository"] and project["tree_index"]))

    for ref in node["context_refs"]:
        check(f"missing context reference: {ref}", (ROOT / ref).is_file())
    for task_id in node["task_refs"]:
        check(f"invalid task UUID: {task_id}", bool(re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", task_id)))

    check("attention schema version mismatch", attention["schema_version"] == "1.0")
    check("attention project key mismatch", attention["project_key"] == "recursive-ai-engineering")
    check("attention shard exceeds configured item bound", len(attention["items"]) <= attention["pagination"]["max_items_per_shard"])
    for item in attention["items"]:
        check(f"missing attention node: {item['node_path']}", (ROOT / item["node_path"]).is_file())
        check(f"unexpected attention node ID: {item['node_id']}", item["node_id"] == node["node_id"])

    startup = (ROOT / "docs/SESSION-START.md").read_text(encoding="utf-8")
    check("startup does not load the RAE root index", "knowledge/rae-root/index.json" in startup)
    check("startup lacks explicit bounded-read section", "Default startup must not:" in startup)
    check("startup still requires full project task enumeration", "list every task in every registered project" in startup)
    check("startup permits eager descendant expansion", "recursively expand all descendants" in startup)
    check("startup lacks no-fixed-role statement", "There is no mandatory role declaration at startup" in startup)
    check("startup lacks single-session runtime boundary", "The Owner manually starts one GPT conversation at a time" in startup and "a daemon, or background scheduling" in startup)

    for relative in (
        "knowledge/rae-root/index.json",
        "knowledge/rae-tree/index.json",
        "knowledge/rae-tree/attention.json",
        "knowledge/rae-tree/nodes/project.json",
    ):
        size = (ROOT / relative).stat().st_size
        check(f"{relative} exceeds 12 KB ({size} bytes)", size <= 12_000)

    print("Recursive tree structural checks passed.")
    print("Default startup loads root + selected branch; descendants remain lazy.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, KeyError, StopIteration, json.JSONDecodeError) as exc:
        print(f"recursive tree check failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
