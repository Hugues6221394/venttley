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
    final hasPhoto = wallpaperUrl != null &&
        wallpaperUrl!.trim().isNotEmpty &&
        wallpaperStyle == 'photo';
    final canvas = _canvasColor(context, isPureBlack: isPureBlack);

    if (!hasPhoto) {
      return ColoredBox(color: canvas, child: child);
    }

    final wallpaperDecodeWidth = (MediaQuery.sizeOf(context).width *
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
          errorBuilder: (_, __, ___) => ColoredBox(
            color: canvas,
          ),
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
        child,
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
