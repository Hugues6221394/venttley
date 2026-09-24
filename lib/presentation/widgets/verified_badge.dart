import 'package:flutter/material.dart';

/// The verification tick shown wherever a verified member is named.
///
/// One source of truth so the badge looks identical everywhere a person
/// appears — feed, whispers, friends, inbox, search, chats, comments,
/// profiles. Beside the display name as well as the handle: a tick that only
/// follows the @handle disappears on every surface that shows somebody's
/// chosen name instead, which is most of them. Render it only when the user is
/// actually verified:
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
