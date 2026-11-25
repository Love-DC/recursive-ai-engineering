-- Add only foreign-key indexes without an adequate existing leading key.
-- This migration is repository-only until independently reviewed and separately
-- authorized for production deployment. No schema, grant, RLS, or data changes.
BEGIN;

CREATE INDEX IF NOT EXISTS idx_initiative_events_worker_fk
  ON public.initiative_events (actor_worker_id, project_id);

CREATE INDEX IF NOT EXISTS idx_initiative_learnings_initiative_fk
  ON public.initiative_learnings (initiative_id, project_id);

CREATE INDEX IF NOT EXISTS idx_initiative_support_requests_initiative_fk
  ON public.initiative_support_requests (initiative_id, project_id);

CREATE INDEX IF NOT EXISTS idx_initiative_support_requests_worker_fk
  ON public.initiative_support_requests (requested_by_worker_id, project_id);

CREATE INDEX IF NOT EXISTS idx_initiatives_proposer_fk
  ON public.initiatives (proposed_by_worker_id, project_id);

CREATE INDEX IF NOT EXISTS idx_problem_report_events_worker_fk
  ON public.problem_report_events (actor_worker_id, project_id);

CREATE INDEX IF NOT EXISTS idx_problem_reports_task_fk
  ON public.problem_reports (linked_task_id, project_id);

CREATE INDEX IF NOT EXISTS idx_problem_reports_worker_fk
  ON public.problem_reports (reported_by_worker_id, project_id);

COMMIT;
