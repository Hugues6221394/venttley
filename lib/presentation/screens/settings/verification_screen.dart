import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/user_friendly_errors.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/premium_motion.dart';
import '../../widgets/vently_error_state.dart';
import '../../widgets/verified_badge.dart';

/// Settings → Verification.
///
/// Before this, applying was only reachable from a small pill on the profile
/// overview, and once submitted the only thing the app could say was
/// "pending" — forever, with no date, no explanation, and no way to answer a
/// reviewer's question.
///
/// The state, the dates and the reviewer's stated reason all come from
/// `my_verification_state`, including whether reapplying is currently
/// allowed. Nothing here decides eligibility on its own: a client that made
/// its own judgement would offer a button the RPC then refuses.
class VerificationScreen extends ConsumerWidget {
  const VerificationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myVerificationStateProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Verification')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => VentlyErrorState(
          error: e,
          title: 'Verification unavailable',
          onRetry: () => ref.invalidate(myVerificationStateProvider),
        ),
        data: (state) => RefreshIndicator(
          color: VentlyColors.berryMagenta,
          onRefresh: () async => ref.invalidate(myVerificationStateProvider),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
            children: [
              _StatusCard(state: state),
              const SizedBox(height: 18),
              if (state.needsResponse)
                _RespondCard(state: state)
              else if (state.canApply || state.hasNeverApplied)
                const _ApplyCard()
              else if (state.status == 'unknown')
                const _Unknown(),
              const SizedBox(height: 22),
              const _WhatItMeans(),
            ],
          ),
        ),
      ),
    );
  }
}

/// The current standing, stated plainly with its dates.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.state});
  final VerificationState state;

  @override
  Widget build(BuildContext context) {
    final (icon, title, body, tone) = _describe(state);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark
            ? tone.withOpacity(0.14)
            : tone.withOpacity(0.07),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tone.withOpacity(0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: tone),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w900,
                    color: context.ink,
                  ),
                ),
              ),
              if (state.isVerified) const VerifiedBadge(size: 18),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.5,
              color: context.ink.withOpacity(0.75),
            ),
          ),
          // The reviewer's reason, when there is one. A decision the person
          // cannot see the reasoning for is not one they can act on.
          if ((state.decisionReason ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: context.ink.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'What the reviewer said',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.2,
                      color: context.ink.withOpacity(0.55),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    state.decisionReason!.trim(),
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.45,
                      color: context.ink.withOpacity(0.85),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (state.appliedAt != null || state.reviewedAt != null) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                if (state.appliedAt != null)
                  _MetaLine(
                    label: 'Applied',
                    value: _date(state.appliedAt!),
                  ),
                if (state.reviewedAt != null)
                  _MetaLine(
                    label: 'Reviewed',
                    value: _date(state.reviewedAt!),
                  ),
                if (state.category != null)
                  _MetaLine(
                    label: 'As',
                    value: VerificationCategories.labelFor(state.category),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _date(DateTime d) => '${d.day}/${d.month}/${d.year}';

  /// One place that turns a state into words, so the screen cannot describe
  /// the same state two different ways.
  static (IconData, String, String, Color) _describe(VerificationState s) {
    switch (s.status) {
      case 'approved':
        return (
          Icons.verified_rounded,
          'You are verified',
          'The check appears next to your name across Venttly.',
          VentlyColors.successGreen,
        );
      case 'pending':
        return (
          Icons.hourglass_top_rounded,
          'Application in the queue',
          'Nobody has picked it up yet. We work through applications in the '
              'order they arrived, so this can take a while.',
          VentlyColors.warningAmber,
        );
      case 'under_review':
        return (
          Icons.rate_review_rounded,
          'Someone is reviewing it',
          'A reviewer has your application open. You do not need to do '
              'anything.',
          VentlyColors.berryMagenta,
        );
      case 'more_info':
        return (
          Icons.help_outline_rounded,
          'We need something from you',
          'A reviewer asked a question. Your application waits until you '
              'answer it.',
          VentlyColors.warningAmber,
        );
      case 'rejected':
        return (
          Icons.cancel_outlined,
          'Not approved',
          'This application was declined. You can apply again once the '
              'waiting period is over.',
          VentlyColors.dangerRed,
        );
      case 'revoked':
        return (
          Icons.remove_moderator_outlined,
          'Verification removed',
          'A reviewer removed the check from this account.',
          VentlyColors.dangerRed,
        );
      case 'not_applied':
        return (
          Icons.verified_outlined,
          'Not verified',
          'The verified check tells other members that this account is who it '
              'says it is. It is earned, not bought.',
          VentlyColors.berryMagenta,
        );
      default:
        return (
          Icons.cloud_off_rounded,
          'We could not check your status',
          'This needs a connection. Pull down to try again.',
          VentlyColors.softMauve,
        );
    }
  }
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label ',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: context.ink.withOpacity(0.5),
            ),
          ),
          TextSpan(
            text: value,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w900,
              color: context.ink.withOpacity(0.78),
            ),
          ),
        ],
      ),
    );
  }
}

/// The reviewer's question, and a box to answer it.
class _RespondCard extends ConsumerStatefulWidget {
  const _RespondCard({required this.state});
  final VerificationState state;

  @override
  ConsumerState<_RespondCard> createState() => _RespondCardState();
}

class _RespondCardState extends ConsumerState<_RespondCard> {
  final _reply = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _reply.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Write your answer first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(repositoryProvider).respondToVerificationRequest(text);
      ref.invalidate(myVerificationStateProvider);
      ref.invalidate(myVerificationStatusProvider);
      if (!mounted) return;
      // Cleared on success as well as on failure. The refreshed state
      // normally replaces this card entirely, but if the refetch still
      // reports more_info the card stays — and a spinner that is never
      // reset spins for as long as the screen is open.
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sent. Your application is back in the queue.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = UserFriendlyErrors.message(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final question = (widget.state.infoRequest ?? '').trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (question.isNotEmpty) ...[
          Text(
            'What we asked',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w900,
              color: context.ink,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: VentlyColors.berryMagenta.withOpacity(0.07),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              question,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.45,
                color: context.ink.withOpacity(0.85),
              ),
            ),
          ),
          const SizedBox(height: 14),
        ],
        TextField(
          controller: _reply,
          maxLines: 5,
          maxLength: 1000,
          decoration: InputDecoration(
            hintText: 'Your answer',
            filled: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 4),
          Text(
            _error!,
            style: const TextStyle(
              color: VentlyColors.dangerRed,
              fontWeight: FontWeight.w600,
              fontSize: 12.5,
            ),
          ),
        ],
        const SizedBox(height: 10),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: VentlyColors.berryMagenta,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          onPressed: _busy ? null : _send,
          child: _busy
              ? const SizedBox(
                  height: 17,
                  width: 17,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Send answer'),
        ),
      ],
    );
  }
}

/// The entry point into the application form.
class _ApplyCard extends ConsumerWidget {
  const _ApplyCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Pressable(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const VerificationApplyScreen(),
        ),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        decoration: BoxDecoration(
          color: VentlyColors.berryMagenta,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Row(
          children: [
            Icon(Icons.verified_outlined, color: Colors.white, size: 19),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Apply for verification',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                ),
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: Colors.white),
          ],
        ),
      ),
    );
  }
}

/// Shown when the state could not be fetched. Deliberately offers no Apply
/// button: an application submitted against an unknown state is how somebody
/// ends up with two open requests, or believes they applied when they did not.
class _Unknown extends StatelessWidget {
  const _Unknown();

  @override
  Widget build(BuildContext context) {
    return Text(
      'Pull down to try again once you have a connection.',
      style: TextStyle(fontSize: 13, color: context.ink.withOpacity(0.6)),
    );
  }
}

class _WhatItMeans extends StatelessWidget {
  const _WhatItMeans();

  @override
  Widget build(BuildContext context) {
    const points = [
      (
        Icons.shield_outlined,
        'It confirms identity, not merit',
        'The check means we believe this account is who it says it is. It is '
            'not a badge of quality and it grants no extra reach.',
      ),
      (
        Icons.lock_outline_rounded,
        'What you send stays private',
        'Anything you submit as evidence is visible only to you and the '
            'reviewers. It never appears on your profile, and Keepers cannot '
            'see it.',
      ),
      (
        Icons.schedule_rounded,
        'It takes as long as it takes',
        'Applications are read in the order they arrive by a small team.',
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'About verification',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w900,
            color: context.ink,
          ),
        ),
        const SizedBox(height: 12),
        for (final (icon, title, body) in points)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 11),
                  child: Icon(
                    icon,
                    size: 17,
                    color: VentlyColors.berryMagenta.withOpacity(0.8),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: context.ink,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        body,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.45,
                          color: context.ink.withOpacity(0.62),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The application form.
///
/// A category, a case in the applicant's own words, public links, and optional
/// private evidence. The four fields exist because a reviewer deciding on one
/// free-text paragraph has nothing to check against — which is what the
/// original single-note sheet gave them.
class VerificationApplyScreen extends ConsumerStatefulWidget {
  const VerificationApplyScreen({super.key});

  @override
  ConsumerState<VerificationApplyScreen> createState() =>
      _VerificationApplyScreenState();
}

class _VerificationApplyScreenState
    extends ConsumerState<VerificationApplyScreen> {
  String? _category;
  final _note = TextEditingController();
  final _links = TextEditingController();
  final _evidence = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    _links.dispose();
    _evidence.dispose();
    super.dispose();
  }

  /// One link per line. The server enforces the real rules — at most six,
  /// http(s) only, each under 300 characters — and rejects anything else, so
  /// this only has to split and tidy.
  List<String> get _linkList => _links.text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  Future<void> _submit() async {
    if (_category == null) {
      setState(() => _error = 'Pick the category that fits best.');
      return;
    }
    if (_note.text.trim().length < 20) {
      setState(
        () => _error =
            'Tell us a little more — at least a sentence or two about why.',
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
          .requestVerificationDetailed(
            note: _note.text.trim(),
            category: _category,
            links: _linkList,
            evidence: [
              if (_evidence.text.trim().isNotEmpty)
                VerificationEvidenceItem(
                  kind: 'other',
                  detail: _evidence.text.trim(),
                ),
            ],
          );
      ref.invalidate(myVerificationStateProvider);
      ref.invalidate(myVerificationStatusProvider);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Application received. We will let you know.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _friendly(e);
      });
    }
  }

  /// The server's error tokens, turned into something a person can act on.
  /// Falling through to UserFriendlyErrors would show `already_pending`.
  static String _friendly(Object e) {
    final raw = e.toString();
    if (raw.contains('already_pending')) {
      return 'You already have an application in the queue.';
    }
    if (raw.contains('respond_to_the_open_request')) {
      return 'A reviewer asked you a question — answer that instead.';
    }
    if (raw.contains('too_soon_to_reapply')) {
      return 'You can apply again 30 days after a decision.';
    }
    if (raw.contains('invalid_link')) {
      return 'Each link needs to start with http:// or https://.';
    }
    if (raw.contains('already verified')) {
      return 'This account is already verified.';
    }
    return UserFriendlyErrors.message(e);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Apply for verification')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          Text(
            'Which of these fits best?',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w900,
              color: context.ink,
            ),
          ),
          const SizedBox(height: 10),
          for (final entry in VerificationCategories.all)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _CategoryTile(
                label: entry.label,
                blurb: entry.blurb,
                selected: _category == entry.key,
                onTap: () => setState(() => _category = entry.key),
              ),
            ),
          const SizedBox(height: 18),
          _FieldLabel(
            'Why should this account be verified?',
            hint: 'The reviewer reads this first.',
          ),
          TextField(
            controller: _note,
            maxLines: 6,
            maxLength: 1200,
            decoration: _boxed('Your case, in your own words'),
          ),
          const SizedBox(height: 12),
          _FieldLabel(
            'Public links',
            hint: 'One per line, up to six. Anywhere you already publish '
                'under this name.',
          ),
          TextField(
            controller: _links,
            maxLines: 4,
            decoration: _boxed('https://…'),
          ),
          const SizedBox(height: 12),
          _FieldLabel(
            'Anything private that supports it',
            hint: 'Optional. Only you and the reviewers can see this — it '
                'never appears on your profile.',
          ),
          TextField(
            controller: _evidence,
            maxLines: 4,
            maxLength: 2000,
            decoration: _boxed('A licence number, an employer, a reference…'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
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
          ],
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: VentlyColors.berryMagenta,
              padding: const EdgeInsets.symmetric(vertical: 15),
            ),
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    height: 17,
                    width: 17,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Submit application'),
          ),
        ],
      ),
    );
  }

  InputDecoration _boxed(String hint) => InputDecoration(
    hintText: hint,
    filled: true,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    ),
  );
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label, {required this.hint});
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w900,
              color: context.ink,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            hint,
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: context.ink.withOpacity(0.58),
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.label,
    required this.blurb,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String blurb;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          decoration: BoxDecoration(
            color: selected
                ? VentlyColors.berryMagenta.withOpacity(0.09)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? VentlyColors.berryMagenta.withOpacity(0.5)
                  : context.ink.withOpacity(0.12),
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 19,
                color: selected
                    ? VentlyColors.berryMagenta
                    : context.ink.withOpacity(0.35),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: context.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      blurb,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        color: context.ink.withOpacity(0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
