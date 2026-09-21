import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vently_app/presentation/screens/onboarding/welcome_screen.dart';
import 'package:vently_app/presentation/theme/app_theme.dart';

/// The welcome screen, rendered in the black theme, sampled pixel by pixel.
///
/// Every previous round of this was settled by a screenshot mailed back and
/// forth, because nothing in the suite could answer "what colour is the page,
/// actually". The theme tests assert the values the theme hands out; this
/// asserts what comes out the other end of a real widget tree — gradients,
/// painters, opacities and all.
void main() {
  testWidgets('the page is pure black and the trust panel is a visible card', (
    tester,
  ) async {
    // ThemeModeController restores the persisted appearance on construction,
    // and without a mock store that reaches a plugin channel that does not
    // exist under flutter test.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(1290, 2796);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: VentlyTheme.dark(pureBlack: true),
          home: const RepaintBoundary(
            key: Key('shot'),
            child: WelcomeScreen(),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('shot')),
    );
    late final Uint8List bytes;
    late final ui.Image image;
    await tester.runAsync(() async {
      image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      bytes = data!.buffer.asUint8List();
    });
    final w = image.width;
    final h = image.height;

    (int, int, int) at(double fx, double fy) {
      final x = (fx * w).clamp(0, w - 1).toInt();
      final y = (fy * h).clamp(0, h - 1).toInt();
      final i = (y * w + x) * 4;
      return (bytes[i], bytes[i + 1], bytes[i + 2]);
    }

    String hex((int, int, int) c) =>
        '#${c.$1.toRadixString(16).padLeft(2, '0')}'
                '${c.$2.toRadixString(16).padLeft(2, '0')}'
                '${c.$3.toRadixString(16).padLeft(2, '0')}'
            .toUpperCase();

    // Down the left gutter, well clear of any content. This is where the orb
    // wash showed up worst: the build this replaced measured #1F0811 near the
    // top and #3A1624 two thirds down. Both are unmistakably maroon.
    for (final y in <double>[0.05, 0.2, 0.4, 0.6, 0.75, 0.95]) {
      final c = at(0.015, y);
      expect(
        c,
        (0, 0, 0),
        reason: 'the page is ${hex(c)} at y=$y, not pure black',
      );
    }
    // And the right gutter, which is where the second orb lived.
    for (final y in <double>[0.2, 0.5, 0.8]) {
      final c = at(0.985, y);
      expect(
        c,
        (0, 0, 0),
        reason: 'the page is ${hex(c)} at right y=$y, not pure black',
      );
    }

    // The trust panel. It has to be lighter than the page — at 52% opacity it
    // landed on #090708 and read as background rather than as a card.
    final panel = _findPanelFill(at);
    expect(
      panel,
      isNotNull,
      reason: 'no lifted card surface found anywhere on the screen',
    );
    expect(
      panel!.$1,
      greaterThanOrEqualTo(16),
      reason: 'the trust panel is ${hex(panel)} — too close to the page to see',
    );
  });
}

/// Scan the middle of the screen for the panel fill.
///
/// By position rather than by widget, deliberately: the question is whether a
/// person looking at the screen can see a card, and a Container that exists in
/// the tree at a colour indistinguishable from the page cannot.
(int, int, int)? _findPanelFill((int, int, int) Function(double, double) at) {
  for (var i = 30; i <= 70; i++) {
    final c = at(0.10, i / 100);
    if (c.$1 > 8) return c;
  }
  return null;
}
