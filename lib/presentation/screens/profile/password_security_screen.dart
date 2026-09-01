import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/providers.dart';
import '../../../core/security_checkup.dart';
import '../../../domain/entities/entities.dart';
import '../../../data/services/supabase_backend.dart'
    show MfaChallengeRequiredException;
import '../../theme/colors.dart';
import '../../widgets/modal_text_controller_scope.dart';
import '../onboarding/mfa_challenge_screen.dart';

/// Instagram-style "Password and security" hub: a security checkup summary,
/// password rotation, a real recovery email, two-factor, and session control.
class PasswordSecurityScreen extends ConsumerStatefulWidget {
  const PasswordSecurityScreen({super.key});

  @override
  ConsumerState<PasswordSecurityScreen> createState() =>
      _PasswordSecurityScreenState();
}

class _PasswordSecurityScreenState
    extends ConsumerState<PasswordSecurityScreen> {
  bool _twoFactorOn = false;
  bool _loadingFactors = true;
  DateTime? _passwordChangedAt;
  int? _deviceCount;

  /// Null until the first load answers. Distinct from "nothing configured", so
  /// the screen can show a neutral row rather than claiming a person has no way
  /// back into their account before we have asked.
  RecoveryMethods? _recovery;

  @override
  void initState() {
    super.initState();
    _loadFactors();
    _loadDeviceCount();
    _loadPasswordChangedAt();
    _loadRecovery();
  }

  Future<void> _loadPasswordChangedAt() async {
    try {
      final at = await ref.read(repositoryProvider).myPasswordChangedAt();
      if (mounted) setState(() => _passwordChangedAt = at);
    } catch (_) {
      // Leave null — the checkup then says the password was never rotated,
      // which is the honest default when we cannot read the stamp.
    }
  }

  /// Just the count for the tile subtitle. The screen behind it does the real
  /// work; this is only here so the row says something true before you tap it.
  Future<void> _loadDeviceCount() async {
    try {
      final sessions = await ref.read(repositoryProvider).myDeviceSessions();
      if (mounted) setState(() => _deviceCount = sessions.length);
    } catch (_) {
      // Leave the subtitle generic rather than showing a wrong number.
    }
  }

  String _deviceSummary() {
    final count = _deviceCount;
    if (count == null) return 'See and manage your signed-in devices';
    if (count <= 1) return 'This device only';
    return '$count devices signed in';
  }

  Future<void> _loadFactors() async {
    try {
      final res = await Supabase.instance.client.auth.mfa.listFactors();
      if (!mounted) return;
      setState(() {
        _twoFactorOn = [
          ...res.totp,
          ...res.phone,
        ].any((f) => f.status == FactorStatus.verified);
        _loadingFactors = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingFactors = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider.notifier);
    final me = ref.watch(sessionProvider);
    final hasRealEmail = session.hasRealEmail;
    final emailVerified = session.isEmailVerified;

    final checkup = SecurityCheckup(
      passwordChangedAt: _passwordChangedAt,
      twoFactorOn: _twoFactorOn,
      hasRealEmail: hasRealEmail,
      emailVerified: emailVerified,
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Password & security')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _CheckupCard(
            covered: checkup.coveredCount,
            total: SecurityCheckup.totalSteps,
            loading: _loadingFactors,
            items: [
              _CheckItem(
                label: checkup.passwordLabel,
                ok: checkup.passwordRotated,
              ),
              _CheckItem(
                label: checkup.twoFactorLabel,
                ok: checkup.twoFactorOn,
              ),
              _CheckItem(
                label: checkup.recoveryLabel,
                ok: checkup.recoveryOk,
              ),
            ],
          ),
          const SizedBox(height: 20),
          const _SectionLabel('Login & recovery'),
          _Tile(
            icon: Icons.lock_outline_rounded,
            title: 'Change password',
            subtitle: 'Update the password you use to sign in',
            onTap: _openChangePassword,
          ),
          // Reads the recovery method, not the login email. The two were the
          // same thing before, which is what made adding a recovery address
          // change how you sign in.
          _Tile(
            icon: Icons.alternate_email_rounded,
            title: 'Recovery email',
            subtitle: _recoverySubtitle(_recovery?.email, 'email address'),
            trailingBadge:
                _recovery?.email.pending == true ? 'Enter code' : null,
            onTap: _openRecoveryEmail,
          ),
          _Tile(
            icon: Icons.sms_outlined,
            title: 'Recovery phone',
            subtitle: _recoverySubtitle(_recovery?.phone, 'phone number'),
            onTap: _openRecoveryPhone,
          ),
          _Tile(
            icon: Icons.verified_user_outlined,
            title: 'Two-factor authentication',
            subtitle: _twoFactorOn
                ? 'On — a code is required at sign-in'
                : 'Add a 6-digit code on top of your password',
            onTap: () => context.push('/profile/security').then((_) {
              _loadFactors();
            }),
          ),
          const SizedBox(height: 20),
          const _SectionLabel('Where you\'re logged in'),
          _Tile(
            icon: Icons.devices_rounded,
            title: 'Active devices',
            subtitle: _deviceSummary(),
            onTap: () => context.push('/profile/devices').then((_) {
              _loadDeviceCount();
            }),
          ),
          _Tile(
            icon: Icons.logout_rounded,
            title: 'Sign out everywhere',
            subtitle: 'Ends every session on all your devices',
            danger: true,
            onTap: _signOutEverywhere,
          ),
          if (me != null) ...[
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                'Signed in as ${me.anonymousPseudonym}. Your username login '
                'always works; a recovery email is a backup way in if you ever '
                'forget your password.',
                style: TextStyle(
                  color: context.ink.withOpacity(0.55),
                  fontSize: 12.5,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---- Change password ---------------------------------------------------

  Future<void> _openChangePassword() async {
    final bool needsRecoveryPhrase;
    try {
      needsRecoveryPhrase = await ref
          .read(sessionProvider.notifier)
          .needsRecoveryPhraseForPasswordChange();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Couldn\'t verify recovery protection. Try again.'),
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    String? error;
    bool busy = false;
    bool obscure = true;

    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => ModalTextControllerScope(
        initialValues: const ['', '', '', ''],
        builder: (ctx, controllers) {
          final current = controllers[0];
          final next = controllers[1];
          final confirm = controllers[2];
          final recoveryPhrase = controllers[3];
          return StatefulBuilder(
            builder: (ctx, setSheet) {
              InputDecoration deco(String label) => InputDecoration(
                labelText: label,
                filled: true,
                fillColor: const Color(0xFFFFF1F6),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              );
              return SingleChildScrollView(
                padding: EdgeInsets.only(
                  left: 20,
                  right: 20,
                  top: 18,
                  bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Change password',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: context.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Enter your current password, then choose a new one.',
                      style: TextStyle(
                        color: context.ink.withOpacity(0.6),
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: current,
                      obscureText: obscure,
                      decoration: deco('Current password').copyWith(
                        suffixIcon: IconButton(
                          icon: Icon(
                            obscure
                                ? Icons.visibility_off_rounded
                                : Icons.visibility_rounded,
                          ),
                          onPressed: () => setSheet(() => obscure = !obscure),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: next,
                      obscureText: obscure,
                      decoration: deco('New password (8+ characters)'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: confirm,
                      obscureText: obscure,
                      decoration: deco('Confirm new password'),
                    ),
                    if (needsRecoveryPhrase) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: recoveryPhrase,
                        minLines: 2,
                        maxLines: 3,
                        textCapitalization: TextCapitalization.none,
                        autocorrect: false,
                        decoration: deco('12-word recovery phrase').copyWith(
                          helperText:
                              'Required because this device does not have your saved phrase.',
                        ),
                      ),
                    ],
                    if (error != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        error!,
                        style: const TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: VentlyColors.berryMagenta,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: busy
                          ? null
                          : () async {
                              if (next.text != confirm.text) {
                                setSheet(
                                  () => error = 'New passwords don\'t match.',
                                );
                                return;
                              }
                              if (next.text.length < 8) {
                                setSheet(
                                  () => error =
                                      'New password must be 8+ characters.',
                                );
                                return;
                              }
                              setSheet(() {
                                busy = true;
                                error = null;
                              });
                              try {
                                await ref
                                    .read(sessionProvider.notifier)
                                    .changePassword(
                                      currentPassword: current.text,
                                      newPassword: next.text,
                                      recoveryPhrase: needsRecoveryPhrase
                                          ? recoveryPhrase.text
                                          : null,
                                    );
                                if (ctx.mounted) Navigator.pop(ctx);
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Password updated.'),
                                    ),
                                  );
                                  _loadPasswordChangedAt();
                                }
                              } on MfaChallengeRequiredException catch (e) {
                                final verified = await showMfaChallengeDialog(
                                  context: ctx,
                                  ref: ref,
                                  factorId: e.factorId,
                                );
                                if (!verified) {
                                  setSheet(() {
                                    busy = false;
                                    error =
                                        'Two-factor verification is required to change your password.';
                                  });
                                  return;
                                }
                                try {
                                  await ref
                                      .read(sessionProvider.notifier)
                                      .changePassword(
                                        currentPassword: current.text,
                                        newPassword: next.text,
                                        recoveryPhrase: needsRecoveryPhrase
                                            ? recoveryPhrase.text
                                            : null,
                                      );
                                  if (ctx.mounted) Navigator.pop(ctx);
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Password updated.'),
                                      ),
                                    );
                                    _loadPasswordChangedAt();
                                  }
                                } catch (_) {
                                  setSheet(() {
                                    busy = false;
                                    error =
                                        'Couldn\'t update password. Try again.';
                                  });
                                }
                              } on AuthException catch (_) {
                                setSheet(() {
                                  busy = false;
                                  error = 'Current password is incorrect.';
                                });
                              } on FormatException catch (e) {
                                setSheet(() {
                                  busy = false;
                                  error = e.message;
                                });
                              } on StateError catch (e) {
                                setSheet(() {
                                  busy = false;
                                  error = e.message;
                                });
                              } catch (e) {
                                setSheet(() {
                                  busy = false;
                                  error =
                                      'Couldn\'t update password. Try again.';
                                });
                              }
                            },
                      child: busy
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Update password',
                              style: TextStyle(fontWeight: FontWeight.w900),
                            ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  // ---- Recovery email ----------------------------------------------------

  // ── Recovery methods ──────────────────────────────────────────────────
  //
  // Was: one sheet that called auth.updateUser(email:), replacing the
  // account's login address. That silently changed what the person signs in
  // with, and failed anyway because Supabase confirms an email change to the
  // old address too — which on an anonymous account is the synthetic
  // @id.venttly.app that GoTrue rejects. Hence the "Couldn't save that email"
  // that arrived together with the email.
  //
  // Now two steps against a recovery method that is separate from the login:
  // nominate an address, then prove you read it with a 6-digit code. A code
  // rather than a link because mail providers prefetch links and can spend a
  // one-time token before the person ever clicks it.

  /// One line describing where a recovery method stands.
  ///
  /// Three states worth distinguishing, because they ask different things of
  /// the reader: nothing set (do something), set but unproven (finish it), and
  /// verified (nothing to do).
  String _recoverySubtitle(RecoveryMethod? method, String noun) {
    if (_recovery == null) return 'Checking…';
    if (method == null || method.isEmpty) {
      return 'Not set — add a $noun to recover your account';
    }
    if (method.verified) return '${method.masked} • verified';
    return '${method.masked} • verification required';
  }

  Future<void> _loadRecovery() async {
    try {
      final methods = await ref.read(repositoryProvider).myRecoveryMethods();
      if (!mounted) return;
      setState(() => _recovery = methods);
    } catch (_) {
      // Leave the last known state alone. Blanking the section on a failed
      // refresh would read as "you have no recovery method", which is a
      // frightening thing to tell somebody incorrectly.
    }
  }

  Future<void> _openRecoveryEmail() async {
    final current = _recovery?.email;

    // Already nominated and waiting on a code — go straight to entering it
    // rather than making them retype an address they already gave us.
    if (current != null && current.pending) {
      await _enterEmailCode(current.masked ?? '');
      return;
    }

    // Verified already: the likely intent is neither "add" nor "change", so
    // ask. Removing a route back into an account should be a deliberate,
    // visible act rather than a hidden gesture.
    if (current != null && current.verified) {
      final choice = await _chooseManageAction(current.masked ?? '');
      if (choice == _ManageChoice.remove) {
        await _removeRecovery(email: true);
        return;
      }
      if (choice != _ManageChoice.change) return;
    }

    final entered = await _promptForValue(
      title: current?.verified == true
          ? 'Change recovery email'
          : 'Add a recovery email',
      blurb: 'If you ever lose your password, this is how we get you back in. '
          'We only use it for account recovery.',
      hint: 'you@example.com',
      keyboard: TextInputType.emailAddress,
      initial: '',
      action: 'Send code',
    );
    if (entered == null || entered.trim().isEmpty) return;

    final masked = await _guard(
      () => ref.read(repositoryProvider).setRecoveryEmail(entered),
      onError: _recoveryErrorText,
    );
    if (masked == null || !mounted) return;
    await _loadRecovery();
    if (!mounted) return;
    await _enterEmailCode(masked);
  }

  Future<void> _enterEmailCode(String masked) async {
    final code = await _promptForValue(
      title: 'Enter the code',
      blurb: 'We sent a 6-digit code to $masked. It expires in 15 minutes.',
      hint: '000000',
      keyboard: TextInputType.number,
      initial: '',
      action: 'Verify',
    );
    if (code == null || code.trim().isEmpty) return;

    // A throw here is the network or the server, NOT a wrong code. Saying
    // "that code was wrong" when we never managed to ask would send somebody
    // hunting for a fresh code they do not need.
    final ok = await _guard(
      () => ref.read(repositoryProvider).confirmRecoveryEmail(code),
      onError: (_) =>
          'Couldn\'t verify that code. Check your connection and try again.',
    );
    if (ok == null) return;
    await _loadRecovery();
    if (!mounted) return;

    // A false return is a wrong or expired code, not a failure of the app —
    // so it gets a specific message rather than "something went wrong".
    _snack(
      ok == true
          ? 'Recovery email verified.'
          : 'That code was wrong or has expired. Ask for a new one.',
    );
  }

  Future<void> _openRecoveryPhone() async {
    final current = _recovery?.phone;
    if (current != null && !current.isEmpty) {
      final choice = await _chooseManageAction(current.masked ?? '');
      if (choice == _ManageChoice.remove) {
        await _removeRecovery(email: false);
        return;
      }
      if (choice != _ManageChoice.change) return;
    }

    final entered = await _promptForValue(
      title: _recovery?.phone.isEmpty == false
          ? 'Change recovery phone'
          : 'Add a recovery phone',
      blurb: 'Include your country code, like +250. Text-message recovery is '
          'not switched on yet — your number is saved and will be confirmed '
          'once it is.',
      hint: '+250 7xx xxx xxx',
      keyboard: TextInputType.phone,
      initial: '',
      action: 'Save',
    );
    if (entered == null || entered.trim().isEmpty) return;

    final masked = await _guard(
      () => ref.read(repositoryProvider).setRecoveryPhone(entered),
      onError: _recoveryErrorText,
    );
    if (masked == null || !mounted) return;
    await _loadRecovery();
    if (!mounted) return;

    // Told plainly rather than left looking broken. The number is stored; the
    // confirmation step genuinely does not exist yet.
    _snack('Saved $masked. We will confirm it when SMS is available.');
  }

  Future<void> _removeRecovery({required bool email}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(email ? 'Remove recovery email?' : 'Remove recovery phone?'),
        content: const Text(
          'You will have one less way back into your account if you lose your '
          'password. Your recovery phrase still works.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _guard(
      () async {
        final repo = ref.read(repositoryProvider);
        if (email) {
          await repo.clearRecoveryEmail();
        } else {
          await repo.clearRecoveryPhone();
        }
        return true;
      },
      onError: _recoveryErrorText,
    );
    await _loadRecovery();
    if (mounted) _snack(email ? 'Recovery email removed.' : 'Recovery phone removed.');
  }

  /// Server error codes turned into something a person can act on. Anything
  /// unrecognised falls through to a generic line rather than showing a raw
  /// PostgREST payload.
  String _recoveryErrorText(Object error) {
    final text = error.toString();
    if (text.contains('resend_too_soon')) {
      return 'Wait a minute before asking for another code.';
    }
    if (text.contains('invalid_email')) {
      // The server returns this both for a malformed address and for one
      // already verified by somebody else, on purpose — telling them apart
      // would let anyone test which emails have Venttly accounts.
      return 'We cannot use that address. Try a different one.';
    }
    if (text.contains('invalid_phone')) {
      return 'Enter the number with its country code, like +250788123456.';
    }
    return 'That did not work. Please try again.';
  }

  /// Change or remove, for a method that is already set.
  Future<_ManageChoice?> _chooseManageAction(String masked) {
    return showModalBottomSheet<_ManageChoice>(
      context: context,
      useRootNavigator: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 14),
            Text(
              masked,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 10),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Change it'),
              onTap: () => Navigator.pop(ctx, _ManageChoice.change),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline,
                  color: VentlyColors.berryMagenta),
              title: const Text('Remove it'),
              subtitle: const Text('One less way back into your account'),
              onTap: () => Navigator.pop(ctx, _ManageChoice.remove),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// One sheet for every short text answer this screen needs.
  Future<String?> _promptForValue({
    required String title,
    required String blurb,
    required String hint,
    required TextInputType keyboard,
    required String initial,
    required String action,
  }) async {
    return showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => ModalTextControllerScope(
        initialValues: [initial],
        builder: (ctx, controllers) {
          final controller = controllers.single;
          return SingleChildScrollView(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                      fontSize: 19, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 6),
                Text(
                  blurb,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(ctx).colorScheme.onSurface.withOpacity(.7),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: keyboard,
                  decoration: InputDecoration(
                    hintText: hint,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (v) => Navigator.pop(ctx, v),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, controller.text),
                    child: Text(
                      action,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Runs [task], turning a throw into a message instead of an unhandled
  /// exception. Returns null when it failed, so callers can stop.
  Future<T?> _guard<T>(
    Future<T> Function() task, {
    required String Function(Object error) onError,
  }) async {
    try {
      return await task();
    } catch (error) {
      if (mounted) _snack(onError(error));
      return null;
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }


  Future<void> _signOutEverywhere() async {
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Sign out everywhere?'),
            content: const Text(
              'You\'ll be signed out on every device, including this one. '
              'You\'ll need your username and password to sign back in.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Sign out everywhere'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok || !mounted) return;
    try {
      await ref.read(sessionProvider.notifier).signOutEverywhere();
      if (mounted) context.go('/onboarding');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Couldn\'t sign out everywhere: $e')),
        );
      }
    }
  }

  // ---- Helpers -----------------------------------------------------------

}

// ============================= Widgets =====================================

class _CheckupCard extends StatelessWidget {
  const _CheckupCard({
    required this.covered,
    required this.total,
    required this.items,
    required this.loading,
  });
  final int covered;
  final int total;
  final List<_CheckItem> items;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final allGood = covered >= total;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: allGood
              ? const [Color(0xFFE7F8EE), Color(0xFFF4FBF6)]
              : const [Color(0xFFFDD9E7), Color(0xFFFBEAF1)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.7),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  allGood
                      ? Icons.verified_user_rounded
                      : Icons.shield_moon_rounded,
                  color: allGood
                      ? const Color(0xFF2ECC71)
                      : VentlyColors.berryMagenta,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Security checkup',
                      style: TextStyle(
                        color: context.ink.withOpacity(0.7),
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                      ),
                    ),
                    Text(
                      loading
                          ? 'Checking…'
                          : allGood
                          ? 'You\'re fully protected'
                          : '$covered of $total steps done',
                      style: TextStyle(
                        color: context.ink,
                        fontWeight: FontWeight.w900,
                        fontSize: 17,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          for (final it in items) ...[
            it,
            if (it != items.last) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _CheckItem extends StatelessWidget {
  const _CheckItem({required this.label, required this.ok});
  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          ok
              ? Icons.check_circle_rounded
              : Icons.radio_button_unchecked_rounded,
          size: 18,
          color: ok
              ? const Color(0xFF2ECC71)
              : VentlyColors.berryMagenta.withOpacity(0.7),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: context.ink.withOpacity(ok ? 0.7 : 0.9),
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.8,
          color: VentlyColors.berryMagenta.withOpacity(0.85),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.trailingBadge,
    this.danger = false,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final String? trailingBadge;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? const Color(0xFFE05C5C) : VentlyColors.berryMagenta;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 19, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14.5,
                          color: danger ? color : context.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: context.ink.withOpacity(0.55),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                if (trailingBadge != null) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: VentlyColors.berryMagenta,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      trailingBadge!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                ] else if (onTap != null)
                  Icon(
                    Icons.chevron_right_rounded,
                    color: context.ink.withOpacity(0.3),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What to do with a recovery method that is already set.
enum _ManageChoice { change, remove }
