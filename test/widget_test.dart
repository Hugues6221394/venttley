import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/presentation/theme/app_theme.dart';
import 'package:vently_app/presentation/widgets/vently_logo.dart';

void main() {
  testWidgets('Vently logo renders inside the light theme', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: VentlyTheme.light(),
        home: const Scaffold(body: Center(child: VentlyLogo())),
      ),
    );
    expect(find.text('Vently'), findsOneWidget);
  });
}
