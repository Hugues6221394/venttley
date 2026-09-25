import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every realtime stream has to be rebuilt when the signed-in user changes.
///
/// Reported from the phone: Notifications said "All quiet for now" and the
/// whole list appeared on a pull to refresh. The stream behind it reads its
/// rows as auth.currentUser and subscribes to that user's realtime channel,
/// both at the moment it is created — and the bell badge on the feed watches
/// it, so it is created during the first frame, sometimes before the session
/// has been restored. Created with no user, it read nothing and subscribed to
/// nothing, and nothing afterwards retried either. It stayed empty until
/// something invalidated it by hand.
///
/// The fix is one line per provider, and one line is exactly the kind of thing
/// the next realtime feature will forget. So this reads the file.
void main() {
  test('a StreamProvider over a realtime read watches the session', () {
    final source = File('lib/core/providers.dart').readAsStringSync();

    // Top-level declarations, which is granular enough: each one is a single
    // `final x = ...;`.
    final declarations = source.split(RegExp(r'\nfinal '));
    final offenders = <String>[];

    for (final declaration in declarations) {
      if (!declaration.contains('StreamProvider')) continue;
      final subscribes = RegExp(
        r'repositoryProvider\)\s*\.\s*watch[A-Z]',
      ).hasMatch(declaration);
      if (!subscribes) continue;
      if (declaration.contains('sessionProvider')) continue;

      offenders.add(declaration.split('=').first.trim());
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'these providers open a realtime stream as whoever is signed in when '
          'they are built, and are never rebuilt when that changes. Add '
          '`ref.watch(sessionProvider.select((user) => user?.userId));` — the '
          'id, not the whole AppUser, so a mood change does not tear down a '
          'channel:\n  ${offenders.join('\n  ')}',
    );
  });
}
