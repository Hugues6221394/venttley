import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// Tribe group avatar — uses uploaded [avatarUrl] when set, else fallback icon.
class TribeAvatar extends StatelessWidget {
  const TribeAvatar({
    super.key,
    this.avatarUrl,
    this.size = 44,
    this.onTap,
  });

  final String? avatarUrl;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hasUrl = avatarUrl != null && avatarUrl!.trim().isNotEmpty;
    final child = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFFFFE3EC),
        shape: BoxShape.circle,
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.55)),
        image: hasUrl
            ? DecorationImage(
                image: CachedNetworkImageProvider(avatarUrl!),
                fit: BoxFit.cover,
              )
            : null,
      ),
      alignment: Alignment.center,
      child: hasUrl
          ? null
          : Icon(
              Icons.diversity_3_rounded,
              color: VentlyColors.berryMagenta,
              size: size * 0.48,
            ),
    );
    if (onTap == null) return child;
    return GestureDetector(onTap: onTap, child: child);
  }
}
