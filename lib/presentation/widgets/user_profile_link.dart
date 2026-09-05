import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'profile_avatar.dart';

/// Tappable avatar (+ optional name) that opens `/user/:userId`.
class UserProfileLink extends StatelessWidget {
  const UserProfileLink({
    super.key,
    required this.userId,
    required this.pseudonym,
    this.displayName,
    required this.avatarSeed,
    this.profilePhotoUrl,
    this.size = 40,
    this.showName = false,
    this.nameStyle,
    this.prefix = '@',
    this.showVerifiedBadge = false,
    this.heroTag,
    this.dense = false,
    this.onTapOverride,
  });

  final String userId;
  final String pseudonym;
  final String? displayName;
  final String avatarSeed;
  final String? profilePhotoUrl;
  final double size;
  final bool showName;
  final TextStyle? nameStyle;
  final String prefix;
  final bool showVerifiedBadge;
  final Object? heroTag;
  final bool dense;

  /// Replaces the default go_router push.
  ///
  /// For callers on a page ABOVE the shell. `/user/:userId` is a shell-branch
  /// route, and go_router derives page keys from the location, so pushing it
  /// from a top-level page collides keys inside the branch navigator and
  /// asserts. Setting parentNavigatorKey on that route is not a way out
  /// either — a sub-route of a branch may not claim the root navigator, which
  /// go_router asserts at build time and which took the whole app down.
  final VoidCallback? onTapOverride;

  void _open(BuildContext context) {
    final override = onTapOverride;
    if (override != null) {
      override();
      return;
    }
    context.push('/user/$userId');
  }

  @override
  Widget build(BuildContext context) {
    final avatar = ProfileAvatar(
      avatarSeed: avatarSeed,
      label: displayName ?? pseudonym,
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
                  displayName ?? '$prefix$pseudonym',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      nameStyle ?? const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
