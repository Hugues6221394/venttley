import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The first thing a brand-new user's app did was throw.
///
/// NotificationForegroundListener is mounted around the whole app in main.dart
/// so it can raise a local notification when a message arrives. It watches
/// allInboxRoomsStreamProvider, which starts fetching at launch — on the
/// welcome screen, before anyone has an account. `inbox_rooms` is granted to
/// `authenticated` only, correctly: the view carries DM metadata, and the
/// grant to `anon` was dropped in 20260719000932. So the query came back
///
///   PostgrestException(permission denied for view inbox_rooms, 42501)
///
/// and, because the stream added its result without catching, it escaped as
/// an unhandled exception rather than a stream error the UI could show.
///
/// Both halves are pinned here. These are source checks rather than
/// behavioural ones: the live path only exists when SupabaseBackend has a real
/// authenticated client, which a unit test has no way to produce, and the
/// alternative — re-granting anon so the query succeeds — is the thing that
/// must never happen.
void main() {
  test('the inbox is not queried without a session', () {
    final src = File(
      'lib/data/services/supabase_backend.dart',
    ).readAsStringSync();

    final start = src.indexOf(
      'Future<List<ChatRoom>> inbox({required String tab}) async {',
    );
    expect(start, isNot(-1), reason: 'inbox() has been renamed');
    final query = src.indexOf("from('inbox_rooms')", start);
    final guard = src.indexOf('if (_uid == null) return const [];', start);

    expect(guard, isNot(-1), reason: 'inbox() no longer checks for a session');
    expect(
      guard,
      lessThan(query),
      reason:
          'the session check has to come before the query, or the query still '
          'happens and still fails',
    );
  });

  test('a failed inbox fetch becomes a stream error, not an unhandled one', () {
    final src = File(
      'lib/data/repositories/vently_repository.dart',
    ).readAsStringSync();
    final start = src.indexOf('Stream<List<ChatRoom>> watchInbox(String tab) {');
    expect(start, isNot(-1), reason: 'watchInbox() has been renamed');
    final body = src.substring(start, start + 1200);

    expect(
      body,
      contains('controller.addError'),
      reason:
          'without this, a failed fetch throws inside an async callback nobody '
          'awaits — the provider can neither show it nor retry',
    );
  });

  test('anon is never granted the inbox back', () {
    // The permission error is real and the tempting fix is a one-line GRANT.
    // It would work, and it would make every signed-out client able to read
    // who is talking to whom.
    //
    // Four early migrations did grant it, up to 20260716224000; 20260719000932
    // recreated the view without anon and that is the state production is in.
    // Applied migrations cannot be edited, so the invariant is about what
    // comes next: nothing after the fix may hand it back.
    const fixedIn = '20260719000932';
    final offenders = <String>[];

    for (final entity in Directory('supabase/migrations').listSync()) {
      if (entity is! File || !entity.path.endsWith('.sql')) continue;
      final name = entity.uri.pathSegments.last;
      if (name.compareTo(fixedIn) <= 0) continue;

      for (final line in entity.readAsStringSync().split('\n')) {
        final sql = line.toLowerCase();
        if (!sql.contains('inbox_rooms')) continue;
        if (!sql.contains('grant') || sql.contains('revoke')) continue;
        if (sql.contains('anon')) offenders.add('$name: ${line.trim()}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'a migration grants anon read access to inbox_rooms — the view '
          'carries DM metadata, so this would expose who is talking to whom '
          'to every signed-out client',
    );
  });
}
