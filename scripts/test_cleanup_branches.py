import json
import tempfile
from datetime import datetime, timezone, timedelta
import unittest
from unittest.mock import patch, Mock
from scripts.cleanup_branches import CONFIRMATION, inspect_batch, main, parse_manifest


class CleanupManifestTests(unittest.TestCase):
    def test_exact_sha_manifest(self):
        with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8") as file:
            json.dump({"generated_at": datetime.now(timezone.utc).isoformat(),
                       "task_reference_scan_complete": True, "task_references": [],
                       "repository": "Love-DC/recursive-ai-engineering",
                       "branches": {"feature/x": "a" * 40}}, file)
            file.flush()
            with patch("scripts.cleanup_branches.run") as run:
                run.return_value = Mock(returncode=0)
                self.assertEqual(parse_manifest(file.name),
                                 {"branches": {"feature/x": "a" * 40}, "task_references": set()})

    def test_rejects_missing_or_invalid_sha(self):
        with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8") as file:
            json.dump({"generated_at": datetime.now(timezone.utc).isoformat(),
                       "task_reference_scan_complete": True, "task_references": [],
                       "branches": {"feature/x": "short"}}, file)
            file.flush()
            with self.assertRaisesRegex(ValueError, "40-character"):
                parse_manifest(file.name)

    def test_rejects_stale_manifest(self):
        with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8") as file:
            json.dump({"generated_at": (datetime.now(timezone.utc) - timedelta(minutes=31)).isoformat(),
                       "task_reference_scan_complete": True, "task_references": [],
                       "branches": {"feature/x": "a" * 40}}, file)
            file.flush()
            with self.assertRaisesRegex(ValueError, "Stale inventory"):
                parse_manifest(file.name)

    def test_incomplete_task_reference_scan_is_rejected(self):
        with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8") as file:
            json.dump({"generated_at": datetime.now(timezone.utc).isoformat(),
                       "task_reference_scan_complete": False, "task_references": [],
                       "branches": {"feature/x": "a" * 40}}, file)
            file.flush()
            with self.assertRaisesRegex(ValueError, "Task-reference scan"):
                parse_manifest(file.name)

    def test_active_task_reference_blocks_a_branch_even_when_other_checks_pass(self):
        repository = "Love-DC/recursive-ai-engineering"
        manifest = {"branches": {"feature/x": "a" * 40}, "task_references": {"feature/x"}}
        with patch.dict("os.environ", {"GH_TOKEN": "test"}), patch("scripts.cleanup_branches.gh_json", side_effect=[
            {"default_branch": "main"}, [],
            {"commit": {"sha": "a" * 40}, "protected": False},
        ]):
            result = inspect_batch(repository, manifest)
        self.assertFalse(result[0]["eligible"])
        self.assertIn("task", result[0]["reason"])

    def test_dry_run_never_deletes_a_branch(self):
        sha = "a" * 40
        manifest = {"generated_at": datetime.now(timezone.utc).isoformat(),
                    "task_reference_scan_complete": True, "task_references": [],
                    "repository": "Love-DC/recursive-ai-engineering",
                    "branches": {"feature/x": sha}}
        with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8") as file:
            json.dump(manifest, file)
            file.flush()
            with patch.dict("os.environ", {"GH_TOKEN": "test", "GITHUB_REPOSITORY": "Love-DC/recursive-ai-engineering"}), \
                 patch("scripts.cleanup_branches.gh_json", side_effect=[
                    {"default_branch": "main"}, [],
                    {"commit": {"sha": sha}, "protected": False}, {"ahead_by": 0}
                 ]), patch("scripts.cleanup_branches.run") as run:
                run.return_value = Mock(returncode=0)
                self.assertEqual(main(["--manifest", file.name]), 0)
                self.assertFalse(any(call.args[0][1] == "push" for call in run.call_args_list))

    def test_execute_uses_force_with_lease_after_final_revalidation(self):
        sha = "a" * 40
        manifest = {"generated_at": datetime.now(timezone.utc).isoformat(),
                    "task_reference_scan_complete": True, "task_references": [],
                    "repository": "Love-DC/recursive-ai-engineering",
                    "branches": {"feature/x": sha}}
        api_responses = [
            {"default_branch": "main"}, [],
            {"commit": {"sha": sha}, "protected": False}, {"ahead_by": 0},
            {"default_branch": "main"}, [],
            {"commit": {"sha": sha}, "protected": False}, {"ahead_by": 0},
        ]
        with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8") as file:
            json.dump(manifest, file)
            file.flush()
            with patch.dict("os.environ", {"GH_TOKEN": "test", "GITHUB_REPOSITORY": "Love-DC/recursive-ai-engineering"}), \
                 patch("scripts.cleanup_branches.gh_json", side_effect=api_responses), \
                 patch("scripts.cleanup_branches.run") as run:
                run.return_value = Mock(returncode=0)
                self.assertEqual(main(["--manifest", file.name, "--execute",
                                       "--confirmation", CONFIRMATION]), 0)
                self.assertTrue(any(call.args[0][1] == "push" and
                                    f"--force-with-lease=refs/heads/feature/x:{sha}" in call.args[0]
                                    for call in run.call_args_list))

    def test_confirmation_is_single_exact_phrase(self):
        self.assertEqual(CONFIRMATION, "DELETE SELECTED RESOURCES")


if __name__ == "__main__":
    unittest.main()
