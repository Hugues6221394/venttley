/// Maps raw backend/transport failures to copy safe for end users.
class UserFriendlyErrors {
  UserFriendlyErrors._();

  static String message(Object? error, {String fallback = 'Something went wrong. Please try again.'}) {
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
    return fallback;
  }
}
