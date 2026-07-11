import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/services/notifications_service.dart';

const _kNotificationsEnabled = 'venttly.notifications_enabled';

/// Whether the user wants Venttly to surface notification alerts.
final pushNotificationsEnabledProvider =
    StateNotifierProvider<PushNotificationsController, bool>(
        (ref) => PushNotificationsController());

class PushNotificationsController extends StateNotifier<bool> {
  PushNotificationsController() : super(true) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_kNotificationsEnabled) ?? true;
    state = enabled;
    NotificationsService.instance.setEnabled(enabled);
  }

  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kNotificationsEnabled, enabled);
    state = enabled;
    NotificationsService.instance.setEnabled(enabled);
    if (enabled) {
      await NotificationsService.instance.requestPermissions();
    }
  }
}

Future<bool> readNotificationsEnabledPref() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_kNotificationsEnabled) ?? true;
}
