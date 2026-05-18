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
  });

  bool get isRestrictedMinor => safetyTier == 'restricted_minor';
  bool get isPlug => userRole == 'plug' || userRole == 'super_admin';

  AppUser copyWith({
    String? anonymousPseudonym,
    String? currentMood,
    String? safetyTier,
    String? userRole,
    bool? isVerified,
  }) {
    return AppUser(
      userId: userId,
      anonymousPseudonym: anonymousPseudonym ?? this.anonymousPseudonym,
      avatarSeed: avatarSeed,
      currentMood: currentMood ?? this.currentMood,
      userRole: userRole ?? this.userRole,
      isVerified: isVerified ?? this.isVerified,
      safetyTier: safetyTier ?? this.safetyTier,
      accountStatus: accountStatus,
      birthYear: birthYear,
    );
  }
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

class Space {
  final String spaceId;
  final String spaceName;
  final String spaceType;
  final String? description;
  final int memberCount;

  const Space({
    required this.spaceId,
    required this.spaceName,
    required this.spaceType,
    required this.memberCount,
    this.description,
  });
}

class Post {
  final String postId;
  final String authorPseudonym;
  final String authorAvatarSeed;
  final String? spaceName;
  final String categoryName;
  final String postType; // user_post | plug_prompt
  final String content;
  final String postMood;
  final bool isAudio;
  final String? audioUrl;
  final int audioDurationMs;
  final int likesCount;
  final int commentsCount;
  final DateTime createdAt;
  final bool likedByMe;
  final bool savedByMe;

  const Post({
    required this.postId,
    required this.authorPseudonym,
    required this.authorAvatarSeed,
    required this.categoryName,
    required this.postType,
    required this.content,
    required this.postMood,
    required this.isAudio,
    required this.likesCount,
    required this.commentsCount,
    required this.createdAt,
    this.spaceName,
    this.audioUrl,
    this.audioDurationMs = 0,
    this.likedByMe = false,
    this.savedByMe = false,
  });

  Post copyWith({
    int? likesCount,
    int? commentsCount,
    bool? likedByMe,
    bool? savedByMe,
  }) {
    return Post(
      postId: postId,
      authorPseudonym: authorPseudonym,
      authorAvatarSeed: authorAvatarSeed,
      categoryName: categoryName,
      postType: postType,
      content: content,
      postMood: postMood,
      isAudio: isAudio,
      likesCount: likesCount ?? this.likesCount,
      commentsCount: commentsCount ?? this.commentsCount,
      createdAt: createdAt,
      spaceName: spaceName,
      audioUrl: audioUrl,
      audioDurationMs: audioDurationMs,
      likedByMe: likedByMe ?? this.likedByMe,
      savedByMe: savedByMe ?? this.savedByMe,
    );
  }
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
    List<ThreadedComment>? children,
  }) : children = children ?? <ThreadedComment>[];
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
  final String plaintext; // for E2EE these arrive encrypted; mock holds plaintext.
  final DateTime createdAt;
  final bool sentByMe;

  const ChatMessage({
    required this.messageId,
    required this.roomId,
    required this.senderId,
    required this.plaintext,
    required this.createdAt,
    required this.sentByMe,
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
