import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../theme/colors.dart';

/// Email-based sign-up screen.
///
/// Collects email + password + handle + birth date, calls
/// SessionController.registerWithEmail, and either routes the user to
/// the post-signup recovery-key reveal (when session is created
/// immediately) or shows a "check your inbox" wait state (when the
/// project enforces email confirmation).
class EmailSignupScreen extends ConsumerStatefulWidget {
  const EmailSignupScreen({super.key});
  @override
  ConsumerState<EmailSignupScreen> createState() => _EmailSignupScreenState();
}

class _EmailSignupScreenState extends ConsumerState<EmailSignupScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _username = TextEditingController();
  DateTime? _birthDate;
  bool _busy = false;
  bool _checkInbox = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _username.dispose();
    super.dispose();
  }

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year - 18, now.month, now.day),
      firstDate: DateTime(now.year - 100),
      lastDate: now,
    );
    if (picked != null) setState(() => _birthDate = picked);
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_birthDate == null) {
        throw const FormatException('Pick your birth date so we can age-gate.');
      }
      const avatarSeed = 'v2:silhouette=orb;palette=berry;hair=none;'
          'accessory=none;aura=glow;outfit=none';
      final result =
          await ref.read(sessionProvider.notifier).registerWithEmail(
                birthDate: _birthDate!,
                email: _email.text.trim(),
                username: _username.text.trim(),
                password: _password.text,
                avatarSeed: avatarSeed,
              );
      if (!mounted) return;
      if (result.user == null) {
        // Email confirmation required — show wait state.
        setState(() => _checkInbox = true);
        return;
      }
      // Session created — surface the recovery phrase, then land on /feed.
      // A non-blocking banner on Home nudges email verification (Venttly's own
      // 6-digit code flow, since Supabase's global confirm-email toggle stays
      // off for the anonymous flow).
      context.go('/onboarding/key', extra: result.recoveryPhrase);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checkInbox) {
      return _CheckInboxState(email: _email.text.trim());
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Continue with email',
            style: TextStyle(fontWeight: FontWeight.w900)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Use email if you want password reset to come to your inbox. '
                'Your handle on Venttly stays anonymous either way.',
                style: TextStyle(
                  color: context.ink.withOpacity(0.7),
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.mail_outline_rounded),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _username,
                autocorrect: false,
                maxLength: 20,
                decoration: const InputDecoration(
                  labelText: 'Anonymous handle',
                  hintText: 'e.g. nightowl',
                  prefixIcon: Icon(Icons.alternate_email_rounded),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  prefixIcon: Icon(Icons.lock_outline_rounded),
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _pickBirthDate,
                icon: const Icon(Icons.cake_outlined, size: 18),
                label: Text(
                  _birthDate == null
                      ? 'Pick your birth date'
                      : 'Birth date: '
                          '${_birthDate!.year}-${_birthDate!.month.toString().padLeft(2, '0')}-${_birthDate!.day.toString().padLeft(2, '0')}',
                ),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color:
                        Theme.of(context).colorScheme.error.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              FilledButton(
                onPressed: _busy ? null : _submit,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(54),
                  backgroundColor: VentlyColors.berryMagenta,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        'Create my account',
                        style: TextStyle(fontWeight: FontWeight.w900),
                      ),
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => context.push('/onboarding/identity'),
                child: const Text(
                  'Or continue anonymously (no email)',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckInboxState extends StatelessWidget {
  const _CheckInboxState({required this.email});
  final String email;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
          child: Column(
            children: [
              const SizedBox(height: 24),
              Container(
                width: 96,
                height: 96,
                decoration: const BoxDecoration(
                  color: Color(0xFFFFE3EC),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.mark_email_read_outlined,
                    color: VentlyColors.berryMagenta, size: 42),
              ),
              const SizedBox(height: 18),
              Text(
                'Check your inbox',
                style: TextStyle(
                  color: context.ink,
                  fontWeight: FontWeight.w900,
                  fontSize: 22,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'We sent a confirmation link to:\n$email',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.ink.withOpacity(0.72),
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Open it on this device to land back inside Venttly.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xFF8B5566),
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => context.go('/onboarding'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  backgroundColor: VentlyColors.berryMagenta,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
                child: const Text(
                  'Back to welcome',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
