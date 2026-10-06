/// Conversations between a member and the Venttly team.
///
/// Staff always appear as "Venttly team": the database never sends a staff
/// name or handle to the app, and nothing here should try to show one.
library;

/// What the member sees of a conversation's state. The staff workflow has
/// more steps; the database folds them into these four.
enum SupportStatus {
  open('Waiting for the team'),
  replied('Venttly replied'),
  resolved('Resolved'),
  closed('Closed');

  const SupportStatus(this.label);
  final String label;

  static SupportStatus parse(String? raw) => switch (raw) {
    'replied' => SupportStatus.replied,
    'resolved' => SupportStatus.resolved,
    'closed' => SupportStatus.closed,
    _ => SupportStatus.open,
  };
}

/// What a member can ask about. Matches member_start_support's allowlist.
enum SupportCategory {
  access('access', 'Signing in or my account'),
  technical('technical', 'Something is not working'),
  safetyFollowup('safety_followup', 'My safety or someone else\'s'),
  appealHelp('appeal_help', 'A moderation decision'),
  verificationHelp('verification_help', 'Verification'),
  privacyRequest('privacy_request', 'My data and privacy'),
  other('other', 'Something else');

  const SupportCategory(this.wire, this.label);
  final String wire;
  final String label;
}

/// A row in the member's list: either a conversation, or a staff message they
/// have not answered yet (no conversation exists until they do).
class SupportConversationSummary {
  const SupportConversationSummary({
    required this.conversationId,
    required this.communicationId,
    required this.subject,
    required this.status,
    required this.lastMessageAt,
    required this.lastFromTeam,
    required this.unread,
    required this.preview,
    required this.canReply,
  });

  final String? conversationId;
  final String? communicationId;
  final String subject;
  final SupportStatus status;
  final DateTime? lastMessageAt;
  final bool lastFromTeam;
  final bool unread;
  final String preview;
  final bool canReply;

  static SupportConversationSummary? fromRow(Map<String, dynamic> row) {
    final conversation = row['conversation_id'] as String?;
    final communication = row['communication_id'] as String?;
    if (conversation == null && communication == null) return null;
    return SupportConversationSummary(
      conversationId: conversation,
      communicationId: communication,
      subject: (row['subject'] as String?) ?? 'Support request',
      status: SupportStatus.parse(row['status'] as String?),
      lastMessageAt: DateTime.tryParse(
        (row['last_message_at'] as String?) ?? '',
      )?.toLocal(),
      lastFromTeam: row['last_message_by'] == 'staff',
      unread: row['unread'] == true,
      preview: (row['preview'] as String?) ?? '',
      canReply: row['can_reply'] == true,
    );
  }
}

class SupportMessage {
  const SupportMessage({
    required this.id,
    required this.fromMe,
    required this.body,
    required this.createdAt,
  });

  final String id;
  final bool fromMe;
  final String body;
  final DateTime? createdAt;
}

class SupportThread {
  const SupportThread({
    required this.conversationId,
    required this.communicationId,
    required this.subject,
    required this.status,
    required this.canReply,
    required this.messages,
  });

  /// Null until the member first replies to a staff message.
  final String? conversationId;
  final String? communicationId;
  final String subject;
  final SupportStatus status;
  final bool canReply;
  final List<SupportMessage> messages;

  static SupportThread fromJson(Map<String, dynamic> json) {
    final raw = (json['messages'] as List?) ?? const [];
    return SupportThread(
      conversationId: json['conversation_id'] as String?,
      communicationId: json['communication_id'] as String?,
      subject: (json['subject'] as String?) ?? 'Support request',
      status: SupportStatus.parse(json['status'] as String?),
      canReply: json['can_reply'] == true,
      messages: [
        for (final m in raw.whereType<Map>())
          SupportMessage(
            id: m['id'] as String? ?? '',
            fromMe: m['from'] == 'me',
            body: m['body'] as String? ?? '',
            createdAt: DateTime.tryParse(
              (m['created_at'] as String?) ?? '',
            )?.toLocal(),
          ),
      ],
    );
  }
}

/// Route and payload identifiers are UUIDs; anything else is refused before it
/// reaches a query.
bool isSupportId(String? value) =>
    value != null &&
    RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(value);

/// Which thread to open: a conversation, or a staff message not yet answered.
class SupportThreadRef {
  const SupportThreadRef({this.conversationId, this.communicationId})
    : assert((conversationId == null) != (communicationId == null));

  final String? conversationId;
  final String? communicationId;

  @override
  bool operator ==(Object other) =>
      other is SupportThreadRef &&
      other.conversationId == conversationId &&
      other.communicationId == communicationId;

  @override
  int get hashCode => Object.hash(conversationId, communicationId);

  String get route => conversationId != null
      ? '/settings/support/thread?conversation=$conversationId'
      : '/settings/support/thread?message=$communicationId';
}
