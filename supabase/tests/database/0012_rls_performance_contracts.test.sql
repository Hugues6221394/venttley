BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(5);

SELECT ok(
  to_regclass('public.push_delivery_outbox_user_id_idx') IS NOT NULL,
  'push-delivery user foreign key has a covering index'
);
SELECT ok(
  to_regclass('public.question_reports_reporter_id_idx') IS NOT NULL,
  'question-report reporter foreign key has a covering index'
);

SELECT is(
  (
    SELECT permissive
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'posts'
      AND policyname = 'active stories only'
  ),
  'RESTRICTIVE'::TEXT,
  'story expiry remains a restrictive boundary on post reads'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'posts'
      AND policyname = 'posts readable'
      AND roles @> ARRAY['anon'::NAME]
      AND roles @> ARRAY['authenticated'::NAME]
  ),
  'Vent reads retain the canonical policy for both API roles'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'user_blocks'
      AND policyname = 'blocks self'
      AND cmd = 'ALL'
  ),
  'block owners retain row-level control after duplicate policy removal'
);

SELECT * FROM finish();
ROLLBACK;
