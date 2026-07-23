// Tribe chat hub - presence roster + group settings.

class TribeOnlineMember {
  final String userId;
  final String pseudonym;
  final String avatarSeed;
  final String? profilePhotoUrl;
  final String role;
  final bool isOnline;
  final DateTime? lastSeenAt;

  const TribeOnlineMember({
    required this.userId,
    required this.pseudonym,
    required this.avatarSeed,
    this.profilePhotoUrl,
    this.role = 'member',
    this.isOnline = false,
    this.lastSeenAt,
  });

  factory TribeOnlineMember.fromJson(Map<String, dynamic> json) {
    return TribeOnlineMember(
      userId: '${json['user_id']}',
      pseudonym: (json['pseudonym'] as String?) ?? 'member',
      avatarSeed: (json['avatar_seed'] as String?) ?? 'default-orb',
      profilePhotoUrl: json['profile_photo_url'] as String?,
      role: (json['role'] as String?) ?? 'member',
      isOnline: json['is_online'] == true,
      lastSeenAt: json['last_seen_at'] != null
          ? DateTime.parse(json['last_seen_at'] as String)
          : null,
    );
  }
}

class TribeTypingUser {
  final String userId;
  final String pseudonym;

  const TribeTypingUser({required this.userId, required this.pseudonym});
}

class TribeChatSettings {
  final bool membersCanInvite;
  final int slowModeSeconds;
  final bool announceJoins;
  final String? wallpaperUrl;
  final String wallpaperStyle;
  final bool membersCanSendMedia;
  final bool disappearingMessages;
  final bool dailyCheckinEnabled;
  final int dailyCheckinHour;
  final String dailyCheckinPrompt;

  const TribeChatSettings({
    this.membersCanInvite = false,
    this.slowModeSeconds = 0,
    this.announceJoins = true,
    this.wallpaperUrl,
    this.wallpaperStyle = 'gradient',
    this.membersCanSendMedia = true,
    this.disappearingMessages = false,
    this.dailyCheckinEnabled = false,
    this.dailyCheckinHour = 13,
    this.dailyCheckinPrompt = 'How is everyone feeling today?',
  });

  factory TribeChatSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const TribeChatSettings();
    return TribeChatSettings(
      membersCanInvite: json['members_can_invite'] == true,
      slowModeSeconds: (json['slow_mode_seconds'] as num?)?.toInt() ?? 0,
      announceJoins: json['announce_joins'] != false,
      wallpaperUrl: json['wallpaper_url'] as String?,
      wallpaperStyle: (json['wallpaper_style'] as String?) ?? 'gradient',
      membersCanSendMedia: json['members_can_send_media'] != false,
      disappearingMessages: json['disappearing_messages'] == true,
      dailyCheckinEnabled: json['daily_checkin_enabled'] == true,
      dailyCheckinHour: (json['daily_checkin_hour'] as num?)?.toInt() ?? 13,
      dailyCheckinPrompt: (json['daily_checkin_prompt'] as String?) ??
          'How is everyone feeling today?',
    );
  }

  Map<String, dynamic> toPatch({
    bool? membersCanInvite,
    int? slowModeSeconds,
    bool? announceJoins,
    String? wallpaperUrl,
    String? wallpaperStyle,
    bool? membersCanSendMedia,
    bool? disappearingMessages,
    bool? dailyCheckinEnabled,
    int? dailyCheckinHour,
    String? dailyCheckinPrompt,
  }) {
    return {
      if (membersCanInvite != null) 'members_can_invite': membersCanInvite,
      if (slowModeSeconds != null) 'slow_mode_seconds': slowModeSeconds,
      if (announceJoins != null) 'announce_joins': announceJoins,
      if (wallpaperUrl != null) 'wallpaper_url': wallpaperUrl,
      if (wallpaperStyle != null) 'wallpaper_style': wallpaperStyle,
      if (membersCanSendMedia != null)
        'members_can_send_media': membersCanSendMedia,
      if (disappearingMessages != null)
        'disappearing_messages': disappearingMessages,
      if (dailyCheckinEnabled != null)
        'daily_checkin_enabled': dailyCheckinEnabled,
      if (dailyCheckinHour != null) 'daily_checkin_hour': dailyCheckinHour,
      if (dailyCheckinPrompt != null)
        'daily_checkin_prompt': dailyCheckinPrompt,
    };
  }
}

class TribeChatInboxSummary {
  final String tribeId;
  final String name;
  final String slug;
  final String? avatarUrl;
  final int unreadCount;
  final String? lastMessagePreview;
  final DateTime? lastMessageAt;

  const TribeChatInboxSummary({
    required this.tribeId,
    required this.name,
    required this.slug,
    this.avatarUrl,
    this.unreadCount = 0,
    this.lastMessagePreview,
    this.lastMessageAt,
  });

  factory TribeChatInboxSummary.fromJson(Map<String, dynamic> json) {
    final at = json['last_message_at'] as String?;
    return TribeChatInboxSummary(
      tribeId: '${json['tribe_id']}',
      name: (json['name'] as String?) ?? 'Tribe',
      slug: (json['slug'] as String?) ?? '',
      avatarUrl: json['avatar_url'] as String?,
      unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
      lastMessagePreview: json['last_message_preview'] as String?,
      lastMessageAt: at == null ? null : DateTime.parse(at),
    );
  }
}

class TribeChatMediaItem {
  final String messageId;
  final String tribeId;
  final String? senderId;
  final String senderPseudonym;
  final String? imageUrl;
  final String? audioUrl;
  final int? audioDurationSeconds;
  final DateTime createdAt;
  final String mediaKind;

  const TribeChatMediaItem({
    required this.messageId,
    required this.tribeId,
    required this.senderPseudonym,
    required this.createdAt,
    required this.mediaKind,
    this.senderId,
    this.imageUrl,
    this.audioUrl,
    this.audioDurationSeconds,
  });

  factory TribeChatMediaItem.fromJson(Map<String, dynamic> json) {
    return TribeChatMediaItem(
      messageId: '${json['message_id']}',
      tribeId: '${json['tribe_id']}',
      senderId: json['sender_id'] as String?,
      senderPseudonym: (json['sender_pseudonym'] as String?) ?? 'member',
      imageUrl: json['image_url'] as String?,
      audioUrl: json['audio_url'] as String?,
      audioDurationSeconds: (json['audio_duration_seconds'] as num?)?.toInt(),
      createdAt: DateTime.parse(json['created_at'] as String),
      mediaKind: (json['media_kind'] as String?) ?? 'other',
    );
  }
}
