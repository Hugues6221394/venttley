// Plugz Creator Studio V2 - RPC payloads for moderation, calendar,
// insights, co-mod grid, and export reports.

String _str(dynamic v, [String fallback = '']) {
  if (v == null) return fallback;
  if (v is String) return v;
  return v.toString();
}

String? _strOrNull(dynamic v) {
  if (v == null) return null;
  if (v is String) return v.isEmpty ? null : v;
  if (v is Map || v is List) return null;
  final s = v.toString();
  return s.isEmpty ? null : s;
}

int _int(dynamic v, [int fallback = 0]) {
  if (v == null) return fallback;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString()) ?? fallback;
}

class KeeperModerationItem {
  final String reportId;
  final String? postId;
  final String reason;
  final String? note;
  final DateTime createdAt;
  final String? postSnippet;
  final String? reporterPseudonym;

  const KeeperModerationItem({
    required this.reportId,
    this.postId,
    required this.reason,
    this.note,
    required this.createdAt,
    this.postSnippet,
    this.reporterPseudonym,
  });

  factory KeeperModerationItem.fromJson(Map<String, dynamic> json) {
    return KeeperModerationItem(
      reportId: _str(json['report_id']),
      postId: _strOrNull(json['post_id']),
      reason: _str(json['reason'], 'other'),
      note: _strOrNull(json['note']),
      createdAt: DateTime.parse(_str(json['created_at'])),
      postSnippet: _strOrNull(json['post_snippet']),
      reporterPseudonym: _strOrNull(json['reporter_pseudonym']),
    );
  }
}

class KeeperModerationQueue {
  final List<KeeperModerationItem> items;
  final int keywordFilterCount;
  final int warnings30d;

  const KeeperModerationQueue({
    required this.items,
    this.keywordFilterCount = 0,
    this.warnings30d = 0,
  });

  factory KeeperModerationQueue.fromJson(Map<String, dynamic> json) {
    final raw = json['items'] as List? ?? const [];
    return KeeperModerationQueue(
      items: raw
          .map((e) => KeeperModerationItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      keywordFilterCount: _int(json['keyword_filter_count']),
      warnings30d: _int(json['warnings_30d']),
    );
  }
}

class KeeperCalendarPrompt {
  final String promptId;
  final String promptText;
  final DateTime? scheduledFor;
  final DateTime? publishedAt;
  final bool isActive;

  const KeeperCalendarPrompt({
    required this.promptId,
    required this.promptText,
    this.scheduledFor,
    this.publishedAt,
    this.isActive = true,
  });

  factory KeeperCalendarPrompt.fromJson(Map<String, dynamic> json) {
    return KeeperCalendarPrompt(
      promptId: json['prompt_id'] as String,
      promptText: (json['prompt_text'] as String?) ?? '',
      scheduledFor: json['scheduled_for'] != null
          ? DateTime.parse(json['scheduled_for'] as String)
          : null,
      publishedAt: json['published_at'] != null
          ? DateTime.parse(json['published_at'] as String)
          : null,
      isActive: json['is_active'] != false,
    );
  }
}

class KeeperCalendarSuggestion {
  final String title;
  final String slot;
  final String hint;

  const KeeperCalendarSuggestion({
    required this.title,
    required this.slot,
    required this.hint,
  });

  factory KeeperCalendarSuggestion.fromJson(Map<String, dynamic> json) {
    return KeeperCalendarSuggestion(
      title: (json['title'] as String?) ?? '',
      slot: (json['slot'] as String?) ?? '',
      hint: (json['hint'] as String?) ?? '',
    );
  }
}

class KeeperEngagementCalendar {
  final List<KeeperCalendarPrompt> scheduled;
  final List<KeeperCalendarPrompt> recentPublished;
  final List<KeeperCalendarSuggestion> suggestions;

  const KeeperEngagementCalendar({
    required this.scheduled,
    required this.recentPublished,
    required this.suggestions,
  });

  factory KeeperEngagementCalendar.fromJson(Map<String, dynamic> json) {
    List<KeeperCalendarPrompt> parseList(String key) {
      final raw = json[key] as List? ?? const [];
      return raw
          .map((e) => KeeperCalendarPrompt.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    final sugRaw = json['suggestions'] as List? ?? const [];
    return KeeperEngagementCalendar(
      scheduled: parseList('scheduled'),
      recentPublished: parseList('recent_published'),
      suggestions: sugRaw
          .map(
            (e) => KeeperCalendarSuggestion.fromJson(e as Map<String, dynamic>),
          )
          .toList(),
    );
  }
}

class KeeperMoodTrend {
  final String mood;
  final int count;

  const KeeperMoodTrend({required this.mood, required this.count});

  factory KeeperMoodTrend.fromJson(Map<String, dynamic> json) {
    return KeeperMoodTrend(
      mood: (json['mood'] as String?) ?? 'unknown',
      count: (json['cnt'] as int?) ?? 0,
    );
  }
}

class KeeperAiInsight {
  final String kind;
  final String severity;
  final String title;
  final String body;
  final String? action;

  const KeeperAiInsight({
    required this.kind,
    required this.severity,
    required this.title,
    required this.body,
    this.action,
  });

  factory KeeperAiInsight.fromJson(Map<String, dynamic> json) {
    return KeeperAiInsight(
      kind: (json['kind'] as String?) ?? 'general',
      severity: (json['severity'] as String?) ?? 'medium',
      title: (json['title'] as String?) ?? '',
      body: (json['body'] as String?) ?? '',
      action: json['action'] as String?,
    );
  }
}

class KeeperAiInsights {
  final int healthScore;
  final int safetyScore;
  final String retentionLabel;
  final List<KeeperMoodTrend> moodTrends;
  final List<KeeperAiInsight> insights;

  const KeeperAiInsights({
    required this.healthScore,
    required this.safetyScore,
    required this.retentionLabel,
    required this.moodTrends,
    required this.insights,
  });

  factory KeeperAiInsights.fromJson(Map<String, dynamic> json) {
    final moodsRaw = json['mood_trends'] as List? ?? const [];
    final insightsRaw = json['insights'] as List? ?? const [];
    return KeeperAiInsights(
      healthScore: (json['health_score'] as int?) ?? 0,
      safetyScore: (json['safety_score'] as int?) ?? 100,
      retentionLabel: (json['retention_label'] as String?) ?? 'stable',
      moodTrends: moodsRaw
          .map((e) => KeeperMoodTrend.fromJson(e as Map<String, dynamic>))
          .toList(),
      insights: insightsRaw
          .map((e) => KeeperAiInsight.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class KeeperComodRow {
  final String userId;
  final String pseudonym;
  final String? avatarSeed;
  final String role;
  final bool canPromote;
  final bool canWarn;
  final bool canReviewReports;
  final bool canPin;
  final bool canSchedule;
  final bool canKickMods;
  final bool canKickMembers;
  final DateTime? joinedAt;

  const KeeperComodRow({
    required this.userId,
    required this.pseudonym,
    this.avatarSeed,
    required this.role,
    this.canPromote = false,
    this.canWarn = false,
    this.canReviewReports = false,
    this.canPin = false,
    this.canSchedule = false,
    this.canKickMods = false,
    this.canKickMembers = false,
    this.joinedAt,
  });

  factory KeeperComodRow.fromJson(Map<String, dynamic> json) {
    return KeeperComodRow(
      userId: json['user_id'] as String,
      pseudonym: (json['pseudonym'] as String?) ?? 'member',
      avatarSeed: json['avatar_seed'] as String?,
      role: (json['role'] as String?) ?? 'mod',
      canPromote: json['can_promote'] == true,
      canWarn: json['can_warn'] == true,
      canReviewReports: json['can_review_reports'] == true,
      canPin: json['can_pin'] == true,
      canSchedule: json['can_schedule'] == true,
      canKickMods: json['can_kick_mods'] == true,
      canKickMembers: json['can_kick_members'] == true,
      joinedAt: json['joined_at'] != null
          ? DateTime.parse(json['joined_at'] as String)
          : null,
    );
  }
}

class KeeperComodMatrix {
  final List<KeeperComodRow> mods;
  final bool callerIsKeeper;

  const KeeperComodMatrix({required this.mods, this.callerIsKeeper = false});

  factory KeeperComodMatrix.fromJson(Map<String, dynamic> json) {
    final raw = json['mods'] as List? ?? const [];
    return KeeperComodMatrix(
      mods: raw
          .map((e) => KeeperComodRow.fromJson(e as Map<String, dynamic>))
          .toList(),
      callerIsKeeper: json['caller_is_keeper'] == true,
    );
  }
}

class KeeperExportReport {
  final String format;
  final String tribeName;
  final String tribeSlug;
  final DateTime generatedAt;
  final String markdown;

  const KeeperExportReport({
    required this.format,
    required this.tribeName,
    required this.tribeSlug,
    required this.generatedAt,
    required this.markdown,
  });

  factory KeeperExportReport.fromJson(Map<String, dynamic> json) {
    return KeeperExportReport(
      format: (json['format'] as String?) ?? 'markdown',
      tribeName: (json['tribe_name'] as String?) ?? '',
      tribeSlug: (json['tribe_slug'] as String?) ?? '',
      generatedAt: DateTime.parse(json['generated_at'] as String),
      markdown: (json['markdown'] as String?) ?? '',
    );
  }
}
