import '../entities/entities.dart';

class TribeChatPollOption {
  const TribeChatPollOption({required this.id, required this.text});
  final String id;
  final String text;

  factory TribeChatPollOption.fromJson(Map<String, dynamic> json) {
    return TribeChatPollOption(
      id: '${json['id']}',
      text: (json['text'] as String?) ?? '',
    );
  }
}

/// Interactive poll embedded in a tribe chat message (`metadata.kind = poll`).
class TribeChatPoll {
  const TribeChatPoll({
    required this.messageId,
    required this.question,
    required this.options,
    required this.optionCounts,
    this.myVoteOptionId,
    this.isClosed = false,
    this.anonymousVotes = false,
  });

  final String messageId;
  final String question;
  final List<TribeChatPollOption> options;
  final Map<String, int> optionCounts;
  final String? myVoteOptionId;
  final bool isClosed;
  final bool anonymousVotes;

  int get totalVotes =>
      optionCounts.values.fold<int>(0, (sum, n) => sum + n);

  bool get hasVoted => myVoteOptionId != null;
  bool get showResults => hasVoted || isClosed;

  int countFor(String optionId) => optionCounts[optionId] ?? 0;

  double fractionFor(String optionId) {
    final total = totalVotes;
    if (total <= 0) return 0;
    return countFor(optionId) / total;
  }

  factory TribeChatPoll.fromMessage(TribeMessage message) {
    final meta = message.metadata ?? const {};
    final rawOptions = meta['options'];
    final options = rawOptions is List
        ? rawOptions
            .whereType<Map>()
            .map((e) => TribeChatPollOption.fromJson(
                  Map<String, dynamic>.from(e),
                ))
            .toList()
        : const <TribeChatPollOption>[];

    return TribeChatPoll(
      messageId: message.messageId,
      question: (meta['question'] as String?) ?? '',
      options: options,
      optionCounts: message.pollOptionCounts ?? const {},
      myVoteOptionId: message.pollMyVoteOptionId,
      isClosed: meta['is_closed'] == true,
      anonymousVotes: meta['anonymous_votes'] == true,
    );
  }

  static Map<String, dynamic> metadataFor({
    required String question,
    required List<TribeChatPollOption> options,
    bool anonymousVotes = false,
  }) {
    return {
      'kind': 'poll',
      'question': question.trim(),
      'options': options
          .map((o) => {'id': o.id, 'text': o.text.trim()})
          .toList(),
      'anonymous_votes': anonymousVotes,
      'is_closed': false,
    };
  }
}

/// Keeper prompt card (`metadata.kind = question`).
class TribeChatQuestion {
  const TribeChatQuestion({
    required this.prompt,
    this.autoCheckin = false,
  });
  final String prompt;
  final bool autoCheckin;

  factory TribeChatQuestion.fromMessage(TribeMessage message) {
    final meta = message.metadata ?? const {};
    return TribeChatQuestion(
      prompt: (meta['prompt'] as String?) ?? '',
      autoCheckin: meta['auto_checkin'] == true,
    );
  }

  static Map<String, dynamic> metadataFor(String prompt) {
    return {'kind': 'question', 'prompt': prompt.trim()};
  }
}

/// Tribe chat emoji reactions (migration 0066).
class TribeChatReaction {
  const TribeChatReaction._();

  static const same = 'same';
  static const proud = 'proud';
  static const tea = 'tea';
  static const heart = 'heart';

  static const all = [same, proud, tea, heart];

  static String label(String key) => switch (key) {
        same => 'Same',
        proud => 'Proud',
        tea => 'Tea',
        heart => 'Heart',
        _ => key,
      };

  /// Maps the four legacy preset keys to their emoji. Any other value is
  /// already a raw emoji the user picked from their keyboard, so it renders
  /// as itself.
  static String emoji(String key) => switch (key) {
        same => '🙌',
        proud => '💪',
        tea => '🍵',
        heart => '💜',
        _ => key,
      };

  /// True for the four built-in reaction keys; false for a raw keyboard emoji.
  static bool isPreset(String key) => all.contains(key);
}
