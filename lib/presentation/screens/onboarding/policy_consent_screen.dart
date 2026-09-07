import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../core/user_friendly_errors.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';

/// Consent for an account that already exists.
///
/// Two paths lead here, and they are the same screen on purpose:
///
///  * the acceptance write failed after signup, so the account exists with
///    nothing on record;
///  * a policy version changed materially, so everybody owes a fresh
///    agreement.
///
/// The server decides which documents are outstanding, so a new version
/// reaches every account with no client release and no per-case branching
/// here.
///
/// There is no skip. A "later" button on a consent wall is how consent stops
/// meaning anything — and because the gate fails open when the answer is
/// unknown, anybody who genuinely cannot reach the server is not sent here in
/// the first place.
class PolicyConsentScreen extends ConsumerStatefulWidget {
  const PolicyConsentScreen({super.key});

  @override
  ConsumerState<PolicyConsentScreen> createState() =>
      _PolicyConsentScreenState();
}

class _PolicyConsentScreenState extends ConsumerState<PolicyConsentScreen> {
  final Set<String> _agreed = <String>{};
  bool _busy = false;
  String? _error;

  Future<void> _submit(PolicyBundle outstanding, PolicyBundle current) async {
    // Accept the current pair, which is what the RPC records. The versions
    // come from `current_policies`, not from the outstanding list, because a
    // document already accepted is absent from the outstanding list yet still
    // has to be named in the call.
    final terms = current.terms;
    final privacy = current.privacy;
    if (terms == null || privacy == null) {
      setState(
        () => _error =
            'We could not load the current documents. Check your connection '
            'and try again.',
      );
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(repositoryProvider)
          .acceptPolicies(
            termsVersion: terms.version,
            privacyVersion: privacy.version,
          );
      ref.invalidate(outstandingPoliciesProvider);
      // Wait for the refreshed answer before navigating. Going straight to
      // /feed would race the router's own gate, which reads the same provider
      // and would send us back here with a stale value.
      await ref.read(outstandingPoliciesProvider.future);
      if (!mounted) return;
      context.go('/feed');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // A stale version means the text moved again while this screen was
        // open. Re-reading is the honest recovery, so the documents are
        // refetched rather than the old versions retried.
        _error = e.toString().contains('policy_version_stale')
            ? 'These documents were just updated. Please read the new version '
                  'and agree again.'
            : UserFriendlyErrors.message(e);
      });
      ref.invalidate(currentPoliciesProvider);
      ref.invalidate(outstandingPoliciesProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final outstandingAsync = ref.watch(outstandingPoliciesProvider);
    final currentAsync = ref.watch(currentPoliciesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Before you continue'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: outstandingAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => _Retry(
            message: 'We could not check which documents need your agreement.',
            onRetry: () => ref.invalidate(outstandingPoliciesProvider),
          ),
          data: (outstanding) {
            final current = currentAsync.valueOrNull;
            if (current == null || !current.isComplete) {
              return _Retry(
                message: 'We could not load the current documents.',
                onRetry: () => ref.invalidate(currentPoliciesProvider),
              );
            }

            final docs = <PolicyDocument>[
              if (outstanding.terms != null) outstanding.terms!,
              if (outstanding.privacy != null) outstanding.privacy!,
            ];

            // Empty is a real state, and briefly the common one: accepting
            // invalidates the provider, so this rebuilds with nothing
            // outstanding a frame or two before the redirect to /feed lands.
            // `docs.first` here used to throw `Bad state: No element` — the
            // screen crashed at the exact moment consent succeeded.
            if (docs.isEmpty) {
              return const Center(child: CircularProgressIndicator());
            }

            final allAgreed = docs.every((d) => _agreed.contains(d.kind));

            return ListView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 36),
              children: [
                Text(
                  docs.length > 1
                      ? 'Our Terms and Privacy Policy have been updated'
                      : 'Our ${docs.first.isTerms ? 'Terms' : 'Privacy Policy'} '
                            'has been updated',
                  style: TextStyle(
                    fontSize: 21,
                    height: 1.25,
                    fontWeight: FontWeight.w900,
                    color: context.ink,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Please read the change and agree to carry on using Venttly. '
                  'Your account and everything in it is untouched.',
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: context.ink.withOpacity(0.7),
                  ),
                ),
                const SizedBox(height: 20),
                for (final doc in docs) ...[
                  _OutstandingDoc(
                    doc: doc,
                    agreed: _agreed.contains(doc.kind),
                    onChanged: (v) => setState(() {
                      if (v) {
                        _agreed.add(doc.kind);
                      } else {
                        _agreed.remove(doc.kind);
                      }
                    }),
                  ),
                  const SizedBox(height: 12),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: VentlyColors.dangerRed.withOpacity(0.09),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        color: VentlyColors.dangerRed,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: VentlyColors.berryMagenta,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                  ),
                  onPressed: _busy
                      ? null
                      : () {
                          if (!allAgreed) {
                            setState(
                              () => _error =
                                  'Please tick each document to continue.',
                            );
                            return;
                          }
                          _submit(outstanding, current);
                        },
                  child: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Text('Agree and continue'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _OutstandingDoc extends StatefulWidget {
  const _OutstandingDoc({
    required this.doc,
    required this.agreed,
    required this.onChanged,
  });

  final PolicyDocument doc;
  final bool agreed;
  final ValueChanged<bool> onChanged;

  @override
  State<_OutstandingDoc> createState() => _OutstandingDocState();
}

class _OutstandingDocState extends State<_OutstandingDoc> {
  late final TapGestureRecognizer _open;

  @override
  void initState() {
    super.initState();
    _open = TapGestureRecognizer()
      ..onTap = () => context.push(
        widget.doc.isTerms ? '/legal/terms' : '/legal/privacy',
      );
  }

  @override
  void dispose() {
    _open.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.doc;
    final label = doc.isTerms ? 'Terms & Conditions' : 'Privacy Policy';
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$label · version ${doc.version}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: context.ink,
              ),
            ),
            // What changed, when the document says. A consent wall that does
            // not state the change is a click-through with extra steps.
            if ((doc.summary ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                doc.summary!.trim(),
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: context.ink.withOpacity(0.72),
                ),
              ),
            ],
            const SizedBox(height: 4),
            Semantics(
              checked: widget.agreed,
              label: doc.isTerms
                  ? 'I agree to the Venttly Terms and Conditions'
                  : 'I acknowledge the Venttly Privacy Policy',
              child: InkWell(
                onTap: () => widget.onChanged(!widget.agreed),
                borderRadius: BorderRadius.circular(10),
                child: Row(
                  children: [
                    ExcludeSemantics(
                      child: Checkbox(
                        value: widget.agreed,
                        onChanged: (v) => widget.onChanged(v ?? false),
                        activeColor: VentlyColors.berryMagenta,
                      ),
                    ),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: doc.isTerms
                                  ? 'I agree to the '
                                  : 'I acknowledge the ',
                            ),
                            TextSpan(
                              text: label,
                              style: const TextStyle(
                                color: VentlyColors.berryMagenta,
                                fontWeight: FontWeight.w800,
                                decoration: TextDecoration.underline,
                                decorationColor: VentlyColors.berryMagenta,
                              ),
                              recognizer: _open,
                            ),
                          ],
                        ),
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.4,
                          color: context.ink.withOpacity(0.85),
                        ),
                      ),
                    ),
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

class _Retry extends StatelessWidget {
  const _Retry({required this.message, required this.onRetry});
  final String message;
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
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: context.ink,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
