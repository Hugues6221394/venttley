import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logger.dart';
import '../../domain/reactions/reaction_overrides.dart';
import '../repositories/vently_repository.dart';

/// Outcome of a tap, for the caller that needs to tell the user something.
enum ReactionResult {
  /// The server accepted it. Nothing to say.
  confirmed,

  /// The server refused it and the UI has been rolled back.
  rolledBack,

  /// Superseded by a newer tap on the same Vent. Not an error, and not
  /// something to report — the newer tap owns the outcome.
  superseded,
}

/// Owns the optimistic reaction state.
///
/// The whole point is the ordering inside [toggle]: the override is written
/// **before** the await, so the heart and the counter move on the same frame
/// as the tap. The network call happens afterwards and only ever removes the
/// override or leaves it in place.
class ReactionController extends StateNotifier<ReactionOverrides> {
  ReactionController(this._repo) : super(const ReactionOverrides.empty()) {
    _queue = ReactionSendQueue(
      (postId, desired) => _repo.reactExact(postId: postId, reaction: desired),
    );
  }

  final VentlyRepository _repo;
  late final ReactionSendQueue _queue;

  /// Set, switch or clear the caller's reaction on a Vent.
  ///
  /// [currentReaction] is what the UI is showing right now — already including
  /// any override — so tapping the filled heart clears it and tapping an empty
  /// one sets [reaction].
  Future<ReactionResult> toggle({
    required String postId,
    required String reaction,
    required String? currentReaction,
  }) {
    final desired = currentReaction == reaction ? null : reaction;
    return setReaction(postId: postId, desired: desired);
  }

  /// Apply an explicit desired reaction (`null` clears it).
  Future<ReactionResult> setReaction({
    required String postId,
    required String? desired,
  }) async {
    final previous = state.forPost(postId);
    final override = previous == null
        ? ReactionOverride(desired: desired, sequence: 1)
        : previous.bump(desired);

    // Optimistic write, before any await. Everything below this line is
    // reconciliation.
    state = state.withOverride(postId, override);

    try {
      final settled = await _queue.submit(postId, desired, override.sequence);

      // A newer tap took over while this was in flight. Leave the override
      // alone — it belongs to that tap now, and clearing it here would revert
      // the user's most recent action.
      final current = state.forPost(postId);
      if (current == null || current.sequence != override.sequence) {
        return ReactionResult.superseded;
      }

      if (settled != desired) {
        // The server settled somewhere else — a guard rejected it, most
        // usefully the self-reaction trigger. Its answer wins.
        log.warn(
          'reaction.server_settled_elsewhere',
          props: {'requested': desired ?? 'none', 'settled': settled ?? 'none'},
        );
        state = state.without(postId);
        return ReactionResult.rolledBack;
      }

      // Confirmed. The override stays until the feed refetches: dropping it
      // now would repaint from feed data that still holds the old value, and
      // the heart would visibly flip back. `apply` is a no-op once the server
      // agrees, so leaving it costs nothing.
      return ReactionResult.confirmed;
    } catch (error) {
      final current = state.forPost(postId);
      if (current != null && current.sequence != override.sequence) {
        // Superseded, and the newer tap will report its own outcome. Do not
        // roll back on its behalf.
        return ReactionResult.superseded;
      }
      log.warn('reaction.failed', props: {'error': error.toString()});
      state = state.without(postId);
      return ReactionResult.rolledBack;
    }
  }

  /// Forget confirmed overrides once fresh server data agrees with them.
  ///
  /// Not required for correctness — [ReactionOverrides.apply] is already a
  /// no-op when the server agrees — but it keeps the map from growing for the
  /// length of a session on a long feed scroll.
  void pruneAgainst(Iterable<({String postId, String? serverReaction})> rows) {
    if (state.isEmpty) return;
    var next = state;
    for (final row in rows) {
      final override = next.forPost(row.postId);
      if (override != null && override.desired == row.serverReaction) {
        next = next.without(row.postId);
      }
    }
    if (next.length != state.length) state = next;
  }
}
