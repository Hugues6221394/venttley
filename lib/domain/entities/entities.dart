/// Plain immutable entities that flow through the app.
/// Matches the columns from `supabase/migrations/0001_init_schema.sql`.
library;

import '../tribe/tribe_chat_hub.dart';

class AppUser {
  final String userId;
  final String anonymousPseudonym;
  final String avatarSeed;
  final String currentMood;
  final String userRole; // normal | plug | super_admin
  final bool isVerified;
  final String safetyTier; // restricted_minor | standard
  final int? birthYear;
  final String accountStatus;
  final int karmaPoints;
  final String? homeCity;
  final String? homeCountry;
  final String? homeCampus;
  final String? profilePhotoUrl;

  /// Public, user-authored profile copy. Both optional and shown on the
  /// public profile when set. `pronouns` is a free short string (e.g. "she/her",
  /// "he/him", "they/them") the user picks in Edit Profile.
  final String? bio;
  final String? pronouns;

  /// True once the account's real email has been verified (via the 6-digit
  /// code flow) or was provided by a pre-verified provider (Google/phone).
  /// Anonymous synthetic-handle accounts stay false — they have no real email
  /// and are never gated on it.
  final bool emailVerified;

  const AppUser({
    required this.userId,
    required this.anonymousPseudonym,
    required this.avatarSeed,
    required this.currentMood,
    required this.userRole,
    required this.isVerified,
    required this.safetyTier,
    required this.accountStatus,
    this.birthYear,
    this.karmaPoints = 0,
    this.homeCity,
    this.homeCountry,
    this.homeCampus,
    this.profilePhotoUrl,
    this.bio,
    this.pronouns,
    this.emailVerified = false,
  });

  bool get isRestrictedMinor => safetyTier == 'restricted_minor';
  bool get isPlug => userRole == 'plug' || userRole == 'super_admin';
  bool get hasLocation =>
      (homeCity != null && homeCity!.isNotEmpty) ||
      (homeCampus != null && homeCampus!.isNotEmpty);

  /// The normalized bucket key the feed uses for "local" scoping.
  String? get localBucket {
    final c = homeCity?.trim().toLowerCase();
    return (c == null || c.isEmpty) ? null : c;
  }

  AppUser copyWith({
    String? anonymousPseudonym,
    String? avatarSeed,
    String? currentMood,
    String? safetyTier,
    String? userRole,
    bool? isVerified,
    int? karmaPoints,
    String? homeCity,
    String? homeCountry,
    String? homeCampus,
    Object? profilePhotoUrl = _unset,
    Object? bio = _unset,
    Object? pronouns = _unset,
    bool? emailVerified,
  }) {
    return AppUser(
      userId: userId,
      anonymousPseudonym: anonymousPseudonym ?? this.anonymousPseudonym,
      avatarSeed: avatarSeed ?? this.avatarSeed,
      currentMood: currentMood ?? this.currentMood,
      userRole: userRole ?? this.userRole,
      isVerified: isVerified ?? this.isVerified,
      safetyTier: safetyTier ?? this.safetyTier,
      accountStatus: accountStatus,
      birthYear: birthYear,
      karmaPoints: karmaPoints ?? this.karmaPoints,
      homeCity: homeCity ?? this.homeCity,
      homeCountry: homeCountry ?? this.homeCountry,
      homeCampus: homeCampus ?? this.homeCampus,
      profilePhotoUrl: profilePhotoUrl == _unset
          ? this.profilePhotoUrl
          : profilePhotoUrl as String?,
      bio: bio == _unset ? this.bio : bio as String?,
      pronouns: pronouns == _unset ? this.pronouns : pronouns as String?,
      emailVerified: emailVerified ?? this.emailVerified,
    );
  }

  static const Object _unset = Object();
}

/// A member of a Tribe — joins tribe_members + users for the manage view.
class TribeMemberRow {
  final String userId;
  final String pseudonym;
  final String avatarSeed;
  final String? profilePhotoUrl;
  final String role; // member | mod | keeper
  final DateTime joinedAt;

  const TribeMemberRow({
    required this.userId,
    required this.pseudonym,
    required this.avatarSeed,
    required this.role,
    required this.joinedAt,
    this.profilePhotoUrl,
  });

  bool get isKeeper => role == 'keeper';
  bool get isMod    => role == 'mod';
}

class BadgeDefinition {
  final String key;
  final String label;
  final String description;
  final String icon;
  final String tier; // bronze | silver | gold
  const BadgeDefinition({
    required this.key,
    required this.label,
    required this.description,
    required this.icon,
    required this.tier,
  });
}

class UserBadge {
  final String key;
  final DateTime awardedAt;
  const UserBadge({required this.key, required this.awardedAt});
}

class UserStreak {
  final String kind;        // posting | commenting | reactions
  final int currentCount;
  final int longestCount;
  final DateTime lastEventAt;
  const UserStreak({
    required this.kind,
    required this.currentCount,
    required this.longestCount,
    required this.lastEventAt,
  });
}

class PlugProfile {
  final String plugId;
  final String displayName;
  final String? bio;
  final String? locationLabel;
  final int tribeCount;
  final String avatarSeed;

  const PlugProfile({
    required this.plugId,
    required this.displayName,
    required this.tribeCount,
    required this.avatarSeed,
    this.bio,
    this.locationLabel,
  });
}

/// Hybrid Tribe — both a community (members join, posts belong to it) and a
/// creator ecosystem (a keeper moderates it; keeper may be a verified Plug).
/// Mirrors `public.tribe_directory` from migration 0005.
class Tribe {
  final String tribeId;
  final String name;
  final String slug;
  final String? description;
  final String category; // campus | city | interest_group | hobby | support | venting
  final int memberCount;
  final bool isPrivate;
  final String? avatarUrl;
  final String? bannerUrl;
  final String? keeperId;
  final String? keeperPseudonym;
  final String? keeperAvatarSeed;
  final bool keeperIsVerified;
  final DateTime createdAt;
  final bool joinedByMe;

  // Studio additions (migration 0028)
  final String? welcomeMessage;
  final String? themeColor;
  final String? spotlightUserId;
  final String? spotlightPseudonym;
  final String? spotlightAvatarSeed;
  final String? spotlightNote;
  final DateTime? spotlightSetAt;

  // Plug dashboard additions (migration 0049)
  final String? rules;
  final bool isPremium;

  /// Group chat settings (migration 0063).
  final TribeChatSettings chatSettings;

  /// Pinned group-chat message (migration 0064).
  final String? pinnedMessageId;

  const Tribe({
    required this.tribeId,
    required this.name,
    required this.slug,
    required this.category,
    required this.memberCount,
    required this.isPrivate,
    required this.createdAt,
    this.description,
    this.avatarUrl,
    this.bannerUrl,
    this.keeperId,
    this.keeperPseudonym,
    this.keeperAvatarSeed,
    this.keeperIsVerified = false,
    this.joinedByMe = false,
    this.welcomeMessage,
    this.themeColor,
    this.spotlightUserId,
    this.spotlightPseudonym,
    this.spotlightAvatarSeed,
    this.spotlightNote,
    this.spotlightSetAt,
    this.rules,
    this.isPremium = false,
    this.chatSettings = const TribeChatSettings(),
    this.pinnedMessageId,
  });

  Tribe copyWith({
    int? memberCount,
    bool? joinedByMe,
    String? avatarUrl,
    String? bannerUrl,
    String? welcomeMessage,
    String? themeColor,
  }) {
    return Tribe(
      tribeId: tribeId,
      name: name,
      slug: slug,
      description: description,
      category: category,
      memberCount: memberCount ?? this.memberCount,
      isPrivate: isPrivate,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      bannerUrl: bannerUrl ?? this.bannerUrl,
      keeperId: keeperId,
      keeperPseudonym: keeperPseudonym,
      keeperAvatarSeed: keeperAvatarSeed,
      keeperIsVerified: keeperIsVerified,
      createdAt: createdAt,
      joinedByMe: joinedByMe ?? this.joinedByMe,
      welcomeMessage: welcomeMessage ?? this.welcomeMessage,
      themeColor: themeColor ?? this.themeColor,
      spotlightUserId: spotlightUserId,
      spotlightPseudonym: spotlightPseudonym,
      spotlightAvatarSeed: spotlightAvatarSeed,
      spotlightNote: spotlightNote,
      spotlightSetAt: spotlightSetAt,
      rules: rules,
      isPremium: isPremium,
      chatSettings: chatSettings,
    );
  }
}

/// A Space — focused conversation room inside a Tribe.
///
/// Tribes used to be one big feed; that doesn't scale socially.
/// A Tribe is now a building of Spaces, each a living, scoped
/// discussion ("Anxiety Check-in", "Weekly Wins", "Midnight
/// Vents"). Every Vent lives in a Space, never directly in the
/// Tribe. See `supabase/migrations/0050_spaces_emotional_communities.sql`.
class Space {
  final String spaceId;
  final String tribeId;
  final String tribeSlug;
  final String tribeName;
  final String slug;
  final String name;
  final String? description;
  final String? weeklyTheme;
  final String? themeColor;
  final bool isDefault;
  final DateTime? archivedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int ventCount;
  final int ventsToday;
  final DateTime? lastVentAt;

  const Space({
    required this.spaceId,
    required this.tribeId,
    required this.tribeSlug,
    required this.tribeName,
    required this.slug,
    required this.name,
    required this.isDefault,
    required this.createdAt,
    required this.updatedAt,
    required this.ventCount,
    required this.ventsToday,
    this.description,
    this.weeklyTheme,
    this.themeColor,
    this.archivedAt,
    this.lastVentAt,
  });

  bool get isArchived => archivedAt != null;
}

/// AI Space Assistant daily digest (migration 0053).
class SpaceSummary {
  final String summaryId;
  final String spaceId;
  final DateTime forDate;
  final String summary;
  final List<String> topTopics;
  final String suggestedPrompt;
  final int ventsAnalyzed;
  final String? model;
  final DateTime? generatedAt;
  const SpaceSummary({
    required this.summaryId,
    required this.spaceId,
    required this.forDate,
    required this.summary,
    required this.topTopics,
    required this.suggestedPrompt,
    required this.ventsAnalyzed,
    this.model,
    this.generatedAt,
  });
  bool get isFresh =>
      generatedAt != null &&
      DateTime.now().difference(generatedAt!).inHours < 36;
}

/// Aggregated metrics for the Plugz Creator Studio dashboard.
/// One round-trip read from `tribe_studio_stats` view (migration 0028).
class TribeStudioStats {
  final String tribeId;
  final int memberCount;
  final int members7d;
  final int members30d;
  final int posts24h;
  final int posts7d;
  final int comments7d;
  final int activePosters7d;
  final int pinnedCount;
  final int scheduledPrompts;
  final int openReports;

  const TribeStudioStats({
    required this.tribeId,
    required this.memberCount,
    required this.members7d,
    required this.members30d,
    required this.posts24h,
    required this.posts7d,
    required this.comments7d,
    required this.activePosters7d,
    required this.pinnedCount,
    required this.scheduledPrompts,
    required this.openReports,
  });
}

/// A keeper-curated scheduled prompt for a tribe.
class ScheduledPrompt {
  final String promptId;
  final String tribeId;
  final String text;
  final DateTime? scheduledFor;
  final DateTime? publishedAt;
  final int answersCount;
  final bool isActive;

  const ScheduledPrompt({
    required this.promptId,
    required this.tribeId,
    required this.text,
    required this.answersCount,
    required this.isActive,
    this.scheduledFor,
    this.publishedAt,
  });

  bool get isLive => publishedAt != null;
  bool get isFuture =>
      scheduledFor != null && scheduledFor!.isAfter(DateTime.now());
}

class Post {
  final String postId;
  /// Stable author identity. Always present, but the UI should treat it
  /// as opaque — never display the raw UUID. Used by the friend-action
  /// chip and report flows to identify the author.
  final String? authorId;
  final String authorPseudonym;
  final String authorAvatarSeed;
  final String? authorProfilePhotoUrl;
  final bool authorIsVerified;
  final int authorKarma;
  final String? tribeId;
  final String? tribeName;
  final String? tribeSlug;
  final String? spaceId;
  final String categoryName;
  final String postType; // user_post | plug_prompt
  final String content;
  final String postMood;
  final bool isWhisper;
  final int likesCount;
  final int commentsCount;
  final int viewCount;
  /// Optional attached image URL (post-media bucket, public). Drives the
  /// rounded image card on the feed.
  final String? imageUrl;
  /// Optional attached voice-note URL (post-media bucket, public). Drives
  /// the waveform playback card on the feed.
  final String? audioUrl;
  final int? audioDurationSeconds;
  final DateTime createdAt;
  /// Author-only edit timestamp (migration 0047). Drives the "(edited)"
  /// footer on the post detail screen + feed card.
  final DateTime? editedAt;
  /// Soft-delete marker. When set, the feed/card renders a tombstone
  /// "Vent removed by author" instead of the body.
  final DateTime? deletedAt;
  /// Author-only lock on new replies (migration 0051). When set the
  /// thread renders read-only with a "comments locked" footer.
  final DateTime? lockedAt;
  /// Keeper-only highlight (migration 0051). Drives the Keeper's Pick
  /// chip on the card and the Keeper Picks smart sort in a Space.
  final bool isKeeperPick;
  final DateTime? keeperPickAt;
  final String? myReaction; // null | hug | love | strong | hope | pray | felt | proud
  final bool savedByMe;
  /// Null when the safety classifier saw nothing concerning. `'elevated'` for
  /// Tier-2 (LLM) self-harm matches, `'high'` for Tier-1 keyword hits. Drives
  /// the helpline banner on the post detail screen.
  final String? crisisLevel;
  /// Media safety verdict (migration 0087): 'clean' | 'pending' | 'sensitive' |
  /// 'blocked'. 'blocked' posts are soft-deleted server-side and never arrive.
  /// The feed veils the image for 'pending'/'sensitive'.
  final String mediaStatus;
  bool get mediaNeedsVeil =>
      hasImage && (mediaStatus == 'pending' || mediaStatus == 'sensitive');

  const Post({
    required this.postId,
    required this.authorPseudonym,
    required this.authorAvatarSeed,
    required this.categoryName,
    required this.postType,
    required this.content,
    required this.postMood,
    required this.likesCount,
    required this.commentsCount,
    required this.createdAt,
    this.authorId,
    this.authorProfilePhotoUrl,
    this.authorIsVerified = false,
    this.authorKarma = 0,
    this.tribeId,
    this.tribeName,
    this.tribeSlug,
    this.spaceId,
    this.isWhisper = false,
    this.viewCount = 0,
    this.imageUrl,
    this.audioUrl,
    this.audioDurationSeconds,
    this.editedAt,
    this.deletedAt,
    this.lockedAt,
    this.isKeeperPick = false,
    this.keeperPickAt,
    this.myReaction,
    this.savedByMe = false,
    this.crisisLevel,
    this.mediaStatus = 'clean',
  });

  bool get hasImage => imageUrl != null && imageUrl!.isNotEmpty;
  bool get hasAudio => audioUrl != null && audioUrl!.isNotEmpty;
  bool get isDeleted => deletedAt != null;
  bool get isEdited  => editedAt  != null;
  bool get isLocked  => lockedAt  != null;
  bool ownedBy(String? userId) => authorId != null && authorId == userId;

  /// True when the caller has any reaction on this post.
  bool get likedByMe => myReaction != null;

  /// Whispers expire 24h after creation.
  Duration get whisperRemaining {
    if (!isWhisper) return Duration.zero;
    final expiresAt = createdAt.add(const Duration(hours: 24));
    final left = expiresAt.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  Post copyWith({
    int? likesCount,
    int? commentsCount,
    int? viewCount,
    Object? myReaction = _unset,
    bool? savedByMe,
    Object? crisisLevel = _unset,
    String? content,
    DateTime? editedAt,
    DateTime? deletedAt,
  }) {
    return Post(
      postId: postId,
      authorId: authorId,
      authorPseudonym: authorPseudonym,
      authorAvatarSeed: authorAvatarSeed,
      authorProfilePhotoUrl: authorProfilePhotoUrl,
      authorIsVerified: authorIsVerified,
      authorKarma: authorKarma,
      categoryName: categoryName,
      postType: postType,
      content: content ?? this.content,
      postMood: postMood,
      isWhisper: isWhisper,
      viewCount: viewCount ?? this.viewCount,
      imageUrl: imageUrl,
      audioUrl: audioUrl,
      audioDurationSeconds: audioDurationSeconds,
      editedAt: editedAt ?? this.editedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      lockedAt: lockedAt,
      isKeeperPick: isKeeperPick,
      keeperPickAt: keeperPickAt,
      likesCount: likesCount ?? this.likesCount,
      commentsCount: commentsCount ?? this.commentsCount,
      createdAt: createdAt,
      tribeId: tribeId,
      tribeName: tribeName,
      tribeSlug: tribeSlug,
      spaceId: spaceId,
      myReaction:
          myReaction == _unset ? this.myReaction : myReaction as String?,
      savedByMe: savedByMe ?? this.savedByMe,
      crisisLevel:
          crisisLevel == _unset ? this.crisisLevel : crisisLevel as String?,
      mediaStatus: mediaStatus,
    );
  }

  static const Object _unset = Object();
}

/// Static catalogue of the six emotion reactions. Kept in sync with the
/// `reaction_type` enum in Postgres (migration 0016).
/// The seven Venttly reactions (migration 0052).
///
/// These replaced the original generic six (like / relate / hug /
/// stay_strong / been_there / crazy). The new vocabulary is
/// emotional-first — every reaction is a thing one human says to
/// another at a hard moment, not a Facebook button.
class PostReactions {
  static const List<String> all = [
    'hug', 'love', 'strong', 'hope', 'pray', 'felt', 'proud',
  ];

  static String emoji(String key) {
    switch (key) {
      case 'hug':    return '\u{1FAC2}';                  // 🫂
      case 'love':   return '\u{2764}\u{FE0F}';           // ❤️
      case 'strong': return '\u{1F4AA}';                  // 💪
      case 'hope':   return '\u{1F331}';                  // 🌱
      case 'pray':   return '\u{1F64F}';                  // 🙏
      case 'felt':   return '\u{1F97A}';                  // 🥺
      case 'proud':  return '\u{1F44F}';                  // 👏
      default:       return '\u{2764}\u{FE0F}';
    }
  }

  static String label(String key) {
    switch (key) {
      case 'hug':    return 'I Relate';
      case 'love':   return 'Sending Love';
      case 'strong': return 'Stay Strong';
      case 'hope':   return 'Hope';
      case 'pray':   return 'Praying';
      case 'felt':   return 'Felt This';
      case 'proud':  return 'Proud of You';
      default:       return key;
    }
  }
}

/// A crisis helpline row sourced from the DB-backed `crisis_resources` table.
/// Distinct from the legacy hard-coded list in moderation_service.dart so the
/// founder can edit/expand resources without an app push.
class CrisisHelpline {
  final String resourceId;
  final String region; // 'global' | ISO country code
  final String label;
  final String reach;
  final String? url;
  final String hours;
  final int sortOrder;

  const CrisisHelpline({
    required this.resourceId,
    required this.region,
    required this.label,
    required this.reach,
    required this.hours,
    required this.sortOrder,
    this.url,
  });
}

/// A staff-managed automod keyword rule (migration 0085). Loaded by the
/// on-device safety classifier to extend its built-in keyword lists without
/// shipping an app update.
class AutomodRule {
  final String pattern;
  final String matchType; // 'contains' | 'word' | 'regex'
  final String category;  // maps to HazardCategory
  final String action;    // 'flag' | 'block' | 'crisis'

  const AutomodRule({
    required this.pattern,
    required this.matchType,
    required this.category,
    required this.action,
  });
}

class Persona {
  final String personaId;
  final String pseudonym;
  final String avatarSeed;
  final String? bio;
  final DateTime createdAt;

  const Persona({
    required this.personaId,
    required this.pseudonym,
    required this.avatarSeed,
    required this.createdAt,
    this.bio,
  });
}

class ThreadedComment {
  final String commentId;
  final String? parentId;
  final String? authorId;
  final String authorPseudonym;
  final String authorAvatarSeed;
  final String? authorProfilePhotoUrl;
  final String content;
  /// Migration 0102 — optional photo / GIF attached to the reply.
  final String? imageUrl;
  final String path;
  final int depth;
  final int likesCount;
  final bool likedByMe;
  final DateTime createdAt;
  /// Migration 0047 — author-only edit timestamp.
  final DateTime? editedAt;
  /// Soft-delete marker. UI renders a tombstone when set.
  final DateTime? deletedAt;
  /// Migration 0051 — set when the vent's author pinned this comment.
  /// Pinned comments render above the chronological thread.
  final DateTime? pinnedAt;
  final List<ThreadedComment> children;

  ThreadedComment({
    required this.commentId,
    required this.authorPseudonym,
    required this.authorAvatarSeed,
    required this.content,
    required this.path,
    required this.depth,
    required this.likesCount,
    required this.createdAt,
    this.authorId,
    this.authorProfilePhotoUrl,
    this.parentId,
    this.imageUrl,
    this.likedByMe = false,
    this.editedAt,
    this.deletedAt,
    this.pinnedAt,
    List<ThreadedComment>? children,
  }) : children = children ?? <ThreadedComment>[];

  bool get isDeleted => deletedAt != null;
  bool get isEdited  => editedAt  != null;
  bool get isPinned  => pinnedAt  != null;
  bool ownedBy(String? uid) => authorId != null && authorId == uid;

  ThreadedComment copyWith({
    int? likesCount,
    bool? likedByMe,
    String? content,
    DateTime? editedAt,
    DateTime? deletedAt,
    DateTime? pinnedAt,
  }) {
    return ThreadedComment(
      commentId: commentId,
      parentId: parentId,
      authorId: authorId,
      authorPseudonym: authorPseudonym,
      authorAvatarSeed: authorAvatarSeed,
      authorProfilePhotoUrl: authorProfilePhotoUrl,
      content: content ?? this.content,
      imageUrl: imageUrl,
      path: path,
      depth: depth,
      likesCount: likesCount ?? this.likesCount,
      likedByMe: likedByMe ?? this.likedByMe,
      editedAt: editedAt ?? this.editedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      pinnedAt: pinnedAt ?? this.pinnedAt,
      createdAt: createdAt,
      children: children,
    );
  }
}

class ChatRoom {
  final String roomId;
  final String peerPseudonym;
  final String peerAvatarSeed;
  /// The peer's user id (from inbox_rooms.peer_id) — for opening their profile.
  final String? peerUserId;
  final String requestPreview;
  final String roomStatus; // pending_request | active | declined | blocked
  final DateTime createdAt;
  final bool initiatedByMe;

  /// Unread peer messages in this room (from inbox_rooms view).
  final int unreadCount;

  /// Latest message preview for active rooms.
  final String? lastMessagePreview;

  /// Timestamp of the latest message, or null when the room is empty.
  final DateTime? lastMessageAt;

  /// Whether the caller's most recent message has been read by the peer.
  final bool lastOwnMessageRead;

  const ChatRoom({
    required this.roomId,
    required this.peerPseudonym,
    required this.peerAvatarSeed,
    required this.requestPreview,
    required this.roomStatus,
    required this.createdAt,
    required this.initiatedByMe,
    this.peerUserId,
    this.unreadCount = 0,
    this.lastMessagePreview,
    this.lastMessageAt,
    this.lastOwnMessageRead = false,
  });
}

class ChatMessage {
  final String messageId;
  final String roomId;
  final String senderId;
  final String plaintext; // stored server-side as plaintext for moderation review.
  final DateTime createdAt;
  final bool sentByMe;

  /// Quoted-reply pointer + lightweight snapshot for inline rendering
  /// (Chat V2). The snapshot lets the UI render the quoted text even
  /// if the parent has since been deleted.
  final String? parentMessageId;
  final String? parentPreview;
  final String? parentSenderPseudonym;

  /// Author-only edit timestamp. Drives the "(edited)" footer.
  final DateTime? editedAt;

  /// Soft-delete marker. When set, the bubble renders as a tombstone.
  final DateTime? deletedAt;

  /// When set, this message carries a shared post. The snapshot is
  /// authoritative — the original may have been soft-deleted later, but
  /// the conversation can still render the card from the snapshot.
  final String? attachedPostId;
  final SharedPostSnapshot? attachedPostSnapshot;

  /// When the recipient marked this message as read. Stamped by the
  /// mark_chat_room_read RPC on every screen-open / new-message arrival
  /// for messages the caller didn't send.
  final DateTime? readAt;

  /// Per-reaction tallies from chat_message_reactions_summary. Empty
  /// map = no reactions. Keys are the same six values as PostReactions.
  final Map<String, int> reactionCounts;

  /// The caller's own reaction on this message, if any.
  final String? myReaction;

  /// Supabase Storage path of an attached image, e.g. `<room>/<msg>.jpg`.
  /// Read via short-lived signed URL — bucket is private.
  final String? attachedMediaPath;

  /// Currently always 'image' when [attachedMediaPath] is set. Reserved
  /// for future media types if/when voice is unlocked.
  final String? attachedMediaType;

  const ChatMessage({
    required this.messageId,
    required this.roomId,
    required this.senderId,
    required this.plaintext,
    required this.createdAt,
    required this.sentByMe,
    this.attachedPostId,
    this.attachedPostSnapshot,
    this.readAt,
    this.reactionCounts = const {},
    this.myReaction,
    this.attachedMediaPath,
    this.attachedMediaType,
    this.parentMessageId,
    this.parentPreview,
    this.parentSenderPseudonym,
    this.editedAt,
    this.deletedAt,
  });

  bool get isDeleted => deletedAt != null;
  bool get isEdited  => editedAt  != null;

  /// WhatsApp-style windows, mirrored by the server RPCs. Editing is
  /// allowed for 30 min after sending; "delete for everyone" for 24h.
  /// Both apply only to your own, not-yet-deleted messages.
  static const editWindow = Duration(minutes: 30);
  static const deleteForEveryoneWindow = Duration(hours: 24);

  bool get canEdit =>
      sentByMe &&
      !isDeleted &&
      DateTime.now().difference(createdAt) <= editWindow;
  bool get canDeleteForEveryone =>
      sentByMe &&
      !isDeleted &&
      DateTime.now().difference(createdAt) <= deleteForEveryoneWindow;

  ChatMessage copyWith({
    Map<String, int>? reactionCounts,
    Object? myReaction = _unsetReaction,
    String? plaintext,
    DateTime? editedAt,
    DateTime? deletedAt,
    String? parentPreview,
    String? parentSenderPseudonym,
  }) {
    return ChatMessage(
      messageId: messageId,
      roomId: roomId,
      senderId: senderId,
      plaintext: plaintext ?? this.plaintext,
      createdAt: createdAt,
      sentByMe: sentByMe,
      attachedPostId: attachedPostId,
      attachedPostSnapshot: attachedPostSnapshot,
      readAt: readAt,
      reactionCounts: reactionCounts ?? this.reactionCounts,
      myReaction: myReaction == _unsetReaction
          ? this.myReaction
          : myReaction as String?,
      attachedMediaPath: attachedMediaPath,
      attachedMediaType: attachedMediaType,
      parentMessageId: parentMessageId,
      parentPreview: parentPreview ?? this.parentPreview,
      parentSenderPseudonym:
          parentSenderPseudonym ?? this.parentSenderPseudonym,
      editedAt: editedAt ?? this.editedAt,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }

  bool get hasAttachedMedia => attachedMediaPath != null;

  bool get hasAttachedPost => attachedPostSnapshot != null;

  static const Object _unsetReaction = Object();
}

/// Captured at the moment a friend shared a post into a chat. Survives
/// the original being deleted, expired (whispers), or moved private.
class SharedPostSnapshot {
  final String postId;
  final String content;
  final String? authorPseudonym;
  final String? authorAvatarSeed;
  final String? category;
  final String? mood;
  final bool isWhisper;
  final DateTime createdAt;

  const SharedPostSnapshot({
    required this.postId,
    required this.content,
    required this.createdAt,
    this.authorPseudonym,
    this.authorAvatarSeed,
    this.category,
    this.mood,
    this.isWhisper = false,
  });

  static SharedPostSnapshot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<String, dynamic>();
    final postId = m['post_id'] as String?;
    if (postId == null) return null;
    return SharedPostSnapshot(
      postId: postId,
      content: (m['content'] as String?) ?? '',
      authorPseudonym: m['author_pseudonym'] as String?,
      authorAvatarSeed: m['author_avatar_seed'] as String?,
      category: m['category'] as String?,
      mood: m['mood'] as String?,
      isWhisper: (m['is_whisper'] as bool?) ?? false,
      createdAt: DateTime.parse(m['created_at'] as String),
    );
  }
}

/// A two-option (or more) poll attached to a Post.
///
/// `myVoteOptionId` is null when the viewer hasn't voted yet. `optionCounts`
/// is keyed by option_id and counts unique votes — the schema enforces one
/// vote per (poll_id, user_id) so the counts are accurate by construction.
class PostPoll {
  final String pollId;
  final String postId;
  final String question;
  final DateTime closesAt;
  final List<PollOption> options;
  final Map<String, int> optionCounts;
  final String? myVoteOptionId;

  const PostPoll({
    required this.pollId,
    required this.postId,
    required this.question,
    required this.closesAt,
    required this.options,
    required this.optionCounts,
    this.myVoteOptionId,
  });

  int get totalVotes =>
      optionCounts.values.fold(0, (a, b) => a + b);

  bool get isClosed => DateTime.now().isAfter(closesAt);
  bool get hasVoted => myVoteOptionId != null;
}

class PollOption {
  final String optionId;
  final String text;
  const PollOption({required this.optionId, required this.text});
}

class PromptAnswer {
  final String answerId;
  final String promptId;
  final String authorPseudonym;
  final String authorAvatarSeed;
  final String text;
  final DateTime createdAt;

  const PromptAnswer({
    required this.answerId,
    required this.promptId,
    required this.authorPseudonym,
    required this.authorAvatarSeed,
    required this.text,
    required this.createdAt,
  });
}

class PlugPrompt {
  final String promptId;
  final String plugDisplayName;
  final String plugAvatarSeed;
  final String promptText;
  final int answersCount;

  const PlugPrompt({
    required this.promptId,
    required this.plugDisplayName,
    required this.plugAvatarSeed,
    required this.promptText,
    required this.answersCount,
  });
}

/// A keeper-issued invitation to join a Tribe. Lifecycle:
/// pending → accepted (joins the tribe) | declined.
class TribeInvite {
  final String inviteId;
  final String tribeId;
  final String tribeName;
  final String? tribeSlug;
  final String? tribeAvatarUrl;
  final String invitedUserId;
  final String? invitedByPseudonym;
  final String? message;
  final String status; // pending | accepted | declined
  final DateTime createdAt;

  const TribeInvite({
    required this.inviteId,
    required this.tribeId,
    required this.tribeName,
    required this.invitedUserId,
    required this.status,
    required this.createdAt,
    this.tribeSlug,
    this.tribeAvatarUrl,
    this.invitedByPseudonym,
    this.message,
  });

  bool get isPending => status == 'pending';
}

/// A report filed against a single post — surfaced to the Tribe Keeper via
/// the manage dashboard. Mirrors `reports JOIN posts` from migration 0008.
class TribeReport {
  final String reportId;
  final String reason;
  final String? note;
  final bool isResolved;
  final DateTime createdAt;
  final String postId;
  final String postPreview;
  final bool postDeleted;

  const TribeReport({
    required this.reportId,
    required this.reason,
    required this.isResolved,
    required this.createdAt,
    required this.postId,
    required this.postPreview,
    required this.postDeleted,
    this.note,
  });

  String get reasonLabel {
    switch (reason) {
      case 'self_harm':      return 'Self-harm concern';
      case 'hate':           return 'Hate speech';
      case 'harassment':     return 'Harassment';
      case 'sexual_content': return 'Sexual content';
      case 'violence':       return 'Violence';
      case 'privacy':        return 'Privacy / doxxing';
      case 'spam':           return 'Spam';
      default:               return 'Other';
    }
  }
}

class NotificationItem {
  final String id;
  final String kind;
  final String title;
  final String body;
  final DateTime createdAt;
  final bool isRead;

  /// Raw payload from the DB row. Tile renderers read kind-specific
  /// fields out of here (e.g. tribe_slug + prompt_id for tribe_prompt
  /// from migration 0036) so the screen can route on tap without a
  /// second fetch.
  final Map<String, dynamic> payload;

  const NotificationItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.isRead,
    this.payload = const {},
  });
}

/// Friend graph state between the current user and a target user. Used
/// by the friend-action button on any screen that surfaces a stranger.
/// Mirrors the `friend_status` SQL RPC (migration 0024).
enum FriendStatus {
  /// You are looking at yourself — no action.
  self,

  /// No edge, no block. The friend-action chip shows "Add friend".
  none,

  /// You sent a request, awaiting acceptance. Chip shows "Requested".
  pendingOutgoing,

  /// They sent you a request. Chip shows "Accept · Decline".
  pendingIncoming,

  /// Accepted in both directions. Chip shows "Friends".
  friends,

  /// You blocked them. Chip shows "Blocked".
  blockedByMe,

  /// They blocked you. UI hides the friend chip entirely; this user
  /// shouldn't normally appear in your feed at all.
  blockedMe;

  static FriendStatus parse(String? raw) => switch (raw) {
        'self' => FriendStatus.self,
        'friends' => FriendStatus.friends,
        'pending_outgoing' => FriendStatus.pendingOutgoing,
        'pending_incoming' => FriendStatus.pendingIncoming,
        'blocked_by_me' => FriendStatus.blockedByMe,
        'blocked_me' => FriendStatus.blockedMe,
        _ => FriendStatus.none,
      };
}

/// A friend (from the `my_friends` view).
class FriendSummary {
  final String friendshipId;
  final String userId;
  final String pseudonym;
  final String avatarSeed;
  final int karma;
  final bool isVerified;
  final DateTime acceptedAt;
  final bool isFavorite;
  final String? profilePhotoUrl;

  const FriendSummary({
    required this.friendshipId,
    required this.userId,
    required this.pseudonym,
    required this.avatarSeed,
    required this.karma,
    required this.isVerified,
    required this.acceptedAt,
    this.isFavorite = false,
    this.profilePhotoUrl,
  });

  FriendSummary copyWith({bool? isFavorite}) {
    return FriendSummary(
      friendshipId: friendshipId,
      userId: userId,
      pseudonym: pseudonym,
      avatarSeed: avatarSeed,
      karma: karma,
      isVerified: isVerified,
      acceptedAt: acceptedAt,
      isFavorite: isFavorite ?? this.isFavorite,
      profilePhotoUrl: profilePhotoUrl,
    );
  }
}

/// One Whisper — anonymous voice story. Returned by `whispers_feed`.
class Whisper {
  final String whisperId;
  final String? authorId;
  final String authorPseudonym;
  final String authorAvatarSeed;
  final String? authorProfilePhotoUrl;
  final bool authorIsVerified;
  final String audioUrl;
  final int audioDurationSeconds;
  final String? backgroundImageUrl;
  final String voiceFilter;
  final String category;
  final String? title;
  final String? description;
  final int playsCount;
  final int likesCount;
  final int commentsCount;
  final String? crisisLevel;
  final DateTime createdAt;
  /// Migration 0047 — author-only edit timestamp on title/description.
  final DateTime? editedAt;
  /// Soft-delete marker.
  final DateTime? deletedAt;
  final bool likedByMe;
  final bool savedByMe;

  /// Per-reaction tallies (migration 0061). Keys match [PostReactions.all].
  final Map<String, int> reactionCounts;

  /// Caller's current reaction, if any.
  final String? myReaction;

  /// Media safety verdict for the background image (migration 0087/0089):
  /// 'clean' | 'pending' | 'sensitive' | 'blocked'. Blocked whispers are
  /// soft-deleted server-side and never arrive; the UI veils the background
  /// for 'pending'/'sensitive'.
  final String mediaStatus;
  bool get hasBackgroundImage =>
      backgroundImageUrl != null && backgroundImageUrl!.isNotEmpty;
  bool get mediaNeedsVeil =>
      hasBackgroundImage &&
      (mediaStatus == 'pending' || mediaStatus == 'sensitive');

  const Whisper({
    required this.whisperId,
    required this.authorPseudonym,
    required this.authorAvatarSeed,
    required this.audioUrl,
    required this.audioDurationSeconds,
    required this.voiceFilter,
    required this.category,
    required this.playsCount,
    required this.likesCount,
    required this.commentsCount,
    required this.createdAt,
    this.authorId,
    this.authorProfilePhotoUrl,
    this.authorIsVerified = false,
    this.backgroundImageUrl,
    this.title,
    this.description,
    this.crisisLevel,
    this.editedAt,
    this.deletedAt,
    this.likedByMe = false,
    this.savedByMe = false,
    this.reactionCounts = const {},
    this.myReaction,
    this.mediaStatus = 'clean',
  });

  bool get isDeleted => deletedAt != null;
  bool get isEdited  => editedAt  != null;
  bool ownedBy(String? uid) => authorId != null && authorId == uid;

  static const Object _unset = Object();

  Whisper copyWith({
    int? likesCount,
    bool? likedByMe,
    bool? savedByMe,
    Map<String, int>? reactionCounts,
    Object? myReaction = _unset,
    String? title,
    String? description,
    DateTime? editedAt,
    DateTime? deletedAt,
  }) =>
      Whisper(
        whisperId: whisperId,
        authorId: authorId,
        authorPseudonym: authorPseudonym,
        authorAvatarSeed: authorAvatarSeed,
        authorProfilePhotoUrl: authorProfilePhotoUrl,
        authorIsVerified: authorIsVerified,
        audioUrl: audioUrl,
        audioDurationSeconds: audioDurationSeconds,
        backgroundImageUrl: backgroundImageUrl,
        voiceFilter: voiceFilter,
        category: category,
        title: title ?? this.title,
        description: description ?? this.description,
        playsCount: playsCount,
        likesCount: likesCount ?? this.likesCount,
        commentsCount: commentsCount,
        crisisLevel: crisisLevel,
        editedAt: editedAt ?? this.editedAt,
        deletedAt: deletedAt ?? this.deletedAt,
        createdAt: createdAt,
        likedByMe: likedByMe ?? this.likedByMe,
        savedByMe: savedByMe ?? this.savedByMe,
        reactionCounts: reactionCounts ?? this.reactionCounts,
        myReaction: myReaction == _unset
            ? this.myReaction
            : myReaction as String?,
        mediaStatus: mediaStatus,
      );
}

/// A comment on an audio Whisper.
class WhisperComment {
  final String commentId;
  final String whisperId;
  final String? authorId;
  final String authorPseudonym;
  final String authorAvatarSeed;
  final String content;
  final DateTime createdAt;

  const WhisperComment({
    required this.commentId,
    required this.whisperId,
    required this.authorPseudonym,
    required this.authorAvatarSeed,
    required this.content,
    required this.createdAt,
    this.authorId,
  });
}

/// Catalogue of available voice filters — labels for the picker on the
/// create-whisper screen. DSP processing ships separately.
class WhisperVoiceFilters {
  static const List<String> all = [
    'none', 'anonymous', 'soft', 'deep_voice', 'robot', 'echo', 'synth', 'dark',
  ];

  static String label(String key) {
    switch (key) {
      case 'none':       return 'Original';
      case 'anonymous':  return 'Anonymous';
      case 'soft':       return 'Soft';
      case 'deep_voice': return 'Deep';
      case 'robot':      return 'Robot';
      case 'echo':       return 'Echo';
      case 'synth':      return 'Synth';
      case 'dark':       return 'Dark';
      default:           return key;
    }
  }
}

/// One keeper-managed keyword filter. Posts/messages containing the
/// keyword get queued for keeper review (when severity=='soft') or
/// hard-blocked at send (severity=='hard').
class TribeKeywordFilter {
  final String filterId;
  final String tribeId;
  final String keyword;
  final String severity; // 'soft' | 'hard'
  final DateTime createdAt;
  const TribeKeywordFilter({
    required this.filterId,
    required this.tribeId,
    required this.keyword,
    required this.severity,
    required this.createdAt,
  });
}

/// One soft warning issued to a tribe member.
class TribeMemberWarning {
  final String warningId;
  final String tribeId;
  final String memberId;
  final String memberPseudonym;
  final String memberAvatarSeed;
  final String reason;
  final String severity; // 'note' | 'warning' | 'final'
  final DateTime createdAt;
  final DateTime? acknowledgedAt;
  const TribeMemberWarning({
    required this.warningId,
    required this.tribeId,
    required this.memberId,
    required this.memberPseudonym,
    required this.memberAvatarSeed,
    required this.reason,
    required this.severity,
    required this.createdAt,
    this.acknowledgedAt,
  });
}

/// One row from `tribe_messages_feed`. Group-chat messages are
/// tribe-scoped and gated by membership in RLS.
class TribeMessage {
  final String messageId;
  final String tribeId;
  final String? senderId;
  final String senderPseudonym;
  final String senderAvatarSeed;
  final String? senderProfilePhotoUrl;
  final String? senderPersonaId;
  final String? content;
  final String? imageUrl;
  final String? audioUrl;
  final int? audioDurationSeconds;
  final int hugsCount;
  final DateTime createdAt;
  final DateTime? editedAt;
  /// Migration 0047 — soft-delete marker. UI renders a tombstone.
  final DateTime? deletedAt;
  final bool sentByMe;
  final String? replyToMessageId;
  final String? replyContent;
  final String? replySenderPseudonym;
  final bool huggedByMe;
  final bool isPinned;
  /// Poll / question cards — migration 0065.
  final Map<String, dynamic>? metadata;
  final String? pollMyVoteOptionId;
  final Map<String, int>? pollOptionCounts;
  final String? myReaction;
  final Map<String, int>? reactionCounts;
  final int questionReplyCount;

  const TribeMessage({
    required this.messageId,
    required this.tribeId,
    required this.senderPseudonym,
    required this.senderAvatarSeed,
    required this.createdAt,
    required this.sentByMe,
    this.senderId,
    this.senderProfilePhotoUrl,
    this.senderPersonaId,
    this.content,
    this.imageUrl,
    this.audioUrl,
    this.audioDurationSeconds,
    this.hugsCount = 0,
    this.editedAt,
    this.deletedAt,
    this.replyToMessageId,
    this.replyContent,
    this.replySenderPseudonym,
    this.huggedByMe = false,
    this.isPinned = false,
    this.metadata,
    this.pollMyVoteOptionId,
    this.pollOptionCounts,
    this.myReaction,
    this.reactionCounts,
    this.questionReplyCount = 0,
  });

  bool get isDeleted => deletedAt != null;
  bool get isEdited  => editedAt  != null;
  bool get hasImage => imageUrl != null && imageUrl!.isNotEmpty;
  bool get hasAudio => audioUrl != null && audioUrl!.isNotEmpty;
  bool get hasText => content != null && content!.trim().isNotEmpty;

  /// WhatsApp-style windows, mirrored by the server RPCs — 30 min to edit,
  /// 24h to delete-for-everyone. Editing is limited to plain-text messages
  /// you sent (not polls/questions/media).
  static const editWindow = Duration(minutes: 30);
  static const deleteForEveryoneWindow = Duration(hours: 24);

  bool get canEdit =>
      sentByMe &&
      !isDeleted &&
      hasText &&
      !hasRichCard &&
      DateTime.now().difference(createdAt) <= editWindow;
  bool get canDeleteForEveryone =>
      sentByMe &&
      !isDeleted &&
      DateTime.now().difference(createdAt) <= deleteForEveryoneWindow;

  bool get isPoll => metadata?['kind'] == 'poll';
  bool get isQuestion => metadata?['kind'] == 'question';
  bool get hasRichCard => isPoll || isQuestion;
}

/// One row from `friend_suggestions` — a mutual-tribe acquaintance the
/// caller could add. Drives the Quick Suggestions strip on the Friends
/// screen.
class FriendSuggestion {
  final String userId;
  final String pseudonym;
  final String avatarSeed;
  final String? profilePhotoUrl;
  final bool isVerified;
  final int sharedTribes;
  final String rationale;

  const FriendSuggestion({
    required this.userId,
    required this.pseudonym,
    required this.avatarSeed,
    required this.isVerified,
    required this.sharedTribes,
    required this.rationale,
    this.profilePhotoUrl,
  });
}

/// A pending friend request (incoming or outgoing).
class FriendRequest {
  final String friendshipId;
  final String otherUserId;
  final String otherPseudonym;
  final String otherAvatarSeed;
  final int otherKarma;
  final String? note;
  final DateTime createdAt;

  /// True when the current user initiated the request (outgoing).
  /// False when they are the recipient awaiting their own decision.
  final bool isOutgoing;

  const FriendRequest({
    required this.friendshipId,
    required this.otherUserId,
    required this.otherPseudonym,
    required this.otherAvatarSeed,
    required this.otherKarma,
    required this.createdAt,
    required this.isOutgoing,
    this.note,
  });
}

/// One mood bucket in the friend-profile distribution.
class MoodCount {
  final String mood;
  final int count;
  const MoodCount({required this.mood, required this.count});
}

/// One day in a friend's 90-day activity heatmap. Count = authored
/// posts + comments that day.
class ActivityHeatmapDay {
  final DateTime day;
  final int count;
  const ActivityHeatmapDay({required this.day, required this.count});
}

/// A high-engagement post surfaced on a friend's profile.
class ProfileHighlightPost {
  final String postId;
  final String content;
  final int likes;
  final int comments;
  final DateTime createdAt;
  final String category;
  final String? mood;
  final String? crisisLevel;

  const ProfileHighlightPost({
    required this.postId,
    required this.content,
    required this.likes,
    required this.comments,
    required this.createdAt,
    required this.category,
    this.mood,
    this.crisisLevel,
  });
}

/// A small slice of a mutual friend, used for the "you have N friends
/// in common" row on a friend's profile.
class MutualFriend {
  final String userId;
  final String pseudonym;
  final String avatarSeed;
  const MutualFriend({
    required this.userId,
    required this.pseudonym,
    required this.avatarSeed,
  });
}

class MutualTribe {
  final String tribeId;
  final String name;
  final String slug;
  const MutualTribe({
    required this.tribeId,
    required this.name,
    required this.slug,
  });
}

/// A friend's profile (or stranger's stripped-down view), returned in
/// one round-trip by the `user_profile_summary` RPC. The `relation`
/// field controls how much of this is populated — `stats` is sparse
/// and `highlights` is empty when the viewer is not a friend.
class UserProfileView {
  final FriendStatus relation;

  // user
  final String userId;
  final String pseudonym;
  final String avatarSeed;
  final String? profilePhotoUrl;
  final int karma;
  final bool isVerified;
  final DateTime joinedAt;
  final String? currentMood;
  final String accountStatus;
  final String safetyTier;

  /// Public profile copy, shown on everyone's profile when set.
  final String? bio;
  final String? pronouns;

  // stats (sparse for non-friends)
  final int vents;
  final int? comments;
  final int? reactionsReceived;
  final int activeTribes;
  final int? badgesCount;
  final int? currentStreak;
  final int? bestStreak;
  final List<MoodCount> topMoods;

  // mutuals
  final int mutualFriendsCount;
  final List<MutualFriend> mutualFriendSample;
  final List<MutualTribe> mutualTribes;

  /// Total accepted friendships. Drives the "30K Connections" KPI
  /// on the public profile (migration 0054).
  final int connectionsCount;
  /// Banner stats (migration 0107): total posts = vents + whispers; total
  /// hugs = 🫂 'hug' reactions received on the user's posts.
  final int postsTotal;
  final int hugsReceived;

  // highlights (empty for non-friends)
  final ProfileHighlightPost? mostLiked;
  final ProfileHighlightPost? mostCommented;
  final List<ProfileHighlightPost> recentPosts;
  final List<UserBadge> badges;

  /// 90-day daily activity for friends-tier views. Empty for strangers.
  final List<ActivityHeatmapDay> heatmap;

  const UserProfileView({
    required this.relation,
    required this.userId,
    required this.pseudonym,
    required this.avatarSeed,
    this.profilePhotoUrl,
    required this.karma,
    required this.isVerified,
    required this.joinedAt,
    required this.accountStatus,
    required this.safetyTier,
    required this.vents,
    required this.activeTribes,
    required this.mutualFriendsCount,
    required this.mutualFriendSample,
    required this.mutualTribes,
    this.connectionsCount = 0,
    this.postsTotal = 0,
    this.hugsReceived = 0,
    required this.topMoods,
    required this.recentPosts,
    required this.badges,
    this.heatmap = const [],
    this.currentMood,
    this.comments,
    this.reactionsReceived,
    this.badgesCount,
    this.currentStreak,
    this.bestStreak,
    this.mostLiked,
    this.mostCommented,
    this.bio,
    this.pronouns,
  });

  bool get isFriend => relation == FriendStatus.friends;
  bool get isSelf => relation == FriendStatus.self;

  /// Narrow helper used by the backend to inject `connections_count`
  /// after the main `user_profile_summary` RPC returns, avoiding a
  /// full copyWith for one denormalized counter.
  UserProfileView copyWithConnections(
    int connectionsCount, {
    String? bio,
    String? pronouns,
    int? postsTotal,
    int? hugsReceived,
  }) {
    return UserProfileView(
      postsTotal: postsTotal ?? this.postsTotal,
      hugsReceived: hugsReceived ?? this.hugsReceived,
      relation: relation,
      userId: userId,
      pseudonym: pseudonym,
      avatarSeed: avatarSeed,
      profilePhotoUrl: profilePhotoUrl,
      karma: karma,
      isVerified: isVerified,
      joinedAt: joinedAt,
      currentMood: currentMood,
      accountStatus: accountStatus,
      safetyTier: safetyTier,
      bio: bio ?? this.bio,
      pronouns: pronouns ?? this.pronouns,
      vents: vents,
      activeTribes: activeTribes,
      mutualFriendsCount: mutualFriendsCount,
      mutualFriendSample: mutualFriendSample,
      mutualTribes: mutualTribes,
      topMoods: topMoods,
      recentPosts: recentPosts,
      badges: badges,
      heatmap: heatmap,
      comments: comments,
      reactionsReceived: reactionsReceived,
      badgesCount: badgesCount,
      currentStreak: currentStreak,
      bestStreak: bestStreak,
      mostLiked: mostLiked,
      mostCommented: mostCommented,
      connectionsCount: connectionsCount,
    );
  }
}

/// Thrown by [VentlyRepository.sendMessageRequest] when DM gating
/// rejects a chat-room creation (caller is not friends with target).
/// The UI catches this to swap the snackbar for a "send a friend
/// request first" prompt instead of leaking the raw error.
class DmGatingException implements Exception {
  final String message;
  const DmGatingException(this.message);
  @override
  String toString() => message;
}

/// A user the current user has blocked.
/// Per-user, per-room DM preferences (migration 0098): mute, peer nickname,
/// disappearing-message TTL, chat theme.
class DmRoomPrefs {
  final bool muted;
  final String? peerNickname;
  final int disappearingSeconds; // 0 = off
  final String theme;

  const DmRoomPrefs({
    this.muted = false,
    this.peerNickname,
    this.disappearingSeconds = 0,
    this.theme = 'default',
  });

  static const empty = DmRoomPrefs();
}

class BlockedUser {
  final String userId;
  final String pseudonym;
  final String avatarSeed;
  final String? reason;
  final DateTime createdAt;

  const BlockedUser({
    required this.userId,
    required this.pseudonym,
    required this.avatarSeed,
    required this.createdAt,
    this.reason,
  });
}

/// Single-roundtrip read for the four Hero KPIs on the premium home.
/// Returned by `home_stats()` (migration 0038).
class HomeStats {
  final int ventsToday;
  final int supporters;
  final int dailyHugs;
  final int streakDays;

  const HomeStats({
    required this.ventsToday,
    required this.supporters,
    required this.dailyHugs,
    required this.streakDays,
  });

  static const HomeStats empty =
      HomeStats(ventsToday: 0, supporters: 0, dailyHugs: 0, streakDays: 0);
}

/// One Global Pulse chip. Returned by `trending_categories()`.
class TrendingCategory {
  final String categoryName;
  final int postCount;
  final int reactionSum;
  const TrendingCategory({
    required this.categoryName,
    required this.postCount,
    required this.reactionSum,
  });
}

/// One row returned by the `search_global` RPC (migration 0039).
/// Tagged sum type — fields are populated based on [hitKind] which is
/// one of `tribe`, `post`, or `topic`.
class SearchHit {
  final String hitKind; // tribe | post | topic
  final String hitId;
  final String title;
  final String subtitle;
  final String? avatarSeed;
  final String? profilePhotoUrl;
  final int? memberCount;
  final int? postCount;
  final int? likesCount;
  final int? commentsCount;
  final DateTime? createdAt;
  final double rankScore;

  const SearchHit({
    required this.hitKind,
    required this.hitId,
    required this.title,
    required this.subtitle,
    required this.rankScore,
    this.avatarSeed,
    this.profilePhotoUrl,
    this.memberCount,
    this.postCount,
    this.likesCount,
    this.commentsCount,
    this.createdAt,
  });

  bool get isTribe => hitKind == 'tribe';
  bool get isPost  => hitKind == 'post';
  bool get isTopic => hitKind == 'topic';
}

/// One Rising Voices card on the Discover screen. Returned by
/// `trending_voices()` (migration 0038).
class TrendingVoice {
  final String userId;
  final String pseudonym;
  final String avatarSeed;
  final String? profilePhotoUrl;
  final bool isVerified;
  final String topQuote;
  final String topCategory;
  final String topMood;
  final int engagementScore;

  const TrendingVoice({
    required this.userId,
    required this.pseudonym,
    required this.avatarSeed,
    required this.isVerified,
    required this.topQuote,
    required this.topCategory,
    required this.topMood,
    required this.engagementScore,
    this.profilePhotoUrl,
  });
}
