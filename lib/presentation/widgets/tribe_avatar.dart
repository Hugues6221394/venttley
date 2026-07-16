import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// Tribe group avatar — uses uploaded [avatarUrl] when set, else fallback icon.
class TribeAvatar extends StatelessWidget {
  const TribeAvatar({
    super.key,
    this.avatarUrl,
    this.fallbackUrl,
    this.size = 44,
    this.onTap,
    this.semanticLabel,
  });

  final String? avatarUrl;
  final String? fallbackUrl;
  final double size;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final child = RepaintBoundary(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFFFFE3EC),
          shape: BoxShape.circle,
          border: Border.all(color: VentlyColors.softMauve.withOpacity(0.55)),
        ),
        clipBehavior: Clip.antiAlias,
        child: _TribeNetworkImage(
          primaryUrl: avatarUrl,
          fallbackUrl: fallbackUrl,
          width: size,
          height: size,
          fallback: Icon(
            Icons.diversity_3_rounded,
            color: VentlyColors.berryMagenta,
            size: size * 0.48,
          ),
        ),
      ),
    );
    if (onTap == null) return child;
    return Semantics(
      button: true,
      label: semanticLabel ?? 'Preview Tribe profile image',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: child,
      ),
    );
  }
}

/// Stable rectangular Tribe preview. The banner is preferred and the avatar
/// is a real fallback, so directory cards never collapse when one image is
/// absent or fails to decode.
class TribeCoverPreview extends StatelessWidget {
  const TribeCoverPreview({
    super.key,
    this.bannerUrl,
    this.avatarUrl,
    this.width = 76,
    this.height = 58,
    this.borderRadius = 8,
    this.onTap,
    this.semanticLabel,
  });

  final String? bannerUrl;
  final String? avatarUrl;
  final double width;
  final double height;
  final double borderRadius;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final resolvedWidth = width.isFinite ? width : constraints.maxWidth;
        final preview = RepaintBoundary(
          child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: const Color(0xFFFFE3EC),
              borderRadius: BorderRadius.circular(borderRadius),
              border:
                  Border.all(color: VentlyColors.softMauve.withOpacity(0.48)),
            ),
            clipBehavior: Clip.antiAlias,
            child: _TribeNetworkImage(
              primaryUrl: bannerUrl,
              fallbackUrl: avatarUrl,
              width: resolvedWidth,
              height: height,
              fallback: const Icon(
                Icons.diversity_3_rounded,
                color: VentlyColors.berryMagenta,
              ),
            ),
          ),
        );
        if (onTap == null) return preview;
        return Semantics(
          button: true,
          label: semanticLabel ?? 'Preview Tribe cover image',
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(borderRadius),
            child: preview,
          ),
        );
      },
    );
  }
}

class _TribeNetworkImage extends StatelessWidget {
  const _TribeNetworkImage({
    required this.primaryUrl,
    required this.fallbackUrl,
    required this.width,
    required this.height,
    required this.fallback,
  });

  final String? primaryUrl;
  final String? fallbackUrl;
  final double width;
  final double height;
  final Widget fallback;

  String? get _primary {
    final value = primaryUrl?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  String? get _secondary {
    final value = fallbackUrl?.trim();
    if (value == null || value.isEmpty || value == _primary) return null;
    return value;
  }

  @override
  Widget build(BuildContext context) {
    final primary = _primary ?? _secondary;
    if (primary == null) return Center(child: fallback);
    return CachedNetworkImage(
      imageUrl: primary,
      width: width,
      height: height,
      fit: BoxFit.cover,
      memCacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
      maxWidthDiskCache: (width * 3).round(),
      fadeInDuration: const Duration(milliseconds: 120),
      placeholder: (_, __) => const ColoredBox(color: Color(0xFFFFE3EC)),
      errorWidget: (_, __, ___) {
        final secondary = _secondary;
        if (secondary == null || secondary == primary) {
          return Center(child: fallback);
        }
        return CachedNetworkImage(
          imageUrl: secondary,
          width: width,
          height: height,
          fit: BoxFit.cover,
          memCacheWidth:
              (width * MediaQuery.devicePixelRatioOf(context)).round(),
          maxWidthDiskCache: (width * 3).round(),
          errorWidget: (_, __, ___) => Center(child: fallback),
        );
      },
    );
  }
}
