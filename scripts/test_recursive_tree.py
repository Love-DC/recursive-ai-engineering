#!/usr/bin/env python3
"""Credential-free recursive-tree schema, reference, and context-budget checks."""

from __future__ import annotations

import json
import re
import sys
from datetime import datetime
from pathlib import Path
from uuid import UUID

ROOT = Path(__file__).resolve().parents[1]
STATUSES = {"active", "dormant", "blocked", "completed", "archived"}
JSON_TYPES = {"object", "array", "string", "integer", "number", "boolean", "null"}
SCHEMA_KEYS = {
    "$schema", "$id", "title", "description", "type", "additionalProperties",
    "required", "properties", "items", "const", "enum", "minLength",
    "maxLength", "pattern", "format", "uniqueItems", "default",
}
SUPPORTED_FORMATS = {"date-time", "uuid"}


def check(label: str, condition: bool) -> None:
    if not condition:
        raise AssertionError(label)


def load_json(relative: str):
    path = ROOT / relative
    check(f"missing JSON file: {relative}", path.is_file())
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise AssertionError(f"invalid JSON file {relative}: {exc}") from exc


def safe_repo_path(value: str, label: str) -> Path:
    check(f"{label} must be a non-empty repository-relative path", isinstance(value, str) and bool(value))
    candidate = Path(value)
    check(f"{label} must not be absolute: {value}", not candidate.is_absolute())
    check(f"{label} contains path traversal: {value}", ".." not in candidate.parts)
    resolved = (ROOT / candidate).resolve()
    check(f"{label} escapes repository root: {value}", resolved == ROOT or ROOT in resolved.parents)
    return resolved


def validate_schema_definition(schema: dict, path: str = "$schema") -> list[str]:
    errors: list[str] = []
    if not isinstance(schema, dict):
        return [f"{path}: schema must be an object"]

    unknown = set(schema) - SCHEMA_KEYS
    if unknown:
        errors.append(f"{path}: unsupported schema keywords {sorted(unknown)}")

    expected_type = schema.get("type")
    if expected_type is not None:
        types = expected_type if isinstance(expected_type, list) else [expected_type]
        if not types or any(item not in JSON_TYPES for item in types):
            errors.append(f"{path}.type: invalid JSON type declaration")

    required = schema.get("required", [])
    properties = schema.get("properties", {})
    if not isinstance(required, list) or any(not isinstance(item, str) for item in required):
        errors.append(f"{path}.required: expected an array of property names")
        required = []
    if not isinstance(properties, dict):
        errors.append(f"{path}.properties: expected an object")
        properties = {}
    missing_definitions = set(required) - set(properties)
    if missing_definitions and schema.get("additionalProperties") is False:
        errors.append(f"{path}.required: no property schema for {sorted(missing_definitions)}")

    additional = schema.get("additionalProperties", True)
    if not isinstance(additional, (bool, dict)):
        errors.append(f"{path}.additionalProperties: expected boolean or schema")
    elif isinstance(additional, dict):
        errors.extend(validate_schema_definition(additional, f"{path}.additionalProperties"))

    if "items" in schema:
        if not isinstance(schema["items"], dict):
            errors.append(f"{path}.items: expected a schema object")
        else:
            errors.extend(validate_schema_definition(schema["items"], f"{path}.items"))

    if "enum" in schema and (not isinstance(schema["enum"], list) or not schema["enum"]):
        errors.append(f"{path}.enum: expected a non-empty array")
    if "pattern" in schema:
        try:
            re.compile(schema["pattern"])
        except (TypeError, re.error):
            errors.append(f"{path}.pattern: invalid regular expression")
    if "format" in schema and schema["format"] not in SUPPORTED_FORMATS:
        errors.append(f"{path}.format: unsupported format {schema['format']!r}")

    for keyword in ("minLength", "maxLength"):
        if keyword in schema and (
            not isinstance(schema[keyword], int) or isinstance(schema[keyword], bool) or schema[keyword] < 0
        ):
            errors.append(f"{path}.{keyword}: expected a non-negative integer")

    if "uniqueItems" in schema and not isinstance(schema["uniqueItems"], bool):
        errors.append(f"{path}.uniqueItems: expected a boolean")

    for name, child in properties.items():
        errors.extend(validate_schema_definition(child, f"{path}.properties.{name}"))

    return errors


def matches_type(value, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "null":
        return value is None
    return False


def validate_instance(value, schema: dict, path: str = "$") -> list[str]:
    errors: list[str] = []
    expected_type = schema.get("type")
    if expected_type is not None:
        types = expected_type if isinstance(expected_type, list) else [expected_type]
        if not any(matches_type(value, item) for item in types):
            return [f"{path}: expected type {types}, got {type(value).__name__}"]

    if "const" in schema and value != schema["const"]:
        errors.append(f"{path}: value does not match const")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: value is not in enum")

    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            errors.append(f"{path}: shorter than minLength")
        if len(value) > schema.get("maxLength", float("inf")):
            errors.append(f"{path}: longer than maxLength")
        if "pattern" in schema and re.search(schema["pattern"], value) is None:
            errors.append(f"{path}: value does not match pattern")
        if schema.get("format") == "uuid":
            try:
                parsed = UUID(value)
                if str(parsed) != value.lower():
                    errors.append(f"{path}: UUID is not canonical")
            except (ValueError, AttributeError):
                errors.append(f"{path}: invalid UUID")
        elif schema.get("format") == "date-time":
            try:
                parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
                if parsed.tzinfo is None:
                    errors.append(f"{path}: date-time must include a timezone")
            except ValueError:
                errors.append(f"{path}: invalid date-time")

    if isinstance(value, dict):
        for name in schema.get("required", []):
            if name not in value:
                errors.append(f"{path}: missing required property {name!r}")
        properties = schema.get("properties", {})
        additional = schema.get("additionalProperties", True)
        for name, child_value in value.items():
            if name in properties:
                errors.extend(validate_instance(child_value, properties[name], f"{path}.{name}"))
            elif additional is False:
                errors.append(f"{path}: unexpected property {name!r}")
            elif isinstance(additional, dict):
                errors.extend(validate_instance(child_value, additional, f"{path}.{name}"))

    if isinstance(value, list):
        if schema.get("uniqueItems") and len({json.dumps(item, sort_keys=True) for item in value}) != len(value):
            errors.append(f"{path}: array items are not unique")
        if "items" in schema:
            for index, item in enumerate(value):
                errors.extend(validate_instance(item, schema["items"], f"{path}[{index}]"))

    return errors


def validator_self_tests(schema: dict, valid_node: dict) -> None:
    check("validator self-test: valid node rejected", not validate_instance(valid_node, schema))

    missing_required = dict(valid_node)
    missing_required.pop("goal")
    check(
        "validator self-test: missing required property accepted",
        bool(validate_instance(missing_required, schema)),
    )

    extra_property = dict(valid_node)
    extra_property["undeclared"] = True
    check(
        "validator self-test: additional property accepted",
        bool(validate_instance(extra_property, schema)),
    )

    bad_uuid = dict(valid_node)
    bad_uuid["task_refs"] = ["not-a-uuid"]
    check(
        "validator self-test: malformed UUID accepted",
        bool(validate_instance(bad_uuid, schema)),
    )

    bad_schema = {"type": "not-a-json-type"}
    check(
        "validator self-test: malformed schema accepted",
        bool(validate_schema_definition(bad_schema)),
    )


def main() -> int:
    root = load_json("knowledge/rae-root/index.json")
    schema = load_json("knowledge/rae-tree/node.schema.json")
    index = load_json("knowledge/rae-tree/index.json")
    attention = load_json("knowledge/rae-tree/attention.json")

    schema_errors = validate_schema_definition(schema)
    check(f"node schema is invalid: {schema_errors}", not schema_errors)
    check("unsupported node schema draft", schema.get("$schema") == "https://json-schema.org/draft/2020-12/schema")
    check("node schema does not declare an object", schema.get("type") == "object")

    check("root schema version mismatch", root["schema_version"] == schema["properties"]["schema_version"]["const"])
    check("tree/node schema version mismatch", index["schema_version"] == schema["properties"]["schema_version"]["const"])
    check("tree index schema pointer mismatch", index.get("node_schema") == "knowledge/rae-tree/node.schema.json")
    check("tree index schema file missing", safe_repo_path(index["node_schema"], "node_schema").is_file())
    check("global root ID mismatch", root["root_node_id"] == "rae:root")
    check("tree index node registry is empty or invalid", isinstance(index.get("nodes"), dict) and bool(index["nodes"]))

    # Resolve and schema-validate every node declared in the selected project's index.
    nodes: dict[str, dict] = {}
    node_paths: dict[str, str] = {}
    for node_id, relative_path in index["nodes"].items():
        path = safe_repo_path(relative_path, f"node path for {node_id}")
        check(f"node file missing from index: {node_id} -> {relative_path}", path.is_file())
        try:
            node_data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise AssertionError(f"invalid node JSON {relative_path}: {exc}") from exc
        errors = validate_instance(node_data, schema, f"node[{node_id}]")
        check(f"node schema validation failed for {node_id}: {errors}", not errors)
        check(f"node registry key does not match node_id: {node_id}", node_data["node_id"] == node_id)
        nodes[node_id] = node_data
        node_paths[node_id] = relative_path

    root_node_id = index["root_node_id"]
    check("project root node missing from node registry", root_node_id in nodes)
    node = nodes[root_node_id]
    check("project root node ID mismatch", root_node_id == "project:recursive-ai-engineering")
    check("project root node type/status invalid", node["node_type"] == "project" and node["status"] in STATUSES)
    for indexed_id, indexed_node in nodes.items():
        parent_id = indexed_node["parent_node_id"]
        if parent_id is not None:
            check(f"parent node reference missing for {indexed_id}: {parent_id}", parent_id in nodes)
    check("node summary exceeds 1200 characters", len(node["summary"]) <= 1200)

    check("node children_index differs from project attention_index", node["children_index"] == index["attention_index"])
    attention_path = safe_repo_path(index["attention_index"], "attention_index")
    check("project attention index file missing", attention_path.is_file())

    project_keys = [p["project_key"] for p in root["projects"]]
    check("duplicate project key in root index", len(project_keys) == len(set(project_keys)))
    rae = next(p for p in root["projects"] if p["project_key"] == "recursive-ai-engineering")
    check("RAE project pointer is not initialized", rae["state"] == "initialized")
    check("RAE project tree pointer mismatch", rae["tree_index"] == "knowledge/rae-tree/index.json")
    check("RAE project tree index file missing", safe_repo_path(rae["tree_index"], "RAE tree_index").is_file())

    for project in root["projects"]:
        if project["state"] == "pending_bootstrap":
            continue
        check(f"unknown project state: {project['state']}", project["state"] == "initialized")
        check(
            f"project pointer incomplete: {project['project_key']}",
            bool(project["repository"] and project["tree_index"]),
        )

    for ref in node["context_refs"]:
        check(f"missing context reference: {ref}", safe_repo_path(ref, "context_ref").is_file())
    if node.get("checkpoint_ref") is not None:
        check(
            f"missing checkpoint reference: {node['checkpoint_ref']}",
            safe_repo_path(node["checkpoint_ref"], "checkpoint_ref").is_file(),
        )
    for dependency in node["dependency_refs"]:
        check(
            f"missing dependency node reference: {dependency['node_id']}",
            dependency["node_id"] in nodes,
        )
    for task_id in node["task_refs"]:
        try:
            UUID(task_id)
        except (ValueError, AttributeError):
            raise AssertionError(f"invalid task UUID: {task_id}")

    check("attention schema version mismatch", attention["schema_version"] == "1.0")
    check("attention project key mismatch", attention["project_key"] == "recursive-ai-engineering")
    check(
        "attention shard exceeds configured item bound",
        len(attention["items"]) <= attention["pagination"]["max_items_per_shard"],
    )
    for item in attention["items"]:
        check(f"attention node ID missing from index: {item['node_id']}", item["node_id"] in nodes)
        check(
            f"attention node path does not match index for {item['node_id']}",
            item["node_path"] == node_paths[item["node_id"]],
        )

    for item in root["global_attention"]:
        check(
            f"global attention node path missing: {item['node_path']}",
            safe_repo_path(item["node_path"], "global_attention.node_path").is_file(),
        )
        if item["project_key"] == "recursive-ai-engineering":
            check(
                "global attention points to an unknown RAE node",
                item["node_id"] in nodes and item["node_path"] == node_paths[item["node_id"]],
            )

    validator_self_tests(schema, node)

    startup = (ROOT / "docs/SESSION-START.md").read_text(encoding="utf-8")
    check("startup does not load the RAE root index", "knowledge/rae-root/index.json" in startup)
    check("startup lacks explicit bounded-read section", "Default startup must not:" in startup)
    check("startup still requires full project task enumeration", "list every task in every registered project" in startup)
    check("startup permits eager descendant expansion", "recursively expand all descendants" in startup)
    check("startup lacks no-fixed-role statement", "There is no mandatory role declaration at startup" in startup)
    check(
        "startup lacks single-session runtime boundary",
        "The Owner manually starts one GPT conversation at a time" in startup
        and "a daemon, or background scheduling" in startup,
    )

    for relative in (
        "knowledge/rae-root/index.json",
        "knowledge/rae-tree/index.json",
        "knowledge/rae-tree/attention.json",
        node_paths[root_node_id],
    ):
        size = (ROOT / relative).stat().st_size
        check(f"{relative} exceeds 12 KB ({size} bytes)", size <= 12_000)

    print(f"Recursive tree schema and reference checks passed for {len(nodes)} indexed node(s).")
    print("Default startup loads root + selected branch; descendants remain lazy.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, KeyError, StopIteration, json.JSONDecodeError) as exc:
        print(f"recursive tree check failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
