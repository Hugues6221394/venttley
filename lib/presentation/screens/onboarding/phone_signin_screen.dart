import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../data/services/supabase_backend.dart'
    show MfaChallengeRequiredException;
import '../../theme/colors.dart';

/// Optional phone sign-in: enter a number, receive an SMS OTP, verify.
///
/// Requires an SMS provider configured in Supabase (Authentication →
/// Providers → Phone). Phone ownership counts as verified, so these accounts
/// are not gated on email verification.
class PhoneSignInScreen extends ConsumerStatefulWidget {
  const PhoneSignInScreen({super.key});

  @override
  ConsumerState<PhoneSignInScreen> createState() => _PhoneSignInScreenState();
}

class _PhoneSignInScreenState extends ConsumerState<PhoneSignInScreen> {
  final _phone = TextEditingController();
  final _otp = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    _otp.dispose();
    super.dispose();
  }

  String get _e164 {
    final raw = _phone.text.trim().replaceAll(RegExp(r'[^0-9+]'), '');
    return raw.startsWith('+') ? raw : '+$raw';
  }

  Future<void> _sendCode() async {
    if (_busy) return;
    if (_phone.text.trim().length < 6) {
      setState(() => _error = 'Enter your phone number with country code.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).startPhoneOtp(_e164);
      if (mounted) setState(() => _codeSent = true);
    } catch (e) {
      if (mounted) setState(() => _error = _clean(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    if (_busy) return;
    if (_otp.text.trim().length < 6) {
      setState(() => _error = 'Enter the 6-digit code you received.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(sessionProvider.notifier)
          .verifyPhoneOtp(phone: _e164, token: _otp.text.trim());
      if (mounted) context.go('/feed');
    } on MfaChallengeRequiredException {
      if (mounted) context.go('/onboarding/mfa');
    } catch (e) {
      if (mounted) setState(() => _error = _clean(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _clean(Object e) => e
      .toString()
      .replaceFirst('Exception: ', '')
      .replaceFirst('StateError: ', '');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Continue with phone')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 72,
                height: 72,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primary.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.sms_outlined,
                  color: scheme.primary,
                  size: 32,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                _codeSent ? 'Enter the code' : 'Your phone number',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: context.ink,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _codeSent
                    ? 'We texted a 6-digit code to $_e164.'
                    : 'We\'ll text you a one-time code. Include your country code, '
                          'e.g. +250 788 123 456.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.ink.withOpacity(0.66),
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              if (!_codeSent)
                TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9+\s]')),
                  ],
                  decoration: _dec('Phone number', Icons.phone_outlined),
                )
              else
                TextField(
                  controller: _otp,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  maxLength: 6,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 10,
                  ),
                  decoration: _dec(
                    '6-digit code',
                    null,
                  ).copyWith(counterText: ''),
                  onSubmitted: (_) => _verify(),
                ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: VentlyColors.dangerRed,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              const SizedBox(height: 22),
              ElevatedButton(
                onPressed: _busy ? null : (_codeSent ? _verify : _sendCode),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(54),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: Colors.white,
                        ),
                      )
                    : Text(_codeSent ? 'Verify & continue' : 'Send code'),
              ),
              if (_codeSent)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _codeSent = false;
                          _otp.clear();
                          _error = null;
                        }),
                  child: const Text('Use a different number'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _dec(String hint, IconData? icon) => InputDecoration(
    hintText: hint,
    prefixIcon: icon == null ? null : Icon(icon),
    filled: true,
    fillColor: Colors.white.withOpacity(0.6),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide.none,
    ),
  );
}
