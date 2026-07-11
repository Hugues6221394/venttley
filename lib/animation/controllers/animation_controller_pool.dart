import 'package:flutter/widgets.dart';

/// Central [AnimationController] pool — prevents controller spam in
/// feed-heavy screens by reusing controllers keyed by purpose.
///
/// Own one pool per screen/state object, call [disposeAll] in `dispose()`.
class AnimationControllerPool {
  final Map<String, AnimationController> _pool = {};

  /// Returns the controller for [key], creating it on first use.
  /// [vsync] and [duration] only apply on creation.
  AnimationController get(
    String key,
    TickerProvider vsync, {
    Duration duration = const Duration(milliseconds: 350),
  }) {
    return _pool.putIfAbsent(
      key,
      () => AnimationController(vsync: vsync, duration: duration),
    );
  }

  /// Disposes and evicts a single controller (e.g. an item left the list).
  void release(String key) {
    _pool.remove(key)?.dispose();
  }

  void disposeAll() {
    for (final c in _pool.values) {
      c.dispose();
    }
    _pool.clear();
  }
}
