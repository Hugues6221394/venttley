import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/services/notifications_service.dart';
import '../data/services/push_registration_service.dart';
import 'logger.dart';
import 'providers.dart';

const _kNotificationsEnabled = 'venttly.notifications_enabled';

/// Whether the user wants Venttly to surface notification alerts.
final pushNotificationsEnabledProvider =
    StateNotifierProvider<PushNotificationsController, bool>(
      (ref) => PushNotificationsController(ref),
    );

class PushNotificationsController extends StateNotifier<bool> {
  PushNotificationsController(this._ref) : super(false) {
    _loaded = _load();
  }

  final Ref _ref;
  late final Future<void> _loaded;
  Future<void> _mutationQueue = Future<void>.value();

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_kNotificationsEnabled) ?? false;
    state = enabled;
    NotificationsService.instance.setEnabled(enabled);
  }

  Future<void> setEnabled(bool enabled) {
    final operation = _mutationQueue.then((_) async {
      await _loaded;
      await _setEnabled(enabled);
    });
    _mutationQueue = operation.catchError((_) {});
    return operation;
  }

  Future<void> _setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    if (enabled) {
      var allowed = false;
      try {
        allowed = await NotificationsService.instance.requestPermissions();
      } catch (_) {
        log.warn('push.local_permission_failed');
      }
      if (!allowed) {
        await prefs.setBool(_kNotificationsEnabled, false);
        state = false;
        NotificationsService.instance.setEnabled(false);
        return;
      }
      await prefs.setBool(_kNotificationsEnabled, true);
      state = true;
      NotificationsService.instance.setEnabled(true);
      final session = _ref.read(sessionProvider);
      if (session != null) {
        await PushRegistrationService.instance.startForSession(
          _ref.read(repositoryProvider),
          sessionKey: session.userId,
        );
      }
      return;
    }

    state = false;
    NotificationsService.instance.setEnabled(false);
    try {
      if (_ref.read(sessionProvider) != null) {
        await PushRegistrationService.instance.disableForSession(
          _ref.read(repositoryProvider),
        );
      }
    } finally {
      await prefs.setBool(_kNotificationsEnabled, false);
    }
  }
}

Future<bool> readNotificationsEnabledPref() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_kNotificationsEnabled) ?? false;
}
