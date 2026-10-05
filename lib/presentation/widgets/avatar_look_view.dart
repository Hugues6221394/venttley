import 'package:flutter/material.dart';

import '../../domain/avatar/avatar_look.dart';

/// Draws an [AvatarLook] by stacking its layers.
///
/// Every layer is a 768px square drawn on the same anchors, so stacking them
/// in order is the whole algorithm — there is no per-piece positioning here,
/// because the positioning was baked into the art by
/// `scripts/avatars/build_layers.py` against the base's measured anchors.
///
/// Decoding is sized to what is actually on screen. A layer left at full size
/// costs 2.4MB of decoded memory, and a grid of twelve hairstyles would hold a
/// hundred megabytes of pixels to show twelve thumbnails.
class AvatarLookView extends StatelessWidget {
  const AvatarLookView({super.key, required this.look, required this.size});

  final AvatarLook look;

  /// Logical size. The widget is square.
  final double size;

  @override
  Widget build(BuildContext context) {
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final decodeTo = (size * ratio).round().clamp(16, 768);
    return SizedBox.square(
      dimension: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          for (final layer in look.layers)
            _AvatarLayer(
              asset: layer.asset,
              tint: layer.tint,
              decodeTo: decodeTo,
            ),
        ],
      ),
    );
  }
}

/// One layer, tinted without losing its shading.
///
/// Not `Image.asset(color:, colorBlendMode: srcIn)` — that replaces every
/// pixel with the tint and leaves a flat silhouette. The layer ships as
/// normalised greyscale precisely so a matrix can scale its luminance into a
/// colour and keep every strand and shadow.
class _AvatarLayer extends StatelessWidget {
  const _AvatarLayer({
    required this.asset,
    required this.tint,
    required this.decodeTo,
  });

  final String asset;
  final Color? tint;
  final int decodeTo;

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      asset,
      cacheWidth: decodeTo,
      cacheHeight: decodeTo,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
    );
    final colour = tint;
    if (colour == null) return image;
    return ColorFiltered(
      colorFilter: AvatarPalettes.multiply(colour),
      child: image,
    );
  }
}
