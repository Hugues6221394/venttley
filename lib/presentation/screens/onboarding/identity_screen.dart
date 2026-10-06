import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/logger.dart';
import '../../../core/password_policy.dart';
import '../../../core/providers.dart';
import '../../../core/user_friendly_errors.dart';
import '../../../data/repositories/vently_repository.dart';
import '../../../data/services/identity_service.dart';
import '../../../data/services/supabase_backend.dart'
    show UsernameTakenException, EmailConfirmationStillOnException;
import '../../theme/colors.dart';
import '../../../core/constants.dart';
import '../../widgets/auth_entry_methods.dart';
import '../../widgets/anonymous_avatar.dart';
import '../../widgets/onboarding_backdrop.dart';
import '../../widgets/username_availability.dart';

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
      // Shuffle writes straight to the controller, so onChanged never fires
      // and the hint would still be describing the previous name.
      ref.read(usernameAvailabilityProvider).check(_username.text);
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
      const message =
          'Please agree to the Terms and acknowledge the Privacy Policy to '
          'continue.';
      setState(() => _error = message);
      // Said twice, deliberately. The banner renders above the submit button
      // and the two consent boxes are above that again, so on a short phone
      // the tap, the refusal and the thing that needs fixing are all on
      // different parts of one scroll -- which reads as the button doing
      // nothing at all. The button is not disabled on purpose (a disabled
      // control announces nothing), so the refusal has to reach the reader
      // wherever they are looking.
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text(message)));
      }
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
      body: OnboardingBackdrop(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            children: [
              // The face you are about to become, with the name under it.
              //
              // The avatar used to sit on its own above the words "Your
              // emotional sanctuary", which described the app rather than
              // anything on the screen. Showing the handle here means the
              // shuffle button below has something visible to change.
              Center(
                child: Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.primary.withValues(alpha: 0.07),
                    border: Border.all(
                      color: scheme.primary.withValues(alpha: 0.18),
                      width: 1.2,
                    ),
                  ),
                  child: AnonymousAvatar(
                    seed: _avatarSeed,
                    label: _username.text,
                    size: 84,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  _username.text.isEmpty ? 'your name' : _username.text,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    color: scheme.primary,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text(
                  'Nobody sees anything else. Not your email, not your phone.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurface.withValues(alpha: 0.6),
                    height: 1.35,
                  ),
                ),
              ),
              const SizedBox(height: 22),
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
                onChanged: () => setState(() {}),
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
                onPrivacyChanged: (v) =>
                    setState(() => _acknowledgedPrivacy = v),
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
              // The other ways to sign up, same as on sign-in.
              //
              // Somebody who got this far wanted an account; making them go
              // back to find the email or Google route is a step nobody
              // benefits from.
              const SizedBox(height: 20),
              const AuthOrDivider(),
              const SizedBox(height: 16),
              const ContinueWithEmailButton(),
              if (VentlyConfig.socialAuthEnabled) ...[
                const SizedBox(height: 12),
                const SocialAuthRow(),
              ],
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
    final set = birthDate != null;
    final age = set
        ? (DateTime.now().difference(birthDate!).inDays / 365.2425).floor()
        : null;
    return _FormCard(
      label: 'Date of birth',
      footnote:
          'Used to keep you in the right age group. Never shown to '
          'anyone, ever.',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.045),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: scheme.primary.withValues(alpha: set ? 0.32 : 0.12),
              width: set ? 1.4 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.cake_outlined,
                size: 19,
                color: scheme.primary.withValues(alpha: 0.75),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  set
                      ? '${birthDate!.day.toString().padLeft(2, '0')} / '
                            '${birthDate!.month.toString().padLeft(2, '0')} / '
                            '${birthDate!.year}'
                      : 'dd / mm / yyyy',
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: set ? FontWeight.w800 : FontWeight.w500,
                    color: set
                        ? context.ink
                        : context.ink.withValues(alpha: 0.40),
                  ),
                ),
              ),
              // The number they can check at a glance, rather than making
              // them work out whether the date they tapped was right.
              if (age != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '$age',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                      color: scheme.primary,
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

class _UsernameCard extends ConsumerWidget {
  const _UsernameCard({
    required this.controller,
    required this.onShuffle,
    required this.onChanged,
  });
  final TextEditingController controller;
  final VoidCallback onShuffle;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final availability = ref.watch(usernameAvailabilityProvider);
    return _FormCard(
      label: 'Your anonymous name',
      // Just the rule. UsernameAvailabilityHint below already says what
      // the name is for, and the two sat under each other saying it twice.
      footnote: 'Letters, numbers and _ only.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            textInputAction: TextInputAction.next,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9_]')),
            ],
            onChanged: (value) {
              availability.check(value);
              onChanged();
            },
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5),
            decoration: _filled(
              context,
              hint: 'pick a name',
              icon: Icons.person_outline,
              // The shuffle sits inside the field it changes, rather than
              // beside it competing for the row.
              suffix: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: TextButton.icon(
                  onPressed: onShuffle,
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.casino_outlined, size: 16),
                  label: const Text(
                    'Shuffle',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Answered while they type, rather than after they have chosen a
          // password, agreed to two policies and pressed the button. Until
          // now the only signal that a name was gone came from the insert
          // failing at the very end.
          UsernameAvailabilityHint(
            status: availability.status,
            username: availability.describes,
          ),
        ],
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
    required this.onChanged,
  });
  final TextEditingController password;
  final TextEditingController confirm;
  final bool showPassword;
  final VoidCallback onToggleVisibility;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final typed = confirm.text.isNotEmpty;
    final matches = typed && confirm.text == password.text;
    return _FormCard(
      label: 'Set a password',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: password,
            obscureText: !showPassword,
            textInputAction: TextInputAction.next,
            onChanged: (_) => onChanged(),
            decoration: _filled(
              context,
              hint: 'At least 8 characters',
              icon: Icons.lock_outline,
              suffix: IconButton(
                icon: Icon(
                  showPassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 19,
                  color: scheme.primary.withValues(alpha: 0.7),
                ),
                onPressed: onToggleVisibility,
              ),
            ),
          ),
          _PasswordStrength(password: password.text),
          const SizedBox(height: 10),
          TextField(
            controller: confirm,
            obscureText: !showPassword,
            onChanged: (_) => onChanged(),
            decoration: _filled(
              context,
              hint: 'Confirm password',
              icon: Icons.lock_outline,
              // Said the moment it is true, not after the button is pressed.
              suffix: !typed
                  ? null
                  : Icon(
                      matches
                          ? Icons.check_circle_rounded
                          : Icons.error_outline_rounded,
                      size: 20,
                      color: matches
                          ? const Color(0xFF2E8B57)
                          : const Color(0xFFE2504F),
                    ),
            ),
          ),
          if (typed && !matches)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'These two do not match yet.',
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFE2504F),
                ),
              ),
            ),
        ],
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

/// One card, one question. Same shell for all three so the form reads as a
/// sequence rather than three unrelated boxes.
class _FormCard extends StatelessWidget {
  const _FormCard({required this.label, required this.child, this.footnote});

  final String label;
  final Widget child;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: context.isDark
            ? Theme.of(context).colorScheme.surface
            : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.10)),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.06),
            blurRadius: 18,
            spreadRadius: -6,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.9,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 12),
          child,
          if (footnote != null) ...[
            const SizedBox(height: 10),
            Text(
              footnote!,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.4,
                fontWeight: FontWeight.w500,
                color: context.ink.withValues(alpha: 0.52),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A filled field. The theme's default is an outlined box on a white card,
/// which reads as a form from 2014; filled on blush reads as a surface you
/// type into.
InputDecoration _filled(
  BuildContext context, {
  required String hint,
  IconData? icon,
  Widget? suffix,
}) {
  final scheme = Theme.of(context).colorScheme;
  OutlineInputBorder border(Color c, double w) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: BorderSide(color: c, width: w),
  );
  return InputDecoration(
    hintText: hint,
    filled: true,
    fillColor: scheme.primary.withValues(alpha: 0.045),
    prefixIcon: icon == null
        ? null
        : Icon(icon, size: 19, color: scheme.primary.withValues(alpha: 0.75)),
    suffixIcon: suffix,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
    border: border(Colors.transparent, 0),
    enabledBorder: border(scheme.primary.withValues(alpha: 0.12), 1),
    focusedBorder: border(scheme.primary, 1.5),
  );
}

/// How strong the password is, while it is being typed.
///
/// The rules were only enforced on submit, so somebody could fill the whole
/// form and then be told the password was the problem.
class _PasswordStrength extends StatelessWidget {
  const _PasswordStrength({required this.password});

  final String password;

  (int, String, Color) _score() {
    final p = password;
    if (p.isEmpty) return (0, '', Colors.transparent);
    var score = 0;
    if (p.length >= 8) score++;
    if (p.length >= 12) score++;
    if (RegExp(r'[A-Z]').hasMatch(p) && RegExp(r'[a-z]').hasMatch(p)) score++;
    if (RegExp(r'[0-9]').hasMatch(p)) score++;
    if (RegExp(r'[^A-Za-z0-9]').hasMatch(p)) score++;
    if (p.length < 8) return (1, 'Too short', const Color(0xFFE2504F));
    if (score <= 2) return (2, 'Could be stronger', const Color(0xFFE08A3C));
    if (score == 3) return (3, 'Good', const Color(0xFF3E9B6B));
    return (4, 'Strong', const Color(0xFF2E8B57));
  }

  @override
  Widget build(BuildContext context) {
    final (filled, label, colour) = _score();
    if (password.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          for (var i = 0; i < 4; i++) ...[
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                height: 4,
                decoration: BoxDecoration(
                  color: i < filled
                      ? colour
                      : context.ink.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            if (i < 3) const SizedBox(width: 5),
          ],
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: colour,
            ),
          ),
        ],
      ),
    );
  }
}
