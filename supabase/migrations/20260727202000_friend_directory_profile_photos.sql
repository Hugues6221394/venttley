-- Keep every friends-directory surface on the same authoritative profile
-- photo contract. The client already renders the URL when it is present.

CREATE OR REPLACE VIEW public.my_friends
WITH (security_invoker = true) AS
SELECT
    f.friendship_id,
    CASE WHEN f.user_a = auth.uid() THEN f.user_b ELSE f.user_a END AS friend_user_id,
    u.anonymous_pseudonym AS friend_pseudonym,
    u.avatar_seed AS friend_avatar_seed,
    u.karma_points AS friend_karma,
    u.is_verified AS friend_is_verified,
    f.accepted_at,
    f.created_at,
    u.profile_photo_url AS friend_profile_photo_url
FROM public.friendships AS f
JOIN public.users AS u
  ON u.user_id = CASE
      WHEN f.user_a = auth.uid() THEN f.user_b
      ELSE f.user_a
  END
WHERE f.status = 'accepted'
  AND auth.uid() IN (f.user_a, f.user_b);

CREATE OR REPLACE VIEW public.friend_requests_inbox
WITH (security_invoker = true) AS
SELECT
    f.friendship_id,
    f.requested_by AS from_user_id,
    u.anonymous_pseudonym AS from_pseudonym,
    u.avatar_seed AS from_avatar_seed,
    u.karma_points AS from_karma,
    f.note,
    f.created_at,
    u.profile_photo_url AS from_profile_photo_url
FROM public.friendships AS f
JOIN public.users AS u ON u.user_id = f.requested_by
WHERE f.status = 'pending'
  AND auth.uid() IN (f.user_a, f.user_b)
  AND f.requested_by <> auth.uid();

CREATE OR REPLACE VIEW public.friend_requests_outbox
WITH (security_invoker = true) AS
SELECT
    f.friendship_id,
    CASE WHEN f.user_a = auth.uid() THEN f.user_b ELSE f.user_a END AS to_user_id,
    u.anonymous_pseudonym AS to_pseudonym,
    u.avatar_seed AS to_avatar_seed,
    u.karma_points AS to_karma,
    f.note,
    f.created_at,
    u.profile_photo_url AS to_profile_photo_url
FROM public.friendships AS f
JOIN public.users AS u
  ON u.user_id = CASE
      WHEN f.user_a = auth.uid() THEN f.user_b
      ELSE f.user_a
  END
WHERE f.status = 'pending'
  AND auth.uid() IN (f.user_a, f.user_b)
  AND f.requested_by = auth.uid();

GRANT SELECT ON public.my_friends TO authenticated;
GRANT SELECT ON public.friend_requests_inbox TO authenticated;
GRANT SELECT ON public.friend_requests_outbox TO authenticated;

NOTIFY pgrst, 'reload schema';
