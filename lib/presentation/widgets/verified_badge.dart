import 'package:flutter/material.dart';

/// The verification tick shown next to a verified member's username.
///
/// One source of truth so the badge looks identical everywhere a username
/// appears — feed, whispers, friends, chats, comments, profiles. Render it
/// only when the user is actually verified:
///
/// ```dart
/// if (user.isVerified) ...[
///   const SizedBox(width: 4),
///   const VerifiedBadge(),
/// ]
/// ```
class VerifiedBadge extends StatelessWidget {
  const VerifiedBadge({super.key, this.size = 14, this.color});

  final double size;

  /// Defaults to the theme's primary (berry) so it reads as a trusted mark.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.verified,
      size: size,
      color: color ?? Theme.of(context).colorScheme.primary,
      semanticLabel: 'Verified',
    );
  }
}
