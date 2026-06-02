/// Plain immutable entities that flow through the app.
/// Matches the columns from `supabase/migrations/0001_init_schema.sql`.
library;

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
    );
  }
}

/// A member of a Tribe — joins tribe_members + users for the manage view.
class TribeMemberRow {
  final String userId;
  final String pseudonym;
  final String avatarSeed;
  final String role; // member | mod | keeper
  final DateTime joinedAt;

  const TribeMemberRow({
    required this.userId,
    required this.pseudonym,
    required this.avatarSeed,
    required this.role,
    required this.joinedAt,
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
    );
  }
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
  final bool authorIsVerified;
  final int authorKarma;
  final String? tribeId;
  final String? tribeName;
  final String? tribeSlug;
  final String categoryName;
  final String postType; // user_post | plug_prompt
  final String content;
  final String postMood;
  final bool isWhisper;
  final int likesCount;
  final int commentsCount;
  final DateTime createdAt;
  final String? myReaction; // null | like | relate | hug | stay_strong | been_there | crazy
  final bool savedByMe;
  /// Null when the safety classifier saw nothing concerning. `'elevated'` for
  /// Tier-2 (LLM) self-harm matches, `'high'` for Tier-1 keyword hits. Drives
  /// the helpline banner on the post detail screen.
  final String? crisisLevel;

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
    this.authorIsVerified = false,
    this.authorKarma = 0,
    this.tribeId,
    this.tribeName,
    this.tribeSlug,
    this.isWhisper = false,
    this.myReaction,
    this.savedByMe = false,
    this.crisisLevel,
  });

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
    Object? myReaction = _unset,
    bool? savedByMe,
    Object? crisisLevel = _unset,
  }) {
    return Post(
      postId: postId,
      authorId: authorId,
      authorPseudonym: authorPseudonym,
      authorAvatarSeed: authorAvatarSeed,
      authorIsVerified: authorIsVerified,
      authorKarma: authorKarma,
      categoryName: categoryName,
      postType: postType,
      content: content,
      postMood: postMood,
      isWhisper: isWhisper,
      likesCount: likesCount ?? this.likesCount,
      commentsCount: commentsCount ?? this.commentsCount,
      createdAt: createdAt,
      tribeId: tribeId,
      tribeName: tribeName,
      tribeSlug: tribeSlug,
      myReaction:
          myReaction == _unset ? this.myReaction : myReaction as String?,
      savedByMe: savedByMe ?? this.savedByMe,
      crisisLevel:
          crisisLevel == _unset ? this.crisisLevel : crisisLevel as String?,
    );
  }

  static const Object _unset = Object();
}

/// Static catalogue of the six emotion reactions. Kept in sync with the
/// `reaction_type` enum in Postgres (migration 0016).
class PostReactions {
  static const List<String> all = [
    'like', 'relate', 'hug', 'stay_strong', 'been_there', 'crazy',
  ];

  static String emoji(String key) {
    switch (key) {
      case 'like':        return '\u{2764}';       // ❤
      case 'relate':      return '\u{1FAC2}';      // 🫂
      case 'hug':         return '\u{1F917}';      // 🤗
      case 'stay_strong': return '\u{1F4AA}';      // 💪
      case 'been_there':  return '\u{1F62E}\u{200D}\u{1F4A8}'; // 😮‍💨
      case 'crazy':       return '\u{1F92F}';      // 🤯
      default:            return '\u{2764}';
    }
  }

  static String label(String key) {
    switch (key) {
      case 'like':        return 'Heart';
      case 'relate':      return 'Relate';
      case 'hug':         return 'Hug';
      case 'stay_strong': return 'Stay strong';
      case 'been_there':  return 'Been there';
      case 'crazy':       return 'Wow';
      default:            return key;
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
  final String authorPseudonym;
  final String authorAvatarSeed;
  final String content;
  final String path;
  final int depth;
  final int likesCount;
  final bool likedByMe;
  final DateTime createdAt;
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
    this.parentId,
    this.likedByMe = false,
    List<ThreadedComment>? children,
  }) : children = children ?? <ThreadedComment>[];

  ThreadedComment copyWith({int? likesCount, bool? likedByMe}) {
    return ThreadedComment(
      commentId: commentId,
      parentId: parentId,
      authorPseudonym: authorPseudonym,
      authorAvatarSeed: authorAvatarSeed,
      content: content,
      path: path,
      depth: depth,
      likesCount: likesCount ?? this.likesCount,
      likedByMe: likedByMe ?? this.likedByMe,
      createdAt: createdAt,
      children: children,
    );
  }
}

class ChatRoom {
  final String roomId;
  final String peerPseudonym;
  final String peerAvatarSeed;
  final String requestPreview;
  final String roomStatus; // pending_request | active | declined | blocked
  final DateTime createdAt;
  final bool initiatedByMe;

  const ChatRoom({
    required this.roomId,
    required this.peerPseudonym,
    required this.peerAvatarSeed,
    required this.requestPreview,
    required this.roomStatus,
    required this.createdAt,
    required this.initiatedByMe,
  });
}

class ChatMessage {
  final String messageId;
  final String roomId;
  final String senderId;
  final String plaintext; // stored server-side as plaintext for moderation review.
  final DateTime createdAt;
  final bool sentByMe;

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
  });

  ChatMessage copyWith({
    Map<String, int>? reactionCounts,
    Object? myReaction = _unsetReaction,
  }) {
    return ChatMessage(
      messageId: messageId,
      roomId: roomId,
      senderId: senderId,
      plaintext: plaintext,
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

  const NotificationItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.isRead,
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

  const FriendSummary({
    required this.friendshipId,
    required this.userId,
    required this.pseudonym,
    required this.avatarSeed,
    required this.karma,
    required this.isVerified,
    required this.acceptedAt,
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
  final int karma;
  final bool isVerified;
  final DateTime joinedAt;
  final String? currentMood;
  final String accountStatus;
  final String safetyTier;

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
  });

  bool get isFriend => relation == FriendStatus.friends;
  bool get isSelf => relation == FriendStatus.self;
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
