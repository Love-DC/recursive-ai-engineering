import json
import tempfile
from datetime import datetime, timezone, timedelta
import unittest
from unittest.mock import patch, Mock
from scripts.cleanup_branches import CONFIRMATION, inspect_batch, parse_manifest


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
        with patch("scripts.cleanup_branches.gh_json", side_effect=[
            {"default_branch": "main"}, [],
            {"commit": {"sha": "a" * 40}, "protected": False},
        ]):
            result = inspect_batch(repository, manifest)
        self.assertFalse(result[0]["eligible"])
        self.assertIn("task", result[0]["reason"])

    def test_confirmation_is_single_exact_phrase(self):
        self.assertEqual(CONFIRMATION, "DELETE SELECTED RESOURCES")


if __name__ == "__main__":
    unittest.main()
