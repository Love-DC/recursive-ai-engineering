#!/usr/bin/env python3
"""Guard the worker-routing migration against duplicated or truncated SQL fragments."""

from pathlib import Path

MIGRATION = Path("supabase/migrations/202611230004_worker_task_routing_safe_release.sql")


def main() -> None:
    sql = MIGRATION.read_text(encoding="utf-8")
    expected = (
        "private.resolve_task_worker_keys",
        "public.claim_task",
        "public.create_review_task",
        "public.release_execution",
    )
    for function_name in expected:
        marker = f"CREATE OR REPLACE FUNCTION {function_name}("
        count = sql.count(marker)
        if count != 1:
            raise SystemExit(f"{function_name}: expected one definition, found {count}")

    if sql.count("DO $migration$") != 1:
        raise SystemExit("Expected exactly one idempotent routing-config seed block")
    if ", '', 'g')" in sql:
        raise SystemExit("Found a truncated regexp_replace fragment in the migration")
    if r"E' \t\n\r\f' || chr(11)" not in sql:
        raise SystemExit("Worker route normalization must trim ASCII whitespace")

    print("PASS: worker-routing migration has one complete definition per function and one seed block")


if __name__ == "__main__":
    main()
