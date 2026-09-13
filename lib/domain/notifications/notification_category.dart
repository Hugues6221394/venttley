import 'package:flutter/material.dart';

/// Every notification kind the database will accept.
///
/// Mirrors the CHECK on `public.notifications.kind`. It is duplicated here on
/// purpose and guarded by a test: the categories below have to partition this
/// list exactly, and the only way to know a new kind has appeared is to have
/// written the old list down. A kind that belongs to no tab is invisible in
/// every tab but "All" — which is the quiet failure this exists to prevent.
const List<String> kNotificationKinds = <String>[
  'comment_reply',
  'post_like',
  'comment_like',
  'mention',
  'new_follower',
  'friend_request',
  'friend_accepted',
  'message_request',
  'message_accepted',
  'tribe_prompt',
  'tribe_invite',
  'tribe_ownership_transfer',
  'whisper_reply',
  'whisper_reaction',
  'moderation_action',
  'admin_broadcast',
  'system',
  'security_alert',
  'security_new_device',
  'security_suspicious_login',
];

/// The tabs across the Activity screen.
///
/// Grouped by what the reader came looking for rather than by which table the
/// row came from. Someone checking whether a friend replied does not care that
/// a reply to a Vent and a reply to a Whisper are different tables, and
/// someone scanning for a safety notice does not want it buried among likes.
enum NotificationCategory {
  all,
  mentions,
  reactions,
  comments,
  friends,
  tribes,
  system;

  String get label => switch (this) {
    NotificationCategory.all => 'All',
    NotificationCategory.mentions => 'Mentions',
    NotificationCategory.reactions => 'Reactions',
    NotificationCategory.comments => 'Comments',
    NotificationCategory.friends => 'Friends',
    NotificationCategory.tribes => 'Tribes',
    NotificationCategory.system => 'System',
  };

  IconData get icon => switch (this) {
    NotificationCategory.all => Icons.all_inclusive_rounded,
    NotificationCategory.mentions => Icons.alternate_email_rounded,
    NotificationCategory.reactions => Icons.favorite_rounded,
    NotificationCategory.comments => Icons.mode_comment_rounded,
    NotificationCategory.friends => Icons.people_alt_rounded,
    NotificationCategory.tribes => Icons.groups_2_rounded,
    NotificationCategory.system => Icons.shield_rounded,
  };

  /// The kinds this tab shows. Empty for [all], which shows everything.
  Set<String> get kinds => switch (this) {
    NotificationCategory.all => const <String>{},
    NotificationCategory.mentions => const {'mention'},
    NotificationCategory.reactions => const {
      'post_like',
      'comment_like',
      'whisper_reaction',
    },
    // Replies, wherever they were left. A reply to a Whisper is a comment to
    // the person who receives it, whatever table it lives in.
    NotificationCategory.comments => const {'comment_reply', 'whisper_reply'},
    NotificationCategory.friends => const {
      'friend_request',
      'friend_accepted',
      'new_follower',
      'message_request',
      'message_accepted',
    },
    NotificationCategory.tribes => const {
      'tribe_prompt',
      'tribe_invite',
      'tribe_ownership_transfer',
    },
    // Everything the platform says to you rather than another person:
    // moderation decisions, broadcasts, and security. Grouped together because
    // they share a property the others do not — ignoring one can cost you
    // something.
    NotificationCategory.system => const {
      'moderation_action',
      'admin_broadcast',
      'system',
      'security_alert',
      'security_new_device',
      'security_suspicious_login',
    },
  };

  bool matches(String kind) => this == all || kinds.contains(kind);

  /// Tabs in display order.
  static const List<NotificationCategory> tabs = <NotificationCategory>[
    all,
    mentions,
    reactions,
    comments,
    friends,
    tribes,
    system,
  ];
}
