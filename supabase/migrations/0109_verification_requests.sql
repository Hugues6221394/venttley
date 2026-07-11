-- 0109_verification_requests.sql
-- Auto-verification (0107) is now reserved for stunning reach (100K connections
-- / 1M hugs / 25K posts). Everyone else can APPLY for the verified check; a
-- super_admin reviews and approves/denies. Approval sets the manual override so
-- the automatic sweep never touches it afterwards.

CREATE TABLE IF NOT EXISTS public.verification_requests (
    request_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    status        TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'approved', 'denied')),
    note          TEXT,                       -- the applicant's case for it
    reviewed_by   UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
    reviewed_at   TIMESTAMPTZ,
    review_reason TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- At most one OPEN (pending) request per user.
CREATE UNIQUE INDEX IF NOT EXISTS verification_requests_one_pending
    ON public.verification_requests (user_id)
    WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS verification_requests_status_idx
    ON public.verification_requests (status, created_at DESC);

ALTER TABLE public.verification_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "vr own read" ON public.verification_requests;
CREATE POLICY "vr own read" ON public.verification_requests FOR SELECT
    USING (user_id = auth.uid() OR is_staff(auth.uid(), ARRAY['super_admin','admin']));

GRANT SELECT ON public.verification_requests TO authenticated;

-- ---- User applies ----------------------------------------------------------
CREATE OR REPLACE FUNCTION public.request_verification(p_note TEXT DEFAULT NULL)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_me UUID := auth.uid(); v_id UUID;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF EXISTS (SELECT 1 FROM users WHERE user_id = v_me AND is_verified) THEN
        RAISE EXCEPTION 'already verified';
    END IF;
    IF EXISTS (SELECT 1 FROM verification_requests
                WHERE user_id = v_me AND status = 'pending') THEN
        RAISE EXCEPTION 'a request is already pending review';
    END IF;
    INSERT INTO verification_requests (user_id, note)
    VALUES (v_me, NULLIF(btrim(coalesce(p_note, '')), ''))
    RETURNING request_id INTO v_id;
    RETURN v_id;
END $$;
GRANT EXECUTE ON FUNCTION public.request_verification(TEXT) TO authenticated;

-- ---- Caller's current status (for the app UI) ------------------------------
-- Returns 'verified' | 'pending' | 'denied' | 'none'.
CREATE OR REPLACE FUNCTION public.my_verification_status()
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public STABLE AS $$
DECLARE v_me UUID := auth.uid(); v_verified BOOLEAN; v_last TEXT;
BEGIN
    IF v_me IS NULL THEN RETURN 'none'; END IF;
    SELECT is_verified INTO v_verified FROM users WHERE user_id = v_me;
    IF v_verified THEN RETURN 'verified'; END IF;
    SELECT status INTO v_last FROM verification_requests
      WHERE user_id = v_me ORDER BY created_at DESC LIMIT 1;
    RETURN COALESCE(v_last, 'none');
END $$;
GRANT EXECUTE ON FUNCTION public.my_verification_status() TO authenticated;

-- ---- Super-admin reviews ---------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_review_verification(
    p_request UUID,
    p_approve BOOLEAN,
    p_reason  TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_user UUID; v_status TEXT; v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden: only super_admin can review verification';
    END IF;
    SELECT user_id, status INTO v_user, v_status
      FROM verification_requests WHERE request_id = p_request;
    IF v_user IS NULL THEN RAISE EXCEPTION 'request not found'; END IF;
    IF v_status <> 'pending' THEN RAISE EXCEPTION 'request already reviewed'; END IF;

    SELECT '@' || anonymous_pseudonym INTO v_label FROM users WHERE user_id = v_user;

    UPDATE verification_requests
       SET status = CASE WHEN p_approve THEN 'approved' ELSE 'denied' END,
           reviewed_by = auth.uid(), reviewed_at = now(), review_reason = p_reason
     WHERE request_id = p_request;

    IF p_approve THEN
        UPDATE users
           SET is_verified = true, verification_override = 'manual_on', updated_at = now()
         WHERE user_id = v_user;
        BEGIN PERFORM award(v_user, 'verified'); EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;

    PERFORM admin_log(
        CASE WHEN p_approve THEN 'verification.approve' ELSE 'verification.deny' END,
        'user', v_user, v_label, NULL,
        jsonb_build_object('request_id', p_request), p_reason, '{}'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.admin_review_verification(UUID, BOOLEAN, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_review_verification(UUID, BOOLEAN, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
