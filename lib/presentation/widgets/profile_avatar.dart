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
  });

  final String avatarSeed;
  final String label;
  final String? profilePhotoUrl;
  final double size;
  final bool showVerifiedBadge;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final url = profilePhotoUrl?.trim();
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

    if (!showVerifiedBadge) return core;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          core,
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
