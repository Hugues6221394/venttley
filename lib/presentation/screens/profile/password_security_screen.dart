import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/providers.dart';
import '../../../core/security_checkup.dart';
import '../../../data/services/supabase_backend.dart'
    show MfaChallengeRequiredException;
import '../../theme/colors.dart';
import '../../widgets/modal_text_controller_scope.dart';
import '../../widgets/wall_controls.dart';
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

  @override
  void initState() {
    super.initState();
    _loadFactors();
    _loadDeviceCount();
    _loadPasswordChangedAt();
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
    final email = session.currentEmail;

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
              _CheckItem(label: checkup.recoveryLabel, ok: checkup.recoveryOk),
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
          _Tile(
            icon: Icons.alternate_email_rounded,
            title: 'Recovery email',
            subtitle: email == null || !hasRealEmail
                ? 'Not set — add one to recover your account'
                : checkup.recoveryOk
                ? _mask(email)
                : '${_mask(email)} • unconfirmed',
            trailingBadge: hasRealEmail && !emailVerified ? 'Confirm' : null,
            onTap: _openRecoveryEmail,
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

  Future<void> _openRecoveryEmail() async {
    final session = ref.read(sessionProvider.notifier);
    final hasRealEmail = session.hasRealEmail;
    final emailVerified = session.isEmailVerified;

    // Already have a real email that just needs confirming → 6-digit verify.
    if (hasRealEmail && !emailVerified) {
      await _verifyExistingEmail();
      return;
    }

    String? error;
    bool busy = false;

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
        initialValues: [hasRealEmail ? (session.currentEmail ?? '') : ''],
        builder: (ctx, controllers) {
          final controller = controllers.single;
          return StatefulBuilder(
            builder: (ctx, setSheet) {
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
                      hasRealEmail
                          ? 'Change recovery email'
                          : 'Add recovery email',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: context.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'We\'ll email a confirmation link to this address. Tap it to '
                      'finish — your username login keeps working either way.',
                      style: TextStyle(
                        color: context.ink.withOpacity(0.6),
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: controller,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: 'Email address',
                        filled: true,
                        fillColor: const Color(0xFFFFF1F6),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
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
                              final value = controller.text.trim();
                              if (!_looksLikeEmail(value)) {
                                setSheet(
                                  () => error = 'Enter a valid email address.',
                                );
                                return;
                              }
                              setSheet(() {
                                busy = true;
                                error = null;
                              });
                              try {
                                await session.setRecoveryEmail(value);
                                if (ctx.mounted) Navigator.pop(ctx);
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Confirmation sent to $value. Tap the link '
                                        'to finish.',
                                      ),
                                    ),
                                  );
                                }
                              } catch (e) {
                                setSheet(() {
                                  busy = false;
                                  error =
                                      'Couldn\'t save that email. Try again.';
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
                              'Send confirmation',
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

  /// Real email already on file but unverified → reuse the app's working
  /// 6-digit code pipeline (sendEmailVerification / confirmEmailVerification).
  Future<void> _verifyExistingEmail() async {
    final session = ref.read(sessionProvider.notifier);
    String? error;
    bool busy = false;
    bool sent = false;

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
        initialValues: const [''],
        builder: (ctx, controllers) {
          final codeCtl = controllers.single;
          return StatefulBuilder(
            builder: (ctx, setSheet) {
              Future<void> send() async {
                setSheet(() {
                  busy = true;
                  error = null;
                });
                try {
                  await session.sendEmailVerification();
                  if (!ctx.mounted) return;
                  setSheet(() {
                    busy = false;
                    sent = true;
                  });
                } catch (_) {
                  if (!ctx.mounted) return;
                  setSheet(() {
                    busy = false;
                    error =
                        'Couldn\'t send a code right now. Try again shortly.';
                  });
                }
              }

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
                      'Confirm recovery email',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: context.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      sent
                          ? 'Enter the 6-digit code we emailed to ${session.currentEmail ?? 'your inbox'}.'
                          : 'We\'ll email a 6-digit code to ${session.currentEmail ?? 'your inbox'}.',
                      style: TextStyle(
                        color: context.ink.withOpacity(0.6),
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (sent)
                      TextField(
                        controller: codeCtl,
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        decoration: InputDecoration(
                          labelText: '6-digit code',
                          counterText: '',
                          filled: true,
                          fillColor: const Color(0xFFFFF1F6),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
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
                              if (!sent) {
                                await send();
                                return;
                              }
                              if (codeCtl.text.trim().length != 6) {
                                setSheet(
                                  () => error = 'Enter the 6-digit code.',
                                );
                                return;
                              }
                              setSheet(() {
                                busy = true;
                                error = null;
                              });
                              try {
                                final ok = await session
                                    .confirmEmailVerification(
                                      codeCtl.text.trim(),
                                    );
                                if (ok) {
                                  if (ctx.mounted) Navigator.pop(ctx);
                                  if (mounted) {
                                    setState(() {});
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Recovery email confirmed.',
                                        ),
                                      ),
                                    );
                                  }
                                } else {
                                  setSheet(() {
                                    busy = false;
                                    error =
                                        'That code didn\'t match. Try again.';
                                  });
                                }
                              } catch (_) {
                                setSheet(() {
                                  busy = false;
                                  error =
                                      'Couldn\'t verify that code. Check your connection and try again.';
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
                          : Text(
                              sent ? 'Confirm' : 'Send code',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                              ),
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

  // ---- Sessions ----------------------------------------------------------

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

  bool _looksLikeEmail(String v) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v);

  String _mask(String email) {
    final at = email.indexOf('@');
    if (at <= 1) return email;
    final name = email.substring(0, at);
    final domain = email.substring(at);
    final shown = name.length <= 2
        ? name.substring(0, 1)
        : name.substring(0, 2);
    return '$shown${'•' * (name.length - shown.length)}$domain';
  }
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
    final dark = context.isDark;
    return WallPanel(
      padding: const EdgeInsets.all(18),
      tint: allGood
          ? (dark ? const Color(0xFF14301C) : const Color(0xFFE7F8EE))
          : (dark ? const Color(0xFF2A1520) : const Color(0xFFFCE4EE)),
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
    return WallPanel(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
      onTap: onTap,
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
          if (trailingBadge != null)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                trailingBadge!,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                ),
              ),
            )
          else if (onTap != null)
            Icon(
              Icons.chevron_right_rounded,
              color: context.ink.withOpacity(0.28),
            ),
        ],
      ),
    );
  }
}
