import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/presentation/theme/app_theme.dart';
import 'package:vently_app/presentation/theme/colors.dart';
import 'package:vently_app/presentation/theme/glass_tokens.dart';

/// What the onboarding surfaces actually look like, per theme, as numbers.
///
/// Every dark-mode fault on these screens has been the same shape: a value
/// chosen while looking at the light theme, which nothing then re-checked. A
/// white panel at 62% opacity. An orb gradient opening on near-white. A
/// desaturated pink introduced on the assumption the brand pink was unreadable
/// on black, when it is not.
///
/// Screenshots caught all three, one round trip at a time. These are the same
/// judgements written down, so the next one fails here instead.

/// WCAG relative luminance.
double _luminance(Color c) {
  double channel(double v) {
    final s = v / 255.0;
    return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4) as double;
  }

  return 0.2126 * channel(c.r * 255) +
      0.7152 * channel(c.g * 255) +
      0.0722 * channel(c.b * 255);
}

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// Flatten a translucent colour onto what sits behind it.
Color _over(Color fg, Color bg) {
  final a = fg.a;
  return Color.fromARGB(
    255,
    ((fg.r * 255 * a) + (bg.r * 255 * (1 - a))).round(),
    ((fg.g * 255 * a) + (bg.g * 255 * (1 - a))).round(),
    ((fg.b * 255 * a) + (bg.b * 255 * (1 - a))).round(),
  );
}

Future<BuildContext> _contextFor(WidgetTester tester, ThemeData theme) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Builder(
        builder: (context) {
          captured = context;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return captured;
}

void main() {
  final themes = <String, ThemeData>{
    'light': VentlyTheme.light(),
    'dark': VentlyTheme.dark(),
    'black': VentlyTheme.dark(pureBlack: true),
  };

  group('onboarding surfaces stay legible', () {
    themes.forEach((name, theme) {
      testWidgets('$name: the panel edge is visible against the page', (
        tester,
      ) async {
        final context = await _contextFor(tester, theme);
        final page = theme.scaffoldBackgroundColor;
        final panel = _over(GlassTokens.tint(context), page);
        final border = _over(GlassTokens.border(context), page);

        // A card is separated from its page by whichever of fill or border
        // does the work, and on these screens it is the border: the fill sits
        // at roughly 1.04 against the page in *every* theme, including light,
        // where the card nonetheless reads perfectly well. Measuring only the
        // fill therefore fails the design that works and says nothing about
        // the one that does not.
        final separation = math.max(
          _contrast(panel, page),
          _contrast(border, page),
        );

        // 1.16 is the light theme's own figure, measured. It is the design
        // that demonstrably reads, so it is the floor the dark ones have to
        // clear rather than a number chosen in the abstract.
        expect(
          separation,
          greaterThan(1.16),
          reason:
              'nothing delineates the panel in $name — fill '
              '${_contrast(panel, page).toStringAsFixed(3)}, border '
              '${_contrast(border, page).toStringAsFixed(3)}',
        );
      });

      testWidgets('$name: body text on the panel passes AA', (tester) async {
        final context = await _contextFor(tester, theme);
        final page = theme.scaffoldBackgroundColor;
        final panel = _over(GlassTokens.tint(context), page);
        final body = theme.colorScheme.onSurface;

        expect(
          _contrast(_over(body, panel), panel),
          greaterThanOrEqualTo(4.5),
          reason: 'body text on the panel is below AA in $name',
        );
      });

      testWidgets('$name: the primary button is the brand berry', (
        tester,
      ) async {
        // The one the email signup screen had already overridden by hand,
        // which was the clue that the theme value was wrong rather than the
        // screen.
        expect(
          theme.colorScheme.primary,
          VentlyColors.berryMagenta,
          reason: 'primary should be the full brand berry in $name',
        );
      });

      testWidgets('$name: label on the primary button passes AA large', (
        tester,
      ) async {
        final label = _contrast(
          theme.colorScheme.onPrimary,
          theme.colorScheme.primary,
        );
        expect(
          label,
          greaterThanOrEqualTo(3.0),
          reason:
              'button label is below AA-large on the primary fill in $name '
              '(${label.toStringAsFixed(2)}:1)',
        );
      });
    });
  });
}
