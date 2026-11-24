import json
import tempfile
import unittest
from pathlib import Path

from scripts.repository_governance import GovernanceError, load_governance

SHA = "a" * 40


class RepositoryGovernanceTests(unittest.TestCase):
    def make_repo(self, manifest=None):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        for name in ("AGENTS.md", "docs/AI_START.md", "docs/WORKFLOW.md"):
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("repository rule\\n", encoding="utf-8")
        value = manifest or {
            "protocol": "rae.repository-governance",
            "protocol_version": "1.0.0",
            "project": "fixture",
            "compatibility": {"min_coordinator_version": "1.0.0"},
            "governance": {
                "agent_instructions": "AGENTS.md",
                "entrypoints": ["docs/AI_START.md"],
                "required": ["docs/WORKFLOW.md"],
                "rule_sets": [{"id": "engineering", "path": "AGENTS.md", "priority": 100}],
            },
            "validation": {
                "provider": "github-actions",
                "repository": "example/ci",
                "workflow": ".github/workflows/validate.yml",
            },
        }
        (root / "rae-governance.json").write_text(
            json.dumps(value), encoding="utf-8"
        )
        return root

    def load(self, root, **kwargs):
        return load_governance(root, expected_sha=SHA, actual_sha=SHA, **kwargs)

    def test_discovers_manifest_and_repository_rules(self):
        manifest = self.load(self.make_repo())
        self.assertEqual(manifest["project"], "fixture")
        self.assertEqual(manifest["governance"]["agent_instructions"], "AGENTS.md")

    def test_discovers_alternate_repository_fixture_without_core_changes(self):
        root = Path(__file__).parent / "fixtures" / "alternate-governance"
        manifest = self.load(root, expected_project="alternate-fixture")
        self.assertEqual(manifest["governance"]["entrypoints"], ["docs/ALTERNATE_START.md"])
        self.assertEqual(
            manifest["validation"]["workflow"],
            ".github/workflows/alternate-validation.yml",
        )

    def test_rejects_missing_manifest(self):
        root = self.make_repo()
        (root / "rae-governance.json").unlink()
        with self.assertRaisesRegex(GovernanceError, "Missing required governance manifest"):
            self.load(root)

    def test_rejects_missing_governance_file(self):
        root = self.make_repo()
        (root / "docs/WORKFLOW.md").unlink()
        with self.assertRaisesRegex(GovernanceError, "Missing required"):
            self.load(root)

    def test_rejects_stale_sha(self):
        with self.assertRaisesRegex(GovernanceError, "Stale repository revision"):
            load_governance(self.make_repo(), expected_sha=SHA, actual_sha="b" * 40)

    def test_rejects_mismatched_project_key(self):
        with self.assertRaisesRegex(GovernanceError, "Manifest project mismatch"):
            load_governance(
                self.make_repo(), expected_sha=SHA, actual_sha=SHA,
                expected_project="another-project"
            )

    def test_rejects_incompatible_coordinator_version(self):
        root = self.make_repo()
        manifest_path = root / "rae-governance.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["compatibility"]["min_coordinator_version"] = "2.0.0"
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(GovernanceError, "older than required"):
            self.load(root)

    def test_rejects_conflicting_rule_ids(self):
        root = self.make_repo()
        manifest_path = root / "rae-governance.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["governance"]["rule_sets"].append(
            {"id": "engineering", "path": "docs/WORKFLOW.md", "priority": 100}
        )
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(GovernanceError, "Conflicting declarations"):
            self.load(root)

    def test_rejects_unsafe_paths(self):
        root = self.make_repo()
        manifest_path = root / "rae-governance.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["governance"]["required"] = ["../outside.md"]
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(GovernanceError, "Unsafe"):
            self.load(root)

    def test_rejects_declared_rule_conflicts(self):
        root = self.make_repo()
        manifest_path = root / "rae-governance.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["conflicts"] = [{"rule": "review", "sources": ["A.md", "B.md"]}]
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(GovernanceError, "unresolved rule conflicts"):
            self.load(root)

    def test_rejects_unsupported_protocol_major(self):
        root = self.make_repo()
        manifest_path = root / "rae-governance.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["protocol_version"] = "2.0.0"
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(GovernanceError, "Incompatible governance protocol major"):
            self.load(root)


    def test_production_claim_safety_gate_is_fail_closed_across_session_contracts(self):
        root = Path(__file__).resolve().parent.parent
        session = (root / "docs/SESSION-START.md").read_text(encoding="utf-8")
        worker = (root / "docs/WORKER-INSTRUCTIONS.md").read_text(encoding="utf-8")
        discovery = (root / "docs/AUTONOMOUS-TASK-DISCOVERY.md").read_text(encoding="utf-8")

        gate_start = session.find("## Mandatory production claim-safety deployment gate")
        self.assertGreaterEqual(gate_start, 0)
        gate_end = session.find("## Autonomous discovery", gate_start)
        self.assertGreater(gate_end, gate_start)
        gate = session[gate_start:gate_end]

        required_migrations = [
            "20261123000300_failure_reporting_retry.sql",
            "20261123000400_worker_task_routing_safe_release.sql",
            "20261124000100_task_dependency_eligibility.sql",
            "20261124000200_ai_initiative_lifecycle.sql",
            "20261124000300_task_worker_routing_safe_reassignment.sql",
            "20261124000400_problem_inbox.sql",
            "20261124000500_review_task_cancellation_recovery.sql",
            "20261124000600_exclusive_branch_claim.sql",
        ]
        positions = [gate.find(name) for name in required_migrations]
        self.assertTrue(all(position >= 0 for position in positions))
        self.assertEqual(positions, sorted(positions))
        self.assertIn("do not invoke any production task/initiative/problem-report write RPC", gate)
        self.assertIn("Do not probe `claim_task`", gate)
        self.assertIn(
            "Before any claim, evaluate the mandatory production claim-safety deployment gate",
            session,
        )

        self.assertIn("Mandatory production claim-safety gate", worker)
        self.assertIn("Do not call `claim_task`", worker)
        self.assertIn(
            "only after the mandatory production claim-safety gate in `docs/SESSION-START.md`",
            worker,
        )
        self.assertIn("## Production task-pool write gate", discovery)
        self.assertIn("Do not call `create_task`, `claim_task`", discovery)
        self.assertIn("keep all Supabase task state unchanged", discovery)


if __name__ == "__main__":
    unittest.main()
