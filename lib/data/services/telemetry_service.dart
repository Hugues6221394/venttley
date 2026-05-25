import 'dart:async';

import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';

/// Lightweight observability layer.
///
/// Two sinks:
///   - Sentry (errors + breadcrumbs)         → live when SENTRY_DSN is set
///   - Supabase RPC `record_event`           → live when not in mock mode
///
/// Both are best-effort and never throw — telemetry must never break the
/// caller, especially in catch-blocks.
class TelemetryService {
  TelemetryService._();
  static final instance = TelemetryService._();

  bool _sentryReady = false;
  void markSentryReady() => _sentryReady = true;

  Future<void> event(
    String name, {
    Map<String, Object?> props = const {},
    String severity = 'info',
  }) async {
    _breadcrumb(name, props, severity);
    if (VentlyConfig.useMockBackend) return;
    try {
      await Supabase.instance.client.rpc(
        'record_event',
        params: {
          'p_name': name,
          'p_severity': severity,
          'p_props': props,
        },
      );
    } catch (_) {
      // Telemetry failures are silent — we already breadcrumbed locally.
    }
  }

  /// Capture an exception. Sends to Sentry when configured, always
  /// records a telemetry row tagged severity=error.
  Future<void> error(
    Object error,
    StackTrace stack, {
    String? name,
    Map<String, Object?> context = const {},
  }) async {
    if (_sentryReady) {
      unawaited(Sentry.captureException(error, stackTrace: stack));
    }
    await event(
      name ?? 'unhandled_error',
      props: {
        'error': error.toString(),
        ...context,
      },
      severity: 'error',
    );
  }

  void _breadcrumb(String name, Map<String, Object?> props, String severity) {
    if (!_sentryReady) return;
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: name,
        data: {for (final e in props.entries) e.key: e.value},
        level: switch (severity) {
          'error' => SentryLevel.error,
          'warn' => SentryLevel.warning,
          'debug' => SentryLevel.debug,
          _ => SentryLevel.info,
        },
      ),
    );
  }
}
