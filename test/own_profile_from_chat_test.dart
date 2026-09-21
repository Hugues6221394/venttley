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

  test('a chat is a root conversation wherever it lives', () {
    final src = File(
      'lib/presentation/widgets/user_link.dart',
    ).readAsStringSync();

    // Tribe and space chats are pushed onto the root navigator so the footer
    // nav gets out of the way, but their paths start with /tribe/ — so the
    // original check saw them as ordinary shell routes and opened a
    // shell-owned profile from a root one.
    expect(
      src,
      contains("currentPath.contains('/chat')"),
      reason:
          'tribe and space chats are on the root navigator too, so profiles '
          'opened from them need the root-safe preview route',
    );
  });
}
