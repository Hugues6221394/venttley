import 'package:flutter/material.dart';

/// The moderation report reasons, matching the DB CHECK on `reports.reason`
/// (migration 0006/0007). Self-harm is first so the safety path is the most
/// visible option.
const List<(String, String)> kReportReasons = <(String, String)>[
  ('self_harm', 'Self-harm or suicide concern'),
  ('harassment', 'Harassment or bullying'),
  ('hate', 'Hate speech'),
  ('sexual_content', 'Sexual content'),
  ('violence', 'Violence or threats'),
  ('privacy', 'Doxxing or personal info'),
  ('spam', 'Spam or scam'),
  ('other', 'Something else'),
];

/// Shows a reason picker for reporting content. Returns the chosen reason key
/// (e.g. `harassment`), or null if the user dismissed it.
Future<String?> showReportReasonSheet(
  BuildContext context, {
  String title = 'Report message',
  String subtitle =
      'A moderator will review this. Reporting is anonymous — the sender is not told who flagged it.',
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(ctx).height * 0.82,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 18)),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  subtitle,
                  style: TextStyle(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.7),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: kReportReasons.length,
                  itemBuilder: (context, index) {
                    final reason = kReportReasons[index];
                    return ListTile(
                      title: Text(reason.$2),
                      onTap: () => Navigator.pop(ctx, reason.$1),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
