#!/usr/bin/env python3
"""Guard the function-only task-dependency migration and its enforcement points."""

from pathlib import Path

MIGRATION = Path("supabase/migrations/202611240001_task_dependency_eligibility.sql")


def one_definition(sql: str, marker: str) -> str:
    count = sql.count(marker)
    if count != 1:
        raise SystemExit(f"{marker}: expected one definition, found {count}")
    start = sql.index(marker)
    end = sql.index("$function$;", start)
    return sql[start : end + len("$function$;")]


def main() -> None:
    sql = MIGRATION.read_text(encoding="utf-8")
    helper = one_definition(sql, "CREATE OR REPLACE FUNCTION private.task_dependency_blockers(")
    claim = one_definition(sql, "CREATE OR REPLACE FUNCTION public.claim_task(")
    resolver = one_definition(sql, "CREATE OR REPLACE FUNCTION public.resolve_task_dependency(")

    for name, function in (("dependency helper", helper), ("claim_task", claim), ("resolver", resolver)):
        if "SECURITY DEFINER" not in function or "SET search_path TO 'pg_catalog', 'public', 'auth', 'private'" not in function:
            raise SystemExit(f"{name}: SECURITY DEFINER must use the fixed trusted search_path")

    if "REVOKE ALL ON FUNCTION private.task_dependency_blockers(uuid,jsonb)" not in sql:
        raise SystemExit("Private dependency helper must not be executable by client roles")
    if "REVOKE ALL ON FUNCTION public.resolve_task_dependency(uuid,text,text,jsonb,text)" not in sql:
        raise SystemExit("Dependency resolver must revoke PUBLIC/anon execution")
    if "GRANT EXECUTE ON FUNCTION public.resolve_task_dependency(uuid,text,text,jsonb,text) TO authenticated" not in sql:
        raise SystemExit("Dependency resolver must grant only the authenticated RPC entrypoint")

    eligibility_predicate = "private.task_dependency_blockers(t.project_id,t.requirements) = '[]'::jsonb"
    if claim.count(eligibility_predicate) != 2:
        raise SystemExit("claim_task must gate both expired retry-cap expiry and pending/expired claim selection")
    for marker in ("'dependency_blocked'", "'dependency_unblocked'", "'dependency_blockers'"):
        if marker not in claim:
            raise SystemExit(f"claim_task is missing blocker reporting/audit marker {marker}")
    if "FOR UPDATE OF t SKIP LOCKED" not in claim:
        raise SystemExit("claim_task must retain row-lock fencing and SKIP LOCKED selection")

    for marker in (
        "private.assert_owner(v_project_id)",
        "private.idempotency_get(v_project_id,'resolve_task_dependency'",
        "private.idempotency_put(v_project_id,'resolve_task_dependency'",
        "DEPENDENCY_NOT_DECLARED",
        "SATISFIED_DEPENDENCY_REQUIRES_EVIDENCE",
    ):
        if marker not in resolver:
            raise SystemExit(f"resolve_task_dependency is missing {marker}")

    forbidden = ("CREATE TABLE ", "ALTER TABLE ", "DROP TABLE ", "TRUNCATE ", "DELETE FROM public.tasks")
    upper = sql.upper()
    for marker in forbidden:
        if marker in upper:
            raise SystemExit(f"Function-only migration unexpectedly contains {marker.strip()}")

    print("PASS: dependency functions are uniquely defined, fixed-search-path and fenced; both claim paths are gated; resolver is owner-authorized/idempotent; no table DDL or destructive task mutation exists")


if __name__ == "__main__":
    main()
