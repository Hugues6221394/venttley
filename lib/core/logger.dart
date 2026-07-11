import 'package:flutter/foundation.dart';

import 'pii_scrubber.dart';

/// Centralised logger. Service implementations write through this
/// instead of reaching into `print` / `debugPrint` directly so we can:
///   * scrub PII on every payload
///   * route through Sentry breadcrumbs in release
///   * silence noisy categories without code surgery
///
/// Usage:
///   log.info('feed.loaded', props: {'count': 42});
///   log.warn('cache.miss', props: {'key': 'home_stats'});
///   log.error('chat.send_failed', error: e, stack: st);
class Logger {
  Logger._();
  static final Logger instance = Logger._();

  /// Per-category mute set. Useful for noisy in-development surfaces.
  final Set<String> _muted = <String>{};
  void mute(String category) => _muted.add(category);
  void unmute(String category) => _muted.remove(category);

  /// Optional callback for Sentry / OTEL integrations to subscribe to.
  /// The wrapper guarantees the payload is already PII-scrubbed.
  void Function(LogRecord record)? onRecord;

  void debug(
    String event, {
    Map<String, Object?> props = const {},
    Object? error,
    StackTrace? stack,
  }) =>
      _emit(LogLevel.debug, event, props, error: error, stack: stack);

  void info(
    String event, {
    Map<String, Object?> props = const {},
    Object? error,
    StackTrace? stack,
  }) =>
      _emit(LogLevel.info, event, props, error: error, stack: stack);

  void warn(
    String event, {
    Map<String, Object?> props = const {},
    Object? error,
    StackTrace? stack,
  }) =>
      _emit(LogLevel.warn, event, props, error: error, stack: stack);

  void error(
    String event, {
    Map<String, Object?> props = const {},
    Object? error,
    StackTrace? stack,
  }) =>
      _emit(LogLevel.error, event, props, error: error, stack: stack);

  void _emit(
    LogLevel level,
    String event,
    Map<String, Object?> props, {
    Object? error,
    StackTrace? stack,
  }) {
    final category = event.split('.').first;
    if (_muted.contains(category)) return;

    final scrubbed = PiiScrubber.scrub(props);
    final record = LogRecord(
      level: level,
      event: event,
      props: scrubbed,
      error: error,
      stack: stack,
      at: DateTime.now(),
    );

    onRecord?.call(record);

    if (kDebugMode) {
      // Format: [LEVEL] event {props}
      // Avoid debugPrint for ERROR so the IDE highlights it red.
      // ignore: avoid_print
      print(
        '[${level.name.toUpperCase()}] $event ${scrubbed.isEmpty ? '' : scrubbed}',
      );
      if (error != null) print('   error: $error');
      if (stack != null) print('   stack: $stack');
    }
  }
}

enum LogLevel { debug, info, warn, error }

class LogRecord {
  final LogLevel level;
  final String event;
  final Map<String, Object?> props;
  final Object? error;
  final StackTrace? stack;
  final DateTime at;
  const LogRecord({
    required this.level,
    required this.event,
    required this.props,
    required this.at,
    this.error,
    this.stack,
  });
}

/// Top-level shorthand so call sites read like `log.info(...)`.
final Logger log = Logger.instance;
