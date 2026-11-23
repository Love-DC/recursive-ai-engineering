import json
import tempfile
from datetime import datetime, timezone, timedelta
import unittest
from unittest.mock import patch, Mock
from scripts.cleanup_branches import CONFIRMATION, parse_manifest


class CleanupManifestTests(unittest.TestCase):
    def test_exact_sha_manifest(self):
        with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8") as file:
            json.dump({"generated_at": datetime.now(timezone.utc).isoformat(),
                       "branches": {"feature/x": "a" * 40}}, file)
            file.flush()
            with patch("scripts.cleanup_branches.run") as run:
                run.return_value = Mock(returncode=0)
                self.assertEqual(parse_manifest(file.name), {"feature/x": "a" * 40})

    def test_rejects_missing_or_invalid_sha(self):
        with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8") as file:
            json.dump({"generated_at": datetime.now(timezone.utc).isoformat(),
                       "branches": {"feature/x": "short"}}, file)
            file.flush()
            with self.assertRaisesRegex(ValueError, "40-character"):
                parse_manifest(file.name)

    def test_rejects_stale_manifest(self):
        with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8") as file:
            json.dump({"generated_at": (datetime.now(timezone.utc) - timedelta(minutes=31)).isoformat(),
                       "branches": {"feature/x": "a" * 40}}, file)
            file.flush()
            with self.assertRaisesRegex(ValueError, "Stale inventory"):
                parse_manifest(file.name)

    def test_confirmation_is_single_exact_phrase(self):
        self.assertEqual(CONFIRMATION, "DELETE SELECTED RESOURCES")


if __name__ == "__main__":
    unittest.main()
