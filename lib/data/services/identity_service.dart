import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Zero-PII identity management.
///
/// We never store emails, phone numbers, or real names. Instead we derive
/// a stable user id from a high-entropy *recovery key* the user keeps
/// off-device, hashed with a device-side salt so the server only ever sees
/// a one-way digest.
class IdentityService {
  IdentityService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kRecoveryKey  = 'vently.recovery_key';
  static const _kDeviceSalt   = 'vently.device_salt';
  static const _kUserId       = 'vently.user_id';
  static const _kPseudonym    = 'vently.pseudonym';
  static const _kAvatarSeed   = 'vently.avatar_seed';
  static const _kBirthYear    = 'vently.birth_year';
  static const _kSafetyTier   = 'vently.safety_tier';

  /// Generate a high-entropy human-friendly recovery key.
  /// Format: 4 groups of 5 base32 characters, e.g. `J3K9W-2QXAP-RT8H4-NM6Z2`.
  String generateRecoveryKey() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random.secure();
    final groups = List.generate(4, (_) {
      return String.fromCharCodes(List.generate(5, (_) =>
          alphabet.codeUnitAt(rng.nextInt(alphabet.length))));
    });
    return groups.join('-');
  }

  /// Derive a server-safe hash of the recovery key + device salt.
  ///
  /// In production this would be Argon2id; here we use SHA-256 with a
  /// per-device salt to avoid pulling a native crypto dependency for the
  /// onboarding pipeline.
  String hashRecoveryKey(String recoveryKey, String deviceSalt) {
    final material = utf8.encode('vently.v1|$recoveryKey|$deviceSalt');
    return sha256.convert(material).toString();
  }

  Future<String> ensureDeviceSalt() async {
    var salt = await _storage.read(key: _kDeviceSalt);
    if (salt == null) {
      final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
      salt = base64Url.encode(bytes);
      await _storage.write(key: _kDeviceSalt, value: salt);
    }
    return salt;
  }

  Future<void> persistSession({
    required String userId,
    required String pseudonym,
    required String avatarSeed,
    required String recoveryKey,
    required int birthYear,
    required String safetyTier,
  }) async {
    await _storage.write(key: _kUserId,      value: userId);
    await _storage.write(key: _kPseudonym,   value: pseudonym);
    await _storage.write(key: _kAvatarSeed,  value: avatarSeed);
    await _storage.write(key: _kRecoveryKey, value: recoveryKey);
    await _storage.write(key: _kBirthYear,   value: birthYear.toString());
    await _storage.write(key: _kSafetyTier,  value: safetyTier);
  }

  Future<Map<String, String>?> loadSession() async {
    final userId    = await _storage.read(key: _kUserId);
    final pseudonym = await _storage.read(key: _kPseudonym);
    final avatar    = await _storage.read(key: _kAvatarSeed);
    final tier      = await _storage.read(key: _kSafetyTier);
    final year      = await _storage.read(key: _kBirthYear);
    if (userId == null || pseudonym == null) return null;
    return {
      'user_id':      userId,
      'pseudonym':    pseudonym,
      'avatar_seed':  avatar ?? 'default-orb',
      'safety_tier':  tier ?? 'standard',
      'birth_year':   year ?? '2000',
    };
  }

  Future<void> clearSession() async {
    await _storage.delete(key: _kUserId);
    await _storage.delete(key: _kPseudonym);
    await _storage.delete(key: _kAvatarSeed);
    await _storage.delete(key: _kRecoveryKey);
    await _storage.delete(key: _kBirthYear);
    await _storage.delete(key: _kSafetyTier);
  }
}

/// Generates random anonymous pseudonyms in the spirit of `SilentSoul`,
/// `MidnightMind`, `BrokenKing`, `HiddenFlower`...
class PseudonymGenerator {
  static const _adjectives = [
    'Silent', 'Midnight', 'Hidden', 'Broken', 'Wandering', 'Whispering',
    'Quiet', 'Healing', 'Restless', 'Anxious', 'Echo', 'Wild', 'Gentle',
    'Shadow', 'Velvet', 'Soft', 'Lonely', 'Lost', 'Starry', 'Foggy', 'Patient',
    'Dreamy', 'Brave', 'Glowing', 'Hopeful', 'Faded', 'Trembling',
  ];

  static const _nouns = [
    'Soul', 'Mind', 'Echo', 'Flower', 'King', 'Storm', 'Pulse', 'Thinker',
    'Whisper', 'Bloom', 'Wave', 'Petal', 'Ember', 'Vessel', 'Wanderer',
    'Cloud', 'Heart', 'Voice', 'Tide', 'Light', 'Moon', 'Ghost', 'Phoenix',
    'River', 'Pearl', 'Lyric', 'Spark',
  ];

  static const _avatarShapes = [
    'orb', 'flame', 'petal', 'moon', 'spark', 'wave', 'leaf', 'mist',
    'bolt', 'vapor', 'ash', 'feather',
  ];

  static String pseudonym([Random? rng]) {
    final r = rng ?? Random.secure();
    return '${_adjectives[r.nextInt(_adjectives.length)]}'
        '${_nouns[r.nextInt(_nouns.length)]}';
  }

  static String avatarSeed([Random? rng]) {
    final r = rng ?? Random.secure();
    final shape = _avatarShapes[r.nextInt(_avatarShapes.length)];
    final tone = ['rose', 'blush', 'plum', 'mauve', 'berry'][r.nextInt(5)];
    return '$tone-$shape-${r.nextInt(9999).toString().padLeft(4, '0')}';
  }
}
