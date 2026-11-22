"""Unit tests for the guarded branch-cleanup decision logic."""
import unittest
from unittest.mock import patch

from scripts.cleanup_branches import (
    CONFIRMATION,
    evaluate_candidate,
    parse_branch_names,
)


class ParseBranchNamesTests(unittest.TestCase):
    @patch("scripts.cleanup_branches.subprocess.run")
    def test_parses_multiline_names_and_ignores_blank_lines(self, run):
        run.return_value.returncode = 0
        self.assertEqual(parse_branch_names("\nfeature/one\n  fix/two  \n"), [
            "feature/one", "fix/two"
        ])
        self.assertEqual(run.call_count, 2)

    @patch("scripts.cleanup_branches.subprocess.run")
    def test_rejects_invalid_branch(self, run):
        run.return_value.returncode = 1
        with self.assertRaisesRegex(ValueError, "Invalid Git branch name"):
            parse_branch_names("bad branch")

    @patch("scripts.cleanup_branches.subprocess.run")
    def test_rejects_duplicate_branch(self, run):
        run.return_value.returncode = 0
        with self.assertRaisesRegex(ValueError, "Duplicate branch name"):
            parse_branch_names("feature/one\nfeature/one")

    @patch("scripts.cleanup_branches.subprocess.run")
    def test_rejects_empty_batch(self, run):
        with self.assertRaisesRegex(ValueError, "at least one"):
            parse_branch_names("\n \n")


class CandidateGuardTests(unittest.TestCase):
    def test_confirmation_phrase_is_explicit(self):
        self.assertEqual(CONFIRMATION, "DELETE MERGED BRANCHES")

    def test_default_branch_is_never_eligible(self):
        item = evaluate_candidate(
            "main", default_branch="main", protected=False,
            has_open_pr=False, merged=True,
        )
        self.assertFalse(item.eligible)
        self.assertEqual(item.reason, "default branch")

    def test_protected_branch_is_never_eligible(self):
        item = evaluate_candidate(
            "release", default_branch="main", protected=True,
            has_open_pr=False, merged=True,
        )
        self.assertFalse(item.eligible)
        self.assertEqual(item.reason, "protected by a branch rule")

    def test_open_pr_branch_is_never_eligible(self):
        item = evaluate_candidate(
            "feature/open", default_branch="main", protected=False,
            has_open_pr=True, merged=True,
        )
        self.assertFalse(item.eligible)
        self.assertEqual(item.reason, "referenced by an open pull request")

    def test_unmerged_branch_is_never_eligible(self):
        item = evaluate_candidate(
            "feature/unmerged", default_branch="main", protected=False,
            has_open_pr=False, merged=False,
        )
        self.assertFalse(item.eligible)
        self.assertIn("not merged", item.reason)

    def test_only_merged_unprotected_unused_branch_is_eligible(self):
        item = evaluate_candidate(
            "feature/done", default_branch="main", protected=False,
            has_open_pr=False, merged=True, sha="a" * 40,
        )
        self.assertTrue(item.eligible)
        self.assertEqual(item.sha, "a" * 40)


if __name__ == "__main__":
    unittest.main()
