import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/constants.dart';
import '../../core/logger.dart';

/// Feature flags layer.
///
/// Two stores in a fall-through chain:
///   1. PostHog flags (when `POSTHOG_KEY` is set) — remote rollouts +
///      A/B tests + per-user gating.
///   2. Local defaults — the source of truth for every flag the app
///      knows about. Used as the dev / offline / no-key baseline.
///
/// Call sites read flags as `await flags.bool('whispers_recorder')` so
/// the rest of the codebase never thinks about the network.
abstract class FeatureFlagsService {
  static final FeatureFlagsService instance = VentlyConfig.isPosthogEnabled
      ? _PostHogFlagsService(
          apiKey: VentlyConfig.posthogKey,
          host: VentlyConfig.posthogHost,
        )
      : _LocalFlagsService();

  /// All known flags + their default values. New flags MUST be added
  /// here so the local impl can answer without a network round-trip.
  static const Map<String, Object> defaults = {
    'whispers_feed': true,
    'whispers_recorder': true,
    'voice_filters_dsp': true,
    'chat_v2': true,
    'tribe_group_chat': true,
    'premium_themes': false,
    'experimental_homepage': false,
    'ai_recommendations': false, // locked
    // Reserved for a future, independently reviewed cryptographic protocol.
    // A disabled flag must never cause an encryption claim to appear in UI.
    'e2ee_chat_real': false,
    'paid_boosted_tribes': false,
    'creator_donations': false,
  };

  /// Identify the current user so server-side targeting can scope
  /// rollouts (e.g. percentage rollouts, country buckets).
  Future<void> identify(String userId,
      {Map<String, Object?> traits = const {}});

  /// Returns the boolean value of [key]. Falls back to [defaults] when
  /// unknown / network unreachable.
  Future<bool> boolFlag(String key);

  /// Returns the string / variant value of [key]. Useful for A/B tests
  /// where multiple variants exist beyond on/off.
  Future<String> stringFlag(String key, {String fallback = ''});

  /// Force-refresh the local flag cache. No-op for the local impl.
  Future<void> refresh();
}

class _LocalFlagsService implements FeatureFlagsService {
  @override
  Future<void> identify(String userId,
      {Map<String, Object?> traits = const {}}) async {}

  @override
  Future<bool> boolFlag(String key) async {
    final v = FeatureFlagsService.defaults[key];
    return v is bool ? v : false;
  }

  @override
  Future<String> stringFlag(String key, {String fallback = ''}) async {
    final v = FeatureFlagsService.defaults[key];
    return v is String ? v : fallback;
  }

  @override
  Future<void> refresh() async {}
}

class _PostHogFlagsService implements FeatureFlagsService {
  _PostHogFlagsService({required this.apiKey, required this.host});
  final String apiKey;
  final String host;

  String? _distinctId;
  Map<String, Object?> _cache = const {};
  DateTime _cacheAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _cacheTtl = Duration(minutes: 5);

  @override
  Future<void> identify(String userId,
      {Map<String, Object?> traits = const {}}) async {
    _distinctId = userId;
    await refresh();
  }

  @override
  Future<bool> boolFlag(String key) async {
    await _ensureFresh();
    final v = _cache[key];
    if (v is bool) return v;
    if (v is String) return v == 'true' || v == '1' || v == 'on';
    final fallback = FeatureFlagsService.defaults[key];
    return fallback is bool ? fallback : false;
  }

  @override
  Future<String> stringFlag(String key, {String fallback = ''}) async {
    await _ensureFresh();
    final v = _cache[key];
    if (v is String) return v;
    if (v != null) return v.toString();
    final fb = FeatureFlagsService.defaults[key];
    return fb is String ? fb : fallback;
  }

  Future<void> _ensureFresh() async {
    if (DateTime.now().difference(_cacheAt) < _cacheTtl) return;
    await refresh();
  }

  @override
  Future<void> refresh() async {
    if (_distinctId == null) return;
    try {
      final res = await http.post(
        Uri.parse('$host/decide/?v=3'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'api_key': apiKey,
          'distinct_id': _distinctId,
        }),
      );
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, Object?>;
        final flags = (body['featureFlags'] as Map?)?.cast<String, Object?>();
        if (flags != null) {
          _cache = flags;
          _cacheAt = DateTime.now();
        }
      }
    } catch (e) {
      log.warn('flags.refresh_failed', error: e);
    }
  }
}
