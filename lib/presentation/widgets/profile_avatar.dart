import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'anonymous_avatar.dart';

class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    required this.avatarSeed,
    required this.label,
    this.profilePhotoUrl,
    this.size = 44,
    this.showVerifiedBadge = false,
    this.animate = false,
    this.heroTag,
  });

  final String avatarSeed;
  final String label;
  final String? profilePhotoUrl;
  final double size;
  final bool showVerifiedBadge;
  final bool animate;

  /// Opt-in Hero tag. Pass when the same avatar appears on two screens
  /// and you want a shared-element transition (e.g. feed card →
  /// profile). Tags must be unique per route stack so this is null by
  /// default — only the screen that owns the destination should set it.
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final url = profilePhotoUrl?.trim();
    final decodeSize = (size * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(1, 512)
        .toInt();
    final core = url == null || url.isEmpty
        ? AnonymousAvatar(
            seed: avatarSeed,
            label: label,
            size: size,
            animate: animate,
          )
        : ClipOval(
            child: CachedNetworkImage(
              imageUrl: url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              memCacheWidth: decodeSize,
              memCacheHeight: decodeSize,
              maxWidthDiskCache: decodeSize,
              maxHeightDiskCache: decodeSize,
              placeholder: (_, __) => AnonymousAvatar(
                seed: avatarSeed,
                label: label,
                size: size,
                animate: animate,
              ),
              errorWidget: (_, __, ___) => AnonymousAvatar(
                seed: avatarSeed,
                label: label,
                size: size,
                animate: animate,
              ),
            ),
          );

    final wrapped = heroTag == null ? core : Hero(tag: heroTag!, child: core);
    if (!showVerifiedBadge) return wrapped;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          wrapped,
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.verified,
                color: Colors.white,
                size: size * 0.30,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
