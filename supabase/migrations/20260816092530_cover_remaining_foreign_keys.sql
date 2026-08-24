BEGIN;

-- PostgreSQL does not automatically index the referencing side of foreign
-- keys. Both production tables were 32 kB with no live rows when audited, so
-- ordinary transactional index creation has a tightly bounded lock window.
CREATE INDEX IF NOT EXISTS push_delivery_outbox_user_id_idx
  ON public.push_delivery_outbox(user_id);
CREATE INDEX IF NOT EXISTS question_reports_reporter_id_idx
  ON public.question_reports(reporter_id);

COMMIT;
