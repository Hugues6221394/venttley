import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/providers.dart';
import '../../../core/user_friendly_errors.dart';
import '../../../data/repositories/vently_repository.dart';
import '../../../data/services/identity_service.dart';
import '../../../data/services/supabase_backend.dart'
    show UsernameTakenException, EmailConfirmationStillOnException;
import '../../theme/colors.dart';
import '../../widgets/anonymous_avatar.dart';

/// Create-Identity screen — DOB age gate + username + password.
///
/// On submit we call [SessionController.register] which generates the
/// recovery phrase and seals the password into the recovery blob. The phrase
/// is then handed to the next screen (`/onboarding/key`) for the user to
/// save — it is the only off-device copy.
class IdentityScreen extends ConsumerStatefulWidget {
  const IdentityScreen({super.key});

  @override
  ConsumerState<IdentityScreen> createState() => _IdentityScreenState();
}

class _IdentityScreenState extends ConsumerState<IdentityScreen> {
  DateTime? _birthDate;
  late final TextEditingController _username;
  final _password = TextEditingController();
  final _passwordConfirm = TextEditingController();
  late String _avatarSeed;
  bool _loading = false;
  bool _showPassword = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _username = TextEditingController(text: PseudonymGenerator.pseudonym());
    _avatarSeed = PseudonymGenerator.avatarSeed();
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _passwordConfirm.dispose();
    super.dispose();
  }

  void _shuffleName() {
    setState(() {
      _username.text = PseudonymGenerator.pseudonym();
      _avatarSeed = PseudonymGenerator.avatarSeed();
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime(now.year - 18, now.month, now.day),
      firstDate: DateTime(1920),
      lastDate: now,
      helpText: 'When were you born?',
      builder: (ctx, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: Theme.of(context).colorScheme.copyWith(
                primary: VentlyColors.berryMagenta,
              ),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _birthDate = picked);
  }

  Future<void> _onSubmit() async {
    if (_birthDate == null) {
      setState(() => _error = 'Please choose your date of birth first.');
      return;
    }
    final username = _username.text.trim();
    if (!IdentityService.usernamePattern.hasMatch(username)) {
      setState(
        () => _error = 'Usernames are 3–20 letters, numbers, or underscores.',
      );
      return;
    }
    if (_password.text.length < 8) {
      setState(() => _error = 'Password must be at least 8 characters.');
      return;
    }
    if (_password.text != _passwordConfirm.text) {
      setState(() => _error = "Passwords don't match.");
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref.read(sessionProvider.notifier).register(
            birthDate: _birthDate!,
            username: username,
            password: _password.text,
            avatarSeed: _avatarSeed,
          );
      if (!mounted) return;
      context.go('/onboarding/key', extra: result.recoveryPhrase);
    } on AgeGateBlocked catch (e) {
      setState(() => _error = e.toString());
    } on UsernameTakenException {
      setState(() => _error = UserFriendlyErrors.message(
            'already exists',
            fallback: 'That username is taken. Try another one.',
          ));
      _shuffleName();
    } on EmailConfirmationStillOnException catch (e) {
      setState(() => _error = e.toString());
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = UserFriendlyErrors.message(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => context.go('/onboarding'),
        ),
        title: const Text('Create Identity'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          children: [
            Center(
              child: AnonymousAvatar(
                seed: _avatarSeed,
                label: _username.text,
                size: 88,
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                'Your emotional sanctuary',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface.withOpacity(0.6),
                    ),
              ),
            ),
            const SizedBox(height: 24),
            _DobCard(
              birthDate: _birthDate,
              onTap: _pickDate,
            ),
            const SizedBox(height: 14),
            _UsernameCard(
              controller: _username,
              onShuffle: _shuffleName,
              onChanged: () => setState(() {}),
            ),
            const SizedBox(height: 14),
            _PasswordCard(
              password: _password,
              confirm: _passwordConfirm,
              showPassword: _showPassword,
              onToggleVisibility: () =>
                  setState(() => _showPassword = !_showPassword),
            ),
            const SizedBox(height: 18),
            if (_error != null) ...[
              _ErrorBanner(message: _error!),
              const SizedBox(height: 12),
            ],
            ElevatedButton(
              onPressed: _loading ? null : _onSubmit,
              child: _loading
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('Step into the Circle'),
                        SizedBox(width: 8),
                        Icon(Icons.arrow_forward_rounded, size: 18),
                      ],
                    ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_outline,
                      size: 14, color: scheme.onSurface.withOpacity(0.55)),
                  const SizedBox(width: 6),
                  Text(
                    'Zero Personal Data Required',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurface.withOpacity(0.55),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DobCard extends StatelessWidget {
  const _DobCard({required this.birthDate, required this.onTap});
  final DateTime? birthDate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Date of birth',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 10),
            InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: Theme.of(context).inputDecorationTheme.fillColor,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: VentlyColors.softMauve.withOpacity(0.7),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today, size: 18),
                    const SizedBox(width: 10),
                    Text(
                      birthDate == null
                          ? 'dd / mm / yyyy'
                          : DateFormat('dd / MM / yyyy').format(birthDate!),
                      style: TextStyle(
                        color: birthDate == null
                            ? scheme.onSurface.withOpacity(0.5)
                            : scheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'We use this to keep you in the right age group. '
              'It is never shown to anyone.',
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface.withOpacity(0.6),
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UsernameCard extends StatelessWidget {
  const _UsernameCard({
    required this.controller,
    required this.onShuffle,
    required this.onChanged,
  });
  final TextEditingController controller;
  final VoidCallback onShuffle;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your anonymous identity',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.person_outline, color: scheme.primary, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: controller,
                    onChanged: (_) => onChanged(),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: 'pick a name',
                    ),
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: onShuffle,
                  icon: const Icon(Icons.casino_outlined, size: 16),
                  label: const Text('Shuffle'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              "This is the name on your vents — and how you sign in next time.",
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface.withOpacity(0.6),
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PasswordCard extends StatelessWidget {
  const _PasswordCard({
    required this.password,
    required this.confirm,
    required this.showPassword,
    required this.onToggleVisibility,
  });
  final TextEditingController password;
  final TextEditingController confirm;
  final bool showPassword;
  final VoidCallback onToggleVisibility;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Set a password',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 10),
            TextField(
              controller: password,
              obscureText: !showPassword,
              decoration: InputDecoration(
                hintText: 'At least 8 characters',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(
                      showPassword ? Icons.visibility : Icons.visibility_off),
                  onPressed: onToggleVisibility,
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: confirm,
              obscureText: !showPassword,
              decoration: const InputDecoration(
                hintText: 'Confirm password',
                prefixIcon: Icon(Icons.lock_outline),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.error.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.error.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_outlined,
              color: scheme.error, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: TextStyle(color: scheme.error, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
