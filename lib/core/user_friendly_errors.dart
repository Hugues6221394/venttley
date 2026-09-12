/// Maps raw backend/transport failures to copy safe for end users.
class UserFriendlyErrors {
  UserFriendlyErrors._();

  static String message(
    Object? error, {
    String fallback = 'Something went wrong. Please try again.',
  }) {
    if (error == null) return fallback;
    final raw = error.toString().toLowerCase();

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
    if (raw.contains('microphone') || raw.contains('permission')) {
      return 'Permission needed. Allow access in Settings to continue.';
    }
    if (raw.contains('invalid login') ||
        raw.contains('invalid credentials') ||
        raw.contains('wrong password')) {
      return 'That username or password didn\'t work. Double-check and try again.';
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
