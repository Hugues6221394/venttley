import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/logger.dart';
import '../../../core/password_policy.dart';
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
  /// Fetched once when the screen opens. Empty until it arrives, and empty
  /// forever if it cannot be fetched — the rest of the rules still apply, and
  /// a wordlist that failed to load must never block somebody signing up.
  Set<String> _weakBases = const {};

  Future<void> _loadWeakBases() async {
    final bases = await ref.read(repositoryProvider).weakPasswordBases();
    if (!mounted) return;
    setState(() => _weakBases = bases);
  }

  DateTime? _birthDate;
  late final TextEditingController _username;
  final _password = TextEditingController();
  final _passwordConfirm = TextEditingController();
  late String _avatarSeed;
  bool _loading = false;
  bool _showPassword = false;
  String? _error;

  /// Two separate agreements, so two separate boxes.
  ///
  /// Not one "I agree to the Terms and Privacy Policy" checkbox: they are
  /// distinct documents, they are recorded as distinct acceptances, and a
  /// single box would make the record claim something the person was never
  /// asked. Both start false and are never pre-ticked — a pre-ticked box is
  /// the silent acceptance this whole path exists to prevent.
  bool _agreedTerms = false;
  bool _acknowledgedPrivacy = false;

  @override
  void initState() {
    super.initState();
    _username = TextEditingController(text: PseudonymGenerator.pseudonym());
    _avatarSeed = PseudonymGenerator.avatarSeed();
    _loadWeakBases();
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
          colorScheme: Theme.of(
            context,
          ).colorScheme.copyWith(primary: VentlyColors.berryMagenta),
        ),
        child: child!,
      ),
    );
    if (!mounted) return;
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
    // Checked before the network call so somebody is told what is wrong while
    // they are still looking at the field, rather than after a round trip.
    // The server enforces the same rules regardless.
    final passwordProblem = PasswordPolicy.problem(
      _password.text,
      weakBases: _weakBases,
    );
    if (passwordProblem != null) {
      setState(() => _error = passwordProblem);
      return;
    }
    if (_password.text != _passwordConfirm.text) {
      setState(() => _error = "Passwords don't match.");
      return;
    }

    // The versions that were actually on screen. Read here rather than
    // re-fetched, and handed to the server unchanged, so the acceptance
    // record names the text this person was shown. If the policy moved while
    // they were filling the form the server refuses it and says so, which is
    // the right outcome — better than recording agreement to something they
    // never saw.
    final policies = ref.read(currentPoliciesProvider).valueOrNull;
    final terms = policies?.terms;
    final privacy = policies?.privacy;
    if (terms == null || privacy == null) {
      setState(
        () => _error =
            'We could not load the Terms and Privacy Policy, so we cannot '
            'create your account yet. Check your connection and try again.',
      );
      return;
    }
    if (!_agreedTerms || !_acknowledgedPrivacy) {
      setState(
        () => _error =
            'Please agree to the Terms and acknowledge the Privacy Policy to '
            'continue.',
      );
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(sessionProvider.notifier)
          .register(
            birthDate: _birthDate!,
            username: username,
            password: _password.text,
            avatarSeed: _avatarSeed,
          );

      // Consent is recorded immediately after the account exists, because it
      // cannot be recorded before — an unauthenticated caller has no row to
      // attach it to, so the two writes cannot share a transaction.
      //
      // A failure here is not swallowed and does not roll the account back.
      // Deleting a just-created account over a failed follow-up write would
      // lose the recovery phrase that has already been generated. Instead the
      // account exists with the consent outstanding, and
      // `outstandingPoliciesProvider` routes it to the consent screen on the
      // next launch — the same self-healing route this codebase already uses
      // for an account with no birth year.
      try {
        await ref
            .read(repositoryProvider)
            .acceptPolicies(
              termsVersion: terms.version,
              privacyVersion: privacy.version,
            );
        ref.invalidate(outstandingPoliciesProvider);
      } catch (e) {
        log.warn(
          'policy.accept_failed_after_register',
          props: {'error': e.toString()},
        );
      }

      if (!mounted) return;
      context.go('/onboarding/key', extra: result.recoveryPhrase);
    } on AgeGateBlocked catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } on UsernameTakenException {
      if (!mounted) return;
      setState(
        () => _error = UserFriendlyErrors.message(
          'already exists',
          fallback: 'That username is taken. Try another one.',
        ),
      );
      _shuffleName();
    } on EmailConfirmationStillOnException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = UserFriendlyErrors.message(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Watched, not read, so the documents are actually fetched while the form
    // is being filled in — `_onSubmit` reads the same provider for the
    // versions, and a read alone would never start the request.
    final policiesAsync = ref.watch(currentPoliciesProvider);
    final policiesLoaded = policiesAsync.valueOrNull?.isComplete ?? false;

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
            _DobCard(birthDate: _birthDate, onTap: _pickDate),
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
            const SizedBox(height: 14),
            _ConsentCard(
              agreedTerms: _agreedTerms,
              acknowledgedPrivacy: _acknowledgedPrivacy,
              documentsLoading: policiesAsync.isLoading,
              documentsUnavailable:
                  !policiesLoaded && !policiesAsync.isLoading,
              onRetryDocuments: () => ref.invalidate(currentPoliciesProvider),
              onTermsChanged: (v) => setState(() => _agreedTerms = v),
              onPrivacyChanged: (v) => setState(() => _acknowledgedPrivacy = v),
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
                  Icon(
                    Icons.lock_outline,
                    size: 14,
                    color: scheme.onSurface.withOpacity(0.55),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'No public real identity required',
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

/// The Terms and Privacy consent step.
///
/// Two boxes and two links, because they are two documents. Each label is
/// tappable to toggle and each document name is tappable to open — separated
/// so that reaching for the link never silently ticks the box, which would
/// make "I read it" mean "I tapped near it".
///
/// The submit button stays enabled with these unticked, and says what is
/// missing when pressed. That follows the precedent already set by
/// `_MessageButton` on the profile: a disabled control announces nothing to a
/// screen reader and gives a sighted user no reason either, so the button
/// explains instead of going dead.
class _ConsentCard extends StatelessWidget {
  const _ConsentCard({
    required this.agreedTerms,
    required this.acknowledgedPrivacy,
    required this.documentsLoading,
    required this.documentsUnavailable,
    required this.onRetryDocuments,
    required this.onTermsChanged,
    required this.onPrivacyChanged,
  });

  final bool agreedTerms;
  final bool acknowledgedPrivacy;
  final bool documentsLoading;
  final bool documentsUnavailable;
  final VoidCallback onRetryDocuments;
  final ValueChanged<bool> onTermsChanged;
  final ValueChanged<bool> onPrivacyChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Said here rather than only on submit. Somebody who ticks two
            // boxes and then gets "we could not load the documents" was asked
            // to agree to something the app never had — better to say so
            // while the boxes are still empty.
            if (documentsUnavailable) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 8, 2, 10),
                child: Row(
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      size: 18,
                      color: VentlyColors.dangerRed,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'We could not load the Terms and Privacy Policy.',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.35,
                          color: context.ink.withOpacity(0.8),
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: onRetryDocuments,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: context.ink.withOpacity(0.08)),
            ],
            if (documentsLoading)
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 10, 2, 10),
                child: Row(
                  children: [
                    const SizedBox(
                      height: 14,
                      width: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Loading the Terms and Privacy Policy…',
                      style: TextStyle(
                        fontSize: 13,
                        color: context.ink.withOpacity(0.7),
                      ),
                    ),
                  ],
                ),
              ),
            _ConsentRow(
              value: agreedTerms,
              onChanged: onTermsChanged,
              leading: 'I agree to the ',
              linkLabel: 'Terms & Conditions',
              route: '/legal/terms',
              semanticLabel: 'I agree to the Venttly Terms and Conditions',
            ),
            Divider(height: 1, color: context.ink.withOpacity(0.08)),
            _ConsentRow(
              value: acknowledgedPrivacy,
              onChanged: onPrivacyChanged,
              leading: 'I acknowledge the ',
              linkLabel: 'Privacy Policy',
              route: '/legal/privacy',
              semanticLabel: 'I acknowledge the Venttly Privacy Policy',
            ),
          ],
        ),
      ),
    );
  }
}

/// Stateful only to own the [TapGestureRecognizer].
///
/// A recognizer built inside `build` is never disposed, and this row rebuilds
/// on every keystroke in the form above it — so the stateless version leaked
/// one recognizer per rebuild. It has to be created once and disposed with
/// the state.
class _ConsentRow extends StatefulWidget {
  const _ConsentRow({
    required this.value,
    required this.onChanged,
    required this.leading,
    required this.linkLabel,
    required this.route,
    required this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String leading;
  final String linkLabel;
  final String route;
  final String semanticLabel;

  @override
  State<_ConsentRow> createState() => _ConsentRowState();
}

class _ConsentRowState extends State<_ConsentRow> {
  late final TapGestureRecognizer _openDocument;

  @override
  void initState() {
    super.initState();
    _openDocument = TapGestureRecognizer()
      ..onTap = () => context.push(widget.route);
  }

  @override
  void dispose() {
    _openDocument.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ink = context.ink;
    final value = widget.value;
    final onChanged = widget.onChanged;
    final leading = widget.leading;
    final linkLabel = widget.linkLabel;
    final semanticLabel = widget.semanticLabel;
    return Semantics(
      checked: value,
      label: semanticLabel,
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // ExcludeSemantics because the row above already announces the
              // checked state and label; without it a screen reader reads the
              // whole thing twice.
              ExcludeSemantics(
                child: Checkbox(
                  value: value,
                  onChanged: (v) => onChanged(v ?? false),
                  activeColor: VentlyColors.berryMagenta,
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 4, top: 2, bottom: 2),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: leading),
                        TextSpan(
                          text: linkLabel,
                          style: const TextStyle(
                            color: VentlyColors.berryMagenta,
                            fontWeight: FontWeight.w800,
                            decoration: TextDecoration.underline,
                            decorationColor: VentlyColors.berryMagenta,
                          ),
                          recognizer: _openDocument,
                        ),
                      ],
                    ),
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      color: ink.withOpacity(0.85),
                    ),
                  ),
                ),
              ),
            ],
          ),
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
            Text(
              'Date of birth',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 10),
            InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
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
            Text(
              'Your anonymous identity',
              style: Theme.of(context).textTheme.titleSmall,
            ),
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
            Text(
              'Set a password',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: password,
              obscureText: !showPassword,
              decoration: InputDecoration(
                hintText: 'At least 8 characters',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(
                    showPassword ? Icons.visibility : Icons.visibility_off,
                  ),
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
          Icon(Icons.warning_amber_outlined, color: scheme.error, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.error, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
