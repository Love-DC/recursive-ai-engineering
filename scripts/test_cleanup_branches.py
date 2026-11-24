import json
import tempfile
from datetime import datetime, timezone, timedelta
import unittest
from unittest.mock import patch, Mock

from scripts.cleanup_branches import gh_json_pages, inspect_batch, main, parse_manifest


SHA = "a" * 40
REPOSITORY = "Love-DC/recursive-ai-engineering"


def manifest(branch="feature/x", task_references=None):
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "task_reference_scan_complete": True,
        "task_references": task_references or [],
        "repository": REPOSITORY,
        "branches": {branch: SHA},
    }


class CleanupManifestTests(unittest.TestCase):
    def test_exact_sha_manifest(self):
        with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8") as file:
            json.dump(manifest(), file)
            file.flush()
            with patch("scripts.cleanup_branches.run") as run:
                run.return_value = Mock(returncode=0, stdout="")
                self.assertEqual(
                    parse_manifest(file.name),
                    {"branches": {"feature/x": SHA}, "task_references": set()},
                )

    def test_rejects_missing_or_invalid_sha(self):
        data = manifest()
        data["branches"]["feature/x"] = "short"
        with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8") as file:
            json.dump(data, file)
            file.flush()
            with self.assertRaisesRegex(ValueError, "40-character"):
                parse_manifest(file.name)

    def test_rejects_stale_manifest(self):
        data = manifest()
        data["generated_at"] = (datetime.now(timezone.utc) - timedelta(minutes=31)).isoformat()
        with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8") as file:
            json.dump(data, file)
            file.flush()
            with self.assertRaisesRegex(ValueError, "Stale inventory"):
                parse_manifest(file.name)

    def test_incomplete_task_reference_scan_is_rejected(self):
        data = manifest()
        data["task_reference_scan_complete"] = False
        with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8") as file:
            json.dump(data, file)
            file.flush()
            with self.assertRaisesRegex(ValueError, "Task-reference scan"):
                parse_manifest(file.name)


class GitHubPaginationTests(unittest.TestCase):
    def test_gh_json_pages_flattens_all_pages(self):
        first = [{"number": 1}, {"number": 2}]
        second = [{"number": 101}, {"number": 102}]
        response = Mock(returncode=0, stdout=json.dumps([first, second]))
        with patch("scripts.cleanup_branches.run", return_value=response) as run:
            self.assertEqual(gh_json_pages("repos/example/repo/pulls?state=open&per_page=100"),
                             first + second)
            self.assertIn("--paginate", run.call_args.args[0])
            self.assertIn("--slurp", run.call_args.args[0])

    def test_open_pr_on_second_page_blocks_branch(self):
        page_one = [{"head": {"ref": "other", "repo": {"full_name": REPOSITORY}}}]
        page_two = [{"head": {"ref": "feature/x", "repo": {"full_name": REPOSITORY}}}]
        with patch.dict("os.environ", {"GH_TOKEN": "test"}), \
             patch("scripts.cleanup_branches.gh_json_pages", return_value=page_one + page_two), \
             patch("scripts.cleanup_branches.gh_json", side_effect=[
                 {"default_branch": "main"},
                 {"commit": {"sha": SHA}, "protected": False},
             ]):
            result = inspect_batch(REPOSITORY, {
                "branches": {"feature/x": SHA},
                "task_references": set(),
            })
        self.assertFalse(result[0]["eligible"])
        self.assertIn("open pull request", result[0]["reason"])

    def test_active_task_reference_snapshot_blocks_preview_candidate(self):
        with patch.dict("os.environ", {"GH_TOKEN": "test"}), \
             patch("scripts.cleanup_branches.gh_json_pages", return_value=[]), \
             patch("scripts.cleanup_branches.gh_json", side_effect=[
                 {"default_branch": "main"},
                 {"commit": {"sha": SHA}, "protected": False},
             ]):
            result = inspect_batch(REPOSITORY, {
                "branches": {"feature/x": SHA},
                "task_references": {"feature/x"},
            })
        self.assertFalse(result[0]["eligible"])
        self.assertIn("task", result[0]["reason"])


class ReadOnlyExecutionTests(unittest.TestCase):
    def test_dry_run_never_deletes_a_branch(self):
        with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8") as file:
            json.dump(manifest(), file)
            file.flush()
            with patch.dict("os.environ", {
                "GH_TOKEN": "test",
                "GITHUB_REPOSITORY": REPOSITORY,
            }), patch("scripts.cleanup_branches.gh_json_pages", return_value=[]), \
                 patch("scripts.cleanup_branches.gh_json", side_effect=[
                     {"default_branch": "main"},
                     {"commit": {"sha": SHA}, "protected": False},
                     {"ahead_by": 0},
                 ]), patch("scripts.cleanup_branches.run") as run:
                run.return_value = Mock(returncode=0, stdout="")
                self.assertEqual(main(["--manifest", file.name]), 0)
                self.assertFalse(any("push" in call.args[0] for call in run.call_args_list))

    def test_execute_is_disabled_even_with_confirmation_attempt(self):
        with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8") as file:
            json.dump(manifest(), file)
            file.flush()
            with self.assertRaises(SystemExit) as raised:
                main(["--manifest", file.name, "--execute"])
            self.assertEqual(raised.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
