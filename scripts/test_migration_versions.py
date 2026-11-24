#!/usr/bin/env python3
"""Reject duplicate, malformed, or incorrectly ordered Supabase migration versions."""

from __future__ import annotations

from collections import defaultdict
from datetime import datetime
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS_DIR = ROOT / "supabase" / "migrations"
SNAPSHOT_FILE = "database-schema.sql"
VERSIONED_SQL = re.compile(r"^(?P<version>\d{14})_(?P<name>[a-z0-9][a-z0-9_-]*)\.sql$")

FEATURE_ORDER = (
    "failure_reporting_retry",
    "worker_task_routing_safe_release",
    "task_dependency_eligibility",
    "ai_initiative_lifecycle",
    "task_worker_routing_safe_reassignment",
    "problem_inbox",
    "review_task_cancellation_recovery",
    "exclusive_branch_claim",
    "submitted_task_reconciliation",
)


def validate_inventory(paths: list[Path], *, check_feature_order: bool = True) -> list[str]:
    """Return validation errors for a set of migration paths."""
    errors: list[str] = []
    versions: dict[str, list[str]] = defaultdict(list)
    feature_versions: dict[str, str] = {}

    for path in sorted(paths, key=lambda item: item.name):
        name = path.name
        if name == SNAPSHOT_FILE:
            continue

        match = VERSIONED_SQL.fullmatch(name)
        if match is None:
            errors.append(
                f"{name}: expected a 14-digit timestamp prefix and lowercase migration slug"
            )
            continue

        version = match.group("version")
        try:
            datetime.strptime(version, "%Y%m%d%H%M%S")
        except ValueError:
            errors.append(f"{name}: invalid calendar timestamp {version}")
            continue

        versions[version].append(name)
        for feature in FEATURE_ORDER:
            if name.endswith(f"_{feature}.sql"):
                feature_versions[feature] = version

    for version, names in sorted(versions.items()):
        if len(names) > 1:
            errors.append(f"duplicate migration version {version}: {', '.join(names)}")

    if check_feature_order:
        missing = [feature for feature in FEATURE_ORDER if feature not in feature_versions]
        if missing:
            errors.append(f"missing required ordered migrations: {', '.join(missing)}")
        else:
            ordered = [feature_versions[feature] for feature in FEATURE_ORDER]
            if ordered != sorted(ordered) or len(set(ordered)) != len(ordered):
                errors.append(
                    "migration dependency order must be failure reporting/retry, "
                    "Worker routing/safe release, task dependency eligibility, "
                    "AI Initiative lifecycle, safe task reassignment, Problem Inbox, review cancellation/failure recovery, then exclusive branch claim, then submitted-task reconciliation"
                )

    return errors


class MigrationVersionTests(unittest.TestCase):
    def test_repository_inventory_is_valid(self) -> None:
        errors = validate_inventory(list(MIGRATIONS_DIR.glob("*.sql")))
        self.assertEqual(errors, [], "\n".join(errors))

    def test_rejects_duplicate_versions(self) -> None:
        errors = validate_inventory(
            [
                Path("20261124000100_first_change.sql"),
                Path("20261124000100_second_change.sql"),
            ],
            check_feature_order=False,
        )
        self.assertTrue(any("duplicate migration version 202611240001" in e for e in errors))

    def test_rejects_missing_or_malformed_prefix(self) -> None:
        errors = validate_inventory(
            [
                Path("latest_change.sql"),
                Path("202611240001-UPPERCASE.sql"),
            ],
            check_feature_order=False,
        )
        self.assertEqual(len(errors), 2)

    def test_rejects_invalid_calendar_timestamp(self) -> None:
        errors = validate_inventory(
            [Path("20261340000000_invalid_date.sql")],
            check_feature_order=False,
        )
        self.assertTrue(any("invalid calendar timestamp" in e for e in errors))

    def test_rejects_incorrect_feature_order(self) -> None:
        errors = validate_inventory(
            [
                Path("20261123000500_failure_reporting_retry.sql"),
                Path("20261123000400_worker_task_routing_safe_release.sql"),
                Path("20261124000100_task_dependency_eligibility.sql"),
                Path("20261124000200_ai_initiative_lifecycle.sql"),
                Path("20261124000300_task_worker_routing_safe_reassignment.sql"),
                Path("20261124000400_problem_inbox.sql"),
                Path("20261124000500_review_task_cancellation_recovery.sql"),
                Path("20261124000600_exclusive_branch_claim.sql"),
            ]
        )
        self.assertTrue(any("dependency order" in e for e in errors))

    def test_rejects_failure_reporting_after_worker_routing(self) -> None:
        errors = validate_inventory(
            [
                Path("20261123000400_worker_task_routing_safe_release.sql"),
                Path("20261123000500_failure_reporting_retry.sql"),
                Path("20261124000100_task_dependency_eligibility.sql"),
                Path("20261124000200_ai_initiative_lifecycle.sql"),
                Path("20261124000300_task_worker_routing_safe_reassignment.sql"),
                Path("20261124000400_problem_inbox.sql"),
                Path("20261124000500_review_task_cancellation_recovery.sql"),
                Path("20261124000600_exclusive_branch_claim.sql"),
            ]
        )
        self.assertTrue(any("dependency order" in e for e in errors))

    def test_rejects_task_reassignment_before_initiative_lifecycle(self) -> None:
        errors = validate_inventory(
            [
                Path("20261123000300_failure_reporting_retry.sql"),
                Path("20261123000400_worker_task_routing_safe_release.sql"),
                Path("20261124000100_task_dependency_eligibility.sql"),
                Path("20261124000150_task_worker_routing_safe_reassignment.sql"),
                Path("20261124000200_ai_initiative_lifecycle.sql"),
                Path("20261124000400_problem_inbox.sql"),
                Path("20261124000500_review_task_cancellation_recovery.sql"),
                Path("20261124000600_exclusive_branch_claim.sql"),
            ]
        )
        self.assertTrue(any("dependency order" in e for e in errors))

    def test_rejects_review_recovery_before_task_reassignment(self) -> None:
        errors = validate_inventory(
            [
                Path("20261123000300_failure_reporting_retry.sql"),
                Path("20261123000400_worker_task_routing_safe_release.sql"),
                Path("20261124000100_task_dependency_eligibility.sql"),
                Path("20261124000200_ai_initiative_lifecycle.sql"),
                Path("20261124000300_review_task_cancellation_recovery.sql"),
                Path("20261124000600_exclusive_branch_claim.sql"),
                Path("20261124000400_task_worker_routing_safe_reassignment.sql"),
                Path("20261124000500_problem_inbox.sql"),
            ]
        )
        self.assertTrue(any("dependency order" in e for e in errors))

    def test_rejects_review_recovery_before_problem_inbox(self) -> None:
        errors = validate_inventory(
            [
                Path("20261123000300_failure_reporting_retry.sql"),
                Path("20261123000400_worker_task_routing_safe_release.sql"),
                Path("20261124000100_task_dependency_eligibility.sql"),
                Path("20261124000200_ai_initiative_lifecycle.sql"),
                Path("20261124000300_task_worker_routing_safe_reassignment.sql"),
                Path("20261124000400_review_task_cancellation_recovery.sql"),
                Path("20261124000600_exclusive_branch_claim.sql"),
                Path("20261124000500_problem_inbox.sql"),
            ]
        )
        self.assertTrue(any("dependency order" in e for e in errors))

    def test_rejects_branch_exclusion_before_review_recovery(self) -> None:
        errors = validate_inventory(
            [
                Path("20261123000300_failure_reporting_retry.sql"),
                Path("20261123000400_worker_task_routing_safe_release.sql"),
                Path("20261124000100_task_dependency_eligibility.sql"),
                Path("20261124000200_ai_initiative_lifecycle.sql"),
                Path("20261124000300_task_worker_routing_safe_reassignment.sql"),
                Path("20261124000400_problem_inbox.sql"),
                Path("20261124000500_exclusive_branch_claim.sql"),
                Path("20261124000600_review_task_cancellation_recovery.sql"),
            ]
        )
        self.assertTrue(any("dependency order" in error for error in errors))


    def test_rejects_submitted_reconciliation_before_branch_exclusion(self) -> None:
        errors = validate_inventory(
            [
                Path("20261123000300_failure_reporting_retry.sql"),
                Path("20261123000400_worker_task_routing_safe_release.sql"),
                Path("20261124000100_task_dependency_eligibility.sql"),
                Path("20261124000200_ai_initiative_lifecycle.sql"),
                Path("20261124000300_task_worker_routing_safe_reassignment.sql"),
                Path("20261124000400_problem_inbox.sql"),
                Path("20261124000500_review_task_cancellation_recovery.sql"),
                Path("20261124000600_submitted_task_reconciliation.sql"),
                Path("20261124000700_exclusive_branch_claim.sql"),
            ]
        )
        self.assertTrue(any("dependency order" in error for error in errors))

    def test_accepts_complete_order_with_submitted_reconciliation_last(self) -> None:
        errors = validate_inventory(
            [
                Path("20261123000300_failure_reporting_retry.sql"),
                Path("20261123000400_worker_task_routing_safe_release.sql"),
                Path("20261124000100_task_dependency_eligibility.sql"),
                Path("20261124000200_ai_initiative_lifecycle.sql"),
                Path("20261124000300_task_worker_routing_safe_reassignment.sql"),
                Path("20261124000400_problem_inbox.sql"),
                Path("20261124000500_review_task_cancellation_recovery.sql"),
                Path("20261124000600_exclusive_branch_claim.sql"),
                Path("20261124172155_submitted_task_reconciliation.sql"),
            ]
        )
        self.assertEqual(errors, [])

    def test_allows_the_unversioned_schema_snapshot_only(self) -> None:
        errors = validate_inventory(
            [
                Path(SNAPSHOT_FILE),
                Path("20261124000100_task_dependency_eligibility.sql"),
            ],
            check_feature_order=False,
        )
        self.assertEqual(errors, [])

    def test_does_not_treat_other_unversioned_sql_as_a_snapshot(self) -> None:
        errors = validate_inventory(
            [
                Path(SNAPSHOT_FILE),
                Path("schema-backup.sql"),
            ],
            check_feature_order=False,
        )
        self.assertTrue(any("schema-backup.sql" in e for e in errors))


if __name__ == "__main__":
    unittest.main(verbosity=2)
