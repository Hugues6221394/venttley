-- Do not offer a recovery route that cannot possibly complete.
--
-- confirm_recovery_phone() is deliberately built not to send its own SMS. It
-- marks a number verified only when GoTrue already confirmed that exact number
-- on the account, which happens through the phone OTP used for phone sign-in.
-- That is the right design: one proof of ownership, owned by the auth provider,
-- rather than a second homemade one.
--
-- But it means the whole phone path depends on GoTrue having an SMS provider
-- configured, and right now there is none — the Twilio quote for Rwanda was
-- $0.3261 per message and the decision was to launch without it.
--
-- So today the flow is: person types their number, set_recovery_phone stores it
-- as pending, and confirm_recovery_phone returns FALSE forever. No error, no
-- explanation, a row that says "pending" until the account is deleted. That is
-- the same silent-failure shape as `?? 'clean'` and the terminal 'skipped'
-- outbox row: a feature that looks present, does nothing, and says nothing.
--
-- A flag is better than deleting the code or hiding it behind a constant. The
-- client reads feature_flags live (0118 + watchFeatureFlags), so the day an SMS
-- provider is configured in the GoTrue dashboard, flipping this one row turns
-- the phone option on for every user with no deploy and no app update. And
-- while it is off, the UI can say the honest thing instead of accepting input
-- it cannot act on.
--
-- Default FALSE. The client passes fallback: false for the same reason — if the
-- row is missing we must assume there is no SMS, because assuming there is
-- reintroduces exactly the dead end this migration exists to close.

BEGIN;

INSERT INTO public.feature_flags (flag_key, enabled, rollout_pct, description)
VALUES (
  'recovery_sms',
  FALSE,
  0,
  'Recovery by phone number. Requires an SMS provider configured in GoTrue — confirm_recovery_phone() can never succeed without one, so leaving this off is what keeps the app from offering a dead end. Turn on only after sending a real test OTP.'
)
ON CONFLICT (flag_key) DO NOTHING;

COMMIT;

SELECT public.record_migration(
  '20260912090000', 'recovery_sms_capability_flag'
);

NOTIFY pgrst, 'reload schema';
