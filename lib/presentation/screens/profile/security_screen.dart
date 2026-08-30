import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../theme/colors.dart';
import '../../widgets/modal_text_controller_scope.dart';
import '../../widgets/wall_controls.dart';

/// Security & 2FA settings. Wires Supabase Auth MFA (TOTP) so a
/// returning user can require a 6-digit code in addition to their
/// password on sign-in.
class SecurityScreen extends ConsumerStatefulWidget {
  const SecurityScreen({super.key});

  @override
  ConsumerState<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends ConsumerState<SecurityScreen> {
  bool _loading = true;
  bool _busy = false;
  List<Factor> _factors = const [];
  String? _err;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final res = await Supabase.instance.client.auth.mfa.listFactors();
      if (!mounted) return;
      setState(() {
        _factors = [...res.totp, ...res.phone];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _enroll() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final enroll = await Supabase.instance.client.auth.mfa.enroll(
        factorType: FactorType.totp,
        issuer: 'Venttly',
      );
      if (!mounted) return;
      await _showEnrollSheet(enroll);
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Couldn\'t start enrollment: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showEnrollSheet(AuthMFAEnrollResponse enroll) async {
    final factorId = enroll.id;
    final secret = enroll.totp?.secret ?? '';
    final uri = enroll.totp?.uri ?? '';
    String? error;
    var verifying = false;
    final verified = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => ModalTextControllerScope(
        initialValues: const [''],
        builder: (ctx, controllers) {
          final codeCtl = controllers.single;
          return StatefulBuilder(builder: (ctx, setSheet) {
            return SingleChildScrollView(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Set up authenticator',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 8),
                  const Text(
                      'Open Google Authenticator / 1Password / Authy. Add a new account with this secret, then enter the 6-digit code below.',
                      style: TextStyle(height: 1.4)),
                  const SizedBox(height: 14),
                  _SecretBlock(secret: secret, uri: uri),
                  const SizedBox(height: 14),
                  TextField(
                    controller: codeCtl,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      labelText: '6-digit code',
                      errorText: error,
                    ),
                  ),
                  const SizedBox(height: 8),
                  WallButton(
                    label: 'Verify & enable 2FA',
                    busy: verifying,
                    onPressed: verifying
                        ? null
                        : () async {
                            final code = codeCtl.text.trim();
                            if (code.length != 6) {
                              setSheet(
                                  () => error = 'Enter the 6-digit code.');
                              return;
                            }
                            setSheet(() {
                              verifying = true;
                              error = null;
                            });
                            try {
                              final challenge = await Supabase
                                  .instance.client.auth.mfa
                                  .challenge(factorId: factorId);
                              await Supabase.instance.client.auth.mfa.verify(
                                factorId: factorId,
                                challengeId: challenge.id,
                                code: code,
                              );
                              if (ctx.mounted) Navigator.pop(ctx, true);
                            } catch (_) {
                              if (!ctx.mounted) return;
                              setSheet(() {
                                verifying = false;
                                error = 'Code didn\'t match. Try again.';
                              });
                            }
                          },
                  ),
                ],
              ),
            );
          });
        },
      ),
    );
    if (verified == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Two-factor authentication is on.')));
    } else {
      // User cancelled — clean up the half-enrolled factor.
      try {
        await Supabase.instance.client.auth.mfa.unenroll(factorId);
      } catch (_) {}
    }
  }

  Future<void> _disable(Factor f) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Turn off 2FA?'),
        content: const Text(
            'Your account will only need your password to sign in. You can re-enable it any time.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: VentlyColors.berryMagenta),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Turn off'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    setState(() => _busy = true);
    try {
      await Supabase.instance.client.auth.mfa.unenroll(f.id);
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Couldn\'t disable: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final verified = _factors.any((f) => f.status == FactorStatus.verified);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Security')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                WallPanel(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            verified
                                ? Icons.verified_user_rounded
                                : Icons.shield_outlined,
                            color: verified
                                ? Colors.green
                                : VentlyColors.berryMagenta,
                            size: 22,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              verified
                                  ? 'Two-factor authentication is ON'
                                  : 'Two-factor authentication is OFF',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                                color: context.ink,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        verified
                            ? 'Sign-ins require your password plus a 6-digit code from your authenticator app. If you lose the authenticator, sign in with your 12-word recovery phrase — that phrase is the backup for this account. We do not issue one-time backup codes.'
                            : 'Add a 6-digit code from any authenticator app (Google Authenticator, 1Password, Authy) on top of your password.',
                        style: TextStyle(
                          color: context.ink.withOpacity(0.7),
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (verified) ...[
                        for (final f in _factors)
                          if (f.status == FactorStatus.verified)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.qr_code_2_rounded),
                              title: Text(f.friendlyName ?? f.factorType.name),
                              subtitle: Text(
                                'Enrolled ${_short(f.createdAt.toIso8601String())}',
                              ),
                              trailing: TextButton(
                                onPressed: _busy ? null : () => _disable(f),
                                child: const Text(
                                  'Disable',
                                  style: TextStyle(
                                      color: VentlyColors.berryMagenta),
                                ),
                              ),
                            ),
                      ] else
                        WallButton(
                          label: 'Turn on 2FA',
                          icon: Icons.lock_outline,
                          onPressed: _busy ? null : _enroll,
                          busy: _busy,
                        ),
                    ],
                  ),
                ),
                if (_err != null) ...[
                  const SizedBox(height: 12),
                  Text(_err!, style: const TextStyle(color: Colors.red)),
                ],
              ],
            ),
    );
  }

  String _short(String iso) {
    try {
      final d = DateTime.parse(iso).toLocal();
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }
}

class _SecretBlock extends StatelessWidget {
  const _SecretBlock({required this.secret, required this.uri});
  final String secret;
  final String uri;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF1F6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Secret (paste into authenticator)',
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w800, color: context.ink),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  secret,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: secret));
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Secret copied')));
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Or copy the full setup URI:',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: context.ink.withOpacity(0.7)),
          ),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  uri,
                  maxLines: 2,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
              IconButton(
                tooltip: 'Copy URI',
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: uri));
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('URI copied')));
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
