import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/logger.dart';

/// Stripe subscription state mirror.
///
/// The client never talks to Stripe directly — it reads from the
/// `subscriptions` table that the `payment-webhook` Edge Function
/// keeps in sync with Stripe events. That keeps the secret key
/// server-side and means a user's premium status survives a fresh
/// install (it's tied to their account, not the device).
///
/// Premium UI surfaces hide behind `await subscriptions.isPremium()`
/// — the call returns false when the user is signed-out or Stripe
/// isn't wired up yet, so plumbing this in early is harmless.
abstract class SubscriptionService {
  static final SubscriptionService instance = _SupabaseSubscriptionService(
    Supabase.instance.client,
  );

  /// Refresh from the server. Returns the current snapshot.
  Future<SubscriptionSnapshot> refresh();

  /// Cheap convenience — true when [status] is `active` or `trialing`
  /// and the plan tier is anything above free.
  Future<bool> isPremium();

  Stream<SubscriptionSnapshot> watch();
}

class SubscriptionSnapshot {
  final String
  status; // 'free' | 'trialing' | 'active' | 'past_due' | 'canceled'
  final String tier; // 'free' | 'plus' | 'pro' | …
  final DateTime? renewsAt;
  final DateTime? canceledAt;
  const SubscriptionSnapshot({
    required this.status,
    required this.tier,
    this.renewsAt,
    this.canceledAt,
  });
  bool get isActive => status == 'active' || status == 'trialing';
  bool get isPaid => isActive && tier != 'free';

  static const free = SubscriptionSnapshot(status: 'free', tier: 'free');
}

class _SupabaseSubscriptionService implements SubscriptionService {
  _SupabaseSubscriptionService(this._client);
  final SupabaseClient _client;

  final _controller = StreamController<SubscriptionSnapshot>.broadcast();
  SubscriptionSnapshot _cached = SubscriptionSnapshot.free;

  @override
  Future<SubscriptionSnapshot> refresh() async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) {
      _cached = SubscriptionSnapshot.free;
      _controller.add(_cached);
      return _cached;
    }
    try {
      final row = await _client
          .from('subscriptions')
          .select('status, tier, renews_at, canceled_at')
          .eq('user_id', uid)
          .maybeSingle();
      _cached = row == null
          ? SubscriptionSnapshot.free
          : SubscriptionSnapshot(
              status: (row['status'] as String?) ?? 'free',
              tier: (row['tier'] as String?) ?? 'free',
              renewsAt: row['renews_at'] == null
                  ? null
                  : DateTime.tryParse(row['renews_at'].toString()),
              canceledAt: row['canceled_at'] == null
                  ? null
                  : DateTime.tryParse(row['canceled_at'].toString()),
            );
    } catch (e) {
      log.warn('subscription.refresh_failed', error: e);
    }
    _controller.add(_cached);
    return _cached;
  }

  @override
  Future<bool> isPremium() async => (await refresh()).isPaid;

  @override
  Stream<SubscriptionSnapshot> watch() => _controller.stream;
}
