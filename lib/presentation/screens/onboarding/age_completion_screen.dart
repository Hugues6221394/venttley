import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';

/// Mandatory completion step for OAuth/phone accounts created without age
/// metadata. Only the year is sent and stored; Postgres derives the safety tier.
class AgeCompletionScreen extends ConsumerStatefulWidget {
  const AgeCompletionScreen({super.key});

  @override
  ConsumerState<AgeCompletionScreen> createState() =>
      _AgeCompletionScreenState();
}

class _AgeCompletionScreenState extends ConsumerState<AgeCompletionScreen> {
  DateTime? _birthDate;
  bool _busy = false;
  String? _error;

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year - 18, 1, 1),
      firstDate: DateTime(1900, 1, 1),
      lastDate: now,
      helpText: 'Select your date of birth',
    );
    if (!mounted || picked == null) return;
    setState(() {
      _birthDate = picked;
      _error = null;
    });
  }

  Future<void> _continue() async {
    final birthDate = _birthDate;
    if (birthDate == null || _busy) {
      setState(() => _error = 'Select your date of birth to continue.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(sessionProvider.notifier)
          .completeAgeVerification(birthDate);
      if (mounted) context.go('/feed');
    } catch (error) {
      final raw = error.toString().toLowerCase();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = raw.contains('age_below_minimum') || raw.contains('under 13')
            ? 'Venttly is not available to children under 13.'
            : 'We couldn\'t verify your age. Check the date and try again.';
      });
    }
  }

  Future<void> _useAnotherAccount() async {
    await ref.read(sessionProvider.notifier).logout();
    if (mounted) context.go('/onboarding');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final date = _birthDate;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Confirm your age'),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.verified_user_outlined,
                    size: 48,
                    color: scheme.primary,
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Safety settings depend on age',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'We store only your birth year. It is not shown on your profile. '
                    'Members aged 13–17 receive additional protections.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Semantics(
                    button: true,
                    label: date == null
                        ? 'Select date of birth'
                        : 'Date of birth selected, ${date.year}',
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _pickDate,
                      icon: const Icon(Icons.cake_outlined),
                      label: Text(
                        date == null
                            ? 'Select date of birth'
                            : '${date.day.toString().padLeft(2, '0')}/'
                                  '${date.month.toString().padLeft(2, '0')}/${date.year}',
                      ),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(54),
                      ),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: scheme.error,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: _busy ? null : _continue,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(54),
                    ),
                    child: _busy
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Continue'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy ? null : _useAnotherAccount,
                    child: const Text('Use another account'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
