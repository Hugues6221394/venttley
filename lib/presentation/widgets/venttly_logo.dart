import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// The Venttly mark, in whichever version suits the theme the reader chose.
///
/// One widget rather than an `Image.asset` at each call site, because the logo
/// appears on the two screens somebody sees before they have an account -- the
/// welcome screen and account recovery -- and a wordmark that stays dark on a
/// black background is the first thing a new user sees go wrong.
///
/// It follows the app's own setting rather than the platform brightness. Venttly
/// has three modes and the platform has two: someone who picked `black` on a
/// phone set to light still wants the light-on-dark mark, and asking the
/// platform would give them the opposite.
///
/// There are three files because there are three themes, and `black` is not
/// just `dark` turned down: the dark mark sits on #1A1A1F and the black one on
/// true black, and using either on the other's background leaves a visible
/// rectangle around the artwork.
///
/// Each variant falls back to the one below it rather than throwing, so a
/// missing file degrades to a slightly wrong background instead of a red error
/// box on the first screen a new user sees.
class VenttlyLogo extends ConsumerWidget {
  const VenttlyLogo({
    super.key,
    this.size,
    this.fit = BoxFit.cover,
  });

  static const String _light = 'assets/images/venttly_logo.png';
  static const String _dark = 'assets/images/venttly_logo_dark.png';
  static const String _black = 'assets/images/venttly_logo_black.png';

  final double? size;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final asset = switch (mode) {
      VentlyThemeMode.light => _light,
      VentlyThemeMode.dark => _dark,
      VentlyThemeMode.black => _black,
    };
    // black -> dark -> light. Each step is a smaller mistake than the last.
    final fallback = mode == VentlyThemeMode.black ? _dark : _light;

    return _image(asset, fallback: fallback);
  }

  Widget _image(String asset, {String? fallback}) {
    return Image.asset(
      asset,
      width: size,
      height: size,
      fit: fit,
      // Semantics rather than a decorative image: this is the product's name,
      // and a screen reader on the welcome screen should say it.
      semanticLabel: 'Venttly',
      errorBuilder: fallback == null
          ? null
          : (context, _, __) => _image(
              fallback,
              fallback: fallback == _light ? null : _light,
            ),
    );
  }
}
