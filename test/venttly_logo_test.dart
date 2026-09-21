import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/presentation/widgets/venttly_logo.dart';

/// The logo has three files and the theme has three modes, and the only thing
/// tying them together is a switch. A wrong branch puts a dark wordmark on a
/// light background, or leaves a #1A1A1F rectangle on true black — visible to
/// a user on the first screen they ever see, invisible to every other test.
void main() {
  late ProviderContainer container;

  Future<String> assetFor(WidgetTester tester, VentlyThemeMode mode) async {
    // Set the mode *after* the first pump. ThemeModeController restores the
    // persisted value asynchronously in its constructor, so anything set before
    // that lands gets overwritten by the restore.
    container.read(themeModeProvider.notifier).setMode(mode);
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image).first);
    return (image.image as AssetImage).assetName;
  }

  testWidgets('each theme mode picks its own artwork', (tester) async {
    container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: VenttlyLogo())),
      ),
    );
    await tester.pump();

    expect(
      await assetFor(tester, VentlyThemeMode.light),
      'assets/images/venttly_logo.png',
    );
    expect(
      await assetFor(tester, VentlyThemeMode.dark),
      'assets/images/venttly_logo_dark.png',
    );
    expect(
      await assetFor(tester, VentlyThemeMode.black),
      'assets/images/venttly_logo_black.png',
    );
  });
}
