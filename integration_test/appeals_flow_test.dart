// Appeals, against a real Supabase stack on a real device.
//
// The widget tests cover the screen and the pgTAP suite covers the rules. What
// neither touches is the join in between: `SupabaseBackend.myEnforcementHistory`
// issues two PostgREST reads under RLS and stitches them on `case_id`. Every
// way that can be wrong — a mistyped column, a policy that returns nothing, an
// appeal matched to the wrong decision — produces an empty or misleading screen
// and no error anywhere.
//
// Two things here are the kind that only a real backend catches:
//
//   * A notice with no `case_id`. `notify_enforcement` sends account-level
//     actions with no case and `jsonb_strip_nulls` deletes the key, so the
//     column is genuinely absent rather than null. An earlier draft required it
//     and silently dropped every suspension and ban — the most consequential
//     notices the platform sends.
//   * Which appeal belongs to a decision when there is more than one. Withdrawing
//     does not spend the appeal, so one case accumulates rows, and the member's
//     standing is the newest of them. Picking any other one shows a withdrawn
//     appeal as current and hides the open one.
//
// Deliberately NOT mock mode. Run it against the live local stack:
//
//   supabase start
//   psql "$DB" -f supabase/seed/test_accounts.sql
//   flutter test integration_test/appeals_flow_test.dart -d <simulator-id> \
//     --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
//     --dart-define=SUPABASE_ANON_KEY=<local anon key>

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/domain/moderation/enforcement_notice.dart';

const _url = String.fromEnvironment('SUPABASE_URL');
const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a member reads their own decisions and appeals one', (
    tester,
  ) async {
    expect(
      _url.isNotEmpty && _anonKey.isNotEmpty,
      isTrue,
      reason:
          'Pass --dart-define=SUPABASE_URL and --dart-define=SUPABASE_ANON_KEY. '
          'This test talks to a real stack on purpose.',
    );

    await Supabase.initialize(url: _url, anonKey: _anonKey, debug: false);
    final client = Supabase.instance.client;
    await client.auth.signInWithPassword(
      email: 'tester_user@id.venttly.app',
      password: 'TestPass123!',
    );
    expect(client.auth.currentUser, isNotNull, reason: 'signed in');

    final repo = VentlyRepository();
    final history = await repo.myEnforcementHistory();

    // The seeded decisions. If this is empty the two reads returned nothing
    // under RLS, which is the failure the screen cannot distinguish from a
    // clean record.
    expect(
      history,
      isNotEmpty,
      reason: 'no enforcement notices came back — seed a decision first, or '
          'the RLS policy on notifications is not returning the member their '
          'own rows',
    );

    // Every notice must have parsed. A null return from
    // fromNotificationPayload is dropped silently in the backend, so a schema
    // drift shows up here as a short list rather than an error.
    final rows = await client
        .from('notifications')
        .select('notification_id')
        .eq('user_id', client.auth.currentUser!.id)
        .eq('kind', 'moderation_action');
    expect(
      history.length,
      rows.length,
      reason: '${rows.length - history.length} moderation_action row(s) failed '
          'to parse and were dropped without a trace',
    );

    for (final notice in history) {
      expect(notice.actionLabel, isNot('Moderation decision'),
          reason: '"${notice.action}" has no label — notify_enforcement sends '
              'an action this client does not recognise');
    }

    final appealable = history.where((n) => n.canAppeal).toList();
    if (appealable.isEmpty) {
      // Not a failure: the seeded decisions may all be appealed or expired.
      // Say so rather than passing silently, because a suite that can never
      // reach the write path is not testing it.
      // ignore: avoid_print
      print('no appealable decision in the seed; the write path was not '
          'exercised this run');
      return;
    }

    // Prefer an account-level decision when one is available: it is the route
    // that had no function behind it until 20261022090000, and the one most
    // worth exercising against a real backend.
    final target = appealable.firstWhere(
      (n) => n.appealRoute == AppealRoute.account,
      orElse: () => appealable.first,
    );
    final appealId = await repo.submitAppeal(
      target,
      'Integration test: filing against ${target.actionLabel}.',
    );
    expect(appealId, isNotEmpty);

    // The read must now show it as open and carry the statement back.
    final after = await repo.myEnforcementHistory();
    final updated = after.firstWhere(
      (n) => n.notificationId == target.notificationId,
    );
    expect(updated.appealStatus, AppealStatus.open);
    expect(updated.appealStatement, contains('Integration test'));
    expect(updated.canAppeal, isFalse, reason: 'one open appeal at a time');

    // Withdraw, then confirm the door is open again — the rule the client
    // mirrors and the one most easily got backwards.
    await repo.withdrawAppeal(updated.appealId!);
    final afterWithdrawal = await repo.myEnforcementHistory();
    final reopened = afterWithdrawal.firstWhere(
      (n) => n.notificationId == target.notificationId,
    );
    expect(reopened.appealStatus, AppealStatus.withdrawn,
        reason: 'the newest appeal for this case is the withdrawn one');
    expect(reopened.canAppeal, isTrue,
        reason: 'withdrawing does not spend the appeal');
  });
}
