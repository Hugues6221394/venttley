import 'dart:async';

import 'package:http/http.dart' as http;
import 'dart:convert';

import '../../core/constants.dart';
import '../../core/logger.dart';
import '../../core/pii_scrubber.dart';
import 'telemetry_service.dart';

/// Product analytics — events, identify, screens.
///
/// Default impl: routes through [TelemetryService] (Sentry breadcrumbs +
/// Supabase `record_event` RPC).
/// PostHog impl: same surface, POSTs to the PostHog ingestion API in
/// addition to the default sinks. Activates when `POSTHOG_KEY` env is
/// set — until then the no-op default keeps the call sites identical.
///
/// Every event is PII-scrubbed before transport. Confession bodies,
/// emails, and free-form message text are stripped automatically by
/// [PiiScrubber] so the data layer can't accidentally leak them.
abstract class AnalyticsService {
  /// Singleton — resolves to PostHog when env keys are present,
  /// otherwise to the in-process default impl.
  static final AnalyticsService instance = VentlyConfig.isPosthogEnabled
      ? _PostHogAnalytics(
          apiKey: VentlyConfig.posthogKey,
          host: VentlyConfig.posthogHost,
        )
      : _DefaultAnalytics();

  /// Track a discrete behavioural event.
  /// Property keys should be snake_case. Values are PII-scrubbed.
  Future<void> track(String event, {Map<String, Object?> props = const {}});

  /// Associate the current session with a stable user id. Idempotent.
  Future<void> identify(
    String userId, {
    Map<String, Object?> traits = const {},
  });

  /// Record a screen view. Maps to `$screen` in PostHog.
  Future<void> screen(String name, {Map<String, Object?> props = const {}});

  /// Reset session (e.g. on logout). Subsequent events are anonymous.
  Future<void> reset();
}

class _DefaultAnalytics implements AnalyticsService {
  @override
  Future<void> track(String event, {Map<String, Object?> props = const {}}) {
    log.info('analytics.$event', props: props);
    return TelemetryService.instance.event(event, props: props);
  }

  @override
  Future<void> identify(
    String userId, {
    Map<String, Object?> traits = const {},
  }) async {
    log.info('analytics.identify', props: {'user_id': userId, ...traits});
    // TelemetryService stores user_id implicitly via the session.
  }

  @override
  Future<void> screen(String name, {Map<String, Object?> props = const {}}) {
    return track('screen.$name', props: props);
  }

  @override
  Future<void> reset() async {
    log.info('analytics.reset');
  }
}

/// Live PostHog impl — POSTs to `/capture/`. Authoritative client lib
/// is `posthog_flutter` but we go raw HTTP here to avoid a heavy
/// dependency for an event sink. When PostHog ships a new endpoint or
/// the team wants session replay, swap in the official SDK behind this
/// same interface.
class _PostHogAnalytics implements AnalyticsService {
  _PostHogAnalytics({required this.apiKey, required this.host});
  final String apiKey;
  final String host;
  String? _distinctId;

  Uri get _capture => Uri.parse('$host/capture/');

  @override
  Future<void> track(
    String event, {
    Map<String, Object?> props = const {},
  }) async {
    log.info('analytics.$event', props: props);
    unawaited(TelemetryService.instance.event(event, props: props));
    final scrubbed = PiiScrubber.scrub(props);
    try {
      await http.post(
        _capture,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'api_key': apiKey,
          'event': event,
          'distinct_id': _distinctId ?? 'anonymous',
          'properties': scrubbed,
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        }),
      );
    } catch (e) {
      log.warn('analytics.posthog_failed', props: {'event': event}, error: e);
    }
  }

  @override
  Future<void> identify(
    String userId, {
    Map<String, Object?> traits = const {},
  }) async {
    _distinctId = userId;
    log.info('analytics.identify', props: {'user_id': userId});
    final scrubbed = PiiScrubber.scrub(traits);
    try {
      await http.post(
        _capture,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'api_key': apiKey,
          'event': r'$identify',
          'distinct_id': userId,
          r'$set': scrubbed,
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        }),
      );
    } catch (e) {
      log.warn('analytics.identify_failed', error: e);
    }
  }

  @override
  Future<void> screen(String name, {Map<String, Object?> props = const {}}) {
    return track(r'$screen', props: {r'$screen_name': name, ...props});
  }

  @override
  Future<void> reset() async {
    _distinctId = null;
    log.info('analytics.reset');
  }
}
