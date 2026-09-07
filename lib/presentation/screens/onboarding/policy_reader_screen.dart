import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/policy_body.dart';

/// Full-screen reader for one policy document.
///
/// Reachable from the consent step, from Settings, and by deep link, which is
/// why it takes a [kind] and resolves the document itself rather than being
/// handed one: a link to the Terms has to work for somebody who has not
/// loaded them yet, including before they have an account.
///
/// Separate routes for Terms and Privacy, not one screen with two tabs. They
/// are two agreements and the consent step links to them individually — a
/// reader that could silently show the other document would make "I read the
/// Privacy Policy" unverifiable.
class PolicyReaderScreen extends ConsumerWidget {
  const PolicyReaderScreen({super.key, required this.kind});

  /// `terms` or `privacy`.
  final String kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(currentPoliciesProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(kind == 'terms' ? 'Terms & Conditions' : 'Privacy Policy'),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _Unavailable(
          onRetry: () => ref.invalidate(currentPoliciesProvider),
        ),
        data: (bundle) {
          final doc = kind == 'terms' ? bundle.terms : bundle.privacy;
          if (doc == null) {
            return _Unavailable(
              onRetry: () => ref.invalidate(currentPoliciesProvider),
            );
          }
          return _Document(doc: doc);
        },
      ),
    );
  }
}

class _Document extends StatelessWidget {
  const _Document({required this.doc});
  final PolicyDocument doc;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scrollbar(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 48),
          children: [
            // The measure is capped rather than filling a tablet edge to
            // edge. Long-form text at 900pt wide is measurably harder to
            // read, and this is a document people are asked to actually read.
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _VersionLine(doc: doc),
                    const SizedBox(height: 18),
                    PolicyBody(markdown: doc.bodyMarkdown),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The version and effective date, stated plainly.
///
/// Present because "which version did I agree to" is the question the whole
/// consent record exists to answer, and a reader that does not show its own
/// version cannot be checked against that record.
class _VersionLine extends StatelessWidget {
  const _VersionLine({required this.doc});
  final PolicyDocument doc;

  @override
  Widget build(BuildContext context) {
    final at = doc.effectiveAt;
    final parts = <String>[
      'Version ${doc.version}',
      if (at != null) 'in force since ${at.day}/${at.month}/${at.year}',
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: VentlyColors.berryMagenta.withOpacity(0.07),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        parts.join(' · '),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: VentlyColors.berryMagenta,
        ),
      ),
    );
  }
}

/// Shown when the document could not be loaded.
///
/// Says the document is missing rather than implying the person has agreed to
/// something. There is no "continue anyway" here on purpose — a policy screen
/// with a bypass is not a policy screen.
class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.wifi_off_rounded,
              size: 40,
              color: context.ink.withOpacity(0.4),
            ),
            const SizedBox(height: 14),
            Text(
              'We could not load this document',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: context.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Check your connection and try again. You can also read it at '
              'venttly.app.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.ink.withOpacity(0.65)),
            ),
            const SizedBox(height: 18),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
