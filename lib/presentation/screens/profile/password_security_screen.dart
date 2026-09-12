import 'dart:async';
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
    final me = ref.watch(sessionProvider);

    // fallback: false on purpose. A missing flag row must read as "no SMS",
    // because guessing the other way puts the dead-end phone flow back.
    final smsReady = flagEnabled(ref, 'recovery_sms', fallback: false);

    final checkup = SecurityCheckup(
      passwordChangedAt: _passwordChangedAt,
      twoFactorOn: _twoFactorOn,
      recovery: _recovery,
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
          // Gated on the live flag, not a constant: confirm_recovery_phone()
          // can only succeed once GoTrue has an SMS provider, so until one is
          // configured this row must not ask for something it cannot finish.
          // Flipping recovery_sms in the console turns it on with no deploy.
          _Tile(
            icon: Icons.sms_outlined,
            title: 'Recovery phone',
            subtitle: _phoneSubtitle(smsReady),
            muted: !smsReady && (_recovery?.phone.isEmpty ?? true),
            onTap: smsReady
                ? _openRecoveryPhone
                : (_recovery?.phone.isEmpty ?? true)
                      // Nothing stored and nothing storable — an inert row is
                      // kinder than one that opens a form leading nowhere.
                      ? null
                      // A number saved before SMS was switched off is stranded.
                      // Removing it is the only real action, so offer that.
                      : () => _removeRecovery(email: false),
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
    // A half-finished change. Naming both addresses is the point: the reader
    // needs to know their existing route still works, which is the opposite of
    // what the old single-column version could tell them.
    final moving = method.pendingAddress;
    if (moving != null && method.verified) {
      return '${method.display} • verified — confirming $moving';
    }
    if (method.verified) return '${method.display} • verified';
    return '${method.display} • verification required';
  }

  /// The phone row cannot borrow [_recoverySubtitle], because the unverified
  /// case there says "verification required" — a request. With no SMS provider
  /// there is nothing the reader can do to satisfy it, and an app that asks for
  /// something impossible and then stays silent is worse than one that admits
  /// the feature is not ready.
  String _phoneSubtitle(bool smsReady) {
    if (_recovery == null) return 'Checking…';
    final phone = _recovery!.phone;

    if (smsReady) return _recoverySubtitle(phone, 'phone number');

    if (phone.isEmpty) {
      return 'Not available yet — a recovery email covers this for now';
    }
    // Stored while the option was open, and now unconfirmable. Say whose
    // problem it is, and point at the one thing that still works.
    return '${phone.display} • we cannot confirm it yet — tap to remove';
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

    // A change is in flight. Two real options — finish it, or drop it and keep
    // what already works — and the sheet must offer the second, because
    // otherwise the only way out of a change whose code never arrived is to
    // remove the verified address entirely.
    final moving = current?.pendingAddress;
    if (moving != null) {
      final choice = await _choosePendingAction(moving);
      if (choice == _PendingChoice.enterCode) {
        await _enterEmailCode(moving);
      } else if (choice == _PendingChoice.discard) {
        await _cancelEmailChange();
      }
      return;
    }

    // Already nominated and waiting on a code — go straight to entering it
    // rather than making them retype an address they already gave us.
    if (current != null && current.pending) {
      await _enterEmailCode(current.display ?? '');
      return;
    }

    // Verified already: the likely intent is neither "add" nor "change", so
    // ask. Removing a route back into an account should be a deliberate,
    // visible act rather than a hidden gesture.
    if (current != null && current.verified) {
      final choice = await _chooseManageAction(current.display ?? '');
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

  Future<void> _enterEmailCode(String target) async {
    final code = await _promptForCode(
      sentTo: target,
      blurb: (to) => 'We sent a 6-digit code to $to. It expires in 15 minutes.',
      onResend: () async {
        // A resend is the same request again: set_recovery_email issues a fresh
        // code for the same address and queues fresh mail. It is only safe to
        // call because the address is now carried in full — a masked string
        // would fail the server's format check.
        if (!target.contains('@') || target.contains('*')) {
          return 'Reopen this screen to send a new code.';
        }
        try {
          await ref.read(repositoryProvider).setRecoveryEmail(target);
          return null;
        } catch (error) {
          return _recoveryErrorText(error);
        }
      },
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
      final choice = await _chooseManageAction(current.display ?? '');
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
      blurb: 'Include your country code, like +250. We will text you a 6-digit '
          'code to confirm the number is yours.',
      hint: '+250 7xx xxx xxx',
      keyboard: TextInputType.phone,
      initial: '',
      action: 'Send code',
    );
    if (entered == null || entered.trim().isEmpty) return;

    final masked = await _guard(
      () => ref.read(repositoryProvider).setRecoveryPhone(entered),
      onError: _recoveryErrorText,
    );
    if (masked == null || !mounted) return;
    await _loadRecovery();
    if (!mounted) return;

    await _enterPhoneCode(entered.trim(), masked);
  }

  /// Ownership of a number is proved through GoTrue's own phone OTP, the same
  /// one phone sign-in uses, and then confirm_recovery_phone() checks that
  /// auth.users.phone_confirmed_at now covers this exact number. We deliberately
  /// do not mint a second proof of our own: two independent ideas of "confirmed"
  /// is how one of them ends up wrong.
  Future<void> _enterPhoneCode(String phone, String shown) async {
    // updateUser(phone:) is what actually sends the SMS, and it is also what a
    // resend calls — GoTrue issues a fresh OTP for the same number.
    Future<void> send() => Supabase.instance.client.auth.updateUser(
      UserAttributes(phone: phone),
    );

    // If no provider is configured this throws, which is why the row is
    // flag-gated: reaching here with SMS off would show a code prompt for a
    // code nobody sent.
    final sent = await _guard(
      () async {
        await send();
        return true;
      },
      onError: (e) => 'We could not text $shown. Check the number and '
          'your connection, then try again.',
    );
    if (sent != true || !mounted) return;

    final code = await _promptForCode(
      sentTo: shown,
      blurb: (to) => 'We texted a 6-digit code to $to.',
      onResend: () async {
        try {
          await send();
          return null;
        } catch (_) {
          // GoTrue enforces its own SMS rate limit, and the message it returns
          // is not something to show a person.
          return 'We could not send another code just yet. Try again shortly.';
        }
      },
    );
    if (code == null || code.trim().isEmpty) return;

    final ok = await _guard(() async {
      // phoneChange is the right type here: the number is being attached to an
      // existing session, not used to sign in.
      await Supabase.instance.client.auth.verifyOTP(
        type: OtpType.phoneChange,
        phone: phone,
        token: code.trim(),
      );
      // Only now can the server see phone_confirmed_at and agree.
      return ref.read(repositoryProvider).confirmRecoveryPhone();
    }, onError: (e) => 'That code was wrong or has expired. Ask for a new one.');

    if (ok == null || !mounted) return;
    await _loadRecovery();
    if (!mounted) return;
    _snack(
      ok == true
          ? 'Recovery phone verified.'
          : 'That code was wrong or has expired. Ask for a new one.',
    );
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

  /// What to do about a change that was started but never confirmed.
  Future<_PendingChoice?> _choosePendingAction(String moving) {
    return showModalBottomSheet<_PendingChoice>(
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Waiting on a code for $moving',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(height: 10),
            ListTile(
              leading: const Icon(Icons.pin_outlined),
              title: const Text('Enter the code'),
              onTap: () => Navigator.pop(ctx, _PendingChoice.enterCode),
            ),
            ListTile(
              leading: const Icon(Icons.undo_rounded),
              title: const Text('Keep my current email'),
              // The reassurance is the whole point of this option existing.
              subtitle: const Text('Cancels the change. Nothing else changes.'),
              onTap: () => Navigator.pop(ctx, _PendingChoice.discard),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _cancelEmailChange() async {
    final done = await _guard(
      () => ref.read(repositoryProvider).cancelRecoveryEmailChange(),
      onError: (_) => 'Couldn\'t cancel that. Check your connection.',
    );
    if (done == null || !mounted) return;
    await _loadRecovery();
    if (!mounted) return;
    _snack('Change cancelled. Your recovery email is unchanged.');
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
                  // Every value this sheet collects is a machine identifier —
                  // an email, a phone number, a 6-digit code. iOS capitalises
                  // the first letter by default, which turned a typed address
                  // into "Hughes.test.recovery@gmail.com" on a real device.
                  // The server lowercases, so nothing broke, but showing
                  // somebody a mangled version of what they just typed makes
                  // them distrust the screen — and autocorrect on an email
                  // field is free to substitute whole words.
                  textCapitalization: TextCapitalization.none,
                  autocorrect: false,
                  enableSuggestions: false,
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

  /// The code sheet, which needs to do more than collect six digits.
  ///
  /// A verification code that does not arrive is the normal case, not the edge
  /// case — mail is delayed, it lands in spam, the number was mistyped, the
  /// person closed the app and came back. Without a resend the only way out is
  /// to abandon the change, which is how somebody ends up with no recovery
  /// method at all. [onResend] returns null on success or a message to show.
  Future<String?> _promptForCode({
    required String sentTo,
    required String Function(String target) blurb,
    required Future<String?> Function() onResend,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _CodeSheet(
        sentTo: sentTo,
        blurb: blurb,
        onResend: onResend,
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
    this.muted = false,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final String? trailingBadge;
  final bool danger;

  /// Drains the colour so the row reads as unavailable rather than merely
  /// undecorated. Without it a tile with no chevron looks identical to one
  /// whose tap handler is broken.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final color = muted
        ? context.ink.withOpacity(0.32)
        : danger
        ? const Color(0xFFE05C5C)
        : VentlyColors.berryMagenta;
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
                          color: (danger || muted) ? color : context.ink,
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

/// What to do with a change that was requested but never confirmed.
enum _PendingChoice { enterCode, discard }

/// Collects a 6-digit code and can ask for a fresh one.
///
/// Stateful because of the cooldown. The server refuses a second code inside 60
/// seconds with `resend_too_soon`, and a button that looks available but always
/// fails is worse than one that says how long is left — people tap it three
/// times, get three errors, and conclude the app is broken. So the countdown is
/// shown, and the button is only live when a resend would actually work.
class _CodeSheet extends StatefulWidget {
  const _CodeSheet({
    required this.sentTo,
    required this.blurb,
    required this.onResend,
  });

  final String sentTo;
  final String Function(String target) blurb;

  /// Null on success, or a message explaining why not.
  final Future<String?> Function() onResend;

  @override
  State<_CodeSheet> createState() => _CodeSheetState();
}

class _CodeSheetState extends State<_CodeSheet> {
  /// Matches the 60-second window enforced by set_recovery_email. Starting the
  /// countdown at full assumes a code has just been sent, which is true at
  /// every entry point into this sheet.
  static const int _cooldownSeconds = 60;

  final _controller = TextEditingController();
  Timer? _ticker;
  int _remaining = _cooldownSeconds;
  bool _resending = false;
  String? _notice;
  bool _noticeIsError = false;

  @override
  void initState() {
    super.initState();
    _startCountdown();
  }

  void _startCountdown() {
    _ticker?.cancel();
    setState(() => _remaining = _cooldownSeconds);
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _remaining--);
      if (_remaining <= 0) timer.cancel();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _resend() async {
    setState(() {
      _resending = true;
      _notice = null;
    });
    final error = await widget.onResend();
    if (!mounted) return;
    setState(() {
      _resending = false;
      _notice = error ?? 'A new code is on its way.';
      _noticeIsError = error != null;
    });
    // Only restart the clock on success. A failed attempt did not consume the
    // server's window, so making somebody wait another minute for it would be
    // punishing them for our error.
    if (error == null) _startCountdown();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canResend = _remaining <= 0 && !_resending;

    return SingleChildScrollView(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Enter the code',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 6),
          Text(
            widget.blurb(widget.sentTo),
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface.withOpacity(.7),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            textCapitalization: TextCapitalization.none,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              hintText: '000000',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
          if (_notice != null) ...[
            const SizedBox(height: 10),
            Text(
              _notice!,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: _noticeIsError
                    ? const Color(0xFFE05C5C)
                    : VentlyColors.berryMagenta,
              ),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.pop(context, _controller.text),
              child: const Text(
                'Verify',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: TextButton(
              onPressed: canResend ? _resend : null,
              child: Text(
                _resending
                    ? 'Sending…'
                    : canResend
                    ? 'Send a new code'
                    // Named in seconds rather than "try again later", so the
                    // wait is a known quantity instead of an open question.
                    : 'Send a new code in ${_remaining}s',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
