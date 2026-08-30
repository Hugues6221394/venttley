import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../widgets/modal_text_controller_scope.dart';
import '../../widgets/wall_controls.dart';

/// Completes AAL2 after any sign-in path that landed at AAL1 with TOTP
/// enrolled: password, recovery phrase, phone OTP, Google, or a restored
/// session. The 12-word recovery phrase is the backup — GoTrue cannot
/// grant AAL2 from a homemade backup-code list.
class MfaChallengeScreen extends ConsumerStatefulWidget {
  const MfaChallengeScreen({super.key});

  @override
  ConsumerState<MfaChallengeScreen> createState() => _MfaChallengeScreenState();
}

class _MfaChallengeScreenState extends ConsumerState<MfaChallengeScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _verify(String code) async {
    final factorId = ref.read(pendingMfaFactorIdProvider);
    if (factorId == null) {
      if (mounted) context.go('/onboarding');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(repositoryProvider)
          .verifyMfa(factorId: factorId, code: code);
      ref.read(pendingMfaFactorIdProvider.notifier).state = null;
      await ref.read(sessionProvider.notifier).restore();
      if (!mounted) return;
      if (ref.read(sessionProvider) == null) {
        setState(
          () => _error =
              'Two-factor verification succeeded, but your session could not be restored. Please try signing in again.',
        );
        return;
      }
      context.go('/feed');
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Code didn\'t match.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    ref.read(pendingMfaFactorIdProvider.notifier).state = null;
    await ref.read(sessionProvider.notifier).logout();
    if (mounted) context.go('/onboarding');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Two-factor verification'),
        leading: IconButton(
          tooltip: 'Cancel',
          onPressed: _busy ? null : _cancel,
          icon: const Icon(Icons.close_rounded),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _MfaCodeForm(
            busy: _busy,
            error: _error,
            onSubmit: _verify,
            footer: Text(
              'Lost your authenticator? Use your 12-word recovery phrase '
              'from the sign-in screen instead. That phrase is the backup '
              'for this account — we do not issue one-time backup codes.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: scheme.onSurface.withOpacity(0.62),
                fontWeight: FontWeight.w600,
                height: 1.4,
                fontSize: 13,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared 6-digit TOTP form. Used by the dedicated challenge route and by
/// in-session prompts (password change) that already have a navigator.
class _MfaCodeForm extends StatefulWidget {
  const _MfaCodeForm({
    required this.busy,
    required this.error,
    required this.onSubmit,
    this.footer,
  });

  final bool busy;
  final String? error;
  final Future<void> Function(String code) onSubmit;
  final Widget? footer;

  @override
  State<_MfaCodeForm> createState() => _MfaCodeFormState();
}

class _MfaCodeFormState extends State<_MfaCodeForm> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _code.text.trim();
    if (code.length != 6) return;
    await widget.onSubmit(code);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Enter the 6-digit code from your authenticator app.',
          textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.w700, height: 1.4),
        ),
        const SizedBox(height: 18),
        TextField(
          controller: _code,
          enabled: !widget.busy,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          maxLength: 6,
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            letterSpacing: 10,
          ),
          decoration: InputDecoration(
            counterText: '',
            labelText: '6-digit code',
            errorText: widget.error,
          ),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 18),
        WallButton(
          label: 'Verify',
          icon: Icons.verified_user_outlined,
          onPressed: widget.busy ? null : _submit,
          busy: widget.busy,
        ),
        if (widget.footer != null) ...[
          const SizedBox(height: 20),
          widget.footer!,
        ],
      ],
    );
  }
}

/// In-session TOTP prompt. Returns true when AAL2 was granted.
Future<bool> showMfaChallengeDialog({
  required BuildContext context,
  required WidgetRef ref,
  required String factorId,
}) async {
  String? error;
  var verifying = false;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => ModalTextControllerScope(
      initialValues: const [''],
      builder: (ctx, controllers) {
        final ctl = controllers.single;
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('Two-factor verification'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Enter the 6-digit code from your authenticator app.',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: ctl,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      labelText: '6-digit code',
                      errorText: error,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: verifying
                      ? null
                      : () async {
                          final code = ctl.text.trim();
                          if (code.length != 6) {
                            setLocal(() => error = 'Enter all 6 digits.');
                            return;
                          }
                          setLocal(() {
                            verifying = true;
                            error = null;
                          });
                          try {
                            await ref
                                .read(repositoryProvider)
                                .verifyMfa(factorId: factorId, code: code);
                            if (ctx.mounted) Navigator.pop(ctx, true);
                          } catch (_) {
                            if (!ctx.mounted) return;
                            setLocal(() {
                              verifying = false;
                              error = 'Code didn\'t match.';
                            });
                          }
                        },
                  child: verifying
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Verify'),
                ),
              ],
            );
          },
        );
      },
    ),
  );
  return ok == true;
}
