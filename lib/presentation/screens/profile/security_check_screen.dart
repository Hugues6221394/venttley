import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';

/// "Was this you?" — the only screen in Venttly that asks the user to make a
/// security decision.
///
/// Two design constraints follow from that. First, it must say *why* the
/// sign-in was flagged: "unusual activity" is unanswerable, while "a new device
/// in Nigeria after four failed password attempts" is something a person can
/// recognise or not. Second, neither answer may be the easy one — a screen
/// where "yes, that was me" is a big friendly button and "no" is a grey link
/// gets tapped through, and then it has protected nobody.
class SecurityCheckScreen extends ConsumerStatefulWidget {
  const SecurityCheckScreen({super.key});

  @override
  ConsumerState<SecurityCheckScreen> createState() =>
      _SecurityCheckScreenState();
}

class _SecurityCheckScreenState extends ConsumerState<SecurityCheckScreen> {
  late Future<List<SecurityAlert>> _future;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _future = ref.read(repositoryProvider).myUnresolvedSecurityAlerts();
  }

  Future<void> _reload() async {
    final future = ref.read(repositoryProvider).myUnresolvedSecurityAlerts();
    // Block body, not an arrow: `() => _future = future` evaluates to the
    // Future itself, and setState rejects a callback that returns one.
    setState(() {
      _future = future;
    });
    await future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Security check')),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: FutureBuilder<List<SecurityAlert>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return const _Message(
                icon: Icons.cloud_off_rounded,
                title: 'Couldn\'t check your account',
                body: 'Check your connection and pull down to try again.',
              );
            }

            final alerts = snapshot.data ?? const <SecurityAlert>[];
            if (alerts.isEmpty) {
              return const _Message(
                icon: Icons.verified_user_rounded,
                title: 'Nothing needs your attention',
                body:
                    'We haven\'t seen any sign-ins that looked unusual. You can '
                    'review your devices any time from Password & security.',
              );
            }

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 0, 6, 14),
                  child: Text(
                    alerts.length == 1
                        ? 'We noticed a sign-in that didn\'t look like your '
                              'usual activity.'
                        : 'We noticed ${alerts.length} sign-ins that didn\'t '
                              'look like your usual activity.',
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      fontWeight: FontWeight.w700,
                      color: context.ink,
                    ),
                  ),
                ),
                for (final alert in alerts)
                  _AlertCard(
                    alert: alert,
                    busy: _busy,
                    onWasMe: () => _answer(alert, true),
                    onWasNotMe: () => _answer(alert, false),
                  ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    'Locations are approximate and based on the country the '
                    'connection appears to come from. If you were travelling or '
                    'using a VPN, an unfamiliar country is expected.',
                    style: TextStyle(
                      color: context.ink.withValues(alpha: 0.55),
                      fontSize: 12.5,
                      height: 1.4,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _answer(SecurityAlert alert, bool wasMe) async {
    final confirmed = wasMe
        ? await _confirm(
            title: 'Confirm ${alert.label}?',
            body:
                'We\'ll trust this device and stop asking about it. Only do '
                'this if you recognise it.',
            action: 'Yes, that was me',
            destructive: false,
          )
        : await _confirm(
            title: 'Block ${alert.label}?',
            body:
                'We\'ll end its session and stop it signing in again, even '
                'with your password. Change your password straight after — '
                'whoever signed in knew it.',
            action: 'Block it',
            destructive: true,
          );
    if (!confirmed) return;

    setState(() => _busy = true);
    try {
      await ref
          .read(repositoryProvider)
          .resolveSuspiciousLogin(
            deviceSessionId: alert.deviceSessionId,
            wasMe: wasMe,
          );
      if (!mounted) return;
      await _reload();
      if (!mounted) return;
      if (!wasMe) {
        // Blocking without rotating the password leaves the credential that
        // got them in still working. Put the next step directly in reach
        // rather than trusting the user to go looking for it.
        _offerPasswordChange();
      }
    } catch (_) {
      if (mounted) _toast('That didn\'t go through. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _offerPasswordChange() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Device blocked. Change your password next.'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'Change',
          onPressed: () => context.push('/profile/password-security'),
        ),
      ),
    );
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
    required bool destructive,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: destructive
                ? ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE05C5C),
                    foregroundColor: Colors.white,
                  )
                : null,
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true && mounted;
  }

  void _toast(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({
    required this.alert,
    required this.busy,
    required this.onWasMe,
    required this.onWasNotMe,
  });

  final SecurityAlert alert;
  final bool busy;
  final VoidCallback onWasMe;
  final VoidCallback onWasNotMe;

  @override
  Widget build(BuildContext context) {
    const danger = Color(0xFFE05C5C);
    final reasons = alert.reasons;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: danger.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _icon(alert.deviceType),
                      size: 20,
                      color: danger,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                alert.label,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 14.5,
                                  color: context.ink,
                                ),
                              ),
                            ),
                            if (alert.isCurrent) ...[
                              const SizedBox(width: 8),
                              const _Chip(
                                label: 'This device',
                                color: VentlyColors.berryMagenta,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _subtitle(alert),
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.35,
                            fontWeight: FontWeight.w600,
                            color: context.ink.withValues(alpha: 0.58),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (reasons.isNotEmpty) ...[
                const SizedBox(height: 12),
                for (final reason in reasons)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Icon(
                            Icons.info_outline_rounded,
                            size: 14,
                            color: danger.withValues(alpha: 0.8),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            reason,
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.35,
                              fontWeight: FontWeight.w600,
                              color: context.ink.withValues(alpha: 0.72),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 10),
              // Both answers carry the same visual weight. Making "that was me"
              // the prettier button would train people to clear the prompt
              // without reading it.
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: busy ? null : onWasMe,
                    child: const Text('Yes, that was me'),
                  ),
                  OutlinedButton(
                    onPressed: busy ? null : onWasNotMe,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: danger,
                      side: const BorderSide(color: Color(0x33E05C5C)),
                    ),
                    child: const Text('No, block it'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _icon(String type) => switch (type) {
    'phone' => Icons.phone_iphone_rounded,
    'tablet' => Icons.tablet_mac_rounded,
    'desktop' => Icons.laptop_mac_rounded,
    'web' => Icons.language_rounded,
    _ => Icons.devices_other_rounded,
  };

  static String _subtitle(SecurityAlert alert) {
    final parts = <String>[
      if (alert.osName != null && alert.osName!.trim().isNotEmpty)
        alert.osName!.trim(),
      if (alert.country != null && alert.country!.isNotEmpty) alert.country!,
      _relative(alert.startedAt),
    ];
    return parts.join(' • ');
  }

  static String _relative(DateTime when) {
    final delta = DateTime.now().toUtc().difference(when.toUtc());
    if (delta.inMinutes < 2) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
    if (delta.inHours < 24) return '${delta.inHours}h ago';
    return '${delta.inDays}d ago';
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    // Scrollable so RefreshIndicator still works when there is nothing to show.
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 96, 32, 32),
      children: [
        Icon(icon, size: 44, color: context.ink.withValues(alpha: 0.28)),
        const SizedBox(height: 14),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 16,
            color: context.ink,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          body,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            height: 1.45,
            fontWeight: FontWeight.w600,
            color: context.ink.withValues(alpha: 0.55),
          ),
        ),
      ],
    );
  }
}
