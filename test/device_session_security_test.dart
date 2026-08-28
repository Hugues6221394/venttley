import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/data/services/device_identity_service.dart';
import 'package:vently_app/data/services/sensitive_store.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/presentation/screens/profile/active_devices_screen.dart';

import 'helpers/memory_sensitive_store.dart';

/// A store whose every operation fails, standing in for a keystore that is
/// locked or unavailable.
class _BrokenStore implements SensitiveStore {
  @override
  Future<void> delete(String key) async => throw StateError('unavailable');

  @override
  Future<String?> read(String key) async => throw StateError('unavailable');

  @override
  Future<Map<String, String>> readAll() async =>
      throw StateError('unavailable');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('unavailable');
}

class _FakeRepository extends VentlyRepository {
  _FakeRepository(this.sessions) : super(forceMock: true);

  final List<DeviceSession> sessions;
  final List<String> revokedSessionIds = <String>[];
  final List<String> blockedDeviceIds = <String>[];
  int revokeOthersCalls = 0;

  @override
  Future<List<DeviceSession>> myDeviceSessions() async => sessions;

  @override
  Future<bool> revokeDeviceSession(String deviceSessionId) async {
    revokedSessionIds.add(deviceSessionId);
    sessions.removeWhere((s) => s.deviceSessionId == deviceSessionId);
    return true;
  }

  @override
  Future<int> blockDevice(String deviceRowId) async {
    blockedDeviceIds.add(deviceRowId);
    sessions.removeWhere((s) => s.deviceRowId == deviceRowId);
    return 1;
  }

  @override
  Future<int> revokeOtherDeviceSessions() async {
    revokeOthersCalls++;
    final removed = sessions.where((s) => !s.isCurrent).length;
    sessions.removeWhere((s) => !s.isCurrent);
    return removed;
  }
}

DeviceSession _session({
  required String id,
  required bool isCurrent,
  String name = 'Pixel 8',
  String deviceRowId = 'device-row-1',
}) {
  final now = DateTime.now().toUtc();
  return DeviceSession(
    deviceSessionId: id,
    deviceRowId: deviceRowId,
    deviceName: name,
    deviceType: 'phone',
    osName: 'Android',
    osVersion: '14',
    country: 'RW',
    isCurrent: isCurrent,
    isTrusted: false,
    riskScore: 0,
    startedAt: now,
    lastSeenAt: now,
  );
}

Future<void> _pumpDevices(WidgetTester tester, _FakeRepository repo) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, __) => const ActiveDevicesScreen()),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repo)],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('DeviceIdentityService', () {
    test('generates an id and persists it for the next launch', () async {
      final store = MemorySensitiveStore();
      final first = await DeviceIdentityService(store: store).read();

      expect(first.deviceId.length, greaterThanOrEqualTo(8));
      expect(store.values.values, contains(first.deviceId));

      final second = await DeviceIdentityService(store: store).read();
      expect(
        second.deviceId,
        first.deviceId,
        reason: 'a reinstall-free relaunch must be the same device',
      );
    });

    test('the id is not guessable from a second installation', () async {
      final a = await DeviceIdentityService(store: MemorySensitiveStore()).read();
      final b = await DeviceIdentityService(store: MemorySensitiveStore()).read();
      expect(a.deviceId, isNot(b.deviceId));
    });

    test('an unreadable keystore still yields an id', () async {
      // A locked keychain must degrade to an extra row in the device list,
      // never to a sign-in that cannot complete.
      final identity = await DeviceIdentityService(store: _BrokenStore()).read();
      expect(identity.deviceId.length, greaterThanOrEqualTo(8));
    });

    test('a short stored value is replaced rather than trusted', () async {
      final store = MemorySensitiveStore({'venttly.device_id.v1': 'abc'});
      final identity = await DeviceIdentityService(store: store).read();
      expect(identity.deviceId, isNot('abc'));
      expect(identity.deviceId.length, greaterThanOrEqualTo(8));
    });
  });

  group('security entities', () {
    test('a device session falls back to a readable label', () {
      final unnamed = DeviceSession(
        deviceSessionId: 's1',
        deviceRowId: 'd1',
        deviceType: 'phone',
        osName: 'iOS',
        isCurrent: false,
        isTrusted: false,
        riskScore: 0,
        startedAt: DateTime.now(),
        lastSeenAt: DateTime.now(),
      );
      expect(unnamed.label, 'iOS device');
    });

    test('a session with no name or OS still prints something', () {
      final bare = DeviceSession(
        deviceSessionId: 's2',
        deviceRowId: 'd2',
        deviceType: 'unknown',
        isCurrent: false,
        isTrusted: false,
        riskScore: 0,
        startedAt: DateTime.now(),
        lastSeenAt: DateTime.now(),
      );
      expect(bare.label, 'Unknown device');
    });

    test('an unrecognised event kind is shown, not dropped', () {
      final event = SecurityEvent.fromJson(const {
        'event_id': 'e1',
        'kind': 'kind_from_a_newer_server',
        'severity': 'info',
        'created_at': '2026-08-28T12:00:00Z',
      });
      expect(event.title, 'Security activity');
    });

    test('a blocked-device login reads as critical', () {
      final event = SecurityEvent.fromJson(const {
        'event_id': 'e2',
        'kind': 'login_blocked_device',
        'severity': 'critical',
        'created_at': '2026-08-28T12:00:00Z',
      });
      expect(event.isCritical, isTrue);
      expect(event.title, 'Blocked device tried to sign in');
    });
  });

  group('ActiveDevicesScreen', () {
    testWidgets('marks the current device and hides its destructive actions', (
      tester,
    ) async {
      final repo = _FakeRepository([
        _session(id: 'current', isCurrent: true, name: 'Pixel 8'),
      ]);
      await _pumpDevices(tester, repo);

      expect(find.text('Pixel 8'), findsOneWidget);
      expect(find.text('This device'), findsOneWidget);
      expect(
        find.text('This wasn\'t me'),
        findsNothing,
        reason: 'you cannot report your own device as an intruder',
      );
    });

    testWidgets('offers to end another device and calls through', (
      tester,
    ) async {
      final repo = _FakeRepository([
        _session(id: 'current', isCurrent: true),
        _session(
          id: 'other',
          isCurrent: false,
          name: 'iPhone 15',
          deviceRowId: 'device-row-2',
        ),
      ]);
      await _pumpDevices(tester, repo);

      expect(find.text('Sign out of 1 other device'), findsOneWidget);

      await tester.tap(find.text('Sign out').first);
      await tester.pumpAndSettle();
      expect(find.text('Sign out iPhone 15?'), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Sign out'));
      await tester.pumpAndSettle();

      expect(repo.revokedSessionIds, ['other']);
    });

    testWidgets('blocking a device asks first and then blocks', (tester) async {
      final repo = _FakeRepository([
        _session(id: 'current', isCurrent: true),
        _session(
          id: 'other',
          isCurrent: false,
          name: 'iPhone 15',
          deviceRowId: 'device-row-2',
        ),
      ]);
      await _pumpDevices(tester, repo);

      await tester.tap(find.text('This wasn\'t me'));
      await tester.pumpAndSettle();
      expect(find.text('Block iPhone 15?'), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Block device'));
      await tester.pumpAndSettle();

      expect(repo.blockedDeviceIds, ['device-row-2']);
    });

    testWidgets('cancelling the confirmation changes nothing', (tester) async {
      final repo = _FakeRepository([
        _session(id: 'current', isCurrent: true),
        _session(
          id: 'other',
          isCurrent: false,
          name: 'iPhone 15',
          deviceRowId: 'device-row-2',
        ),
      ]);
      await _pumpDevices(tester, repo);

      await tester.tap(find.text('This wasn\'t me'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(repo.blockedDeviceIds, isEmpty);
      expect(repo.revokedSessionIds, isEmpty);
    });

    testWidgets('a lone session offers no bulk sign-out', (tester) async {
      final repo = _FakeRepository([_session(id: 'current', isCurrent: true)]);
      await _pumpDevices(tester, repo);

      expect(find.textContaining('other device'), findsNothing);
    });

    testWidgets('location wording stays honest about precision', (
      tester,
    ) async {
      final repo = _FakeRepository([_session(id: 'current', isCurrent: true)]);
      await _pumpDevices(tester, repo);

      expect(find.textContaining('approximate'), findsOneWidget);
    });
  });
}
