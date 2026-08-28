import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Instagram-style: open any user's public profile from their username/avatar.
/// No-op for null/empty ids (e.g. system or anonymized authors). The
/// `/user/:userId` route (FriendProfileScreen) redirects to your own profile
/// when the id is you.
void openUserProfile(BuildContext context, String? userId) {
  if (userId == null || userId.trim().isEmpty) return;
  final currentPath = GoRouterState.of(context).uri.path;
  final fromRootConversation = currentPath.startsWith('/chat/') ||
      currentPath.startsWith('/group-chat/') ||
      currentPath.startsWith('/post-preview/');
  context.push(
    fromRootConversation ? '/user-preview/$userId' : '/user/$userId',
  );
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
