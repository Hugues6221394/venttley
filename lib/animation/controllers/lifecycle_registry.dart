import 'dart:collection';

/// Remembers which items already played their entrance animation, so feed
/// items animate exactly once — scrolling back up never replays them.
///
/// Bounded (LRU) so an infinite feed can't grow it without limit.
class AnimationLifecycleRegistry {
  AnimationLifecycleRegistry({this.capacity = 600});

  final int capacity;
  final LinkedHashSet<String> _seen = LinkedHashSet<String>();

  /// True the first time [id] is asked about; false afterwards.
  bool shouldAnimate(String id) {
    if (_seen.contains(id)) return false;
    _seen.add(id);
    if (_seen.length > capacity) {
      _seen.remove(_seen.first);
    }
    return true;
  }

  /// Forget everything — call on pull-to-refresh if a fresh entrance pass
  /// is desired.
  void reset() => _seen.clear();
}

/// Shared registry for the home feed. Screens with their own lists may
/// create private instances instead.
final feedAnimationRegistry = AnimationLifecycleRegistry();
