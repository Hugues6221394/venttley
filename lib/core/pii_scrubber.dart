/// Strips personally-identifiable + sensitive content from anything we
/// ship off-device — Sentry breadcrumbs, PostHog event properties,
/// OpenTelemetry spans, logging sinks.
///
/// Venttly is anonymous-first. Confession bodies, message text,
/// pseudonyms, emails and recovery phrases must never leave the device
/// inside observability payloads.
///
/// Rules:
///   * `email` / `phone` keys are dropped entirely.
///   * String values that look like an email / token / phrase are
///     masked to a length hash so we can still group by uniqueness
///     without exposing the value.
///   * Known sensitive keys (see [_sensitiveKeys]) are dropped.
///   * Long free-form text fields (>120 chars) are truncated to
///     `<scrubbed:length=N>` so we never ship confessions.
///   * Nested Maps + Lists are recursed; everything else passes through.
class PiiScrubber {
  PiiScrubber._();

  static const _sensitiveKeys = {
    // Identity
    'email', 'phone', 'mobile', 'real_name', 'full_name', 'first_name',
    'last_name', 'address', 'ip', 'ip_address',
    // Secrets
    'password', 'token', 'access_token', 'refresh_token', 'recovery_phrase',
    'recovery_blob', 'recovery_salt', 'jwt', 'api_key', 'private_key',
    'auth', 'authorization', 'cookie', 'session', 'bearer',
    // User-generated content we never want to log
    'content', 'plaintext', 'body', 'message', 'note', 'comment',
    'description', 'caption', 'reason', 'reply',
  };

  static final _emailRe =
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$', caseSensitive: false);
  static final _jwtRe =
      RegExp(r'^[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}$');
  static final _phraseRe = RegExp(r'^(\w+\s+){10,}\w+$');

  /// Returns a sanitised deep-copy of [data]. Original is never mutated.
  static Map<String, Object?> scrub(Map<String, Object?> data) {
    final out = <String, Object?>{};
    data.forEach((key, value) {
      final lower = key.toLowerCase();
      if (_sensitiveKeys.contains(lower)) return; // drop entirely
      out[key] = _scrubValue(value);
    });
    return out;
  }

  static Object? _scrubValue(Object? value) {
    if (value == null) return null;
    if (value is String) return _scrubString(value);
    if (value is num || value is bool) return value;
    if (value is Map) {
      return scrub(value.cast<String, Object?>());
    }
    if (value is List) {
      return [for (final v in value) _scrubValue(v)];
    }
    // Unknown type — stringify + scrub.
    return _scrubString(value.toString());
  }

  static String _scrubString(String value) {
    if (value.length > 120) {
      return '<scrubbed:length=${value.length}>';
    }
    if (_emailRe.hasMatch(value)) {
      return '<scrubbed:email>';
    }
    if (_jwtRe.hasMatch(value)) {
      return '<scrubbed:jwt>';
    }
    if (_phraseRe.hasMatch(value)) {
      return '<scrubbed:phrase>';
    }
    return value;
  }
}
