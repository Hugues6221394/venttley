import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../animation/core/motion_tokens.dart';
import '../../../core/providers.dart';
import '../../../core/vently_haptics.dart';
import '../../../domain/moderation/enforcement_notice.dart';
import '../../theme/colors.dart';

/// What was decided about you, and what you can do about it.
///
/// This screen exists because the product was telling members a decision could
/// be appealed and then offering nowhere to appeal it. `submit_appeal` has
/// been in the database and under test since 20261007090000; nothing in the
/// app called it, so every enforcement notice carrying `appealable: true` was
/// an unkept promise.
///
/// It shows only what the member was already told — the action, the policy
/// code, the moderator's own words, and the outcome of any appeal.
/// `moderation_cases` stays unreadable to members: it holds the reporter's
/// identity and the evidence snapshot, and the subject of a decision is not
/// owed those and must not be given them.
class AppealsScreen extends ConsumerWidget {
  const AppealsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myEnforcementHistoryProvider);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: Navigator.of(context).canPop()
            ? IconButton(
                tooltip: 'Back',
                onPressed: context.pop,
                icon: const Icon(Icons.arrow_back_rounded),
              )
            : null,
        titleSpacing: Navigator.of(context).canPop() ? 0 : 20,
        title: const Text(
          'Decisions & appeals',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
        ),
      ),
      body: RefreshIndicator(
        color: VentlyColors.berryMagenta,
        onRefresh: () async {
          ref.invalidate(myEnforcementHistoryProvider);
          await ref.read(myEnforcementHistoryProvider.future);
        },
        child: async.when(
          loading: () => const Center(
            child: Padding(
              padding: EdgeInsets.only(top: 80),
              child: CircularProgressIndicator(
                color: VentlyColors.berryMagenta,
              ),
            ),
          ),
          error: (_, __) => _Message(
            icon: Icons.cloud_off_rounded,
            title: 'Could not load your decisions',
            body: 'Check your connection and pull down to try again.',
          ),
          data: (notices) {
            if (notices.isEmpty) {
              return const _Message(
                icon: Icons.verified_user_rounded,
                title: 'Nothing on your record',
                body:
                    'No moderation decisions have been made about your '
                    'account. If that ever changes, it will appear here with '
                    'the reason and a way to appeal.',
              );
            }
            return ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 120),
              itemCount: notices.length,
              separatorBuilder: (_, __) => const SizedBox(height: 14),
              itemBuilder: (_, i) => _NoticeCard(notice: notices[i]),
            );
          },
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(32, 90, 32, 40),
      children: [
        Icon(icon, size: 42, color: VentlyColors.berryMagenta.withOpacity(0.7)),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        Text(
          body,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.5,
            color: dark ? Colors.white70 : Colors.black54,
          ),
        ),
      ],
    );
  }
}

class _NoticeCard extends ConsumerStatefulWidget {
  const _NoticeCard({required this.notice});
  final EnforcementNotice notice;

  @override
  ConsumerState<_NoticeCard> createState() => _NoticeCardState();
}

class _NoticeCardState extends ConsumerState<_NoticeCard> {
  bool _busy = false;

  Future<void> _appeal() async {
    final statement = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AppealSheet(notice: widget.notice),
    );
    if (statement == null || !mounted) return;

    final caseId = widget.notice.caseId;
    if (caseId == null) return;

    setState(() => _busy = true);
    try {
      await ref
          .read(repositoryProvider)
          .submitAppeal(caseId: caseId, statement: statement);
      ref.invalidate(myEnforcementHistoryProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Appeal submitted. Someone else will review it.'),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        // The database's own message, unchanged. It says which rule stopped
        // this — already appealed, out of time, not your decision — and a
        // generic "could not submit" would hide the one useful fact.
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_clean(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _withdraw() async {
    final id = widget.notice.appealId;
    if (id == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(repositoryProvider).withdrawAppeal(id);
      ref.invalidate(myEnforcementHistoryProvider);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_clean(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _clean(Object error) {
    final raw = error.toString();
    // Postgres prefixes its own message; the sentence after it is the part
    // written for a person to read.
    final match = RegExp(r'(?:message: )?([^:]*:\s*)?(.+)$').firstMatch(raw);
    final text = match?.group(2) ?? raw;
    return text.length > 160 ? '${text.substring(0, 157)}…' : text;
  }

  @override
  Widget build(BuildContext context) {
    final notice = widget.notice;
    final dark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedContainer(
      duration: MotionTokens.feedback.duration,
      curve: MotionTokens.feedback.curve,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: dark ? Colors.white10 : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: dark ? Colors.white12 : VentlyColors.softMauve,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(dark ? 0.22 : 0.04),
            blurRadius: 18,
            spreadRadius: -8,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  notice.actionLabel,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              _StatusChip(status: notice.appealStatus),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                _date(notice.decidedAt),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: dark ? Colors.white54 : Colors.black45,
                ),
              ),
              if (notice.policyCode != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: VentlyColors.roseTint,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    notice.policyCode!,
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      color: VentlyColors.roseDeep,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if ((notice.reason ?? '').isNotEmpty) ...[
            const SizedBox(height: 12),
            _Quote(label: 'Reason given', text: notice.reason!),
          ],
          if ((notice.appealStatement ?? '').isNotEmpty) ...[
            const SizedBox(height: 10),
            _Quote(label: 'Your appeal', text: notice.appealStatement!),
          ],
          if ((notice.reviewNote ?? '').isNotEmpty) ...[
            const SizedBox(height: 10),
            _Quote(label: 'Review outcome', text: notice.reviewNote!),
          ],
          if (notice.canAppeal || notice.appealStatus == AppealStatus.open) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                if (notice.canAppeal)
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy ? null : _appeal,
                      style: FilledButton.styleFrom(
                        backgroundColor: VentlyColors.berryMagenta,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Appeal this decision',
                              style: TextStyle(fontWeight: FontWeight.w800),
                            ),
                    ),
                  ),
                if (notice.appealStatus == AppealStatus.open)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : _withdraw,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text(
                        'Withdraw appeal',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
              ],
            ),
            if (notice.appealStatus == AppealStatus.open)
              _Footnote(
                'Withdrawing does not use up your appeal — you can file '
                'again while the decision is still within thirty days.',
              ),
          ],
          // Said plainly rather than by an absent button. Someone looking for
          // a way to contest a decision deserves to know it has closed, not to
          // be left hunting for a control that is not there.
          if (notice.appealBlockedReason != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _Footnote(notice.appealBlockedReason!),
            ),
        ],
      ),
    );
  }

  static String _date(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }
}

class _Footnote extends StatelessWidget {
  const _Footnote(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          height: 1.4,
          color: dark ? Colors.white54 : Colors.black45,
        ),
      ),
    );
  }
}

class _Quote extends StatelessWidget {
  const _Quote({required this.label, required this.text});
  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
      decoration: BoxDecoration(
        color: dark ? Colors.white10 : const Color(0xFFFBF7F9),
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(color: VentlyColors.berryMagenta.withOpacity(0.45), width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 9,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w900,
              color: dark ? Colors.white54 : Colors.black38,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: dark ? Colors.white : VentlyColors.deepBurgundy,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final AppealStatus status;

  @override
  Widget build(BuildContext context) {
    if (status == AppealStatus.none) return const SizedBox.shrink();
    final (bg, fg) = switch (status) {
      AppealStatus.open => (const Color(0xFFFFF3E0), const Color(0xFF8A5300)),
      AppealStatus.overturned => (
        const Color(0xFFE8F6EC),
        const Color(0xFF1B6B33),
      ),
      AppealStatus.upheld => (VentlyColors.roseTint, VentlyColors.roseDeep),
      _ => (const Color(0xFFF1F1F3), const Color(0xFF55555E)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w900,
          color: fg,
        ),
      ),
    );
  }
}

/// Composer for an appeal.
///
/// The statement is required and has a floor, because a one-word appeal wastes
/// the reviewer's time and the member's single attempt. The database enforces
/// its own rules underneath; this only stops the obviously-empty case before
/// it costs anyone anything.
class _AppealSheet extends StatefulWidget {
  const _AppealSheet({required this.notice});
  final EnforcementNotice notice;

  @override
  State<_AppealSheet> createState() => _AppealSheetState();
}

class _AppealSheetState extends State<_AppealSheet> {
  final _controller = TextEditingController();
  static const _min = 20;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final length = _controller.text.trim().length;
    final ready = length >= _min;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF1A1016) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: dark ? Colors.white24 : VentlyColors.softMauve,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Appeal: ${widget.notice.actionLabel}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            Text(
              'Someone other than the moderator who made this decision will '
              'read it. Say what you think they got wrong.',
              style: TextStyle(
                fontSize: 13,
                height: 1.45,
                color: dark ? Colors.white70 : Colors.black54,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: 4,
              maxLines: 8,
              maxLength: 1000,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'What should the reviewer know?',
                filled: true,
                fillColor: dark ? Colors.white10 : const Color(0xFFFBF7F9),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: ready
                    ? () {
                        VentlyHaptics.send();
                        Navigator.of(context).pop(_controller.text.trim());
                      }
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: VentlyColors.berryMagenta,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15),
                  ),
                ),
                child: Text(
                  ready
                      ? 'Submit appeal'
                      : 'Add ${_min - length} more characters',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
