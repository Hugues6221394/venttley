import '../../core/constants.dart';

/// Which function files an appeal against a decision.
enum AppealRoute { moderationCase, account, verification }

/// Where an appeal stands, from the member's side.
enum AppealStatus {
  /// Nothing filed. Whether one *can* be filed is [EnforcementNotice.canAppeal].
  none,
  open,
  upheld,
  overturned,
  withdrawn;

  static AppealStatus parse(String? raw) => switch (raw) {
    'open' => AppealStatus.open,
    'upheld' => AppealStatus.upheld,
    'overturned' => AppealStatus.overturned,
    'withdrawn' => AppealStatus.withdrawn,
    _ => AppealStatus.none,
  };

  String get label => switch (this) {
    AppealStatus.none => 'Not appealed',
    AppealStatus.open => 'Under review',
    AppealStatus.upheld => 'Decision stands',
    AppealStatus.overturned => 'Decision reversed',
    AppealStatus.withdrawn => 'Withdrawn',
  };
}

/// One enforcement decision as the member sees it, with the appeal against it.
///
/// Assembled on the client from two rows the member may already read: their own
/// `notifications` row of kind `moderation_action`, which carries the action,
/// policy code, the moderator's stated reason and whether it can be appealed;
/// and their own `moderation_appeals` row, which carries the outcome and the
/// reviewer's note.
///
/// Deliberately not a new RPC. `moderation_cases` is not readable by members
/// and should not become so — it holds the reporter's identity, the evidence
/// snapshot and internal case history. Everything a member is owed about a
/// decision was already written to them when it was taken; this reads what
/// they were told, not the case file behind it.
class EnforcementNotice {
  const EnforcementNotice({
    required this.action,
    required this.decidedAt,
    required this.appealable,
    this.notificationId,
    this.caseId,
    this.verificationRequestId,
    this.policyCode,
    this.reason,
    this.appealId,
    this.appealStatus = AppealStatus.none,
    this.appealStatement,
    this.reviewNote,
    this.appealedAt,
  });

  /// The notice row itself. For an account-level action this is what an appeal
  /// is filed against, because there is no case and no request — the notice is
  /// the decision as far as the member is concerned.
  final String? notificationId;

  /// Null for decisions taken outside a moderation case.
  ///
  /// `notify_enforcement` is called with no case for account-level actions
  /// (`admin_set_user_status`, the suspension ladder, `admin_lift_suspension`)
  /// and for verification decisions, and `jsonb_strip_nulls` then removes the
  /// key entirely. Those notices are real and must be shown; they simply have
  /// nothing `submit_appeal` can be pointed at. See [needsOffAppRoute].
  final String? caseId;

  /// Set for verification decisions. Carried by the notice since
  /// 20261022090000; notices written before that have none and fall back to
  /// the off-app route.
  final String? verificationRequestId;

  /// What was done, in the database's own vocabulary.
  ///
  /// Four families, and the shape of each matters because both the label and
  /// the appeal route depend on it:
  ///
  ///   * `case_<decision>` — from `admin_decide_case`, which sends
  ///     `'case_' || p_decision`. Case-backed, so appealable in-app.
  ///   * `account_<status>` and `account_reinstated` — from
  ///     `admin_set_user_status`, `admin_suspend_user_ladder` and
  ///     `admin_lift_suspension`. No case id.
  ///   * `verification_approved` / `verification_denied`.
  ///   * `appeal_upheld` / `appeal_overturned` — the outcome of an appeal,
  ///     sent with `p_appealable => false` because it is final at this tier.
  ///
  /// The first draft of this file guessed `user_warned` and `user_suspended`,
  /// which the database never sends. Every one of those notices would have
  /// rendered as a bare "Moderation decision" with no indication anything was
  /// wrong.
  final String action;
  final DateTime decidedAt;

  /// What the decision itself said about appealing.
  final bool appealable;
  final String? policyCode;

  /// The moderator's note. This is what the member was told, verbatim.
  final String? reason;

  final String? appealId;
  final AppealStatus appealStatus;
  final String? appealStatement;

  /// The reviewer's note on the outcome, which the appellant may read.
  final String? reviewNote;
  final DateTime? appealedAt;

  /// How long a decision stays contestable. Mirrors the window in
  /// `submit_appeal`: thirty days from the decision, not from the case
  /// opening.
  static const Duration appealWindow = Duration(days: 30);

  bool get withinAppealWindow =>
      DateTime.now().difference(decidedAt) < appealWindow;

  /// True when this notice can still be appealed from inside the app.
  ///
  /// Mirrors `submit_appeal`, which is the authority — it refuses with a
  /// message naming the rule, and that message is shown to the member
  /// unchanged. This only decides whether to offer the button, and being wrong
  /// in either direction is a real cost: offering it on a decision that will be
  /// refused, or hiding it from someone still entitled to appeal.
  ///
  /// Withdrawing does not spend the appeal — `submit_appeal` bars a refile only
  /// after an outcome ('upheld' or 'overturned'), because being heard is what
  /// is final, not having filed. An [AppealStatus.open] appeal is barred by the
  /// unique index rather than by finality; withdraw it first.
  ///
  /// Requires a route: a case for `submit_appeal`, a request for
  /// `submit_verification_appeal`, or the notice itself for
  /// `submit_account_appeal`.
  bool get canAppeal =>
      appealable &&
      appealRoute != null &&
      withinAppealWindow &&
      (appealStatus == AppealStatus.none ||
          appealStatus == AppealStatus.withdrawn);

  /// Which function files an appeal against this decision.
  ///
  /// Three, because three kinds of decision exist and each reverses
  /// differently: a case appeal restores the content and writes to the case
  /// history, an account appeal reinstates the account, and a verification
  /// appeal puts the application back in the queue rather than granting the
  /// badge. Routing them through one function would have to guess.
  AppealRoute? get appealRoute {
    if (caseId != null) return AppealRoute.moderationCase;
    if (verificationRequestId != null) return AppealRoute.verification;
    if (notificationId != null) return AppealRoute.account;
    return null;
  }

  /// True when the member was told they may appeal and the app has no way to
  /// file one.
  ///
  /// 20261022090000 closed this for account-level and verification decisions,
  /// which had none. What is left are notices written before that migration:
  /// a verification refusal from the old workflow carries no request id, and
  /// nothing can recover it from the payload. Those name a channel rather than
  /// leaving someone to conclude there is no recourse.
  bool get needsOffAppRoute => appealable && appealRoute == null;

  /// A human label for what was done.
  String get actionLabel => switch (action) {
    'case_content_removed' => 'Content removed',
    'case_user_warned' => 'Warning issued',
    'case_user_suspended' => 'Account suspended',
    'case_user_banned' => 'Account banned',
    'account_suspended' => 'Account suspended',
    'account_restricted' => 'Account restricted',
    'account_reinstated' => 'Account reinstated',
    'verification_approved' => 'Verification approved',
    'verification_denied' => 'Verification declined',
    'appeal_overturned' => 'Decision reversed',
    'appeal_upheld' => 'Appeal reviewed',
    _ => 'Moderation decision',
  };

  /// Why this cannot be appealed here, phrased for the member. Null when it
  /// can be, and null when there is nothing useful to say — an unappealable
  /// decision is not told it is unappealable, which would only invite the
  /// question.
  String? get appealBlockedReason {
    if (canAppeal || !appealable) return null;
    if (appealStatus == AppealStatus.upheld ||
        appealStatus == AppealStatus.overturned) {
      return 'This decision has been through appeal. That outcome is final '
          'at this tier.';
    }
    if (!withinAppealWindow) {
      return 'The 30-day window to appeal this decision has passed.';
    }
    if (needsOffAppRoute) {
      return 'This decision is appealable, but not from inside the app yet. '
          'Email ${VentlyConfig.appealsEmail} within 30 days and quote the '
          'date above.';
    }
    return null;
  }

  /// Build from the member's own notification payload.
  ///
  /// A missing `case_id` is normal — see [caseId]. A missing `decided_at` is
  /// not, and such a row is skipped rather than dated with "now": a moderation
  /// notice carrying the wrong date is worse than one that is absent, because
  /// the date is what the appeal window is counted from.
  static EnforcementNotice? fromNotificationPayload(
    Map<String, dynamic> payload, {
    String? notificationId,
  }) {
    final decidedAt = DateTime.tryParse(
      (payload['decided_at'] as String?) ?? '',
    );
    if (decidedAt == null) return null;
    return EnforcementNotice(
      notificationId: notificationId,
      caseId: payload['case_id'] as String?,
      verificationRequestId: payload['verification_request_id'] as String?,
      action: (payload['action'] as String?) ?? 'moderation_action',
      decidedAt: decidedAt.toLocal(),
      appealable: payload['appealable'] == true,
      policyCode: payload['policy'] as String?,
      reason: payload['reason'] as String?,
    );
  }

  EnforcementNotice withAppeal({
    required String appealId,
    required AppealStatus status,
    String? statement,
    String? reviewNote,
    DateTime? appealedAt,
  }) => EnforcementNotice(
    // Every field that decides the appeal route has to survive the copy. When
    // notificationId did not, a suspension with any appeal history lost its
    // route and the card offered an email address instead of the button —
    // visible only once an appeal existed, which no unit test constructed.
    notificationId: notificationId,
    caseId: caseId,
    verificationRequestId: verificationRequestId,
    action: action,
    decidedAt: decidedAt,
    appealable: appealable,
    policyCode: policyCode,
    reason: reason,
    appealId: appealId,
    appealStatus: status,
    appealStatement: statement,
    reviewNote: reviewNote,
    appealedAt: appealedAt,
  );
}
