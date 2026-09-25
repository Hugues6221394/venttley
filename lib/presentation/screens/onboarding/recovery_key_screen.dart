import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../widgets/onboarding_backdrop.dart';

/// Recovery phrase reveal — shown once, right after signup.
///
/// The 12-word phrase is the only off-device thing that can restore the
/// account on a new install. We show it, copy it, then require an explicit
/// acknowledgment before letting the user proceed.
class RecoveryKeyScreen extends ConsumerStatefulWidget {
  const RecoveryKeyScreen({super.key, required this.phrase});
  final String phrase;

  @override
  ConsumerState<RecoveryKeyScreen> createState() => _RecoveryKeyScreenState();
}

class _RecoveryKeyScreenState extends ConsumerState<RecoveryKeyScreen> {
  bool _acknowledged = false;
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // No phrase to show.
    //
    // The route reads it from `extra`, and go_router drops `extra` across a
    // redirect — so any rule that bounced this path and came back would land
    // here with nothing. Splitting an empty string gives one empty chip, so
    // the screen used to render a blank grid under "write these down" with a
    // checkbox saying you had.
    //
    // The phrase is generated once at signup and never stored anywhere, so an
    // empty one is not a loading state that resolves. It is gone. Saying that
    // is the only honest thing available, and a recovery email is the
    // remaining way back into the account.
    if (widget.phrase.trim().isEmpty) {
      return _PhraseUnavailable(
        onContinue: () => context.go('/onboarding/personalise'),
      );
    }

    final words = widget.phrase.split(RegExp(r'\s+'));
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Your Recovery Phrase')),
      body: OnboardingBackdrop(
        child: SafeArea(
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
                      child: Icon(
                        Icons.vpn_key_outlined,
                        color: scheme.primary,
                      ),
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
                  'This username account has no recovery email or phone unless you add one later. If you ever lose '
                  'your password, these 12 words are how you get back into your '
                  'sanctuary on any device. Save them somewhere safe — a password '
                  'manager, a notes app you trust, or even paper.',
                  style: TextStyle(
                    color: scheme.onSurface.withOpacity(0.7),
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 20),
                Expanded(
                  child: SingleChildScrollView(
                    child: Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: scheme.primary.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: scheme.primary.withOpacity(0.3),
                        ),
                      ),
                      child: Column(
                        children: [
                          _PhraseGrid(words: words, blurred: !_revealed),
                          const SizedBox(height: 14),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 10,
                            runSpacing: 8,
                            children: [
                              TextButton.icon(
                                onPressed: () =>
                                    setState(() => _revealed = !_revealed),
                                icon: Icon(
                                  _revealed
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                ),
                                label: Text(_revealed ? 'Hide' : 'Reveal'),
                              ),
                              OutlinedButton.icon(
                                onPressed: () {
                                  Clipboard.setData(
                                    ClipboardData(text: widget.phrase),
                                  );
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Recovery phrase copied'),
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.copy, size: 16),
                                label: const Text('Copy'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _acknowledged,
                  onChanged: (v) => setState(() => _acknowledged = v ?? false),
                  title: const Text(
                    "I have saved my recovery phrase somewhere safe.",
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
                const SizedBox(height: 6),
                ElevatedButton(
                  onPressed: _acknowledged
                      ? () => context.go('/onboarding/personalise')
                      : null,
                  child: const Text('Enter Venttly'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PhraseGrid extends StatelessWidget {
  const _PhraseGrid({required this.words, required this.blurred});
  final List<String> words;
  final bool blurred;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: words.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisExtent: 44,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemBuilder: (ctx, i) {
        final w = words[i];
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.primary.withOpacity(0.25)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${i + 1}',
                style: TextStyle(
                  fontSize: 10,
                  color: scheme.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                blurred ? '•••••' : w,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// What the phrase screen shows when there is no phrase to show.
class _PhraseUnavailable extends StatelessWidget {
  const _PhraseUnavailable({required this.onContinue});
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Your Recovery Phrase')),
      body: OnboardingBackdrop(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.key_off_rounded,
                  size: 44,
                  color: scheme.onSurface.withOpacity(0.5),
                ),
                const SizedBox(height: 16),
                Text(
                  'We could not show your recovery phrase',
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 10),
                Text(
                  'Your account was created and you are signed in. The phrase '
                  'is generated once and never stored, so it cannot be shown '
                  'again.\n\nAdd a recovery email on the next screen — it '
                  'becomes the way back in if you lose your password.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    height: 1.45,
                    color: scheme.onSurface.withOpacity(0.75),
                  ),
                ),
                const SizedBox(height: 28),
                ElevatedButton(
                  onPressed: onContinue,
                  child: const Text('Add a recovery email'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
