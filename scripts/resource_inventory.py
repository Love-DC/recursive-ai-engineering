"""Read-only, deterministic resource inventory and fail-closed batch planner."""
from datetime import datetime, timezone
from typing import Any

ELIGIBLE = "eligible_batch"
DECISION = "owner_decision_required"
PRESERVE = "preserve_or_blocked"


def _time(value: str) -> datetime:
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("generated_at must include a timezone")
    return result.astimezone(timezone.utc)


def build_report(snapshot: dict[str, Any], current_repository: str) -> dict[str, Any]:
    generated = snapshot.get("generated_at")
    if not isinstance(generated, str):
        raise ValueError("snapshot.generated_at is required")
    _time(generated)
    resources = []

    def add(project, platform, kind, identity, state, risk, action, reason, evidence=None):
        resources.append({
            "id": f"{project.get('project_id', 'account')}:{platform}:{kind}:{identity}",
            "project_id": project.get("project_id"), "project_key": project.get("project_key"),
            "repository": project.get("repository"), "platform": platform, "kind": kind,
            "identity": str(identity), "observed_state": state, "risk_class": risk,
            "recommended_action": action, "reason": reason, "evidence": evidence or {},
        })

    for project in sorted(snapshot.get("registered_projects", []), key=lambda p: (p.get("project_key") or "", p.get("project_id") or "")):
        if not project.get("project_id") or not project.get("repository"):
            add(project, "registry", "project", "unknown", "incomplete", DECISION, "inspect registration", "Missing project ID or canonical repository.")
            continue
        github = project.get("github", {})
        default = project.get("default_branch")
        task_scan = project.get("task_reference_scan", {})
        active_task_refs = set(task_scan.get("active_branch_refs", []))
        task_scan_complete = task_scan.get("complete") is True
        historical_task_refs = task_scan.get("historical_references", [])
        for branch in sorted(github.get("branches", []), key=lambda b: b.get("name", "")):
            name, sha = branch.get("name", "unknown"), branch.get("sha")
            prs = sorted(set(branch.get("open_pr_numbers") or []))
            if name == (branch.get("default_branch") or default):
                risk, action, reason = PRESERVE, "preserve", "Default branch."
            elif branch.get("protected") is True:
                risk, action, reason = PRESERVE, "preserve", "Branch is protected."
            elif prs:
                risk, action, reason = PRESERVE, "preserve", "Referenced by open pull request(s)."
            elif name in active_task_refs:
                risk, action, reason = PRESERVE, "preserve", "Referenced by an active or submitted task."
            elif not task_scan_complete:
                risk, action, reason = PRESERVE, "preserve until verified", "Task-reference scan is incomplete; uncertain dependencies are never cleanup candidates."
            elif branch.get("protection_verified") is not True:
                risk, action, reason = PRESERVE, "preserve until verified", "Protection state is unknown; uncertain branches are never cleanup candidates."
            elif branch.get("merged") is False:
                risk, action, reason = PRESERVE, "preserve", "Branch is not merged into default."
            elif branch.get("merged") is not True or not isinstance(sha, str) or len(sha) != 40:
                risk, action, reason = PRESERVE, "preserve until verified", "Merged ancestry or exact SHA is unknown; uncertain branches are never cleanup candidates."
            elif project["repository"] != current_repository:
                risk, action, reason = DECISION, "manual handoff", "Cross-repository mutation is disabled without a scoped credential."
            else:
                risk, action, reason = ELIGIBLE, "batch preview only", "Merged, unprotected, unused RAE-local branch."
            historical_refs = [item for item in historical_task_refs if item.get("branch") == name]
            add(project, "github", "branch", name, "present" if sha else "unknown", risk, action, reason,
                {"sha": sha, "protected": branch.get("protected"), "protection_verified": branch.get("protection_verified") is True,
                 "open_pr_numbers": prs, "merged": branch.get("merged"), "default_branch": default,
                 "active_task_reference": name in active_task_refs, "task_reference_scan_complete": task_scan_complete,
                 "historical_task_references": historical_refs})
        for pr in sorted(github.get("open_pull_requests", []), key=lambda p: int(p.get("number", 0))):
            add(project, "github", "open_pr_reference", pr.get("number", "unknown"), "open", PRESERVE,
                "preserve referenced branch", "Open PR reference is never a cleanup target.",
                {"head_repository": pr.get("head_repository"), "head_branch": pr.get("head_branch"), "url": pr.get("url")})
        supa = project.get("supabase", {})
        for item in sorted(supa.get("development_branches", []), key=lambda x: str(x.get("id", ""))):
            add(project, "supabase", "development_branch", item.get("id", "unknown"), item.get("status", "unknown"),
                PRESERVE, "inventory only", "Supabase development branches are never deleted by this center.",
                {"name": item.get("name"), "project_ref": supa.get("project_ref")})
        for item in sorted(supa.get("edge_functions", []), key=lambda x: str(x.get("slug", ""))):
            add(project, "supabase", "edge_function", item.get("slug", "unknown"), item.get("status", "unknown"),
                PRESERVE, "inventory only", "Edge Functions are inventory-only; deployment and deletion are excluded.",
                {"version": item.get("version"), "project_ref": supa.get("project_ref")})
    for item in sorted(snapshot.get("supabase_projects", []), key=lambda x: str(x.get("id", ""))):
        ref = item.get("id", "unknown")
        add({}, "supabase", "project", ref, item.get("status", "unknown"),
            PRESERVE, "inventory only", "Supabase projects are inventory-only and cannot be deleted here.",
            {"name": item.get("name"), "region": item.get("region"), "mapping_status": item.get("mapping_status")})
        for dev in sorted(item.get("development_branches", []), key=lambda x: str(x.get("id", ""))):
            add({}, "supabase", "development_branch", dev.get("id", "unknown"), dev.get("status", "unknown"),
                PRESERVE, "inventory only", "Supabase development branches are inventory-only.",
                {"name": dev.get("name"), "project_ref": ref})
        for fn in sorted(item.get("edge_functions", []), key=lambda x: str(x.get("slug", ""))):
            add({}, "supabase", "edge_function", fn.get("slug", "unknown"), fn.get("status", "unknown"),
                PRESERVE, "inventory only", "Edge Functions are inventory-only.",
                {"version": fn.get("version"), "project_ref": ref})
    resources.sort(key=lambda r: (r["project_key"] or "", r["platform"], r["kind"], r["identity"]))
    counts = {risk: sum(r["risk_class"] == risk for r in resources) for risk in (ELIGIBLE, DECISION, PRESERVE)}
    current_scan = next((p.get("task_reference_scan", {}) for p in snapshot.get("registered_projects", [])
                         if p.get("repository") == current_repository), {})
    return {"schema_version": 1, "generated_at": generated, "current_repository": current_repository,
            "dry_run_default": True, "resources": resources, "counts": counts, "deletion_performed": False,
            "task_reference_scan_complete": current_scan.get("complete") is True,
            "task_references": sorted(set(current_scan.get("active_branch_refs", []))),
            "collection_notes": snapshot.get("collection_notes", {})}


def preview_batch(report: dict[str, Any], ids: list[str], now: datetime | None = None, max_age_minutes: int = 30):
    if not ids or len(ids) != len(set(ids)):
        raise ValueError("Batch must contain unique resource IDs.")
    if report.get("task_reference_scan_complete") is not True:
        raise ValueError("Task-reference scan is incomplete; batch preview is blocked.")
    current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    age = (current - _time(report["generated_at"])).total_seconds() / 60
    if age < 0 or age > max_age_minutes:
        raise ValueError("Inventory snapshot is stale; refresh before preview or execution.")
    lookup = {r["id"]: r for r in report["resources"]}
    targets = []
    for identity in ids:
        row = lookup.get(identity)
        if row is None:
            raise ValueError(f"Unknown resource ID: {identity}")
        if row["risk_class"] != ELIGIBLE:
            raise ValueError(f"Resource is not batch-eligible: {identity}")
        if row["repository"] != report["current_repository"]:
            raise ValueError("Cross-repository mutation is disabled.")
        targets.append({"id": identity, "repository": row["repository"], "branch": row["identity"],
                        "expected_sha": row["evidence"].get("sha")})
    return {"generated_at": report["generated_at"], "dry_run": True, "confirmation_required": True,
            "task_reference_scan_complete": True, "task_references": report.get("task_references", []),
            "repository": report["current_repository"],
            "branches": {target["branch"]: target["expected_sha"] for target in targets},
            "targets": targets}


def authorize_batch(preview: dict[str, Any], confirmation: str, expected_shas: dict[str, str]):
    if confirmation != "DELETE SELECTED RESOURCES":
        raise ValueError("Explicit batch confirmation is required.")
    for target in preview["targets"]:
        if expected_shas.get(target["branch"]) != target["expected_sha"]:
            raise ValueError(f"Stale inventory for {target['branch']}; refresh and preview again.")
    return preview["targets"]


def render_markdown(report: dict[str, Any]) -> str:
    c = report["counts"]
    lines = ["# Cross-project resource inventory", "", f"- Generated: {report['generated_at']}",
             f"- Current repository: {report['current_repository']}", "- Mode: read-only; dry-run by default",
             f"- Eligible batch candidates: {c[ELIGIBLE]}", f"- Owner decision required: {c[DECISION]}",
             f"- Preserved / blocked / inventory-only: {c[PRESERVE]}", "",
             "| Project | Platform | Resource | State | Risk | Action | Reason |",
             "|---|---|---|---|---|---|---|"]
    for r in report["resources"]:
        vals = (r["project_key"] or r["project_id"] or "Supabase account", r["platform"], r["identity"],
                r["observed_state"], r["risk_class"], r["recommended_action"], r["reason"])
        lines.append("| " + " | ".join(str(v).replace("|", "\\\\|").replace("\n", " ") for v in vals) + " |")
    notes = report.get("collection_notes", {})
    if notes:
        lines.extend(["", "## Collection notes"])
        for key, value in notes.items():
            lines.append(f"- {key}: {value}")
    lines.extend(["", "No resources were deleted. ChatGPT conversation history is outside this inventory."])
    return "\n".join(lines) + "\n"


def main():
    import argparse
    import json
    from pathlib import Path
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=Path, help="JSON snapshot collected from authorized Supabase/GitHub integrations")
    parser.add_argument("--repository", required=True, help="Canonical RAE repository owner/name")
    parser.add_argument("--json-out", type=Path, required=True)
    parser.add_argument("--markdown-out", type=Path, required=True)
    args = parser.parse_args()
    snapshot = json.loads(args.snapshot.read_text(encoding="utf-8"))
    report = build_report(snapshot, args.repository)
    args.json_out.parent.mkdir(parents=True, exist_ok=True)
    args.markdown_out.parent.mkdir(parents=True, exist_ok=True)
    args.json_out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    args.markdown_out.write_text(render_markdown(report), encoding="utf-8")
    print(render_markdown(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
