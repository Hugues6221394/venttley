import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';

/// Shown once after signup. The user copies / writes down their recovery
/// key (the only way to sign back in without re-creating an identity).
class RecoveryKeyScreen extends ConsumerStatefulWidget {
  const RecoveryKeyScreen({super.key});

  @override
  ConsumerState<RecoveryKeyScreen> createState() => _RecoveryKeyScreenState();
}

class _RecoveryKeyScreenState extends ConsumerState<RecoveryKeyScreen> {
  String _key = '';
  bool _acknowledged = false;

  @override
  void initState() {
    super.initState();
    () async {
      final k = await ref.read(repositoryProvider).currentRecoveryKey();
      if (mounted) setState(() => _key = k);
    }();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Your Recovery Key')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: scheme.primary.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(Icons.vpn_key_outlined, color: scheme.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'This is the only way back in.',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Vently does not collect email or phone numbers. Save this Secret Recovery Key somewhere safe — without it, your sanctuary cannot be restored on another device.',
                style: TextStyle(
                  color: scheme.onSurface.withOpacity(0.7),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: scheme.primary.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: scheme.primary.withOpacity(0.3),
                  ),
                ),
                child: Column(
                  children: [
                    Text(
                      _key.isEmpty ? '....-....-....-....' : _formatKey(_key),
                      style: const TextStyle(
                        fontSize: 22,
                        letterSpacing: 4,
                        fontWeight: FontWeight.w800,
                        fontFamily: 'monospace',
                      ),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: _key.isEmpty
                          ? null
                          : () {
                              Clipboard.setData(ClipboardData(text: _key));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Recovery key copied')),
                              );
                            },
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copy to clipboard'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _acknowledged,
                onChanged: (v) => setState(() => _acknowledged = v ?? false),
                title: const Text(
                  'I have saved my key somewhere safe.',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const Spacer(),
              ElevatedButton(
                onPressed: _acknowledged ? () => context.go('/') : null,
                child: const Text('Enter Vently'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatKey(String k) {
    if (k.contains('-')) return k;
    final groups = <String>[];
    for (var i = 0; i < k.length; i += 5) {
      groups.add(k.substring(i, (i + 5).clamp(0, k.length)));
    }
    return groups.join('-');
  }
}
