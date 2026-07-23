class TribeRuleItem {
  final String? ruleId;
  final int position;
  final String title;
  final String? description;
  final String? templateKey;
  final bool isEnabled;

  const TribeRuleItem({
    required this.position,
    required this.title,
    this.ruleId,
    this.description,
    this.templateKey,
    this.isEnabled = true,
  });

  factory TribeRuleItem.fromJson(Map<String, dynamic> json) => TribeRuleItem(
        ruleId: json['rule_id'] as String?,
        position: (json['position'] as num?)?.toInt() ?? 0,
        title: (json['title'] as String?) ?? '',
        description: json['description'] as String?,
        templateKey: json['template_key'] as String?,
        isEnabled: json['is_enabled'] != false,
      );

  Map<String, dynamic> toJson() => {
        'position': position,
        'title': title.trim(),
        if (description?.trim().isNotEmpty == true)
          'description': description!.trim(),
        if (templateKey != null) 'template_key': templateKey,
        'is_enabled': isEnabled,
      };

  TribeRuleItem copyWith({
    int? position,
    String? title,
    String? description,
    bool? isEnabled,
  }) =>
      TribeRuleItem(
        ruleId: ruleId,
        position: position ?? this.position,
        title: title ?? this.title,
        description: description ?? this.description,
        templateKey: templateKey,
        isEnabled: isEnabled ?? this.isEnabled,
      );
}

class TribeGovernanceSettings {
  final bool joinApprovalRequired;
  final int minimumAccountAgeDays;
  final String postApprovalMode;
  final String postingPermission;
  final int slowModeSeconds;
  final bool allowWhispers;
  final bool allowPolls;
  final bool allowAnonymousReactions;
  final String contentSensitivityFilter;
  final bool showContentWhenPaused;
  final bool inviteLinksEnabled;

  const TribeGovernanceSettings({
    this.joinApprovalRequired = false,
    this.minimumAccountAgeDays = 0,
    this.postApprovalMode = 'off',
    this.postingPermission = 'members',
    this.slowModeSeconds = 0,
    this.allowWhispers = true,
    this.allowPolls = true,
    this.allowAnonymousReactions = true,
    this.contentSensitivityFilter = 'standard',
    this.showContentWhenPaused = true,
    this.inviteLinksEnabled = true,
  });

  factory TribeGovernanceSettings.fromJson(Map<String, dynamic>? json) {
    final value = json ?? const <String, dynamic>{};
    return TribeGovernanceSettings(
      joinApprovalRequired: value['join_approval_required'] == true,
      minimumAccountAgeDays:
          (value['minimum_account_age_days'] as num?)?.toInt() ?? 0,
      postApprovalMode: (value['post_approval_mode'] as String?) ?? 'off',
      postingPermission: (value['posting_permission'] as String?) ?? 'members',
      slowModeSeconds: (value['slow_mode_seconds'] as num?)?.toInt() ?? 0,
      allowWhispers: value['allow_whispers'] != false,
      allowPolls: value['allow_polls'] != false,
      allowAnonymousReactions: value['allow_anonymous_reactions'] != false,
      contentSensitivityFilter:
          (value['content_sensitivity_filter'] as String?) ?? 'standard',
      showContentWhenPaused: value['show_content_when_paused'] != false,
      inviteLinksEnabled: value['invite_links_enabled'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
        'join_approval_required': joinApprovalRequired,
        'minimum_account_age_days': minimumAccountAgeDays,
        'post_approval_mode': postApprovalMode,
        'posting_permission': postingPermission,
        'slow_mode_seconds': slowModeSeconds,
        'allow_whispers': allowWhispers,
        'allow_polls': allowPolls,
        'allow_anonymous_reactions': allowAnonymousReactions,
        'content_sensitivity_filter': contentSensitivityFilter,
        'show_content_when_paused': showContentWhenPaused,
        'invite_links_enabled': inviteLinksEnabled,
      };

  TribeGovernanceSettings copyWith({
    bool? joinApprovalRequired,
    int? minimumAccountAgeDays,
    String? postApprovalMode,
    String? postingPermission,
    int? slowModeSeconds,
    bool? allowWhispers,
    bool? allowPolls,
    bool? allowAnonymousReactions,
    String? contentSensitivityFilter,
    bool? showContentWhenPaused,
    bool? inviteLinksEnabled,
  }) =>
      TribeGovernanceSettings(
        joinApprovalRequired: joinApprovalRequired ?? this.joinApprovalRequired,
        minimumAccountAgeDays:
            minimumAccountAgeDays ?? this.minimumAccountAgeDays,
        postApprovalMode: postApprovalMode ?? this.postApprovalMode,
        postingPermission: postingPermission ?? this.postingPermission,
        slowModeSeconds: slowModeSeconds ?? this.slowModeSeconds,
        allowWhispers: allowWhispers ?? this.allowWhispers,
        allowPolls: allowPolls ?? this.allowPolls,
        allowAnonymousReactions:
            allowAnonymousReactions ?? this.allowAnonymousReactions,
        contentSensitivityFilter:
            contentSensitivityFilter ?? this.contentSensitivityFilter,
        showContentWhenPaused:
            showContentWhenPaused ?? this.showContentWhenPaused,
        inviteLinksEnabled: inviteLinksEnabled ?? this.inviteLinksEnabled,
      );
}

class TribePendingTransfer {
  final String transferId;
  final String toUserId;
  final String toPseudonym;
  final bool keepPreviousOwnerAsMod;
  final DateTime createdAt;
  final DateTime expiresAt;

  const TribePendingTransfer({
    required this.transferId,
    required this.toUserId,
    required this.toPseudonym,
    required this.keepPreviousOwnerAsMod,
    required this.createdAt,
    required this.expiresAt,
  });

  factory TribePendingTransfer.fromJson(Map<String, dynamic> json) =>
      TribePendingTransfer(
        transferId: json['transfer_id'] as String,
        toUserId: json['to_user_id'] as String,
        toPseudonym: (json['to_pseudonym'] as String?) ?? 'member',
        keepPreviousOwnerAsMod: json['keep_previous_owner_as_mod'] != false,
        createdAt: DateTime.parse(json['created_at'] as String),
        expiresAt: DateTime.parse(json['expires_at'] as String),
      );
}

class TribeManagementOverview {
  final String tribeId;
  final String name;
  final String slug;
  final String? description;
  final String category;
  final List<String> tags;
  final String visibility;
  final String lifecycleStatus;
  final String? lifecycleReason;
  final String? avatarUrl;
  final String? bannerUrl;
  final String? welcomeMessage;
  final DateTime? deletionRequestedAt;
  final DateTime? deletionPurgeAt;
  final int memberCount;
  final int postCount;
  final int spaceCount;
  final int pendingJoinRequests;
  final int pendingInvitations;
  final int openReports;
  final TribeGovernanceSettings settings;
  final List<TribeRuleItem> rules;
  final TribePendingTransfer? pendingTransfer;

  const TribeManagementOverview({
    required this.tribeId,
    required this.name,
    required this.slug,
    required this.category,
    required this.tags,
    required this.visibility,
    required this.lifecycleStatus,
    required this.memberCount,
    required this.postCount,
    required this.spaceCount,
    required this.pendingJoinRequests,
    required this.pendingInvitations,
    required this.openReports,
    required this.settings,
    required this.rules,
    this.description,
    this.lifecycleReason,
    this.avatarUrl,
    this.bannerUrl,
    this.welcomeMessage,
    this.deletionRequestedAt,
    this.deletionPurgeAt,
    this.pendingTransfer,
  });

  factory TribeManagementOverview.fromJson(Map<String, dynamic> json) {
    final rawRules = (json['rules'] as List<dynamic>?) ?? const [];
    final rawTransfer = json['pending_transfer'];
    return TribeManagementOverview(
      tribeId: json['tribe_id'] as String,
      name: (json['name'] as String?) ?? '',
      slug: (json['slug'] as String?) ?? '',
      description: json['description'] as String?,
      category: (json['category'] as String?) ?? 'community',
      tags: ((json['tags'] as List<dynamic>?) ?? const [])
          .map((e) => e.toString())
          .toList(growable: false),
      visibility: (json['visibility'] as String?) ?? 'public',
      lifecycleStatus: (json['lifecycle_status'] as String?) ?? 'active',
      lifecycleReason: json['lifecycle_reason'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      bannerUrl: json['banner_url'] as String?,
      welcomeMessage: json['welcome_message'] as String?,
      deletionRequestedAt: _date(json['deletion_requested_at']),
      deletionPurgeAt: _date(json['deletion_purge_at']),
      memberCount: (json['member_count'] as num?)?.toInt() ?? 0,
      postCount: (json['post_count'] as num?)?.toInt() ?? 0,
      spaceCount: (json['space_count'] as num?)?.toInt() ?? 0,
      pendingJoinRequests:
          (json['pending_join_requests'] as num?)?.toInt() ?? 0,
      pendingInvitations: (json['pending_invitations'] as num?)?.toInt() ?? 0,
      openReports: (json['open_reports'] as num?)?.toInt() ?? 0,
      settings: TribeGovernanceSettings.fromJson(
        json['settings'] is Map
            ? Map<String, dynamic>.from(json['settings'] as Map)
            : null,
      ),
      rules: rawRules
          .whereType<Map>()
          .map((e) => TribeRuleItem.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
      pendingTransfer: rawTransfer is Map
          ? TribePendingTransfer.fromJson(
              Map<String, dynamic>.from(rawTransfer),
            )
          : null,
    );
  }

  static DateTime? _date(dynamic value) =>
      value is String && value.isNotEmpty ? DateTime.tryParse(value) : null;
}

class TribeJoinRequest {
  final String requestId;
  final String userId;
  final String pseudonym;
  final String avatarSeed;
  final String? profilePhotoUrl;
  final String? note;
  final DateTime createdAt;

  const TribeJoinRequest({
    required this.requestId,
    required this.userId,
    required this.pseudonym,
    required this.avatarSeed,
    required this.createdAt,
    this.profilePhotoUrl,
    this.note,
  });

  factory TribeJoinRequest.fromJson(Map<String, dynamic> json) =>
      TribeJoinRequest(
        requestId: json['request_id'] as String,
        userId: json['user_id'] as String,
        pseudonym: (json['anonymous_pseudonym'] as String?) ?? 'member',
        avatarSeed: (json['avatar_seed'] as String?) ?? 'default-orb',
        profilePhotoUrl: json['profile_photo_url'] as String?,
        note: json['note'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}

class TribeAuditEvent {
  final String auditId;
  final String action;
  final String? actorPseudonym;
  final String? targetType;
  final String? targetId;
  final String? reason;
  final DateTime createdAt;

  const TribeAuditEvent({
    required this.auditId,
    required this.action,
    required this.createdAt,
    this.actorPseudonym,
    this.targetType,
    this.targetId,
    this.reason,
  });

  factory TribeAuditEvent.fromJson(Map<String, dynamic> json) {
    final actor = json['actor'] is Map
        ? Map<String, dynamic>.from(json['actor'] as Map)
        : const <String, dynamic>{};
    return TribeAuditEvent(
      auditId: json['audit_id'] as String,
      action: (json['action'] as String?) ?? 'UNKNOWN',
      actorPseudonym: actor['anonymous_pseudonym'] as String?,
      targetType: json['target_type'] as String?,
      targetId: json['target_id'] as String?,
      reason: json['reason'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

class TribeManagedPost {
  final String postId;
  final String? authorId;
  final String authorPseudonym;
  final String authorAvatarSeed;
  final String? authorProfilePhotoUrl;
  final String content;
  final String categoryName;
  final String postMood;
  final String? spaceId;
  final String? spaceName;
  final int likesCount;
  final int commentsCount;
  final DateTime createdAt;
  final bool isApproved;
  final bool isPinned;
  final DateTime? featuredAt;
  final DateTime? hiddenAt;
  final DateTime? lockedAt;
  final DateTime? sensitiveAt;
  final DateTime? archivedAt;

  const TribeManagedPost({
    required this.postId,
    required this.authorPseudonym,
    required this.authorAvatarSeed,
    required this.content,
    required this.categoryName,
    required this.postMood,
    required this.likesCount,
    required this.commentsCount,
    required this.createdAt,
    required this.isApproved,
    required this.isPinned,
    this.authorId,
    this.authorProfilePhotoUrl,
    this.spaceId,
    this.spaceName,
    this.featuredAt,
    this.hiddenAt,
    this.lockedAt,
    this.sensitiveAt,
    this.archivedAt,
  });

  factory TribeManagedPost.fromJson(Map<String, dynamic> json) =>
      TribeManagedPost(
        postId: json['post_id'] as String,
        authorId: json['author_id'] as String?,
        authorPseudonym: (json['author_pseudonym'] as String?) ?? '@anonymous',
        authorAvatarSeed:
            (json['author_avatar_seed'] as String?) ?? 'default-orb',
        authorProfilePhotoUrl: json['author_profile_photo_url'] as String?,
        content: (json['content'] as String?) ?? '',
        categoryName: (json['category_name'] as String?) ?? 'community',
        postMood: (json['post_mood'] as String?) ?? 'hopeful',
        spaceId: json['space_id'] as String?,
        spaceName: json['space_name'] as String?,
        likesCount: (json['likes_count'] as num?)?.toInt() ?? 0,
        commentsCount: (json['comments_count'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.parse(json['created_at'] as String),
        isApproved: json['is_approved'] != false,
        isPinned: json['is_pinned'] == true,
        featuredAt: _optionalDate(json['featured_at']),
        hiddenAt: _optionalDate(json['hidden_at']),
        lockedAt: _optionalDate(json['locked_at']),
        sensitiveAt: _optionalDate(json['sensitive_at']),
        archivedAt: _optionalDate(json['archived_at']),
      );

  bool get isPending => !isApproved;
  bool get isFeatured => featuredAt != null;
  bool get isHidden => hiddenAt != null;
  bool get isLocked => lockedAt != null;
  bool get isSensitive => sensitiveAt != null;
  bool get isArchived => archivedAt != null;
  bool get needsAttention => isPending || isHidden || isSensitive;

  static DateTime? _optionalDate(dynamic value) =>
      value is String && value.isNotEmpty ? DateTime.tryParse(value) : null;
}
