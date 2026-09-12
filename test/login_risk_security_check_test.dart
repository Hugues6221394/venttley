import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:vently_app/core/notification_routing.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/presentation/screens/profile/security_check_screen.dart';

class _FakeRepository extends VentlyRepository {
  _FakeRepository(this.alerts) : super(forceMock: true);

  final List<SecurityAlert> alerts;
  final List<({String sessionId, bool wasMe})> answers = [];

  @override
  Future<List<SecurityAlert>> myUnresolvedSecurityAlerts() async => alerts;

  @override
  Future<bool> resolveSuspiciousLogin({
    required String deviceSessionId,
    required bool wasMe,
  }) async {
    answers.add((sessionId: deviceSessionId, wasMe: wasMe));
    alerts.removeWhere((a) => a.deviceSessionId == deviceSessionId);
    return true;
  }
}

SecurityAlert _alert({
  String id = 'session-1',
  String deviceRowId = 'device-1',
  String? name = 'iPhone 15',
  bool isCurrent = false,
  int riskScore = 85,
  Map<String, dynamic> signals = const {
    'new_device': true,
    'new_country': 'NG',
    'recent_failures': 4,
  },
}) {
  return SecurityAlert(
    deviceSessionId: id,
    deviceRowId: deviceRowId,
    deviceName: name,
    deviceType: 'phone',
    osName: 'iOS',
    country: 'NG',
    riskScore: riskScore,
    signals: signals,
    isCurrent: isCurrent,
    startedAt: DateTime.now().toUtc(),
  );
}

Future<void> _pump(WidgetTester tester, _FakeRepository repo) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, __) => const SecurityCheckScreen()),
      GoRoute(
        path: '/profile/password-security',
        builder: (_, __) => const Scaffold(body: Text('password screen')),
      ),
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
  group('SecurityAlert', () {
    test('turns server signals into reasons a person can act on', () {
      final alert = _alert();
      expect(alert.reasons, [
        'First time we\'ve seen this device',
        'New location for your account (NG)',
        '4 failed sign-in attempts beforehand',
      ]);
    });

    test('a signal the client does not understand is dropped, not printed', () {
      final alert = _alert(
        signals: const {'new_device': true, 'weather_was_bad': true},
      );
      expect(alert.reasons, ['First time we\'ve seen this device']);
    });

    test('an alert with no signals still renders without reasons', () {
      expect(_alert(signals: const {}).reasons, isEmpty);
    });

    test('falls back to a readable label when the device has no name', () {
      expect(_alert(name: null).label, 'iOS device');
    });

    test('parses the server payload, including the signal map', () {
      final alert = SecurityAlert.fromJson(const {
        'device_session_id': 's1',
        'device_row_id': 'd1',
        'device_name': 'Pixel 8',
        'device_type': 'phone',
        'os_name': 'Android',
        'country': 'GB',
        'risk_score': 65,
        'risk_signals': {'new_country': 'GB'},
        'is_current': false,
        'started_at': '2026-08-29T12:00:00Z',
      });
      expect(alert.riskScore, 65);
      expect(alert.reasons, ['New location for your account (GB)']);
    });
  });

  group('DeviceRegistration', () {
    test('reads the server confirmation flag', () {
      final reg = DeviceRegistration.fromJson(const {
        'device_row_id': 'd1',
        'device_session_id': 's1',
        'is_new_device': true,
        'is_blocked': false,
        'risk_score': 85,
        'needs_confirmation': true,
      });
      expect(reg.needsConfirmation, isTrue);
    });

    test('an older server that omits the flag does not challenge', () {
      // Rolling deploys mean the app can meet a backend that predates the
      // risk engine. Absent policy must mean "no challenge", never a prompt
      // the user cannot resolve.
      final reg = DeviceRegistration.fromJson(const {
        'device_row_id': 'd1',
        'is_new_device': false,
        'is_blocked': false,
        'risk_score': 0,
      });
      expect(reg.needsConfirmation, isFalse);
    });
  });

  group('security notification routing', () {
    test('a flagged sign-in routes to the decision screen', () {
      expect(
        NotificationPayload.fromNotificationItem(
          'security_suspicious_login',
          const {},
        ),
        '/security-check',
      );
    });

    test('informational security rows route to the device list', () {
      expect(
        NotificationPayload.fromNotificationItem('security_new_device', const {}),
        '/profile/devices',
      );
      expect(
        NotificationPayload.fromNotificationItem('security_alert', const {}),
        '/profile/devices',
      );
    });
  });

  group('SecurityCheckScreen', () {
    testWidgets('shows the device and why it was flagged', (tester) async {
      await _pump(tester, _FakeRepository([_alert()]));

      expect(find.text('iPhone 15'), findsOneWidget);
      expect(find.text('First time we\'ve seen this device'), findsOneWidget);
      expect(
        find.text('New location for your account (NG)'),
        findsOneWidget,
        reason: 'an alert the user cannot interpret cannot be answered',
      );
    });

    testWidgets('offers both answers with equal prominence', (tester) async {
      await _pump(tester, _FakeRepository([_alert()]));

      // Both are OutlinedButtons. If one ever becomes an ElevatedButton, the
      // screen has started nudging users toward an answer.
      expect(
        find.widgetWithText(OutlinedButton, 'Yes, that was me'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(OutlinedButton, 'No, block it'),
        findsOneWidget,
      );
    });

    testWidgets('confirming asks first, then trusts the device', (
      tester,
    ) async {
      final repo = _FakeRepository([_alert()]);
      await _pump(tester, repo);

      await tester.tap(find.text('Yes, that was me'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm iPhone 15?'), findsOneWidget);

      await tester.tap(
        find.widgetWithText(ElevatedButton, 'Yes, that was me'),
      );
      await tester.pumpAndSettle();

      expect(repo.answers, [(sessionId: 'session-1', wasMe: true)]);
    });

    testWidgets('rejecting blocks and then points at the password', (
      tester,
    ) async {
      final repo = _FakeRepository([_alert()]);
      await _pump(tester, repo);

      await tester.tap(find.text('No, block it'));
      await tester.pumpAndSettle();
      expect(find.text('Block iPhone 15?'), findsOneWidget);

      // Deliberately not pumpAndSettle: it advances the clock past the
      // snackbar's own lifetime, so the prompt would be gone before we looked.
      // Step forward far enough to close the dialog and drain the async
      // answer, but well short of the eight seconds the snackbar lives for.
      await tester.tap(find.widgetWithText(ElevatedButton, 'Block it'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }

      expect(repo.answers, [(sessionId: 'session-1', wasMe: false)]);
      expect(
        find.text('Device blocked. Change your password next.'),
        findsOneWidget,
        reason: 'blocking without rotating the password leaves them a way back',
      );
    });

    testWidgets('cancelling answers nothing', (tester) async {
      final repo = _FakeRepository([_alert()]);
      await _pump(tester, repo);

      await tester.tap(find.text('No, block it'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(repo.answers, isEmpty);
    });

    testWidgets('an empty queue reassures rather than alarms', (tester) async {
      await _pump(tester, _FakeRepository([]));

      expect(find.text('Nothing needs your attention'), findsOneWidget);
      expect(find.text('No, block it'), findsNothing);
    });

    testWidgets('several alerts are all offered', (tester) async {
      final repo = _FakeRepository([
        _alert(id: 'a', deviceRowId: 'd-a', name: 'iPhone 15'),
        _alert(id: 'b', deviceRowId: 'd-b', name: 'Galaxy S24'),
      ]);
      await _pump(tester, repo);

      expect(find.textContaining('2 sign-ins'), findsOneWidget);
      expect(find.text('No, block it'), findsNWidgets(2));
    });

    testWidgets('a flagged current device is labelled as such', (tester) async {
      await _pump(tester, _FakeRepository([_alert(isCurrent: true)]));

      expect(find.text('This device'), findsOneWidget);
    });

    testWidgets('location wording stays honest about precision', (
      tester,
    ) async {
      await _pump(tester, _FakeRepository([_alert()]));

      expect(find.textContaining('approximate'), findsOneWidget);
      expect(
        find.textContaining('VPN'),
        findsOneWidget,
        reason: 'a traveller must be told why their own sign-in looked odd',
      );
    });
  });
}
