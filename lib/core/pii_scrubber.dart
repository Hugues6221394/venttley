/// Removes personally identifiable, secret, and user-authored content before
/// data reaches logging, analytics, or crash-reporting transports.
class PiiScrubber {
  PiiScrubber._();

  static const _sensitiveKeys = {
    'email',
    'phone',
    'mobile',
    'real_name',
    'full_name',
    'first_name',
    'last_name',
    'display_name',
    'username',
    'handle',
    'pseudonym',
    'anonymous_pseudonym',
    'address',
    'location',
    'city',
    'campus',
    'latitude',
    'longitude',
    'ip',
    'ip_address',
    'password',
    'token',
    'access_token',
    'refresh_token',
    'recovery_phrase',
    'recovery_blob',
    'recovery_salt',
    'jwt',
    'api_key',
    'private_key',
    'auth',
    'authorization',
    'cookie',
    'session',
    'bearer',
    'content',
    'plaintext',
    'body',
    'message',
    'note',
    'comment',
    'description',
    'caption',
    'reason',
    'reply',
  };

  static const _secretKeyTokens = {
    'email',
    'phone',
    'mobile',
    'password',
    'token',
    'jwt',
    'secret',
    'cookie',
    'authorization',
  };

  static const _contentKeySuffixes = {
    'content',
    'plaintext',
    'body',
    'message',
    'note',
    'comment',
    'description',
    'caption',
    'reason',
    'reply',
  };

  static final _emailPattern = RegExp(
    r'\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b',
    caseSensitive: false,
  );
  static final _jwtPattern = RegExp(
    r'\b[A-Za-z0-9_\-]{16,}\.[A-Za-z0-9_\-]{16,}\.[A-Za-z0-9_\-]{16,}\b',
  );
  static final _bearerPattern = RegExp(
    r'\bbearer\s+[A-Za-z0-9._~+\-/=]{12,}',
    caseSensitive: false,
  );
  static final _providerSecretPattern = RegExp(
    r'\b(?:gsk|sk_live|sk_test|phc)_[A-Za-z0-9_\-]{12,}\b',
    caseSensitive: false,
  );
  static final _phonePattern = RegExp(r'(?:\+?\d[\s\-]?){7,}');
  static final _phrasePattern = RegExp(r'^(?:[A-Za-z]+\s+){10,}[A-Za-z]+$');

  /// A whole-value canonical 8-4-4-4-12 identifier.
  ///
  /// We log opaque ids constantly (`user_id`, `post_id`, `room_id`). They
  /// carry no personal data on their own, but a UUID's digit runs joined by
  /// hyphens are indistinguishable from a phone number to [_phonePattern],
  /// which rewrote them into unusable rubble — and with them our ability to
  /// trace a Sentry breadcrumb back to an account.
  ///
  /// Anchored deliberately: only a value that is *entirely* an identifier
  /// takes this path, so a phone number sitting in free text is still
  /// scrubbed exactly as before.
  static final _identifierPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  static Map<String, Object?> scrub(Map<String, Object?> data) {
    final output = <String, Object?>{};
    for (final entry in data.entries) {
      if (_isSensitiveKey(entry.key)) continue;
      output[entry.key] = _scrubValue(entry.value);
    }
    return output;
  }

  /// Scrubs an unstructured error, breadcrumb, or transport message.
  static String scrubText(String value) {
    if (_identifierPattern.hasMatch(value)) return value;
    if (value.length > 120) return '<scrubbed:length=${value.length}>';
    if (_phrasePattern.hasMatch(value.trim())) return '<scrubbed:phrase>';

    return value
        .replaceAll(_bearerPattern, '<scrubbed:bearer>')
        .replaceAll(_jwtPattern, '<scrubbed:jwt>')
        .replaceAll(_providerSecretPattern, '<scrubbed:secret>')
        .replaceAll(_emailPattern, '<scrubbed:email>')
        .replaceAll(_phonePattern, '<scrubbed:phone>');
  }

  static ScrubbedException scrubError(Object error) {
    return ScrubbedException(
      error.runtimeType.toString(),
      scrubText(error.toString()),
    );
  }

  static Object? _scrubValue(Object? value) {
    if (value == null || value is num || value is bool) return value;
    if (value is String) return scrubText(value);
    if (value is Map) {
      final map = <String, Object?>{};
      for (final entry in value.entries) {
        if (entry.key is String) {
          map[entry.key as String] = entry.value;
        }
      }
      return scrub(map);
    }
    if (value is Iterable) {
      return [for (final item in value) _scrubValue(item)];
    }
    return scrubText(value.toString());
  }

  static bool _isSensitiveKey(String key) {
    final normalized = key
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (_sensitiveKeys.contains(normalized)) return true;

    final tokens = normalized.split('_');
    if (tokens.any(_secretKeyTokens.contains)) return true;
    return _contentKeySuffixes.any((suffix) => normalized.endsWith('_$suffix'));
  }
}

/// Exception wrapper safe to hand to an off-device crash reporter.
class ScrubbedException implements Exception {
  const ScrubbedException(this.type, this.message);

  final String type;
  final String message;

  @override
  String toString() => '$type: $message';
}
