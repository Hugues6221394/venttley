import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/presentation/widgets/vently_notification_bell.dart';

void main() {
  testWidgets('notification bell uses the shared thin outline glyph',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: VentlyNotificationBell()),
      ),
    );

    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.icon, CupertinoIcons.bell);
  });

  testWidgets('muted notification bell stays in the same icon family',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: VentlyNotificationBell(muted: true)),
      ),
    );

    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.icon, CupertinoIcons.bell_slash);
  });

  test('presentation code does not reintroduce Material notification bells',
      () {
    final offenders = Directory('lib/presentation')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .where(
            (file) => file.readAsStringSync().contains('Icons.notifications'))
        .map((file) => file.path)
        .toList();

    expect(offenders, isEmpty);
  });
}
