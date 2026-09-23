import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/providers.dart';
import '../../../core/user_friendly_errors.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../theme/glass_tokens.dart';

/// Report a bug, or ask for something.
///
/// There has been no in-app route for either. Somebody who hits a bug could
/// open a support case — a moderation surface, read by moderators, routing to
/// nothing that fixes software — or say nothing. Most say nothing, so the
/// reports that matter most, from the people who hit them first, never
/// arrived at all.
///
/// The version, platform and device are collected without asking. A bug report
/// you cannot reproduce is barely a bug report, and nobody types their build
/// number correctly.
class FeedbackScreen extends ConsumerStatefulWidget {
  const FeedbackScreen({super.key});

  @override
  ConsumerState<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends ConsumerState<FeedbackScreen> {
  String _kind = 'bug';
  final _title = TextEditingController();
  final _detail = TextEditingController();
  final _screen = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _detail.dispose();
    _screen.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final title = _title.text.trim();
    final detail = _detail.text.trim();
    if (title.length < 3) {
      setState(() => _error = 'Give it a short title — a few words is plenty.');
      return;
    }
    if (detail.length < 10) {
      setState(
        () => _error = _kind == 'bug'
            ? 'What did you do, and what happened instead?'
            : 'Tell us a little about what you would like.',
      );
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      String? version;
      try {
        final info = await PackageInfo.fromPlatform();
        version = '${info.version}+${info.buildNumber}';
      } catch (_) {
        // Not worth failing a bug report over.
      }

      await ref
          .read(repositoryProvider)
          .submitFeedback(
            kind: _kind,
            title: title,
            detail: detail,
            screen: _screen.text.trim().isEmpty ? null : _screen.text.trim(),
            appVersion: version,
            platform: Platform.operatingSystem,
            device: Platform.operatingSystemVersion,
          );

      ref.invalidate(myFeedbackProvider);
      if (!mounted) return;
      _title.clear();
      _detail.clear();
      _screen.clear();
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Thank you — that is in front of the team now.'),
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

  static String _friendly(Object e) {
    final raw = e.toString();
    if (raw.contains('rate_limited')) {
      return 'That is a lot of reports in one hour. Try again a bit later.';
    }
    return UserFriendlyErrors.message(e);
  }

  @override
  Widget build(BuildContext context) {
    final mine = ref.watch(myFeedbackProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Report a bug or suggest something')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 40),
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'bug',
                icon: Icon(Icons.bug_report_outlined, size: 18),
                label: Text('Something is broken'),
              ),
              ButtonSegment(
                value: 'suggestion',
                icon: Icon(Icons.lightbulb_outline_rounded, size: 18),
                label: Text('An idea'),
              ),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: 18),
          const _Label('Title'),
          TextField(
            controller: _title,
            maxLength: 120,
            textCapitalization: TextCapitalization.sentences,
            decoration: _boxed(
              _kind == 'bug'
                  ? 'Tab bar stays black in light mode'
                  : 'Let me pin a vent to my profile',
            ),
          ),
          const SizedBox(height: 4),
          _Label(_kind == 'bug' ? 'What happened?' : 'What would you like?'),
          TextField(
            controller: _detail,
            maxLines: 6,
            maxLength: 4000,
            textCapitalization: TextCapitalization.sentences,
            decoration: _boxed(
              _kind == 'bug'
                  ? 'What you did, what you expected, what happened instead.'
                  : 'What it would let you do, and why it would help.',
            ),
          ),
          const SizedBox(height: 4),
          const _Label('Where in the app? (optional)'),
          TextField(
            controller: _screen,
            maxLength: 120,
            decoration: _boxed('Profile, Keeper Studio, a chat…'),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 4),
            child: Text(
              'Your app version and device are attached automatically. Nothing '
              'else about you is sent, and nothing you write here appears on '
              'your profile.',
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: GlassTokens.onCardMuted(context),
              ),
            ),
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
          const SizedBox(height: 14),
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
                : const Text('Send it'),
          ),
          const SizedBox(height: 26),
          Text(
            'What you have sent',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 15,
              color: GlassTokens.onCard(context),
            ),
          ),
          const SizedBox(height: 8),
          mine.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (_, __) => Text(
              'Could not load your reports.',
              style: TextStyle(color: GlassTokens.onCardMuted(context)),
            ),
            data: (reports) => reports.isEmpty
                ? Text(
                    'Nothing yet.',
                    style: TextStyle(color: GlassTokens.onCardMuted(context)),
                  )
                : Column(
                    children: [
                      for (final r in reports) _ReportTile(report: r),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  InputDecoration _boxed(String hint) => InputDecoration(
    hintText: hint,
    counterText: '',
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
  );
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6, top: 8),
    child: Text(
      text,
      style: TextStyle(
        fontWeight: FontWeight.w800,
        fontSize: 13,
        color: GlassTokens.onCard(context),
      ),
    ),
  );
}

/// What the reporter sees afterwards.
///
/// Status alone would be a word with no consequence attached, so the staff
/// note is shown verbatim when there is one — it is the only reply anybody
/// gets.
class _ReportTile extends StatelessWidget {
  const _ReportTile({required this.report});
  final FeedbackReport report;

  static const _label = <String, String>{
    'new': 'Waiting',
    'triaged': 'Read by the team',
    'planned': 'Planned',
    'fixed': 'Fixed',
    'declined': 'Not planned',
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: GlassTokens.card(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: GlassTokens.cardEdge(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                report.isBug
                    ? Icons.bug_report_outlined
                    : Icons.lightbulb_outline_rounded,
                size: 16,
                color: VentlyColors.berryMagenta,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  report.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: GlassTokens.onCard(context),
                  ),
                ),
              ),
              Text(
                _label[report.status] ?? report.status,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w900,
                  color: VentlyColors.berryMagenta,
                ),
              ),
            ],
          ),
          if (report.staffNote != null) ...[
            const SizedBox(height: 8),
            Text(
              report.staffNote!,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.35,
                color: GlassTokens.onCardMuted(context),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
