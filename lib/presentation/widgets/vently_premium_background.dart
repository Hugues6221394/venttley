import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// The quiet Venttly canvas used behind member-facing screens.
///
/// A stable opaque surface keeps long social lists cheap to composite. Photo
/// wallpapers remain supported, but the default experience intentionally has
/// no animated paint or full-screen blur competing with scrolling content.
class VentlyPremiumBackground extends StatelessWidget {
  const VentlyPremiumBackground({
    super.key,
    required this.child,
    this.wallpaperUrl,
    this.wallpaperStyle = 'gradient',
  });

  final Widget child;
  final String? wallpaperUrl;
  final String wallpaperStyle;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isPureBlack = context.isPureBlack;
    final hasPhoto =
        wallpaperUrl != null &&
        wallpaperUrl!.trim().isNotEmpty &&
        wallpaperStyle == 'photo';
    final canvas = _canvasColor(context, isPureBlack: isPureBlack);

    // The child is wrapped in a transparent Material on both branches below.
    //
    // This widget paints the app's canvas — a ColoredBox on the plain branch,
    // a photo plus a scrim on the other — and it sits ABOVE anything inside
    // that paints ink on its nearest Material ancestor. So a ListTile,
    // SwitchListTile or InkWell placed directly on this background drew its
    // splash underneath the canvas, where it cannot be seen, and Flutter
    // reported it in debug:
    //
    //   ListTile background color or ink splashes may be invisible.
    //   The ListTile is wrapped in a ColoredBox that has a background color.
    //
    // Found on step 2 of Create a Tribe, where both "Approve new members" and
    // the safety-template switch had no visible press feedback at all.
    //
    // MaterialType.transparency contributes an ink surface and nothing else —
    // no colour, no elevation, no shape — so the canvas above is unchanged.
    // GlassCard and GlassSheet do the same thing for the same reason.
    final inkable = Material(type: MaterialType.transparency, child: child);

    if (!hasPhoto) {
      return ColoredBox(color: canvas, child: inkable);
    }

    final wallpaperDecodeWidth =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .ceil()
            .clamp(1, 4096)
            .toInt();

    return Stack(
      fit: StackFit.expand,
      children: [
        Image.network(
          wallpaperUrl!,
          fit: BoxFit.cover,
          cacheWidth: wallpaperDecodeWidth,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, __, ___) => ColoredBox(color: canvas),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withOpacity(isDark ? 0.45 : 0.25),
                Colors.black.withOpacity(isDark ? 0.65 : 0.35),
              ],
            ),
          ),
        ),
        inkable,
      ],
    );
  }

  Color _canvasColor(BuildContext context, {required bool isPureBlack}) {
    if (isPureBlack) return VentlyColors.pureBlack;
    if (Theme.of(context).brightness == Brightness.dark) {
      return VentlyColors.charcoal;
    }
    return VentlyColors.blushPink;
  }
}
