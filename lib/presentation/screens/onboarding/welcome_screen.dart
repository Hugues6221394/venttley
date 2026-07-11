import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants.dart';
import '../../../core/providers.dart';
import '../../theme/colors.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? [VentlyColors.charcoal, VentlyColors.cardDark]
                : [
                    const Color(0xFFFFEEF3),
                    const Color(0xFFFFF8F8),
                    VentlyColors.cardBlush,
                  ],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - 44,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(height: constraints.maxHeight < 760 ? 8 : 16),
                      const _WelcomeLogo(),
                      const SizedBox(height: 16),
                      Text(
                        'Welcome to Venttly',
                        textAlign: TextAlign.center,
                        style:
                            Theme.of(context).textTheme.headlineMedium?.copyWith(
                                  fontWeight: FontWeight.w900,
                                  color: isDark
                                      ? VentlyColors.softOffWhite
                                      : VentlyColors.deepBurgundy,
                                ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'A social space for anonymous stories, 24h vents, tribes, and honest conversations.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              color: scheme.onSurface.withOpacity(0.66),
                              height: 1.42,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 22),
                      const _TrustPanel(),
                      SizedBox(height: constraints.maxHeight < 760 ? 14 : 20),
                      ElevatedButton(
                        onPressed: () => context.push('/onboarding/identity'),
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size.fromHeight(58),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          ),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('Step into the Circle'),
                            SizedBox(width: 8),
                            Icon(Icons.arrow_forward_rounded, size: 18),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: () => context.push('/onboarding/email'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(54),
                          side: BorderSide(
                            color: scheme.primary.withOpacity(0.6),
                          ),
                          foregroundColor: scheme.primary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(28),
                          ),
                        ),
                        icon: const Icon(Icons.mail_outline_rounded, size: 18),
                        label: const Text(
                          'Continue with email',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Center(
                        child: TextButton(
                          onPressed: () =>
                              context.push('/onboarding/recover'),
                          child: RichText(
                            text: TextSpan(
                              style: TextStyle(
                                color: scheme.onSurface.withOpacity(0.72),
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                              children: [
                                const TextSpan(
                                    text: 'Already have an account?  '),
                                TextSpan(
                                  text: 'Log in',
                                  style: TextStyle(
                                    color: scheme.primary,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (VentlyConfig.socialAuthEnabled) ...[
                        const SizedBox(height: 16),
                        const _OrDivider(),
                        const SizedBox(height: 16),
                        const _SocialAuthRow(),
                      ],
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _OrDivider extends StatelessWidget {
  const _OrDivider();
  @override
  Widget build(BuildContext context) {
    final line = Expanded(
      child: Divider(color: VentlyColors.softMauve.withOpacity(0.4), height: 1),
    );
    return Row(
      children: [
        line,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'or continue with',
            style: TextStyle(
              color: VentlyColors.deepBurgundy.withOpacity(0.5),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ),
        line,
      ],
    );
  }
}

/// Optional Google + phone entry points. Both are additive to the anonymous
/// flow; each needs its provider configured in Supabase before it will work.
class _SocialAuthRow extends ConsumerStatefulWidget {
  const _SocialAuthRow();
  @override
  ConsumerState<_SocialAuthRow> createState() => _SocialAuthRowState();
}

class _SocialAuthRowState extends ConsumerState<_SocialAuthRow> {
  bool _busy = false;

  Future<void> _google() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(sessionProvider.notifier).signInWithGoogle();
      // The session arrives via the OAuth redirect; the router's refresh
      // listener routes to /feed once it lands.
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Google sign-in unavailable: ${e.toString().replaceFirst('Exception: ', '')}')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _SocialButton(
            icon: Icons.g_mobiledata_rounded,
            label: 'Google',
            onTap: _busy ? null : _google,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _SocialButton(
            icon: Icons.phone_iphone_rounded,
            label: 'Phone',
            onTap: _busy ? null : () => context.push('/onboarding/phone'),
          ),
        ),
      ],
    );
  }
}

class _SocialButton extends StatelessWidget {
  const _SocialButton({required this.icon, required this.label, this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(50),
        side: BorderSide(color: VentlyColors.softMauve.withOpacity(0.6)),
        foregroundColor: VentlyColors.deepBurgundy,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      ),
      icon: Icon(icon, size: 22),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
    );
  }
}

class _WelcomeLogo extends StatelessWidget {
  const _WelcomeLogo();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 188,
        height: 188,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(34),
          boxShadow: [
            BoxShadow(
              color: VentlyColors.berryMagenta.withOpacity(0.12),
              blurRadius: 34,
              offset: const Offset(0, 20),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.asset(
          'assets/images/venttly_logo.png',
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

class _TrustPanel extends StatelessWidget {
  const _TrustPanel();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.62),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.30)),
      ),
      child: const Column(
        children: [
          _Bullet(
            icon: Icons.lock_outline,
            title: 'Anonymous by design',
            text: 'No email or phone number needed to start.',
          ),
          _Bullet(
            icon: Icons.auto_awesome_rounded,
            title: 'Stories, feeds, and tribes',
            text: 'Read what hits your vibe and join spaces that feel alive.',
          ),
          _Bullet(
            icon: Icons.shield_outlined,
            title: 'Safer social energy',
            text: 'AI-assisted moderation helps keep posts cleaner.',
          ),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({
    required this.icon,
    required this.title,
    required this.text,
  });

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: scheme.primary.withOpacity(0.12),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(icon, color: scheme.primary, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: VentlyColors.deepBurgundy,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  text,
                  style: TextStyle(
                    color: VentlyColors.deepBurgundy.withOpacity(0.62),
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Replaced by the real EmailSignupScreen at /onboarding/email.
/// Kept here only as a reference for the soon-state pattern.
// ignore: unused_element
void _legacyShowEmailSoonSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: VentlyColors.softMauve.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 14),
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: scheme.primary.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(Icons.mail_lock_outlined,
                    color: scheme.primary, size: 38),
              ),
              const SizedBox(height: 14),
              const Text(
                'Email signup shipping this week',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: VentlyColors.deepBurgundy,
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Right now Venttly identities are zero-PII — username + recovery phrase. '
                'Email signup with verification + handle picking lands next. '
                'For today, the anonymous flow is the path forward.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: VentlyColors.deepBurgundy.withOpacity(0.65),
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  GoRouter.of(context).push('/onboarding/identity');
                },
                style: FilledButton.styleFrom(
                  backgroundColor: VentlyColors.berryMagenta,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 28, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: const Text(
                  'Continue anonymously',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
