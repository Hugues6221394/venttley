import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'profile_avatar.dart';

/// Tappable avatar (+ optional name) that opens `/user/:userId`.
class UserProfileLink extends StatelessWidget {
  const UserProfileLink({
    super.key,
    required this.userId,
    required this.pseudonym,
    required this.avatarSeed,
    this.profilePhotoUrl,
    this.size = 40,
    this.showName = false,
    this.nameStyle,
    this.prefix = '@',
    this.showVerifiedBadge = false,
    this.heroTag,
    this.dense = false,
  });

  final String userId;
  final String pseudonym;
  final String avatarSeed;
  final String? profilePhotoUrl;
  final double size;
  final bool showName;
  final TextStyle? nameStyle;
  final String prefix;
  final bool showVerifiedBadge;
  final Object? heroTag;
  final bool dense;

  void _open(BuildContext context) => context.push('/user/$userId');

  @override
  Widget build(BuildContext context) {
    final avatar = ProfileAvatar(
      avatarSeed: avatarSeed,
      label: pseudonym,
      profilePhotoUrl: profilePhotoUrl,
      size: size,
      showVerifiedBadge: showVerifiedBadge,
      heroTag: heroTag,
    );

    if (!showName) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _open(context),
          customBorder: const CircleBorder(),
          child: avatar,
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _open(context),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.symmetric(
            vertical: dense ? 2 : 4,
            horizontal: dense ? 0 : 2,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              avatar,
              SizedBox(width: dense ? 8 : 10),
              Flexible(
                child: Text(
                  '$prefix$pseudonym',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: nameStyle ??
                      const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
