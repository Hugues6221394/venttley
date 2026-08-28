import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/constants.dart';
import '../../core/logger.dart';
import '../repositories/vently_repository.dart';

enum PushPermissionStatus { authorized, provisional, denied }

/// Narrow adapter around Firebase so registration behavior can be exercised
/// without platform channels or real credentials.
abstract interface class PushMessagingGateway {
  String? get platform;

  Future<bool> initialize();
  Future<PushPermissionStatus> requestPermission();
  Future<void> setAutoInitEnabled(bool enabled);
  Future<String?> getToken();
  Future<void> deleteToken();
  Stream<String> get tokenRefreshes;
  Stream<Map<String, dynamic>> get notificationOpens;
  Future<Map<String, dynamic>?> initialNotification();
}

abstract interface class PushTokenStore {
  Future<void> register({
    required String token,
    required String platform,
    String? locale,
    String? appVersion,
  });

  Future<void> unregister(String token);
}

class RepositoryPushTokenStore implements PushTokenStore {
  RepositoryPushTokenStore(this._repository);

  final VentlyRepository _repository;

  @override
  Future<void> register({
    required String token,
    required String platform,
    String? locale,
    String? appVersion,
  }) => _repository.registerPushToken(
    token: token,
    platform: platform,
    locale: locale,
    appVersion: appVersion,
  );

  @override
  Future<void> unregister(String token) =>
      _repository.unregisterPushToken(token);
}

class PushClientMetadata {
  const PushClientMetadata({this.locale, this.appVersion});

  final String? locale;
  final String? appVersion;
}

abstract interface class PushMetadataProvider {
  Future<PushClientMetadata> read();
}

class _PlatformPushMetadataProvider implements PushMetadataProvider {
  @override
  Future<PushClientMetadata> read() async {
    String? version;
    try {
      final info = await PackageInfo.fromPlatform();
      version = '${info.version}+${info.buildNumber}';
    } catch (_) {
      // Registration remains useful without package metadata.
    }
    return PushClientMetadata(
      locale: PlatformDispatcher.instance.locale.toLanguageTag(),
      appVersion: version,
    );
  }
}

/// Background delivery is intentionally data-only here. The system renders
/// the generic server-authored notification; this isolate never reads or logs
/// user-authored content.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (Firebase.apps.isEmpty) await Firebase.initializeApp();
}

class FirebasePushMessagingGateway implements PushMessagingGateway {
  bool _initialized = false;

  @override
  String? get platform {
    // This rollout intentionally covers Android + iOS. Web push needs a VAPID
    // key and service-worker lifecycle that is not yet configured or claimed.
    if (kIsWeb) return null;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      _ => null,
    };
  }

  @override
  Future<bool> initialize() async {
    if (_initialized) return true;
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      _initialized = true;
      return true;
    } catch (_) {
      log.warn('push.firebase_unavailable');
      return false;
    }
  }

  @override
  Future<PushPermissionStatus> requestPermission() async {
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    return switch (settings.authorizationStatus) {
      AuthorizationStatus.authorized => PushPermissionStatus.authorized,
      AuthorizationStatus.provisional => PushPermissionStatus.provisional,
      _ => PushPermissionStatus.denied,
    };
  }

  @override
  Future<void> setAutoInitEnabled(bool enabled) =>
      FirebaseMessaging.instance.setAutoInitEnabled(enabled);

  @override
  Future<String?> getToken() async {
    // Firebase Apple SDK 10.4+ requires APNs registration to complete before
    // FCM token APIs. Bound the wait so poor connectivity never stalls login.
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      for (var attempt = 0; attempt < 6; attempt++) {
        if (await FirebaseMessaging.instance.getAPNSToken() != null) break;
        await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      }
      if (await FirebaseMessaging.instance.getAPNSToken() == null) return null;
    }
    return FirebaseMessaging.instance.getToken();
  }

  @override
  Future<void> deleteToken() => FirebaseMessaging.instance.deleteToken();

  @override
  Stream<String> get tokenRefreshes =>
      FirebaseMessaging.instance.onTokenRefresh;

  @override
  Stream<Map<String, dynamic>> get notificationOpens =>
      FirebaseMessaging.onMessageOpenedApp.map((message) => message.data);

  @override
  Future<Map<String, dynamic>?> initialNotification() async {
    final message = await FirebaseMessaging.instance.getInitialMessage();
    return message?.data;
  }
}

/// Owns the complete opt-in push lifecycle.
///
/// Server writes are idempotent. A refreshed token is registered before the
/// old token is removed, and failed stale-token cleanup is retried on the next
/// app resume. Sign-out waits for the current registration attempt, unregisters
/// every known token while auth still exists, then deletes the Firebase token.
class PushRegistrationService {
  PushRegistrationService._production()
    : _gateway = FirebasePushMessagingGateway(),
      _metadataProvider = _PlatformPushMetadataProvider(),
      _enabled = VentlyConfig.fcmEnabled,
      _devToken = const String.fromEnvironment('PUSH_DEV_TOKEN'),
      _retryDelays = const [
        Duration.zero,
        Duration(milliseconds: 400),
        Duration(seconds: 2),
      ];

  @visibleForTesting
  PushRegistrationService.forTesting({
    required PushMessagingGateway gateway,
    required PushMetadataProvider metadataProvider,
    bool enabled = true,
    String devToken = '',
    List<Duration> retryDelays = const [Duration.zero],
  }) : _gateway = gateway,
       _metadataProvider = metadataProvider,
       _enabled = enabled,
       _devToken = devToken,
       _retryDelays = retryDelays;

  static final PushRegistrationService instance =
      PushRegistrationService._production();

  final PushMessagingGateway _gateway;
  final PushMetadataProvider _metadataProvider;
  final bool _enabled;
  final String _devToken;
  final List<Duration> _retryDelays;

  Future<bool>? _configuration;
  Future<void>? _starting;
  Future<void>? _registration;
  Future<void> _registrationQueue = Future<void>.value();
  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<Map<String, dynamic>>? _openSubscription;
  void Function(Map<String, dynamic> data)? _onNotificationOpened;

  PushTokenStore? _store;
  String? _sessionKey;
  String? _deviceToken;
  String? _registeredToken;
  final Set<String> _staleTokens = <String>{};
  int _generation = 0;
  bool _initialNotificationConsumed = false;

  bool get available => _enabled;

  /// Register the background isolate before runApp, but only for a user who
  /// previously opted in. Native auto-init remains off and no token is read.
  Future<bool> prepareForConsentedUser() async {
    if (!_enabled || _devToken.isNotEmpty) return false;
    return _configure();
  }

  void setNotificationOpenedHandler(
    void Function(Map<String, dynamic> data)? handler,
  ) {
    _onNotificationOpened = handler;
  }

  Future<void> startForSession(
    VentlyRepository repository, {
    required String sessionKey,
  }) => start(RepositoryPushTokenStore(repository), sessionKey: sessionKey);

  @visibleForTesting
  Future<void> start(PushTokenStore store, {required String sessionKey}) async {
    if (!_enabled) return;
    final activeStart = _starting;
    if (activeStart != null) {
      await activeStart;
      if (_sessionKey == sessionKey) return;
    }
    final future = _start(store, sessionKey: sessionKey);
    _starting = future;
    try {
      await future;
    } finally {
      if (identical(_starting, future)) _starting = null;
    }
  }

  Future<void> _start(
    PushTokenStore store, {
    required String sessionKey,
  }) async {
    if (_sessionKey != null && _sessionKey != sessionKey) {
      await _stop(store: _store, deleteDeviceToken: true);
    }
    _store = store;
    _sessionKey = sessionKey;
    final generation = ++_generation;

    final platform = _gateway.platform;
    if (platform == null) {
      log.warn('push.unsupported_platform');
      return;
    }

    if (_devToken.isNotEmpty) {
      if (!_isValidToken(_devToken)) {
        log.warn('push.dev_token_invalid');
        return;
      }
      _deviceToken = _devToken;
      await _register(_devToken, store, platform, generation);
      return;
    }

    if (!await _configure()) return;
    _listenForNotificationOpens();
    await _consumeInitialNotification();
    _tokenRefreshSubscription ??= _gateway.tokenRefreshes.listen(
      (token) => unawaited(_handleTokenRefresh(token)),
      onError: (_) => log.warn('push.token_refresh_stream_failed'),
    );

    PushPermissionStatus permission;
    try {
      permission = await _gateway.requestPermission();
    } catch (_) {
      log.warn('push.permission_check_failed');
      return;
    }
    if (permission == PushPermissionStatus.denied) {
      log.info('push.permission_denied', props: {'platform': platform});
      await _stop(store: store, deleteDeviceToken: true);
      return;
    }

    try {
      await _gateway.setAutoInitEnabled(true);
      final token = await _gateway.getToken();
      if (generation != _generation || _sessionKey != sessionKey) return;
      if (token == null || !_isValidToken(token)) {
        log.warn('push.token_unavailable', props: {'platform': platform});
        return;
      }
      _deviceToken = token;
      await _register(token, store, platform, generation);
    } catch (_) {
      log.warn('push.token_acquisition_failed', props: {'platform': platform});
    }
  }

  Future<bool> _configure() async {
    final existing = _configuration;
    if (existing != null) return existing;
    final future = _gateway.initialize();
    _configuration = future;
    final initialized = await future;
    if (!initialized && identical(_configuration, future)) {
      // Missing/malformed configuration can be repaired by the next build or
      // resume; do not permanently wedge the singleton.
      _configuration = null;
    }
    return initialized;
  }

  void _listenForNotificationOpens() {
    _openSubscription ??= _gateway.notificationOpens.listen(
      (data) => _onNotificationOpened?.call(data),
      onError: (_) => log.warn('push.notification_open_stream_failed'),
    );
  }

  Future<void> _consumeInitialNotification() async {
    if (_initialNotificationConsumed) return;
    try {
      final data = await _gateway.initialNotification();
      _initialNotificationConsumed = true;
      if (data != null) _onNotificationOpened?.call(data);
    } catch (_) {
      log.warn('push.initial_notification_failed');
    }
  }

  Future<void> _handleTokenRefresh(String token) async {
    final store = _store;
    final platform = _gateway.platform;
    final sessionKey = _sessionKey;
    if (store == null || platform == null || sessionKey == null) return;
    if (!_isValidToken(token) || token == _registeredToken) return;
    final generation = _generation;
    _deviceToken = token;
    await _register(token, store, platform, generation);
  }

  Future<void> _register(
    String token,
    PushTokenStore store,
    String platform,
    int generation,
  ) async {
    // Firebase can emit refresh events during startup. Serialize mutations so
    // a slower old-token request cannot overwrite a newer token binding.
    final operation = _registrationQueue.then(
      (_) => _performRegistration(token, store, platform, generation),
    );
    _registrationQueue = operation.catchError((_) {});
    _registration = operation;
    await operation;
    if (identical(_registration, operation)) _registration = null;
  }

  Future<void> _performRegistration(
    String token,
    PushTokenStore store,
    String platform,
    int generation,
  ) async {
    final previous = _registeredToken;
    final registered = await _registerWithRetry(
      token,
      store,
      platform,
      generation,
    );
    if (!registered) return;
    _registeredToken = token;
    if (previous != null && previous != token) _staleTokens.add(previous);
    await _cleanupStaleTokens(store, generation);
  }

  Future<bool> _registerWithRetry(
    String token,
    PushTokenStore store,
    String platform,
    int generation,
  ) async {
    final metadata = await _metadataProvider.read();
    for (var attempt = 0; attempt < _retryDelays.length; attempt++) {
      if (generation != _generation || !identical(_store, store)) return false;
      final delay = _retryDelays[attempt];
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (generation != _generation || !identical(_store, store)) return false;
      try {
        await store.register(
          token: token,
          platform: platform,
          locale: metadata.locale,
          appVersion: metadata.appVersion,
        );
        if (generation != _generation || !identical(_store, store)) {
          await _bestEffortUnregister(store, token);
          return false;
        }
        log.info('push.token_registered', props: {'platform': platform});
        return true;
      } catch (_) {
        log.warn(
          'push.token_register_retry',
          props: {'platform': platform, 'attempt': attempt + 1},
        );
      }
    }
    return false;
  }

  Future<void> _cleanupStaleTokens(PushTokenStore store, int generation) async {
    for (final token in _staleTokens.toList(growable: false)) {
      if (generation != _generation || !identical(_store, store)) return;
      if (await _bestEffortUnregister(store, token)) {
        _staleTokens.remove(token);
      }
    }
  }

  /// Called by the setting while the authenticated session still exists.
  Future<void> disableForSession(VentlyRepository repository) => _stop(
    store: _store ?? RepositoryPushTokenStore(repository),
    deleteDeviceToken: true,
  );

  /// Must run before Supabase Auth is cleared; otherwise the unregister RPC
  /// correctly rejects the now-anonymous request.
  Future<void> unregisterBeforeSignOut(VentlyRepository repository) => _stop(
    store: _store ?? RepositoryPushTokenStore(repository),
    deleteDeviceToken: true,
  );

  Future<void> _stop({
    required PushTokenStore? store,
    required bool deleteDeviceToken,
  }) async {
    ++_generation;
    final pendingRegistration = _registration;
    if (pendingRegistration != null) {
      try {
        await pendingRegistration.timeout(const Duration(seconds: 5));
      } catch (_) {
        log.warn('push.pending_registration_timeout');
      }
    }

    final tokens = <String>{
      ..._staleTokens,
      if (_registeredToken != null) _registeredToken!,
      if (_deviceToken != null) _deviceToken!,
    };
    if (store != null) {
      for (final token in tokens) {
        await _bestEffortUnregister(store, token);
      }
    }

    if (deleteDeviceToken && _devToken.isEmpty && _configuration != null) {
      try {
        await _gateway.setAutoInitEnabled(false);
        await _gateway.deleteToken();
      } catch (_) {
        log.warn('push.device_token_delete_failed');
      }
    }

    try {
      await _tokenRefreshSubscription?.cancel();
    } catch (_) {
      log.warn('push.token_refresh_cancel_failed');
    }
    _tokenRefreshSubscription = null;
    _store = null;
    _sessionKey = null;
    _deviceToken = null;
    _registeredToken = null;
    _staleTokens.clear();
  }

  Future<bool> _bestEffortUnregister(PushTokenStore store, String token) async {
    try {
      await store.unregister(token).timeout(const Duration(seconds: 4));
      log.info('push.token_unregistered');
      return true;
    } catch (_) {
      log.warn('push.token_unregister_failed');
      return false;
    }
  }

  /// Session loss caused elsewhere (expiry/admin revoke). The RPC may reject
  /// after auth disappears, but local token deletion still stops delivery.
  Future<void> detachSession() => _stop(store: _store, deleteDeviceToken: true);

  @visibleForTesting
  Future<void> stopForTesting(PushTokenStore store) =>
      _stop(store: store, deleteDeviceToken: true);

  @visibleForTesting
  Future<void> dispose() async {
    ++_generation;
    await _tokenRefreshSubscription?.cancel();
    await _openSubscription?.cancel();
    _tokenRefreshSubscription = null;
    _openSubscription = null;
    _onNotificationOpened = null;
  }

  static bool _isValidToken(String token) =>
      token.length >= 16 &&
      token.length <= 4096 &&
      !token.contains(RegExp(r'\s'));
}
