/// Maps raw backend/transport failures to copy safe for end users.
class UserFriendlyErrors {
  UserFriendlyErrors._();

  static String message(
    Object? error, {
    String fallback = 'Something went wrong. Please try again.',
  }) {
    if (error == null) return fallback;
    final raw = error.toString().toLowerCase();

    // ---- Sign-up and sign-in ------------------------------------------
    //
    // First, and deliberately. GoTrue's failures are the ones a stranger
    // meets before they have any reason to trust us, and several of them
    // contain words the generic rules below would grab: a 422 mentions a
    // status code, a failed profile read mentions permission. Answering
    // them here means the specific sentence wins over the vague one.

    // "Password should be at least 12 characters." The number is the
    // project's, set in the Supabase dashboard, so it is read back out of
    // the message rather than written here where it would quietly drift.
    if (raw.contains('weakpassword') ||
        raw.contains('password should be at least')) {
      final digits = RegExp(r'at least (\d+)').firstMatch(raw)?.group(1);
      return digits == null
          ? 'Please choose a longer password.'
          : 'Please choose a longer password — at least $digits characters.';
    }
    if (raw.contains('password is too short') ||
        raw.contains('password should contain')) {
      return 'That password is too easy to guess. Try a longer one.';
    }

    // The handle is unique in the database and the profile row is written by
    // a trigger during sign-up, so a name taken between typing it and
    // pressing the button surfaces as the bare Postgres violation --
    //
    //   {"code":"23505","message":"duplicate key value violates unique
    //    constraint \"users_pseudonym_lower_unique\"","detail":"Key
    //    (lower(anonymous_pseudonym::text))=(first_light) already exists."}
    //
    // which names the constraint and repeats the handle back. Matched on the
    // constraint rather than on 23505 alone: other unique constraints on the
    // same insert must not all claim to be about handles.
    //
    // `pseudonym_taken` is what the trigger raises once migration
    // 20261081090000 is applied; the raw constraint is what a database
    // without it still says. Both are matched, because the app ships ahead of
    // the database and must read either.
    if (raw.contains('pseudonym_taken') ||
        raw.contains('users_pseudonym_lower_unique') ||
        (raw.contains('23505') && raw.contains('anonymous_pseudonym'))) {
      return 'That handle was taken a moment ago. Pick another and try again.';
    }
    // Raised by handle_new_auth_user before it writes anything, so no account
    // exists. Arrives as P0001 with the bare identifier as the message.
    if (raw.contains('age_below_minimum')) {
      return 'Venttly is for members aged 16 and over.';
    }
    if (raw.contains('could_not_allocate_pseudonym')) {
      return 'We couldn\'t reserve a handle for you. Please try again.';
    }
    // GoTrue's own wrapper, which replaces the database's message with this
    // one. It is NOT specifically a taken handle -- an earlier version of this
    // file claimed it was, which would have told somebody blocked by the age
    // floor to pick another name. It says only that the write failed, so the
    // copy says only that, and the retryable class it arrives in is the clue
    // that trying again is worth something.
    if (raw.contains('database error saving new user')) {
      return 'We couldn\'t finish creating your account. Please try again in '
          'a moment.';
    }
    if (raw.contains('already in someone\'s sanctuary') ||
        raw.contains('usernametakenexception')) {
      return 'That handle is already taken. Try another.';
    }
    if (raw.contains('user already registered') ||
        raw.contains('already been registered') ||
        raw.contains('email address is already')) {
      return 'That email already has an account. Sign in instead, or use '
          'another address.';
    }
    if (raw.contains('invalid login') ||
        raw.contains('invalid credentials') ||
        raw.contains('wrong password') ||
        raw.contains('password doesn\'t match')) {
      return 'That username or password didn\'t work. Double-check and try '
          'again.';
    }
    if (raw.contains('email not confirmed')) {
      return 'Confirm your email first — the link is in your inbox.';
    }
    if (raw.contains('unable to validate email') ||
        raw.contains('invalid email')) {
      return 'That email address doesn\'t look right.';
    }
    // Both the OTP codes and the password-reset links land here.
    if (raw.contains('token has expired') ||
        raw.contains('otp_expired') ||
        raw.contains('expired or is invalid')) {
      return 'That code has expired. Ask for a new one.';
    }
    if (raw.contains('rate limit') ||
        raw.contains('rate_limit') ||
        raw.contains('too many requests') ||
        raw.contains('statuscode: 429')) {
      return 'Too many tries. Wait a minute, then try again.';
    }
    if (raw.contains('signups not allowed') ||
        raw.contains('signup_disabled')) {
      return 'New accounts are paused right now. Please try again later.';
    }
    // Authentication succeeded but the profile row is missing, which means
    // sign-up half-finished -- the auth user exists and the trigger that
    // writes the profile did not. Left to the rules below this reads as
    // "you don't have permission", which sends somebody to check an
    // account that is not the problem.
    if (raw.contains('no matching profile row')) {
      return 'Your account setup didn\'t finish. Please contact support so we '
          'can sort it out.';
    }

    if (raw.contains('row-level security') ||
        raw.contains('rls') ||
        raw.contains('403') ||
        raw.contains('unauthorized') ||
        raw.contains('forbidden')) {
      return 'You don\'t have permission to do that yet. Check your account or try again in a moment.';
    }
    if (raw.contains('bucket not found') || raw.contains('storage')) {
      return 'Profile photo upload is being prepared. Please try again shortly.';
    }
    if (raw.contains('network') ||
        raw.contains('socket') ||
        raw.contains('connection') ||
        raw.contains('timeout')) {
      return 'Connection issue. Check your internet and try again.';
    }
    if (raw.contains('not signed in') || raw.contains('jwt')) {
      return 'Your session expired. Please sign in again.';
    }
    // Device permissions only. This used to match a bare "permission", which
    // also catches Postgres's "permission denied for table ..." -- and sent
    // somebody to the iOS Settings app to grant a microphone they had never
    // been asked for, over a database grant they cannot see or change.
    if (raw.contains('microphone') ||
        raw.contains('camera') ||
        raw.contains('photo library') ||
        raw.contains('permission denied by user') ||
        raw.contains('permissiondeniedexception')) {
      return 'Permission needed. Allow access in Settings to continue.';
    }
    if (raw.contains('permission denied')) {
      return 'You don\'t have permission to do that yet. Check your account '
          'or try again in a moment.';
    }
    if (raw.contains('duplicate') || raw.contains('already exists')) {
      return 'That already exists. Try a different option.';
    }

    // PostgREST found no function matching the shape the app asked for, which
    // in practice means one thing: the app is newer than the database, because
    // a migration has not been applied yet. It is not a fault the person can
    // do anything about, and the generic fallback — "Please try again" —
    // invites them to keep pressing a button that cannot work until somebody
    // deploys. Observed exactly this way: the Keeper agreement added two
    // parameters to create_managed_tribe_idempotent, and until the migration
    // ran every attempt failed with "Couldn't create this Tribe."
    if (raw.contains('pgrst202') ||
        raw.contains('could not find the function')) {
      return 'Venttly is being updated right now. Please try again in a few '
          'minutes.';
    }

    // Named errors raised by the Tribe RPCs. These reach the client as the bare
    // identifier, which is meaningless to a person — and the create screen used
    // to interpolate the whole exception into a snackbar.
    if (raw.contains('adults_only')) {
      return 'Keeping a Tribe is for 18 and over.';
    }
    if (raw.contains('age_verification_required')) {
      return 'We need one more detail about your age first.';
    }
    // Reaching this means the tick on step 3 was somehow not sent — the button
    // is disabled without it, so in practice this is a stale build talking to
    // a current server. Say what to do rather than naming the field.
    if (raw.contains('keeper_attestation_version_invalid')) {
      return 'Please update Venttly and try creating your Tribe again.';
    }
    if (raw.contains('keeper_attestation_required')) {
      return 'Please confirm the Keeper agreement before creating your Tribe.';
    }
    if (raw.contains('blocked_by_user')) {
      return 'You can\'t contact this person. One of you has blocked the other.';
    }
    if (raw.contains('unsupportedimageformatexception') ||
        raw.contains('not a jpeg, png, gif, webp or heic') ||
        raw.contains('too small to be an image')) {
      return 'That file is not a JPEG, PNG, GIF, WebP or HEIC image.';
    }
    if (raw.contains('rate_limited')) {
      return "That's a lot of Tribes for one day. Try again tomorrow.";
    }
    if (raw.contains('tribe_name_length')) {
      return 'Tribe names need to be between 3 and 50 characters.';
    }
    if (raw.contains('tribe_description_length')) {
      return 'That description is too long.';
    }
    if (raw.contains('tribe_category_length') ||
        raw.contains('invalid_visibility')) {
      return 'Pick a category and visibility, then try again.';
    }
    if (raw.contains('too_many_tags')) {
      return 'That is too many tags — trim a few.';
    }
    if (raw.contains('plug_approval_required')) {
      // Only reachable against a database that predates the age floor.
      return 'Tribe creation is not enabled on this server yet.';
    }
    if (raw.contains('birth_month_already_set')) {
      return 'Your birth month is already recorded and cannot be changed here.';
    }

    return fallback;
  }

  /// True when retrying will never succeed — the server rejected the write
  /// on purpose. The outbox exists for dropped connections, not for policy.
  static bool isPermanent(Object? error) {
    if (error == null) return false;
    final raw = error.toString().toLowerCase();
    return raw.contains('blocked_by_user') ||
        raw.contains('unsupportedimageformatexception');
  }
}
