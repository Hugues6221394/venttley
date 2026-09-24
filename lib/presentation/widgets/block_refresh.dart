import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// Everything that changes when a block goes up or comes down.
///
/// Blocking used to delete the friendship row outright, so the only list that
/// needed refreshing was the blocks list itself — the friendship was gone and
/// was never coming back. Now blocking suspends it and unblocking restores it,
/// which means the friend list, the story ring, the presence rail and the
/// friend-status badge on a profile all change at the same moment.
///
/// One function, because both places that toggle a block invalidated only
/// myBlocksProvider, and "he must come back immediately in friend list" is the
/// requirement.
void refreshAfterBlockChange(WidgetRef ref) {
  ref.invalidate(myBlocksProvider);
  ref.invalidate(myFriendsProvider);
  ref.invalidate(friendStatusProvider);
  ref.invalidate(onlineFriendsProvider);
  ref.invalidate(inboxStreamProvider);
  // The story ring is not listed: both story providers already watch
  // myFriendsProvider, so invalidating that rebuilds them.
}
