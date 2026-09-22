import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Instagram-style: open any user's public profile from their username/avatar.
/// No-op for null/empty ids (e.g. system or anonymized authors). The
/// `/user/:userId` route (FriendProfileScreen) redirects to your own profile
/// when the id is you.
void openUserProfile(BuildContext context, String? userId) {
  if (userId == null || userId.trim().isEmpty) return;

  // Ask the tree, not the path.
  //
  // This used to decide by matching the current location against a list of
  // prefixes — /chat/, /group-chat/, /post-preview/ — and the list was always
  // going to be incomplete. Tribe and space chats are pushed onto the root
  // navigator for the same reason those are, but their paths begin with
  // /tribe/, so a profile opened from a space's chat info page pushed a
  // shell-owned route from outside the shell and tripped
  //
  //   'package:flutter/src/widgets/navigator.dart': Failed assertion:
  //   '!keyReservation.contains(key)': is not true.
  //
  // which surfaces as the "This part of Venttly didn't load" boundary.
  //
  // Whether the nearest Navigator is the root one answers the actual question
  // and cannot fall behind the router: if it is, this route is outside the
  // shell and needs the root-safe twin.
  final onRoot =
      Navigator.of(context) == Navigator.of(context, rootNavigator: true);
  context.push(onRoot ? '/user-preview/$userId' : '/user/$userId');
}

/// Wraps [child] so tapping it opens [userId]'s public profile.
class UserProfileTap extends StatelessWidget {
  const UserProfileTap({
    super.key,
    required this.userId,
    required this.child,
    this.borderRadius,
  });

  final String? userId;
  final Widget child;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    if (userId == null || userId!.trim().isEmpty) return child;
    return InkWell(
      borderRadius: borderRadius ?? BorderRadius.circular(8),
      onTap: () => openUserProfile(context, userId),
      child: child,
    );
  }
}
