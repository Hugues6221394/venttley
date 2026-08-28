import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/presentation/widgets/glass_surfaces.dart';

void main() {
  testWidgets('glass sheets give ListTile a visible Material surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GlassSheet(child: ListTile(title: Text('Member action'))),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Member action'), findsOneWidget);
  });

  test('presence heartbeat is explicitly best effort', () {
    final source = File('lib/main.dart').readAsStringSync();

    expect(source, contains('unawaited(_touchLastSeenSafely())'));
    expect(
      source,
      contains('await ref.read(repositoryProvider).touchLastSeen();'),
    );
    expect(
      source,
      contains("Logger.instance.warn('presence.heartbeat_failed')"),
    );
  });

  test('keeper action rail leaves enough height for two-line labels', () {
    final source = File(
      'lib/presentation/screens/tribes/tribe_manage_screen.dart',
    ).readAsStringSync();

    expect(source, contains('height: 100,'));
  });
}
