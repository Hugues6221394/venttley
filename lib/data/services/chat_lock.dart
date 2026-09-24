import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:local_auth/local_auth.dart';

import 'sensitive_store.dart';

/// Opening a conversation somebody has locked.
///
/// Two things are deliberately separate. Whether a chat is locked is account
/// state — it lives on `dm_room_prefs.locked_at`, so it follows you to a new
/// phone, and so the server can stop the last message leaving the database at
/// all. Whether *you* may open it is a device question, answered here, because
/// the fingerprint reader is on the device.
///
/// What this is not: encryption. A locked chat is stored exactly like any
/// other, and anybody with the account password can read it after signing in
/// on their own phone. What it buys is that somebody holding your unlocked
/// phone — which is the actual threat for an app people vent into — cannot
/// open the thread.
///
/// The PIN is the fallback, not the primary. Biometrics are tried first
/// because they are faster and because a PIN typed in front of the person you
/// are hiding the chat from is not much of a secret. But a PIN has to exist:
/// biometrics fail wet-handed, they are absent on some devices, and a lock
/// with no way past it would strand somebody out of their own conversation.
class ChatLock {
  ChatLock({SensitiveStore? store, LocalAuthentication? auth})
    : _store = store ?? DeviceSensitiveStore(),
      _auth = auth ?? LocalAuthentication();

  final SensitiveStore _store;
  final LocalAuthentication _auth;

  static const _pinKey = 'chat_lock_pin';
  static const _saltKey = 'chat_lock_salt';

  /// Whether a PIN has been chosen on this device.
  Future<bool> get hasPin async => (await _store.read(_pinKey)) != null;

  /// Whether the device can do Face ID / Touch ID / fingerprint at all.
  Future<bool> get canUseBiometrics async {
    try {
      return await _auth.canCheckBiometrics || await _auth.isDeviceSupported();
    } catch (_) {
      // A device that cannot answer the question cannot do it either, and
      // throwing here would block the lock screen from drawing.
      return false;
    }
  }

  /// Store the PIN as a salted hash.
  ///
  /// Salted because a four-digit PIN has ten thousand possibilities: an
  /// unsalted digest of one is a lookup table, and secure storage is only as
  /// private as the device it sits on.
  Future<void> setPin(String pin) async {
    final salt = _newSalt();
    await _store.write(_saltKey, salt);
    await _store.write(_pinKey, _hash(pin, salt));
  }

  Future<void> clearPin() async {
    await _store.delete(_pinKey);
    await _store.delete(_saltKey);
  }

  Future<bool> checkPin(String pin) async {
    final stored = await _store.read(_pinKey);
    final salt = await _store.read(_saltKey);
    if (stored == null || salt == null) return false;
    return _constantTimeEquals(stored, _hash(pin, salt));
  }

  /// Ask the device. Returns false if it says no, or cannot ask.
  Future<bool> authenticateWithDevice() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Open this locked conversation',
        options: const AuthenticationOptions(
          // The device passcode counts. Somebody with no enrolled fingerprint
          // still has a lock screen, and refusing them their own chat to
          // insist on a biometric is worse security theatre than useful.
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }

  String _newSalt() {
    final random = Random.secure();
    return base64Url.encode(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
  }

  String _hash(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();

  /// Comparing digests without leaking how far the match got.
  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
