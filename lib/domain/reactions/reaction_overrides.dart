import 'dart:async';

import '../entities/entities.dart';

/// A reaction the user has expressed that the server has not confirmed yet.
///
/// Holds only the *desired* state, not a count delta. The delta is derived at
/// render time from whatever the server currently says, which makes the
/// override self-correcting: it is right before the server has caught up, and
/// it becomes a no-op the moment the server agrees. A stored delta would go
/// wrong as soon as anybody else reacted to the same Vent.
class ReactionOverride {
  const ReactionOverride({required this.desired, required this.sequence});

  /// The reaction the user wants — `null` means they removed it.
  final String? desired;

  /// Monotonic per-post tap counter.
  ///
  /// Rapid tapping is the case this exists for: taps 1..n each start a send,
  /// and responses can land out of order. A response is only allowed to
  /// settle the override if it belongs to the newest tap.
  final int sequence;

  ReactionOverride bump(String? next) =>
      ReactionOverride(desired: next, sequence: sequence + 1);
}

/// The optimistic reaction layer.
///
/// Before this, tapping the heart did:
///
///     await repo.react(...)          // network round trip
///     ref.invalidate(feedPostsProvider)   // and then refetch the whole feed
///
/// so the heart did not move until both finished. The backend was never the
/// problem — `set_post_reaction` is a desired-state RPC and has been
/// idempotent since migration 0052. The delay was entirely client-side.
///
/// What this does *not* do is decide the truth. The server remains
/// authoritative: [apply] only paints over what the server has not told us
/// yet, a rejected write is rolled back to the server's value, and nothing
/// here increments a stored counter that could drift.
class ReactionOverrides {
  const ReactionOverrides(this._byPostId);

  const ReactionOverrides.empty() : _byPostId = const {};

  final Map<String, ReactionOverride> _byPostId;

  bool get isEmpty => _byPostId.isEmpty;
  int get length => _byPostId.length;

  ReactionOverride? forPost(String postId) => _byPostId[postId];

  /// What this Vent should look like right now.
  ///
  /// Derives the count adjustment from `post.likesCount` rather than storing
  /// one, so:
  ///
  ///  * before the server catches up, the count moves by exactly one;
  ///  * once the server reports the same reaction, the adjustment is zero and
  ///    the post passes through untouched — so a lingering override cannot
  ///    double-count;
  ///  * if somebody else reacted in between, their change is preserved,
  ///    because the base is always the server's latest number.
  Post apply(Post post) {
    final override = _byPostId[post.postId];
    if (override == null) return post;

    final serverReaction = post.myReaction;
    if (serverReaction == override.desired) return post;

    // Reactions are one-per-user, so switching from 'hug' to 'love' does not
    // change the total — only adding or removing does.
    final adjust =
        (override.desired == null ? 0 : 1) - (serverReaction == null ? 0 : 1);

    return post.copyWith(
      myReaction: override.desired,
      // Clamped: a stale feed page can report 0 while the user is removing a
      // reaction the server has already dropped, and a negative count would
      // render as "-1 Hugs".
      likesCount: (post.likesCount + adjust).clamp(0, 1 << 30),
    );
  }

  ReactionOverrides withOverride(String postId, ReactionOverride override) =>
      ReactionOverrides({..._byPostId, postId: override});

  ReactionOverrides without(String postId) =>
      ReactionOverrides({..._byPostId}..remove(postId));
}

/// Serialises the writes for one Vent and keeps only the newest intent.
///
/// Two properties matter here, and both come from rapid tapping:
///
///  * **One write at a time per Vent.** Concurrent `set_post_reaction` calls
///    for the same row would race in the database and the last commit to land
///    would win — which is not necessarily the last tap.
///  * **Only the newest intent is worth sending.** The RPC is desired-state,
///    so ten taps do not need ten round trips; they need one call carrying
///    the tenth value. Intermediate taps are coalesced away rather than
///    queued, which is what keeps the UI responsive on a bad connection.
class ReactionSendQueue {
  ReactionSendQueue(this._send);

  /// Performs the write. Returns the reaction the server settled on.
  final Future<String?> Function(String postId, String? desired) _send;

  final Map<String, _PendingSend> _pending = {};

  /// Queue [desired] for [postId].
  ///
  /// Returns the server's final answer for the *last* intent submitted, or
  /// throws if that write failed. A tap that is superseded before it is sent
  /// completes with the superseding tap's result — the caller only ever needs
  /// to reconcile against the newest one.
  Future<String?> submit(String postId, String? desired, int sequence) {
    final existing = _pending[postId];
    if (existing != null) {
      // A send is already in flight or queued. Replace its target and let the
      // existing chain deliver it, rather than starting a second write.
      existing.desired = desired;
      existing.sequence = sequence;
      return existing.completer.future;
    }

    final pending = _PendingSend(desired: desired, sequence: sequence);
    _pending[postId] = pending;
    _drain(postId, pending);
    return pending.completer.future;
  }

  Future<void> _drain(String postId, _PendingSend pending) async {
    try {
      // Loops, because a tap that arrives while the request is open updates
      // `pending.desired`. When that happens the loop sends again rather than
      // returning a result the user has already moved past.
      while (true) {
        final sending = pending.desired;
        final sequence = pending.sequence;
        final settled = await _send(postId, sending);
        if (pending.desired == sending && pending.sequence == sequence) {
          _pending.remove(postId);
          pending.completer.complete(settled);
          return;
        }
      }
    } catch (error, stack) {
      _pending.remove(postId);
      pending.completer.completeError(error, stack);
    }
  }

  /// In-flight or queued writes, for tests and diagnostics.
  int get inFlight => _pending.length;
}

class _PendingSend {
  _PendingSend({required this.desired, required this.sequence});

  String? desired;
  int sequence;
  final Completer<String?> completer = Completer<String?>();
}
