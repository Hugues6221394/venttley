import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';

/// Every place this account is currently signed in, with a way to end each one.
///
/// The list answers one question under stress — "is someone else in my
/// account?" — so the current device is pinned first and labelled, and every
/// other row leads to a single obvious action.
class ActiveDevicesScreen extends ConsumerStatefulWidget {
  const ActiveDevicesScreen({super.key});

  @override
  ConsumerState<ActiveDevicesScreen> createState() =>
      _ActiveDevicesScreenState();
}

class _ActiveDevicesScreenState extends ConsumerState<ActiveDevicesScreen> {
  late Future<List<DeviceSession>> _future;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _future = ref.read(repositoryProvider).myDeviceSessions();
  }

  Future<void> _reload() async {
    final future = ref.read(repositoryProvider).myDeviceSessions();
    setState(() => _future = future);
    await future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Where you\'re logged in')),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: FutureBuilder<List<DeviceSession>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return const _Message(
                icon: Icons.cloud_off_rounded,
                title: 'Couldn\'t load your devices',
                body: 'Check your connection and pull down to try again.',
              );
            }

            final sessions = snapshot.data ?? const <DeviceSession>[];
            if (sessions.isEmpty) {
              return const _Message(
                icon: Icons.devices_other_rounded,
                title: 'No other sessions',
                body:
                    'This is the only device signed in to your account right '
                    'now.',
              );
            }

            final others = sessions.where((s) => !s.isCurrent).length;

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                for (final session in sessions)
                  _DeviceCard(
                    session: session,
                    busy: _busy,
                    onSignOut: () => _signOut(session),
                    onNotYou: () => _notYou(session),
                  ),
                if (others > 0) ...[
                  const SizedBox(height: 8),
                  _DangerButton(
                    label: others == 1
                        ? 'Sign out of 1 other device'
                        : 'Sign out of $others other devices',
                    onPressed: _busy ? null : _signOutOthers,
                  ),
                ],
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    'Locations are approximate and based on the country your '
                    'connection appears to come from. Signing a device out '
                    'takes effect within about a minute.',
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

  Future<void> _signOut(DeviceSession session) async {
    // Ending your own session is a sign-out, not device management. Send the
    // user to the existing global path rather than silently killing the app
    // they are holding.
    if (session.isCurrent) {
      _toast('Use "Sign out everywhere" to end this device\'s session.');
      return;
    }
    if (!await _confirm(
      title: 'Sign out ${session.label}?',
      body:
          'That device will need your username and password to sign back in.',
      action: 'Sign out',
    )) {
      return;
    }
    await _run(() => ref.read(repositoryProvider).revokeDeviceSession(
          session.deviceSessionId,
        ));
  }

  Future<void> _notYou(DeviceSession session) async {
    if (!await _confirm(
      title: 'Block ${session.label}?',
      body:
          'We\'ll end its session and stop it signing in again, even with your '
          'password. Change your password next if you think someone else knows '
          'it.',
      action: 'Block device',
    )) {
      return;
    }
    await _run(
      () => ref.read(repositoryProvider).blockDevice(session.deviceRowId),
    );
  }

  Future<void> _signOutOthers() async {
    if (!await _confirm(
      title: 'Sign out other devices?',
      body: 'You\'ll stay signed in here. Every other device will be ended.',
      action: 'Sign out others',
    )) {
      return;
    }
    await _run(
      () => ref.read(repositoryProvider).revokeOtherDeviceSessions(),
    );
  }

  Future<void> _run(Future<Object?> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      await _reload();
    } catch (_) {
      if (mounted) _toast('That didn\'t go through. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
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

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.session,
    required this.busy,
    required this.onSignOut,
    required this.onNotYou,
  });

  final DeviceSession session;
  final bool busy;
  final VoidCallback onSignOut;
  final VoidCallback onNotYou;

  @override
  Widget build(BuildContext context) {
    const accent = VentlyColors.berryMagenta;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(_icon(session.deviceType),
                        size: 20, color: accent),
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
                                session.label,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 14.5,
                                  color: context.ink,
                                ),
                              ),
                            ),
                            if (session.isCurrent) ...[
                              const SizedBox(width: 8),
                              const _Chip(label: 'This device', color: accent),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _subtitle(session),
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
              if (!session.isCurrent) ...[
                const SizedBox(height: 6),
                // Wrap, not Row: "This wasn't me" plus "Sign out" overflow a
                // card on a 390pt phone, and the second action is the one
                // someone reaching for it most needs to be able to hit.
                Wrap(
                  spacing: 4,
                  runSpacing: 2,
                  children: [
                    TextButton(
                      onPressed: busy ? null : onSignOut,
                      child: const Text('Sign out'),
                    ),
                    TextButton(
                      onPressed: busy ? null : onNotYou,
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFFE05C5C),
                      ),
                      child: const Text('This wasn\'t me'),
                    ),
                  ],
                ),
              ],
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

  static String _subtitle(DeviceSession session) {
    final parts = <String>[
      if (session.platformSummary.isNotEmpty) session.platformSummary,
      if (session.country != null && session.country!.isNotEmpty)
        session.country!,
      _relative(session.lastSeenAt),
    ];
    return parts.join(' • ');
  }

  static String _relative(DateTime when) {
    final delta = DateTime.now().toUtc().difference(when.toUtc());
    if (delta.inMinutes < 2) return 'active now';
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

class _DangerButton extends StatelessWidget {
  const _DangerButton({required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.logout_rounded, size: 18),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFFE05C5C),
          side: const BorderSide(color: Color(0x33E05C5C)),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    // Scrollable so RefreshIndicator still works when there is nothing to show.
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 96, 32, 32),
      children: [
        Icon(
          icon,
          size: 44,
          color: context.ink.withValues(alpha: 0.28),
        ),
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
