import 'package:flutter/foundation.dart';

import '../../core/constants.dart';
import '../repositories/vently_repository.dart';

/// Registers the device for OS-level push (FCM/APNs).
///
/// Firebase is optional — when `FCM_ENABLED=true` and `firebase_messaging`
/// is wired (see docs/notifications.md), call [init] after sign-in.
class PushRegistrationService {
  PushRegistrationService._();
  static final PushRegistrationService instance = PushRegistrationService._();

  bool _initialized = false;

  /// Dev-only token from `--dart-define=PUSH_DEV_TOKEN=...` for testing
  /// [registerPushToken] without Firebase config files.
  static const String _devToken = String.fromEnvironment('PUSH_DEV_TOKEN');

  Future<void> init(VentlyRepository repo) async {
    if (_initialized) return;
    _initialized = true;

    if (!VentlyConfig.fcmEnabled) return;

    if (_devToken.isNotEmpty) {
      try {
        await repo.registerPushToken(
          token: _devToken,
          platform: defaultTargetPlatform.name,
        );
        if (kDebugMode) {
          debugPrint('PushRegistrationService: registered PUSH_DEV_TOKEN');
        }
      } catch (e) {
        if (kDebugMode) debugPrint('PushRegistrationService dev token failed: $e');
      }
      return;
    }

    if (kDebugMode) {
      debugPrint(
        'FCM_ENABLED but no token source. Add Firebase (docs/notifications.md) '
        'or pass --dart-define=PUSH_DEV_TOKEN=... for testing.',
      );
    }
  }
}
