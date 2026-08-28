import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/data/services/push_registration_service.dart';

const _oldToken = 'old-token-1234567890';
const _newToken = 'new-token-1234567890';

void main() {
  test(
    'kill switch prevents Firebase initialization and token writes',
    () async {
      final gateway = _FakeGateway();
      final store = _FakeTokenStore();
      final service = _service(gateway, enabled: false);

      await service.start(store, sessionKey: 'user-a');

      expect(gateway.initializeCalls, 0);
      expect(store.operations, isEmpty);
      await service.dispose();
      await gateway.close();
    },
  );

  test('pre-runApp preparation installs handlers without a token', () async {
    final gateway = _FakeGateway();
    final service = _service(gateway);

    expect(await service.prepareForConsentedUser(), isTrue);

    expect(gateway.initializeCalls, 1);
    expect(gateway.permissionCalls, 0);
    expect(gateway.getTokenCalls, 0);
    expect(gateway.autoInitValues, isEmpty);
    await service.dispose();
    await gateway.close();
  });

  test('explicitly authorized session registers bounded metadata', () async {
    final gateway = _FakeGateway(token: _oldToken);
    final store = _FakeTokenStore();
    final service = _service(gateway);

    await service.start(store, sessionKey: 'user-a');

    expect(gateway.initializeCalls, 1);
    expect(gateway.autoInitValues, [true]);
    expect(store.operations, ['register:$_oldToken']);
    expect(store.lastPlatform, 'android');
    expect(store.lastLocale, 'en-RW');
    expect(store.lastAppVersion, '1.2.3+45');
    await service.dispose();
    await gateway.close();
  });

  test(
    'denied permission creates no server binding and deletes token',
    () async {
      final gateway = _FakeGateway(
        token: _oldToken,
        permission: PushPermissionStatus.denied,
      );
      final store = _FakeTokenStore();
      final service = _service(gateway);

      await service.start(store, sessionKey: 'user-a');

      expect(store.operations, isEmpty);
      expect(gateway.getTokenCalls, 0);
      expect(gateway.deleteTokenCalls, 1);
      expect(gateway.autoInitValues, [false]);
      await service.dispose();
      await gateway.close();
    },
  );

  test('refresh registers replacement before removing old token', () async {
    final gateway = _FakeGateway(token: _oldToken);
    final store = _FakeTokenStore();
    final service = _service(gateway);
    await service.start(store, sessionKey: 'user-a');

    gateway.tokenRefreshController.add(_newToken);
    await _waitFor(() => store.operations.length == 3);

    expect(store.operations, [
      'register:$_oldToken',
      'register:$_newToken',
      'unregister:$_oldToken',
    ]);

    gateway.tokenRefreshController.add(_newToken);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(store.operations.length, 3);
    await service.dispose();
    await gateway.close();
  });

  test('transient registration failures retry idempotently', () async {
    final gateway = _FakeGateway(token: _oldToken);
    final store = _FakeTokenStore(failuresRemaining: 2);
    final service = _service(
      gateway,
      retryDelays: const [Duration.zero, Duration.zero, Duration.zero],
    );

    await service.start(store, sessionKey: 'user-a');

    expect(store.registerCalls, 3);
    expect(store.successfulRegistrations, 1);
    await service.dispose();
    await gateway.close();
  });

  test(
    'sign-out waits for in-flight registration and removes late write',
    () async {
      final gateway = _FakeGateway(token: _oldToken);
      final gate = Completer<void>();
      final store = _FakeTokenStore(registerGate: gate);
      final service = _service(gateway);

      final starting = service.start(store, sessionKey: 'user-a');
      await _waitFor(() => store.registerCalls == 1);
      final stopping = service.stopForTesting(store);
      gate.complete();
      await Future.wait([starting, stopping]);

      expect(
        store.operations.where((value) => value == 'unregister:$_oldToken'),
        isNotEmpty,
      );
      expect(gateway.deleteTokenCalls, 1);
      expect(gateway.autoInitValues.last, false);
      await service.dispose();
      await gateway.close();
    },
  );

  test(
    'initial and resumed notification opens reach the strict parser seam',
    () async {
      final gateway = _FakeGateway(
        token: _oldToken,
        initialData: {
          'kind': 'notification',
          'notification_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        },
      );
      final service = _service(gateway);
      final opened = <Map<String, dynamic>>[];
      service.setNotificationOpenedHandler(opened.add);

      await service.start(_FakeTokenStore(), sessionKey: 'user-a');
      gateway.notificationOpenController.add({
        'kind': 'friend_request',
        'friendship_id': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      });
      await _waitFor(() => opened.length == 2);

      expect(opened.first['kind'], 'notification');
      expect(opened.last['kind'], 'friend_request');
      await service.dispose();
      await gateway.close();
    },
  );
}

PushRegistrationService _service(
  _FakeGateway gateway, {
  bool enabled = true,
  List<Duration> retryDelays = const [Duration.zero],
}) => PushRegistrationService.forTesting(
  gateway: gateway,
  metadataProvider: _FakeMetadataProvider(),
  enabled: enabled,
  retryDelays: retryDelays,
);

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition did not become true');
}

class _FakeMetadataProvider implements PushMetadataProvider {
  @override
  Future<PushClientMetadata> read() async =>
      const PushClientMetadata(locale: 'en-RW', appVersion: '1.2.3+45');
}

class _FakeGateway implements PushMessagingGateway {
  _FakeGateway({
    this.token = _oldToken,
    this.permission = PushPermissionStatus.authorized,
    this.initialData,
  });

  final String? token;
  final PushPermissionStatus permission;
  final Map<String, dynamic>? initialData;
  final tokenRefreshController = StreamController<String>.broadcast();
  final notificationOpenController =
      StreamController<Map<String, dynamic>>.broadcast();
  int initializeCalls = 0;
  int permissionCalls = 0;
  int getTokenCalls = 0;
  int deleteTokenCalls = 0;
  final List<bool> autoInitValues = [];

  @override
  String? get platform => 'android';

  @override
  Future<bool> initialize() async {
    initializeCalls++;
    return true;
  }

  @override
  Future<PushPermissionStatus> requestPermission() async {
    permissionCalls++;
    return permission;
  }

  @override
  Future<void> setAutoInitEnabled(bool enabled) async {
    autoInitValues.add(enabled);
  }

  @override
  Future<String?> getToken() async {
    getTokenCalls++;
    return token;
  }

  @override
  Future<void> deleteToken() async {
    deleteTokenCalls++;
  }

  @override
  Stream<String> get tokenRefreshes => tokenRefreshController.stream;

  @override
  Stream<Map<String, dynamic>> get notificationOpens =>
      notificationOpenController.stream;

  @override
  Future<Map<String, dynamic>?> initialNotification() async => initialData;

  Future<void> close() async {
    await tokenRefreshController.close();
    await notificationOpenController.close();
  }
}

class _FakeTokenStore implements PushTokenStore {
  _FakeTokenStore({this.failuresRemaining = 0, this.registerGate});

  int failuresRemaining;
  final Completer<void>? registerGate;
  int registerCalls = 0;
  int successfulRegistrations = 0;
  final List<String> operations = [];
  String? lastPlatform;
  String? lastLocale;
  String? lastAppVersion;

  @override
  Future<void> register({
    required String token,
    required String platform,
    String? locale,
    String? appVersion,
  }) async {
    registerCalls++;
    operations.add('register:$token');
    lastPlatform = platform;
    lastLocale = locale;
    lastAppVersion = appVersion;
    if (registerGate != null) await registerGate!.future;
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw StateError('transient');
    }
    successfulRegistrations++;
  }

  @override
  Future<void> unregister(String token) async {
    operations.add('unregister:$token');
  }
}
