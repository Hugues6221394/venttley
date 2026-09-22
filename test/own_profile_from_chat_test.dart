import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// "Open your own profile from a space chat and there is no way back."
///
/// FriendProfileScreen handles every user id including your own, and for your
/// own it used to `context.go('/profile')`. `go` replaces the stack, and
/// `/profile` is the bottom-nav tab, which has no back affordance because a
/// tab does not need one. So the chat you came from was gone and the screen
/// you landed on had no way out.
///
/// It renders your profile in place now. pushReplacement would have fixed the
/// stack but not the route hazard — this screen is reachable from
/// conversations on the root navigator, and re-entering a shell-owned route
/// from there is the thing /user-preview and /post-preview exist to avoid.
void main() {
  test('your own profile is rendered, not navigated to', () {
    final src = File(
      'lib/presentation/screens/friends/friend_profile_screen.dart',
    ).readAsStringSync();

    expect(
      src,
      isNot(contains("context.go('/profile')")),
      reason:
          'go() replaces the stack, so the conversation you came from is lost '
          'and the tab you land on has no back button',
    );
    expect(
      src,
      contains('ProfileScreen(showBackButton: true)'),
      reason: 'the self case should render in place, with a back affordance',
    );
  });

  test('the route is chosen by the tree, not by matching path strings', () {
    final src = File(
      'lib/presentation/widgets/user_link.dart',
    ).readAsStringSync();

    // The prefix list was always going to fall behind the router. It had
    // /chat/, /group-chat/ and /post-preview/ on it, and missed tribe and
    // space chats, which are pushed onto the root navigator for exactly the
    // same reason but whose paths begin with /tribe/. Opening a profile from a
    // space's chat info page therefore pushed a shell-owned route from outside
    // the shell and tripped !keyReservation.contains(key), which surfaces as
    // the "This part of Venttly didn't load" boundary.
    expect(
      src,
      contains('rootNavigator: true'),
      reason:
          'whether the nearest Navigator is the root one is the actual '
          'question, and unlike a list of prefixes it cannot go stale',
    );
    expect(
      src,
      isNot(contains('GoRouterState.of(context).uri.path')),
      reason: 'the path-prefix check should be gone, not merely extended',
    );
  });

  test('nothing pushes a user profile route by hand', () {
    // One place decides which of the two profile routes to use. Twenty-two
    // call sites were pushing /user/:id directly, and the ones reachable from
    // a chat were the ones that crashed — so the rule was correct and simply
    // was not being asked.
    final offenders = <String>[];
    for (final entity in Directory('lib/presentation').listSync(
      recursive: true,
    )) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('user_link.dart')) continue;
      final src = entity.readAsStringSync();
      for (final line in src.split('\n')) {
        // The stat sub-route is a different destination and is not affected.
        if (line.contains("push('/user/") && !line.contains('/stat/')) {
          offenders.add('${entity.uri.pathSegments.last}: ${line.trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'these push a profile route directly instead of calling '
          'openUserProfile, so they will crash from anywhere outside the shell',
    );
  });
}
