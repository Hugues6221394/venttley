import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'recovery_wordlist.dart';

/// Pseudonymous username identity + account recovery.
///
/// The username flow maps **username + password** to a synthetic internal
/// handle (`<username>@id.venttly.app`) used as the Supabase auth email. Other
/// optional sign-in/profile flows may collect user-chosen contact or profile
/// data, so this service never claims the product stores zero personal data.
///
/// The optional **12-word recovery phrase** lets a user restore access on a new
/// device with no server infrastructure: the password is sealed into an
/// AES-GCM blob whose key is derived (Argon2id) from the phrase. The blob +
/// salt are stored on the user row and read back, pre-auth, during recovery.
class IdentityService {
  IdentityService({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kUsername = 'venttly.username';
  static const _kAvatarSeed = 'venttly.avatar_seed';
  static const _kRecoveryPhrase = 'venttly.recovery_phrase';
  static const _kBirthYear = 'venttly.birth_year';
  static const _kSafetyTier = 'venttly.safety_tier';

  /// Domain for the synthetic username auth handle. Never receives mail.
  static const String identityEmailDomain = 'id.venttly.app';

  /// Allowed username shape — also the login handle, so keep it email-safe.
  static final RegExp usernamePattern = RegExp(r'^[A-Za-z0-9_]{3,20}$');

  /// Deterministic, case-insensitive map from username to the internal auth
  /// email, so login only ever needs the username the user already knows.
  static String syntheticEmail(String username) =>
      '${username.trim().toLowerCase()}@$identityEmailDomain';

  // ===================== Recovery phrase =====================

  /// A 12-word phrase from [kRecoveryWordlist] (~84 bits of entropy).
  String generateRecoveryPhrase() {
    final rng = Random.secure();
    return List.generate(
      12,
      (_) => kRecoveryWordlist[rng.nextInt(kRecoveryWordlist.length)],
    ).join(' ');
  }

  // Light Argon2id params: the 12-word phrase already carries the entropy, so
  // the KDF only needs to map it to key bytes — it is not stretching a weak
  // secret. Kept modest so onboarding/recovery stay responsive.
  final _argon2 = Argon2id(
    parallelism: 1,
    memory: 8192, // 8 MiB
    iterations: 2,
    hashLength: 32,
  );
  final _aead = AesGcm.with256bits();

  /// Seal [password] into a recovery blob with a key derived from [phrase].
  /// Returns the blob and salt (both base64) to persist on the user row.
  Future<({String blob, String salt})> sealPassword({
    required String password,
    required String phrase,
  }) async {
    final rng = Random.secure();
    final salt = List<int>.generate(16, (_) => rng.nextInt(256));
    final key = await _deriveKey(phrase, salt);
    final box = await _aead.encrypt(utf8.encode(password), secretKey: key);
    final blob = [
      base64Url.encode(box.nonce),
      base64Url.encode(box.cipherText),
      base64Url.encode(box.mac.bytes),
    ].join('.');
    return (blob: blob, salt: base64Url.encode(salt));
  }

  /// Reverse of [sealPassword]. Returns the password, or null when the phrase
  /// is wrong (the AES-GCM MAC fails) or the blob is malformed.
  Future<String?> openPassword({
    required String blob,
    required String salt,
    required String phrase,
  }) async {
    try {
      final parts = blob.split('.');
      if (parts.length != 3) return null;
      final key = await _deriveKey(phrase, base64Url.decode(salt));
      final box = SecretBox(
        base64Url.decode(parts[1]),
        nonce: base64Url.decode(parts[0]),
        mac: Mac(base64Url.decode(parts[2])),
      );
      return utf8.decode(await _aead.decrypt(box, secretKey: key));
    } catch (_) {
      return null;
    }
  }

  Future<SecretKey> _deriveKey(String phrase, List<int> salt) {
    return _argon2.deriveKey(
      secretKey: SecretKey(utf8.encode(_normalizePhrase(phrase))),
      nonce: salt,
    );
  }

  /// Phrases compare case-insensitively with single-spaced words.
  static String _normalizePhrase(String phrase) =>
      phrase.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');

  // ===================== Local session cache =====================
  // Convenience only — Supabase owns the real session/token. We keep the
  // username (to pre-fill login) and recovery phrase (so the user can re-view
  // it from Settings) on the device.

  Future<void> persistSession({
    required String username,
    required String avatarSeed,
    required int? birthYear,
    required String safetyTier,
    String? recoveryPhrase,
  }) async {
    await _storage.write(key: _kUsername, value: username);
    await _storage.write(key: _kAvatarSeed, value: avatarSeed);
    if (birthYear == null) {
      await _storage.delete(key: _kBirthYear);
    } else {
      await _storage.write(key: _kBirthYear, value: birthYear.toString());
    }
    await _storage.write(key: _kSafetyTier, value: safetyTier);
    if (recoveryPhrase != null) {
      await _storage.write(key: _kRecoveryPhrase, value: recoveryPhrase);
    }
  }

  Future<String?> lastUsername() => _storage.read(key: _kUsername);
  Future<String?> savedRecoveryPhrase() => _storage.read(key: _kRecoveryPhrase);

  Future<void> saveRecoveryPhrase(String phrase) =>
      _storage.write(key: _kRecoveryPhrase, value: _normalizePhrase(phrase));

  Future<void> clearSession() async {
    await _storage.delete(key: _kUsername);
    await _storage.delete(key: _kAvatarSeed);
    await _storage.delete(key: _kRecoveryPhrase);
    await _storage.delete(key: _kBirthYear);
    await _storage.delete(key: _kSafetyTier);
  }
}

/// Generates random anonymous pseudonyms in the spirit of `SilentSoul`,
/// `MidnightMind`, `BrokenKing`, `HiddenFlower`...
class PseudonymGenerator {
  static const _adjectives = [
    'Silent',
    'Midnight',
    'Hidden',
    'Broken',
    'Wandering',
    'Whispering',
    'Quiet',
    'Healing',
    'Restless',
    'Anxious',
    'Echo',
    'Wild',
    'Gentle',
    'Shadow',
    'Velvet',
    'Soft',
    'Lonely',
    'Lost',
    'Starry',
    'Foggy',
    'Patient',
    'Dreamy',
    'Brave',
    'Glowing',
    'Hopeful',
    'Faded',
    'Trembling',
  ];

  static const _nouns = [
    'Soul',
    'Mind',
    'Echo',
    'Flower',
    'King',
    'Storm',
    'Pulse',
    'Thinker',
    'Whisper',
    'Glow',
    'Wave',
    'Petal',
    'Ember',
    'Vessel',
    'Wanderer',
    'Cloud',
    'Heart',
    'Voice',
    'Tide',
    'Light',
    'Moon',
    'Ghost',
    'Phoenix',
    'River',
    'Pearl',
    'Lyric',
    'Spark',
  ];

  static const _avatarShapes = [
    'orb',
    'flame',
    'petal',
    'moon',
    'spark',
    'wave',
    'leaf',
    'mist',
    'bolt',
    'vapor',
    'ash',
    'feather',
  ];

  /// A pseudonym with a short numeric suffix — keeps fresh suggestions likely
  /// to be unique on the first try (the username is the unique login handle).
  static String pseudonym([Random? rng]) {
    final r = rng ?? Random.secure();
    return '${_adjectives[r.nextInt(_adjectives.length)]}'
        '${_nouns[r.nextInt(_nouns.length)]}'
        '${r.nextInt(900) + 100}';
  }

  static String avatarSeed([Random? rng]) {
    final r = rng ?? Random.secure();
    final shape = _avatarShapes[r.nextInt(_avatarShapes.length)];
    final tone = ['rose', 'blush', 'plum', 'mauve', 'berry'][r.nextInt(5)];
    return '$tone-$shape-${r.nextInt(9999).toString().padLeft(4, '0')}';
  }
}
