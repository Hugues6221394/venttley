BEGIN;

-- Engagement writes use desired-state, auth-bound RPCs. Direct table writes
-- cannot provide the same idempotency and counter guarantees and are not used
-- by the current Flutter client. Keep SELECT grants for rendering, but force
-- every mutation through the server ingress functions.
REVOKE INSERT, UPDATE, DELETE ON TABLE
  public.post_likes,
  public.comment_likes,
  public.whisper_reactions,
  public.whisper_comment_likes,
  public.poll_votes
FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
