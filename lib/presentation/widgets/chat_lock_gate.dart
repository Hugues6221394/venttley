import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../theme/colors.dart';
import '../theme/glass_tokens.dart';

/// Proving it is you, before a locked conversation opens.
///
/// Biometrics first, because they are quicker and because a PIN typed in front
/// of the person you are hiding the chat from is not much of a secret. The PIN
/// is the fallback and it has to exist: biometrics fail with wet hands, some
/// devices have none, and a lock with no way past it would strand somebody out
/// of their own conversation.
///
/// Returns true only if the check passed.
Future<bool> promptChatUnlock(
  BuildContext context,
  WidgetRef ref, {
  required String reason,
}) async {
  final lock = ref.read(chatLockProvider);

  // Somebody locking their first chat has no PIN yet. Asked for here rather
  // than in settings, because this is the moment they have a reason to care.
  if (!await lock.hasPin) {
    if (!context.mounted) return false;
    final pin = await _askForPin(
      context,
      title: 'Choose a PIN',
      blurb:
          'Four digits, used when Face ID or your fingerprint is not available.',
      confirm: true,
    );
    if (pin == null) return false;
    await lock.setPin(pin);
    return true;
  }

  if (await lock.canUseBiometrics) {
    if (await lock.authenticateWithDevice()) return true;
  }

  if (!context.mounted) return false;
  final pin = await _askForPin(
    context,
    title: reason,
    blurb: 'Enter your PIN.',
    confirm: false,
  );
  if (pin == null) return false;
  final ok = await lock.checkPin(pin);
  if (!ok && context.mounted) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('That PIN is not right.')));
  }
  return ok;
}

Future<String?> _askForPin(
  BuildContext context, {
  required String title,
  required String blurb,
  required bool confirm,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _PinDialog(title: title, blurb: blurb, confirm: confirm),
  );
}

class _PinDialog extends StatefulWidget {
  const _PinDialog({
    required this.title,
    required this.blurb,
    required this.confirm,
  });

  final String title;
  final String blurb;

  /// Ask twice, for a PIN being set. A typo in a PIN nobody has written down
  /// locks a conversation for good.
  final bool confirm;

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _first = TextEditingController();
  final _second = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  void _submit() {
    final a = _first.text.trim();
    if (a.length < 4) {
      setState(() => _error = 'Four digits.');
      return;
    }
    if (widget.confirm && a != _second.text.trim()) {
      setState(() => _error = 'Those do not match.');
      return;
    }
    Navigator.pop(context, a);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.blurb,
            style: TextStyle(
              fontSize: 12.5,
              color: GlassTokens.onCardMuted(context),
            ),
          ),
          const SizedBox(height: 14),
          _PinField(controller: _first, label: 'PIN', autofocus: true),
          if (widget.confirm) ...[
            const SizedBox(height: 10),
            _PinField(controller: _second, label: 'Again', autofocus: false),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: VentlyColors.dangerRed,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Done')),
      ],
    );
  }
}

class _PinField extends StatelessWidget {
  const _PinField({
    required this.controller,
    required this.label,
    required this.autofocus,
  });

  final TextEditingController controller;
  final String label;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      obscureText: true,
      keyboardType: TextInputType.number,
      maxLength: 8,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(labelText: label, counterText: ''),
    );
  }
}
