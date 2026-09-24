import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';

/// What the button should say, and what happens after it is pressed.
///
/// Three screens offered to join a tribe and all three behaved differently.
/// The directory called `joinTribe` and threw the answer away, so pressing
/// Join on a private tribe did nothing visible — the pill still read "Join"
/// after a refresh, because a pending request is not a membership. The
/// recommended-tribe card in Friends did the same and then optimistically
/// said "You joined ${tribe.name}" and flipped itself to "View", which was
/// simply false. Only the detail screen read the status.
///
/// Hence one place. The server answers `'joined'` or `'pending'`; both are
/// reported, and the label says which one to expect before it is pressed.

/// The label for a join button, given what joining this tribe actually does.
String tribeJoinLabel(Tribe tribe) => switch (tribe.visibility) {
  'invite_only' => 'Invite only',
  'private' => 'Request to join',
  _ => 'Join',
};

/// The same thing in one word, for the 82px pill on a recommendation card.
String tribeJoinLabelShort(Tribe tribe) => switch (tribe.visibility) {
  'invite_only' => 'Invite',
  'private' => 'Ask',
  _ => 'Join',
};

/// Whether the button should be pressable at all.
///
/// An invite-only tribe raises `invite_required` on the server, so offering a
/// button that can only fail is worse than showing a disabled one that says
/// why.
bool canRequestToJoin(Tribe tribe) =>
    tribe.visibility != 'invite_only' && tribe.acceptsNewActivity;

/// Join, or ask to, and say which one happened.
///
/// Returns the server's status, or null if it failed.
Future<String?> joinTribeAndTell(
  BuildContext context,
  WidgetRef ref,
  Tribe tribe,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final status = await ref.read(repositoryProvider).joinTribe(tribe.tribeId);
    ref.invalidate(tribesProvider);
    ref.invalidate(tribeBySlugProvider);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          status == 'pending'
              ? 'Request sent. The Keeper will let you know.'
              : 'You joined ${tribe.name}.',
        ),
      ),
    );
    return status;
  } catch (error) {
    messenger?.showSnackBar(SnackBar(content: Text(_explainJoin(error))));
    return null;
  }
}

/// Postgres raises these as bare strings.
String _explainJoin(Object error) {
  final text = error.toString();
  if (text.contains('invite_required')) {
    return 'This Tribe is invite-only.';
  }
  if (text.contains('member_banned')) {
    return 'You cannot join this Tribe.';
  }
  if (text.contains('minimum_account_age_not_met')) {
    return 'This Tribe only accepts older accounts.';
  }
  if (text.contains('tribe_not_accepting_members')) {
    return 'This Tribe is not accepting members right now.';
  }
  return 'Could not join this Tribe.';
}

/// Leave, and say so if it could not be done.
Future<void> leaveTribeAndTell(
  BuildContext context,
  WidgetRef ref,
  Tribe tribe,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await ref.read(repositoryProvider).leaveTribe(tribe.tribeId);
    ref.invalidate(tribesProvider);
    ref.invalidate(tribeBySlugProvider);
  } catch (error) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          error.toString().contains('keeper_must_transfer_first')
              // A tribe with no keeper has nobody to approve a request or
              // answer a report, so this is a redirection rather than a wall.
              ? 'Hand the Tribe to somebody else before you leave it.'
              : 'Could not leave this Tribe.',
        ),
      ),
    );
  }
}
