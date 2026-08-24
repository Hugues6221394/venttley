import 'package:flutter/material.dart';

import '../profile_avatar.dart';
import '../tribe_avatar.dart';

/// Avatar with optional green online ring (glass-friendly border glow).
class OnlineAvatarRing extends StatelessWidget {
  const OnlineAvatarRing({
    super.key,
    this.avatarUrl,
    this.avatarSeed,
    this.label,
    this.profilePhotoUrl,
    this.size = 40,
    this.isOnline = false,
    this.useTribeAvatar = false,
  });

  final String? avatarUrl;
  final String? avatarSeed;
  final String? label;
  final String? profilePhotoUrl;
  final double size;
  final bool isOnline;
  final bool useTribeAvatar;

  @override
  Widget build(BuildContext context) {
    final ring = isOnline ? const Color(0xFF21C76A) : Colors.transparent;
    return Container(
      padding: const EdgeInsets.all(2.2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: ring, width: isOnline ? 2.2 : 0),
        boxShadow: isOnline
            ? [
                BoxShadow(
                  color: const Color(0xFF21C76A).withOpacity(0.35),
                  blurRadius: 8,
                ),
              ]
            : null,
      ),
      child: useTribeAvatar
          ? TribeAvatar(avatarUrl: avatarUrl, size: size)
          : ProfileAvatar(
              avatarSeed: avatarSeed ?? 'default-orb',
              label: label ?? 'member',
              profilePhotoUrl: profilePhotoUrl,
              size: size,
            ),
    );
  }
}

String formatLastSeen(DateTime? at) {
  if (at == null) return 'Offline';
  final diff = DateTime.now().difference(at);
  if (diff.inMinutes < 5) return 'Online';
  if (diff.inMinutes < 60) return 'Last seen ${diff.inMinutes}m ago';
  if (diff.inHours < 24) return 'Last seen ${diff.inHours}h ago';
  if (diff.inDays < 7) return 'Last seen ${diff.inDays}d ago';
  return 'Last seen ${at.month}/${at.day}';
}
