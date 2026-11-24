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
    "worker_task_routing_safe_release",
    "task_dependency_eligibility",
    "ai_initiative_lifecycle",
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
                    "migration dependency order must be Worker routing/safe release, "
                    "then task dependency eligibility, then AI Initiative lifecycle"
                )

    return errors


class MigrationVersionTests(unittest.TestCase):
    def test_repository_inventory_is_valid(self) -> None:
        errors = validate_inventory(list(MIGRATIONS_DIR.glob("*.sql")))
        self.assertEqual(errors, [], "\n".join(errors))

    def test_rejects_duplicate_versions(self) -> None:
        errors = validate_inventory(
            [
                Path("202611240001_first_change.sql"),
                Path("202611240001_second_change.sql"),
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
                Path("202611240003_worker_task_routing_safe_release.sql"),
                Path("202611240001_task_dependency_eligibility.sql"),
                Path("202611240002_ai_initiative_lifecycle.sql"),
            ]
        )
        self.assertTrue(any("dependency order" in e for e in errors))

    def test_allows_the_unversioned_schema_snapshot_only(self) -> None:
        errors = validate_inventory(
            [
                Path(SNAPSHOT_FILE),
                Path("202611240001_task_dependency_eligibility.sql"),
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
