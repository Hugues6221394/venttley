import 'dart:math' as math;
import 'dart:ui' as ui show Image, ImageByteFormat;
import 'dart:ui' show Color;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/presentation/theme/app_theme.dart';
import 'package:vently_app/presentation/theme/colors.dart';
import 'package:vently_app/presentation/theme/glass_tokens.dart';
import 'package:vently_app/presentation/widgets/onboarding_backdrop.dart';

/// What the onboarding surfaces actually look like, per theme, as numbers.
///
/// Every dark-mode fault on these screens has been the same shape: a value
/// chosen while looking at the light theme, which nothing then re-checked. A
/// white panel at 62% opacity. An orb gradient opening on near-white. A
/// desaturated pink introduced on the assumption the brand pink was unreadable
/// on black, when it is not. A card at 52% that measures 1.046 against a
/// true-black page — which is to say a card nobody can see.
///
/// The figures below are read off the approved design rather than picked: a
/// #000000 page, an opaque #120D0F card, the brand berry, and the palette's
/// own dividers doing the delineating.
///
/// Screenshots caught every one of these, one round trip at a time. This is
/// the same set of judgements written down, so the next one fails here.

/// WCAG relative luminance.
double _luminance(Color c) {
  double channel(double v) {
    final s = v / 255.0;
    return s <= 0.03928
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4) as double;
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
        final panel = _over(GlassTokens.card(context), page);
        final border = _over(GlassTokens.border(context), page);

        // A card is separated from its page by whichever of fill or border
        // does the work, and on these screens it is the border: even an opaque
        // card sits at 1.05–1.09 against its page in every theme, including
        // light, where it nonetheless reads perfectly well. Measuring only the
        // fill therefore fails the design that works and says nothing about
        // the one that does not.
        final separation = math.max(
          _contrast(panel, page),
          _contrast(border, page),
        );

        // 1.16 is the light theme's own figure, measured. It is the design
        // that demonstrably reads, so it is the floor the dark ones have to
        // clear rather than a number chosen in the abstract.
        //
        // It turned out not to be enough on its own. A card can clear this on
        // its border alone while its fill stays at 1.09, and that is exactly
        // what shipped and what came back as "I still cannot see the grey
        // section" — a rim around a panel the same colour as the page. The
        // fill now carries its own floor below.
        expect(
          separation,
          greaterThan(1.16),
          reason:
              'nothing delineates the panel in $name — fill '
              '${_contrast(panel, page).toStringAsFixed(3)}, border '
              '${_contrast(border, page).toStringAsFixed(3)}',
        );
      });

      testWidgets('$name: the panel is an opaque card, not a wash', (
        tester,
      ) async {
        final context = await _contextFor(tester, theme);
        final card = GlassTokens.card(context);

        // GlassTokens.tint stays translucent — it is glass, sitting on a
        // BackdropFilter over content that scrolls beneath it, and that is
        // the whole point of it in chat and the sheets. The onboarding
        // surfaces have a flat page behind them instead, so translucency
        // there bought nothing and cost the card its edges: 52% of #120D0F
        // over #000000 renders as #090708 and stops being visible.
        expect(
          card.a,
          1.0,
          reason:
              'the panel fill in $name is translucent, so it dissolves into '
              'the page instead of reading as a card',
        );
        // There was a floor on the fill here — 1.28, taken off the profile
        // dashboard — and it is gone on purpose rather than quietly relaxed.
        //
        // It encoded a belief that turned out to be wrong: that a card is
        // found by its fill. Four values were pushed through this test trying
        // to satisfy it (1.29, 1.61, 2.98, 4.70) and every one of them was
        // still reported as not reading. The screen that does read — Spaces —
        // sits at 1.05 and marks its cards with a berry hairline instead. The
        // edge is what is asserted now, just below.
      });

      testWidgets('$name: body text on the panel passes AA', (tester) async {
        final context = await _contextFor(tester, theme);
        final page = theme.scaffoldBackgroundColor;
        final panel = _over(GlassTokens.card(context), page);

        // GlassTokens.onCard, not colorScheme.onSurface. A lifted card in a
        // dark theme is now lighter than the page rather than darker, so the
        // theme's on-surface ink — an off-white — is the wrong way round on
        // it. That inversion is the whole reason the token exists, and
        // measuring the old one here would pass a screen nobody can read.
        final body = GlassTokens.onCard(context);

        expect(
          _contrast(_over(body, panel), panel),
          greaterThanOrEqualTo(4.5),
          reason: 'body text on the panel is below AA in $name',
        );
      });

      testWidgets('$name: secondary text on the panel clears 3:1', (
        tester,
      ) async {
        final context = await _contextFor(tester, theme);
        final page = theme.scaffoldBackgroundColor;
        final panel = _over(GlassTokens.card(context), page);
        final muted = _over(GlassTokens.onCardMuted(context), panel);

        // 3.0 is the floor; the surface currently clears 4.3.
        //
        // It briefly did not. A mid-grey card has only 4.7:1 of range in it
        // end to end, so once the primary ink spends that there is nothing
        // left for a softer tone, and secondary text sat at 3.5 — legible,
        // below AA, and a real cost. Going back to a dark surface and letting
        // colour do the distinguishing bought that range back.
        expect(
          _contrast(muted, panel),
          greaterThanOrEqualTo(3.0),
          reason:
              'secondary text on the panel is ${_contrast(muted, panel).toStringAsFixed(2)}'
              ':1 in $name, below even the large-text floor',
        );
      });

      testWidgets('$name: the card edge is the thing that marks the card', (
        tester,
      ) async {
        // The fill barely lifts off the page and that is on purpose: this is
        // the surface the Spaces screen uses, and Spaces is the screen that
        // was held up as the one that reads. Four attempts went into
        // lightening this fill — 1.29, 1.61, 2.98, 4.70 — before it was clear
        // the fill was never what made a card findable. The berry hairline is.
        final context = await _contextFor(tester, theme);
        final page = theme.scaffoldBackgroundColor;
        final edge = _over(GlassTokens.cardEdge(context), page);

        expect(
          _contrast(edge, page),
          greaterThan(1.16),
          reason:
              'the card edge in $name is ${_contrast(edge, page).toStringAsFixed(3)}'
              ':1 — below what the light theme achieves, so the card has '
              'nothing marking it at all',
        );
      });

      testWidgets('$name: the welcome panel carries its own contents', (
        tester,
      ) async {
        // A light slab on a dark canvas, which means its type runs the other
        // way to everything around it. The panel was drawn this colour from
        // the start and kept the dark theme's off-white ink, so the contents
        // came out faint — the thing that was reported, five times, as a grey
        // that could not be read.
        final context = await _contextFor(tester, theme);
        final panel = GlassTokens.panel(context);

        expect(
          _contrast(GlassTokens.onPanel(context), panel),
          greaterThanOrEqualTo(4.5),
          reason: 'the panel title is below AA in $name',
        );
        expect(
          _contrast(_over(GlassTokens.onPanelMuted(context), panel), panel),
          greaterThanOrEqualTo(4.5),
          reason: 'the panel body text is below AA in $name',
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

  group('the black theme is actually black', () {
    test('the canvas is #000000, not a tinted near-black', () {
      // The AMOLED option exists so that the page is off. A value one step
      // above zero is indistinguishable in a screenshot and entirely visible
      // on the phone it is meant to be saving.
      expect(
        VentlyTheme.dark(pureBlack: true).scaffoldBackgroundColor,
        VentlyColors.pureBlack,
      );
    });

    testWidgets('nothing decorative is painted over a dark canvas', (
      tester,
    ) async {
      // Three rounds of tuning orb opacity proved the strength was never the
      // problem. Any coloured light on a near-black page shows up as a maroon
      // wash in the corners and a halo around whatever sits in front of it —
      // which is what made the berry buttons read as lacquered rather than
      // flat. Sampled off the build this replaced, the page ran from #1F0811
      // to #3A1624 down a single screen; the approved design is (0, 0, 0) at
      // every point from the status bar to the home indicator.
      expect(OnboardingBackdrop.decorates(VentlyTheme.light()), isTrue);
      expect(OnboardingBackdrop.decorates(VentlyTheme.dark()), isFalse);
      expect(
        OnboardingBackdrop.decorates(VentlyTheme.dark(pureBlack: true)),
        isFalse,
      );

      // And the widget honours it: on black the backdrop hands back the canvas
      // colour with nothing over it.
      await tester.pumpWidget(
        MaterialApp(
          theme: VentlyTheme.dark(pureBlack: true),
          home: const Scaffold(
            backgroundColor: Colors.transparent,
            body: RepaintBoundary(
              child: OnboardingBackdrop(
                animate: false,
                child: SizedBox.shrink(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final box = tester.widget<ColoredBox>(
        find
            .descendant(
              of: find.byType(OnboardingBackdrop),
              matching: find.byType(ColoredBox),
            )
            .first,
      );
      expect(box.color, VentlyColors.pureBlack);

      // No orb. The orbs are the only thing this backdrop paints, and they are
      // drawn by a CustomPaint with a `painter`; the backdrop's transparent
      // Material — the ink surface that lets a tap ripple show in front of the
      // page rather than behind it — also builds a CustomPaint, but only ever
      // a foreground shape border, and with no shape it draws nothing.
      final painters = tester
          .widgetList<CustomPaint>(
            find.descendant(
              of: find.byType(OnboardingBackdrop),
              matching: find.byType(CustomPaint),
            ),
          )
          .where((p) => p.painter != null);
      expect(
        painters,
        isEmpty,
        reason: 'the black canvas should have nothing painted over it',
      );

      // And the claim the comment above makes, measured rather than inferred:
      // every pixel from the status bar to the home indicator is (0, 0, 0).
      final bytes = await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byType(RepaintBoundary).first,
        );
        final ui.Image image = await boundary.toImage();
        return image.toByteData(format: ui.ImageByteFormat.rawRgba);
      });
      final rgba = bytes!.buffer.asUint8List();
      var offColour = 0;
      for (var i = 0; i < rgba.length; i += 4) {
        if (rgba[i] != 0 || rgba[i + 1] != 0 || rgba[i + 2] != 0) offColour++;
      }
      expect(
        offColour,
        0,
        reason:
            'sampled the whole page: $offColour of ${rgba.length ~/ 4} pixels '
            'are not #000000',
      );
    });
  });
}
