import unittest
from datetime import datetime, timezone, timedelta
from scripts.resource_inventory import ELIGIBLE, DECISION, PRESERVE, build_report, preview_batch, render_markdown, validate_report_freshness

SHA = "a" * 40
NOW = datetime(2026, 11, 23, 1, 30, tzinfo=timezone.utc)


def sample():
    return {"generated_at": "2026-11-23T01:30:00Z", "registered_projects": [{
        "project_id": "p1", "project_key": "alpha", "repository": "Love-DC/recursive-ai-engineering",
        "default_branch": "main", "task_reference_scan": {"complete": True, "active_branch_refs": [], "historical_references": []},
        "github": {"branches": [
            {"name": "main", "sha": SHA, "default_branch": "main", "protected": False, "protection_verified": True, "open_pr_numbers": [], "merged": True},
            {"name": "safe", "sha": SHA, "default_branch": "main", "protected": False, "protection_verified": True, "open_pr_numbers": [], "merged": True},
            {"name": "protected", "sha": SHA, "default_branch": "main", "protected": True, "protection_verified": True, "open_pr_numbers": [], "merged": True},
            {"name": "open", "sha": SHA, "default_branch": "main", "protected": False, "protection_verified": True, "open_pr_numbers": [3], "merged": True},
            {"name": "unmerged", "sha": SHA, "default_branch": "main", "protected": False, "protection_verified": True, "open_pr_numbers": [], "merged": False},
            {"name": "unknown", "sha": SHA, "default_branch": "main", "protected": None, "protection_verified": False, "open_pr_numbers": [], "merged": None}],
            "open_pull_requests": [{"number": 3, "head_branch": "open", "url": "https://example.test/3"}]},
        "supabase": {"project_ref": "ref", "development_branches": [{"id": "dev"}], "edge_functions": [{"slug": "fn"}]}}],
        "supabase_projects": [{"id": "ref", "name": "Alpha", "status": "ACTIVE_HEALTHY"}]}


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.report = build_report(sample(), "Love-DC/recursive-ai-engineering")

    def row(self, kind, name):
        return next(r for r in self.report["resources"] if r["kind"] == kind and r["identity"] == name)

    def test_default_protected_open_pr_unmerged_are_preserved(self):
        for name in ("main", "protected", "open", "unmerged"):
            self.assertEqual(self.row("branch", name)["risk_class"], PRESERVE)

    def test_active_task_reference_is_preserved(self):
        data = sample()
        data["registered_projects"][0]["task_reference_scan"]["active_branch_refs"] = ["safe"]
        report = build_report(data, "Love-DC/recursive-ai-engineering")
        row = next(r for r in report["resources"] if r["kind"] == "branch" and r["identity"] == "safe")
        self.assertEqual(row["risk_class"], PRESERVE)
        self.assertTrue(row["evidence"]["active_task_reference"])

    def test_incomplete_task_reference_scan_blocks_cleanup(self):
        data = sample()
        data["registered_projects"][0]["task_reference_scan"]["complete"] = False
        report = build_report(data, "Love-DC/recursive-ai-engineering")
        row = next(r for r in report["resources"] if r["kind"] == "branch" and r["identity"] == "safe")
        self.assertEqual(row["risk_class"], PRESERVE)

    def test_preview_manifest_carries_task_reference_guard(self):
        data = sample()
        data["registered_projects"][0]["task_reference_scan"]["active_branch_refs"] = ["other-task-branch"]
        report = build_report(data, "Love-DC/recursive-ai-engineering")
        row = next(r for r in report["resources"] if r["kind"] == "branch" and r["identity"] == "safe")
        plan = preview_batch(report, [row["id"]], now=NOW)
        self.assertTrue(plan["dry_run"])
        self.assertTrue(plan["preview_only"])
        self.assertFalse(plan["authorization_granted"])
        self.assertFalse(plan["deletion_performed"])
        self.assertEqual(plan["selected_count"], 1)
        self.assertNotIn("targets", plan)
        self.assertNotIn("branches", plan)

    def test_unknown_protection_or_ancestry_is_preserved(self):
        self.assertEqual(self.row("branch", "unknown")["risk_class"], PRESERVE)

    def test_only_verified_local_merged_branch_is_eligible(self):
        self.assertEqual(self.row("branch", "safe")["risk_class"], ELIGIBLE)

    def test_supabase_resources_are_inventory_only(self):
        for kind in ("development_branch", "edge_function", "project"):
            self.assertEqual(next(r for r in self.report["resources"] if r["kind"] == kind)["risk_class"], PRESERVE)

    def test_project_isolation_blocks_cross_repo_batch(self):
        data = sample()
        data["registered_projects"][0]["repository"] = "other/private-repo"
        report = build_report(data, "Love-DC/recursive-ai-engineering")
        row = next(r for r in report["resources"] if r["kind"] == "branch" and r["identity"] == "safe")
        self.assertEqual(row["risk_class"], DECISION)

    def test_batch_preview_is_non_authorizing_and_returns_no_target_data(self):
        row = self.row("branch", "safe")
        plan = preview_batch(self.report, [row["id"]], now=NOW)
        self.assertEqual(plan["selected_count"], 1)
        self.assertTrue(plan["preview_only"])
        self.assertFalse(plan["authorization_granted"])
        self.assertFalse(plan["deletion_performed"])
        for key in ("targets", "branches", "expected_shas", "authorized_targets"):
            self.assertNotIn(key, plan)

    def test_stale_snapshot_is_rejected(self):
        row = self.row("branch", "safe")
        with self.assertRaisesRegex(ValueError, "stale"):
            preview_batch(self.report, [row["id"]], now=NOW + timedelta(minutes=31))


    def test_report_freshness_requires_complete_collection_and_task_scan(self):
        data = sample()
        data["collection_notes"] = {
            "branch_inventory": {"all_pages_exhausted": True},
            "open_pr_inventory": {"all_pages_exhausted": True},
        }
        report = build_report(data, "Love-DC/recursive-ai-engineering")
        self.assertTrue(validate_report_freshness(report, now=NOW)["fresh"])

        data["collection_notes"]["branch_inventory"]["all_pages_exhausted"] = False
        report = build_report(data, "Love-DC/recursive-ai-engineering")
        with self.assertRaisesRegex(ValueError, "pagination is incomplete"):
            validate_report_freshness(report, now=NOW)

        data["collection_notes"]["branch_inventory"]["all_pages_exhausted"] = True
        data["registered_projects"][0]["task_reference_scan"]["complete"] = False
        report = build_report(data, "Love-DC/recursive-ai-engineering")
        with self.assertRaisesRegex(ValueError, "task-reference scan is incomplete"):
            validate_report_freshness(report, now=NOW)

    def test_stale_snapshot_is_blocked_even_when_no_branches_are_eligible(self):
        data = sample()
        data["collection_notes"] = {
            "branch_inventory": {"all_pages_exhausted": True},
            "open_pr_inventory": {"all_pages_exhausted": True},
        }
        report = build_report(data, "Love-DC/recursive-ai-engineering")
        report["resources"] = []
        with self.assertRaisesRegex(ValueError, "stale"):
            validate_report_freshness(report, now=NOW + timedelta(minutes=31))

    def test_report_is_grouped_and_preserves_collection_evidence(self):
        data = sample()
        data["collection_notes"] = {"branch_ancestry": "unknown"}
        report = build_report(data, "Love-DC/recursive-ai-engineering")
        self.assertEqual(report["collection_notes"]["branch_ancestry"], "unknown")
        markdown = render_markdown(report)
        self.assertIn("## Collection notes", markdown)
        self.assertIn("No resources were deleted", markdown)

    def test_duplicate_and_unknown_targets_rejected(self):
        row = self.row("branch", "safe")
        with self.assertRaisesRegex(ValueError, "unique"):
            preview_batch(self.report, [row["id"], row["id"]], now=NOW)
        with self.assertRaisesRegex(ValueError, "Unknown"):
            preview_batch(self.report, ["missing"], now=NOW)


if __name__ == "__main__":
    unittest.main()
