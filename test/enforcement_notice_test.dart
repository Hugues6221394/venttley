// When the app offers an appeal, and when it must not.
//
// `canAppeal` is a client-side copy of rules that live in `submit_appeal`
// (20261007090000). The database is the authority and refuses with a message,
// so a wrong answer here is never a security hole — but it is a product one in
// both directions. Offering the button on a decision the database will refuse
// makes the platform look like it is pretending to hear you. Hiding it from
// someone still entitled to appeal takes away the only recourse they have, and
// silently.
//
// The two rules most easily got wrong, and both were, in the first draft of
// this screen:
//
//   * Withdrawing does not spend the appeal. submit_appeal bars a refile only
//     after an outcome — "one bite at this tier. Withdrawing does not spend
//     it; being heard does." A client treating 'withdrawn' as spent locks
//     people out of a door the database is holding open.
//   * There is a thirty-day window, from the decision. A notice from last year
//     is not appealable, and offering it produces a refusal the member cannot
//     do anything about.
//
// Both were then confirmed against a live database rather than read off the
// migration: submit_appeal refused a refile while one was open, accepted one
// after a withdrawal, and refused the 45-day-old case with the exact sentence
// this screen shows.
//
// The action strings are checked here too, because the first draft invented
// them. The database sends 'case_user_suspended'; the client looked for
// 'user_suspended'. Every real notice would have rendered as an unlabelled
// "Moderation decision" and nothing would have looked broken.

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/domain/moderation/enforcement_notice.dart';

EnforcementNotice _notice({
  bool appealable = true,
  AppealStatus status = AppealStatus.none,
  Duration age = const Duration(days: 1),
  String? caseId = '20000000-0000-4000-8000-000000000001',
  String? notificationId,
}) => EnforcementNotice(
  caseId: caseId,
  notificationId: notificationId,
  action: 'case_content_removed',
  decidedAt: DateTime.now().subtract(age),
  appealable: appealable,
  appealStatus: status,
);

void main() {
  group('canAppeal mirrors submit_appeal', () {
    test('a fresh appealable decision can be appealed', () {
      expect(_notice().canAppeal, isTrue);
    });

    test('a withdrawn appeal can be refiled — withdrawing does not spend it',
        () {
      expect(_notice(status: AppealStatus.withdrawn).canAppeal, isTrue);
    });

    test('an open appeal offers no second one', () {
      // Barred by appeals_one_open_per_case, not by finality. The screen
      // offers Withdraw instead.
      expect(_notice(status: AppealStatus.open).canAppeal, isFalse);
    });

    test('a decided appeal is final at this tier', () {
      for (final status in [AppealStatus.upheld, AppealStatus.overturned]) {
        expect(_notice(status: status).canAppeal, isFalse,
            reason: '$status should be final');
      }
    });

    test('the window closes at thirty days', () {
      expect(_notice(age: const Duration(days: 29)).canAppeal, isTrue);
      expect(_notice(age: const Duration(days: 31)).canAppeal, isFalse);
    });

    test('an account-level decision is appealed through its notice', () {
      // No case, so submit_appeal cannot take it. submit_account_appeal keys
      // on the notice the member received, which is the decision as far as
      // they are concerned and carries the date the window runs from.
      final notice = _notice(caseId: null, notificationId: 'notice-1');
      expect(notice.appealRoute, AppealRoute.account);
      expect(notice.canAppeal, isTrue);
      expect(notice.needsOffAppRoute, isFalse);
    });

    test('a notice from before the account route existed has none', () {
      // Payloads written before 20261022090000 carry neither a case nor a
      // notice reference this client can use. They are shown, and the card
      // names a channel instead.
      expect(_notice(caseId: null).canAppeal, isFalse);
      expect(_notice(caseId: null).needsOffAppRoute, isTrue);
    });

    test('a decision marked unappealable is never offered', () {
      // Shadow restriction sends no notice at all, but a reversal notice does
      // arrive carrying appealable: false — there is nothing left to contest.
      expect(_notice(appealable: false).canAppeal, isFalse);
    });
  });

  group('blocked reasons are explained, or silent', () {
    test('an expired window says so', () {
      expect(
        _notice(age: const Duration(days: 40)).appealBlockedReason,
        contains('30-day'),
      );
    });

    test('a decided appeal says it is final', () {
      expect(
        _notice(status: AppealStatus.upheld).appealBlockedReason,
        contains('final'),
      );
    });

    test('an unappealable decision is not told it is unappealable', () {
      // Nothing useful to say, and saying it only invites the question.
      expect(_notice(appealable: false).appealBlockedReason, isNull);
    });

    test('an account-level decision names a channel instead', () {
      // Not silence. Someone who has just been suspended and told they may
      // appeal must not be left hunting for a control that does not exist.
      expect(
        _notice(caseId: null).appealBlockedReason,
        contains('@'),
      );
    });

    test('an open appeal is not reported as blocked', () {
      // It is not blocked; it is in progress, and the card says so with the
      // status chip.
      expect(_notice(status: AppealStatus.open).appealBlockedReason, isNull);
    });
  });

  group('parsing the notification payload', () {
    test('reads what notify_enforcement writes', () {
      final notice = EnforcementNotice.fromNotificationPayload({
        'action': 'case_user_suspended',
        'case_id': '20000000-0000-4000-8000-000000000001',
        'policy': 'harassment',
        'reason': 'Repeated targeting of one member after a warning.',
        'appealable': true,
        'decided_at': '2026-09-01T10:00:00Z',
      });
      expect(notice, isNotNull);
      expect(notice!.action, 'case_user_suspended');
      expect(notice.actionLabel, 'Account suspended');
      expect(notice.policyCode, 'harassment');
      expect(notice.appealable, isTrue);
      expect(notice.decidedAt.toUtc(), DateTime.utc(2026, 9, 1, 10));
    });

    test('jsonb_strip_nulls means optional keys are absent, not null', () {
      // notify_enforcement strips nulls, so a decision with no policy code and
      // no note arrives as a payload missing those keys entirely.
      final notice = EnforcementNotice.fromNotificationPayload({
        'action': 'case_user_warned',
        'case_id': '20000000-0000-4000-8000-000000000001',
        'appealable': true,
        'decided_at': '2026-09-01T10:00:00Z',
      });
      expect(notice, isNotNull);
      expect(notice!.policyCode, isNull);
      expect(notice.reason, isNull);
    });

    test('appealable is false unless the payload says true', () {
      // A missing key must not read as appealable. Offering an appeal the
      // database will refuse is worse than not offering one.
      final notice = EnforcementNotice.fromNotificationPayload({
        'action': 'appeal_overturned',
        'case_id': '20000000-0000-4000-8000-000000000001',
        'decided_at': '2026-09-01T10:00:00Z',
      });
      expect(notice!.appealable, isFalse);
    });

    test('an account-level notice parses without a case id', () {
      // This is the normal shape for a suspension, not a malformed row.
      final notice = EnforcementNotice.fromNotificationPayload({
        'action': 'account_suspended',
        'policy': 'tier_1',
        'reason': 'Suspended for seven days after a second finding.',
        'appealable': true,
        'decided_at': '2026-09-01T10:00:00Z',
      });
      expect(notice, isNotNull);
      expect(notice!.caseId, isNull);
      expect(notice.actionLabel, 'Account suspended');
      // Parsed without a notification id here, which is the pre-migration
      // shape; the backend supplies one from the row it read.
      expect(notice.canAppeal, isFalse);
      expect(notice.needsOffAppRoute, isTrue);
    });

    test('the notice id makes an account decision appealable', () {
      final notice = EnforcementNotice.fromNotificationPayload(
        {
          'action': 'account_suspended',
          'appealable': true,
          'decided_at': DateTime.now()
              .toUtc()
              .subtract(const Duration(days: 1))
              .toIso8601String(),
        },
        notificationId: 'notice-1',
      );
      expect(notice!.appealRoute, AppealRoute.account);
      expect(notice.canAppeal, isTrue);
    });

    test('a verification decision carries its request id', () {
      final notice = EnforcementNotice.fromNotificationPayload(
        {
          'action': 'verification_denied',
          'verification_request_id': '30000000-0000-4000-8000-000000000001',
          'appealable': true,
          'decided_at': DateTime.now()
              .toUtc()
              .subtract(const Duration(days: 1))
              .toIso8601String(),
        },
        notificationId: 'notice-2',
      );
      // The request wins over the notice: overturning reopens the application,
      // which the account route cannot do.
      expect(notice!.appealRoute, AppealRoute.verification);
    });

    test('a row with no date is skipped rather than dated with now', () {
      // The date is what the appeal window is counted from, so a wrong one is
      // worse than an absent row.
      expect(
        EnforcementNotice.fromNotificationPayload({
          'action': 'case_user_warned',
          'case_id': '20000000-0000-4000-8000-000000000001',
        }),
        isNull,
      );
    });

    test('every action the database sends has a label', () {
      // Enumerated from the six notify_enforcement call sites in
      // 20261007090000. A bare "Moderation decision" here means an action was
      // added and this switch was not.
      const sent = [
        'case_content_removed',
        'case_user_warned',
        'case_user_suspended',
        'case_user_banned',
        'account_suspended',
        'account_restricted',
        'account_reinstated',
        'verification_approved',
        'verification_denied',
        'appeal_upheld',
        'appeal_overturned',
      ];
      for (final action in sent) {
        final notice = EnforcementNotice.fromNotificationPayload({
          'action': action,
          'decided_at': '2026-09-01T10:00:00Z',
        });
        expect(notice!.actionLabel, isNot('Moderation decision'),
            reason: '"\$action" is sent by notify_enforcement and has no label');
      }
    });

    test('an unknown action still gets a label rather than a raw identifier',
        () {
      final notice = EnforcementNotice.fromNotificationPayload({
        'action': 'some_action_added_later',
        'case_id': '20000000-0000-4000-8000-000000000001',
        'decided_at': '2026-09-01T10:00:00Z',
      });
      expect(notice!.actionLabel, 'Moderation decision');
    });
  });

  group('copying a notice keeps its route', () {
    // withAppeal is applied to every notice that has one, so a field dropped
    // here is invisible until an appeal exists — and then the card silently
    // stops offering the button. The integration test caught exactly this.
    test('an account notice keeps its notification id', () {
      final copied = _notice(caseId: null, notificationId: 'notice-1')
          .withAppeal(appealId: 'a1', status: AppealStatus.withdrawn);
      expect(copied.appealRoute, AppealRoute.account);
      expect(copied.canAppeal, isTrue,
          reason: 'withdrawing does not spend the appeal');
    });

    test('a verification notice keeps its request id', () {
      final copied = EnforcementNotice(
        action: 'verification_denied',
        decidedAt: DateTime.now().subtract(const Duration(days: 1)),
        appealable: true,
        verificationRequestId: 'request-1',
      ).withAppeal(appealId: 'a1', status: AppealStatus.open);
      expect(copied.appealRoute, AppealRoute.verification);
    });

    test('a case notice keeps its case id', () {
      final copied = _notice()
          .withAppeal(appealId: 'a1', status: AppealStatus.open);
      expect(copied.appealRoute, AppealRoute.moderationCase);
    });
  });

  group('appeal status', () {
    test('every status the CHECK allows parses', () {
      // Mirrors the CHECK on moderation_appeals.status.
      for (final raw in ['open', 'upheld', 'overturned', 'withdrawn']) {
        expect(AppealStatus.parse(raw), isNot(AppealStatus.none),
            reason: '"$raw" is a status the database can store');
      }
    });

    test('an unrecognised status reads as none, not as a crash', () {
      expect(AppealStatus.parse('something_new'), AppealStatus.none);
      expect(AppealStatus.parse(null), AppealStatus.none);
    });
  });
}
