import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/password_policy.dart';
import '../../../core/providers.dart';
import '../../theme/colors.dart';
import '../../../animation/widgets/animated_button.dart';

/// Reset a password using the verified recovery email on the account.
///
/// Until this existed the only way back into a locked-out account was the
/// 12-word phrase, which is a fine mechanism and a poor only-mechanism: it is
/// handed over at signup, the moment somebody is least invested, and the people
/// this app is for are exactly the people who will not have kept it. Meanwhile
/// they have a recovery email sitting verified in their settings, doing
/// nothing at the one moment it matters.
///
/// Three steps in one screen rather than three routes, because the back button
/// should return to sign-in from any of them, not walk backwards through a
/// half-finished reset.
class PasswordResetScreen extends ConsumerStatefulWidget {
  const PasswordResetScreen({super.key});

  @override
  ConsumerState<PasswordResetScreen> createState() =>
      _PasswordResetScreenState();
}

enum _Step { identify, code, newPassword }

class _PasswordResetScreenState extends ConsumerState<PasswordResetScreen> {
  static const int _resendCooldown = 60;

  _Step _step = _Step.identify;

  final _identifier = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool _busy = false;
  bool _showPassword = false;
  String? _error;
  String? _notice;

  /// Empty until loaded, and empty forever if it cannot be fetched. The other
  /// rules still apply, and a wordlist that failed to download must never stop
  /// somebody recovering their account.
  Set<String> _weakBases = const {};

  Timer? _ticker;
  int _remaining = 0;

  @override
  void initState() {
    super.initState();
    _loadWeakBases();
  }

  Future<void> _loadWeakBases() async {
    try {
      final bases = await ref.read(repositoryProvider).weakPasswordBases();
      if (mounted) setState(() => _weakBases = bases);
    } catch (_) {
      // Deliberately silent — see the field comment.
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _identifier.dispose();
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _ticker?.cancel();
    setState(() => _remaining = _resendCooldown);
    _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _remaining--);
      if (_remaining <= 0) t.cancel();
    });
  }

  // ---------------------------------------------------------------------------
  // Step 1 — who are you
  // ---------------------------------------------------------------------------

  Future<void> _sendCode({bool resend = false}) async {
    final identifier = _identifier.text.trim();
    if (identifier.isEmpty) {
      setState(() => _error = 'Enter your email or your username.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });

    try {
      await ref.read(repositoryProvider).requestPasswordReset(identifier);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'We could not reach the server. Check your connection.';
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      _step = _Step.code;
      // Carefully non-committal. The server will not tell us whether that
      // account exists or has a verified address, because an app that says
      // "no account with that email" is an app that lets anyone check who is
      // here. So this promises nothing except that we tried.
      _notice = resend
          ? 'If that account has a verified recovery email, a new code is on '
                'its way.'
          : 'If that account has a verified recovery email, we have sent a '
                '6-digit code to it.';
    });
    _startCooldown();
  }

  // ---------------------------------------------------------------------------
  // Step 2 → 3 — the code is only checked when the new password is submitted
  // ---------------------------------------------------------------------------

  void _codeEntered() {
    final code = _code.text.trim();
    if (code.length < 6) {
      setState(() => _error = 'Enter the 6-digit code from your email.');
      return;
    }
    setState(() {
      _error = null;
      _notice = null;
      _step = _Step.newPassword;
    });
  }

  Future<void> _finish() async {
    final problem = PasswordPolicy.problem(
      _password.text,
      weakBases: _weakBases,
    );
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    if (_password.text != _confirm.text) {
      setState(() => _error = 'Those two passwords are not the same.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final failure = await ref
        .read(repositoryProvider)
        .confirmPasswordReset(
          identifier: _identifier.text.trim(),
          code: _code.text.trim(),
          newPassword: _password.text,
        )
        .catchError(
          (_) => 'We could not reach the server. Check your connection.',
        );

    if (!mounted) return;

    if (failure != null) {
      setState(() {
        _busy = false;
        _error = failure;
        // A rejected code is a step-2 problem, so go back to it rather than
        // leaving somebody staring at a password field they already filled in
        // correctly.
        if (failure.contains('code')) _step = _Step.code;
      });
      return;
    }

    setState(() => _busy = false);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Password changed, and every other device has been signed out. '
          'Sign in with your new password.',
        ),
        duration: Duration(seconds: 6),
      ),
    );
    context.go('/onboarding/recover');
  }

  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Reset your password')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              switch (_step) {
                _Step.identify => 'We will send a code to the recovery email '
                    'on your account.',
                _Step.code => 'Enter the 6-digit code we sent. It expires in '
                    '15 minutes.',
                _Step.newPassword => 'Choose a new password.',
              },
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface.withOpacity(0.75),
              ),
            ),
            const SizedBox(height: 20),

            if (_step == _Step.identify) ...[
              TextField(
                controller: _identifier,
                keyboardType: TextInputType.emailAddress,
                textCapitalization: TextCapitalization.none,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Email or username',
                  prefixIcon: Icon(Icons.person_outline_rounded),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Either works — whichever you remember.',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface.withOpacity(0.55),
                ),
              ),
            ],

            if (_step == _Step.code) ...[
              TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                textCapitalization: TextCapitalization.none,
                autocorrect: false,
                enableSuggestions: false,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '6-digit code',
                  hintText: '000000',
                  prefixIcon: Icon(Icons.pin_outlined),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: TextButton(
                  onPressed: (_remaining <= 0 && !_busy)
                      ? () => _sendCode(resend: true)
                      : null,
                  child: Text(
                    _remaining <= 0
                        ? 'Send a new code'
                        : 'Send a new code in ${_remaining}s',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ],

            if (_step == _Step.newPassword) ...[
              TextField(
                controller: _password,
                obscureText: !_showPassword,
                autofocus: true,
                textCapitalization: TextCapitalization.none,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'New password',
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _showPassword
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                    ),
                    onPressed: () =>
                        setState(() => _showPassword = !_showPassword),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _confirm,
                obscureText: !_showPassword,
                textCapitalization: TextCapitalization.none,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Confirm new password',
                  prefixIcon: Icon(Icons.lock_outline_rounded),
                ),
              ),
            ],

            if (_notice != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: VentlyColors.berryMagenta.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  _notice!,
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    fontWeight: FontWeight.w700,
                    color: VentlyColors.berryMagenta,
                  ),
                ),
              ),
            ],

            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.error.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: scheme.error.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_outlined,
                      color: scheme.error,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(color: scheme.error, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 20),
            AnimatedButton(
              label: switch (_step) {
                _Step.identify => 'Send me a code',
                _Step.code => 'Continue',
                _Step.newPassword => 'Change my password',
              },
              state: _busy
                  ? VentlyButtonState.loading
                  : VentlyButtonState.idle,
              onPressed: switch (_step) {
                _Step.identify => _sendCode,
                _Step.code => _codeEntered,
                _Step.newPassword => _finish,
              },
            ),

            const SizedBox(height: 20),
            Center(
              child: TextButton(
                onPressed: () => context.go('/onboarding/recover'),
                child: const Text('Back to sign in'),
              ),
            ),
            // Named rather than hidden. Somebody who never verified an email is
            // not stuck here — they just need the other door, and being told
            // so beats retyping an address that will never receive anything.
            Center(
              child: Text(
                'No recovery email on your account? Use your 12-word recovery '
                'phrase from the sign-in screen.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface.withOpacity(0.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
