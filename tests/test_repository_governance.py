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
            path.write_text("repository rule\n", encoding="utf-8")
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

    def test_governance_workflow_covers_every_declared_manifest_file(self):
        root = Path(__file__).resolve().parent.parent
        manifest = json.loads(
            (root / "rae-governance.json").read_text(encoding="utf-8")
        )
        governance = manifest["governance"]
        declared_paths = {
            governance["agent_instructions"],
            *governance["entrypoints"],
            *governance["required"],
            *(rule["path"] for rule in governance["rule_sets"]),
        }
        required_triggers = declared_paths | {
            "rae-governance.json",
            "README.md",
            "scripts/repository_governance.py",
            "tests/test_repository_governance.py",
            ".github/workflows/repository-governance.yml",
        }
        workflow = (
            root / ".github/workflows/repository-governance.yml"
        ).read_text(encoding="utf-8")

        for event in ("pull_request", "push"):
            event_start = workflow.index(f"  {event}:") + len(f"  {event}:")
            if event == "pull_request":
                event_end = workflow.index("  push:", event_start)
            else:
                event_end = workflow.index("permissions:", event_start)
            event_body = workflow[event_start:event_end]
            self.assertIn("    paths:", event_body)
            paths_body = event_body.split("    paths:", 1)[1]
            triggers = {
                line.strip()[3:-1]
                for line in paths_body.splitlines()
                if line.strip().startswith('- "') and line.strip().endswith('"')
            }
            self.assertTrue(
                required_triggers <= triggers,
                f"{event} path filters omit: {sorted(required_triggers - triggers)}",
            )

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
            "20261123000300_failure_reporting_retry",
            "20261123000400_worker_task_routing_safe_release",
            "20261124000100_task_dependency_eligibility",
            "20261124000200_ai_initiative_lifecycle",
            "20261124000300_task_worker_routing_safe_reassignment",
            "20261124000400_problem_inbox",
            "20261124000500_review_task_cancellation_recovery",
            "20261124000600_exclusive_branch_claim",
        ]
        positions = [gate.find(name) for name in required_migrations]
        self.assertTrue(all(position >= 0 for position in positions))
        self.assertEqual(positions, sorted(positions))
        self.assertIn("If the database gate becomes closed or cannot be proven open, do not invoke `claim_task` or any task-lifecycle write RPC", gate)
        self.assertIn("Do not probe `claim_task`", gate)
        self.assertIn(
            "Before any claim, still verify the live migration registry and project-specific activation policy",
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



    def test_rae_task_activation_policy_is_repository_owned(self) -> None:
        root = Path(__file__).resolve().parents[1]
        manifest = json.loads((root / "rae-governance.json").read_text(encoding="utf-8"))
        rule_sets = manifest["governance"]["rule_sets"]
        activation_rules = [
            item for item in rule_sets
            if item.get("path") == "docs/AUTONOMOUS-TASK-DISCOVERY.md"
        ]
        self.assertEqual(len(activation_rules), 1)
        policy = (root / "docs/AUTONOMOUS-TASK-DISCOVERY.md").read_text(encoding="utf-8")
        self.assertIn("active_session_autonomy", policy)
        self.assertIn("Supabase is not the source of project activation policy", policy)
        self.assertIn("autonomy.paused", policy)
        self.assertIn("autonomy.max_active_executions", policy)

if __name__ == "__main__":
    unittest.main()
