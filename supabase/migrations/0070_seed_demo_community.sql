-- Historical migration intentionally retired.
--
-- This version previously inserted showcase users, posts, comments, tribes,
-- friendships, chats, notifications, and whispers into application tables.
-- Runtime migrations must define schema and behavior only; development data
-- belongs in explicit local test fixtures such as MockBackend.
--
-- Existing launch datasets are retained until an operator deliberately runs
-- supabase/maintenance/remove_demo_seed_from_runtime.sql after enough genuine
-- or first-party editorial content exists. Fresh databases perform no data
-- writes here.

DO $$
BEGIN
  RAISE NOTICE '0070 demo community seed is retired; no rows were inserted';
END;
$$;
