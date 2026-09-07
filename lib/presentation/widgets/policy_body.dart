import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// Renders a policy document's Markdown body.
///
/// Deliberately not `flutter_markdown`. This renders exactly the subset the
/// policy documents are written in — `#`/`##` headings, paragraphs, `-`
/// bullets, `**bold**`, `_italic_` and `---` rules — and the documents are
/// authored in this repository, so the subset is a contract rather than a
/// guess about arbitrary input. Adding a Markdown engine and its transitive
/// dependencies to lay out six headings and a bullet list would not pay for
/// itself, and the project's standing rule is not to add one that does not.
///
/// If a future policy needs a table or an image, that is the moment to take
/// the dependency — not before.
///
/// Typography is set for reading rather than for scanning: 15pt at 1.55 line
/// height, generous paragraph spacing, and a measure that stays comfortable
/// because the caller constrains the width. This is the screen where somebody
/// decides whether to trust the platform with what they are about to write.
class PolicyBody extends StatelessWidget {
  const PolicyBody({super.key, required this.markdown});

  final String markdown;

  @override
  Widget build(BuildContext context) {
    final blocks = _parse(markdown);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final block in blocks) _BlockView(block: block),
      ],
    );
  }

  /// Line-oriented, because the source is line-oriented. Consecutive
  /// non-blank, non-special lines join into one paragraph so a hard-wrapped
  /// source paragraph reflows to the reader's width instead of breaking at
  /// the author's 78 columns.
  static List<_Block> _parse(String source) {
    final out = <_Block>[];
    final paragraph = <String>[];

    void flushParagraph() {
      if (paragraph.isEmpty) return;
      out.add(_Block(_BlockKind.paragraph, paragraph.join(' ')));
      paragraph.clear();
    }

    for (final raw in source.split('\n')) {
      final line = raw.trimRight();
      final trimmed = line.trim();

      if (trimmed.isEmpty) {
        flushParagraph();
        continue;
      }
      if (trimmed == '---' || trimmed == '***') {
        flushParagraph();
        out.add(const _Block(_BlockKind.rule, ''));
        continue;
      }
      if (trimmed.startsWith('### ')) {
        flushParagraph();
        out.add(_Block(_BlockKind.h3, trimmed.substring(4).trim()));
        continue;
      }
      if (trimmed.startsWith('## ')) {
        flushParagraph();
        out.add(_Block(_BlockKind.h2, trimmed.substring(3).trim()));
        continue;
      }
      if (trimmed.startsWith('# ')) {
        flushParagraph();
        out.add(_Block(_BlockKind.h1, trimmed.substring(2).trim()));
        continue;
      }
      if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
        flushParagraph();
        out.add(_Block(_BlockKind.bullet, trimmed.substring(2).trim()));
        continue;
      }
      // A bullet's continuation line is indented in the source. Fold it into
      // the bullet above rather than starting a paragraph, which would
      // un-indent the rest of the item.
      if (raw.startsWith('  ') &&
          out.isNotEmpty &&
          paragraph.isEmpty &&
          out.last.kind == _BlockKind.bullet) {
        final last = out.removeLast();
        out.add(_Block(_BlockKind.bullet, '${last.text} $trimmed'));
        continue;
      }
      paragraph.add(trimmed);
    }
    flushParagraph();
    return out;
  }
}

enum _BlockKind { h1, h2, h3, paragraph, bullet, rule }

class _Block {
  const _Block(this.kind, this.text);
  final _BlockKind kind;
  final String text;
}

class _BlockView extends StatelessWidget {
  const _BlockView({required this.block});
  final _Block block;

  @override
  Widget build(BuildContext context) {
    final ink = context.ink;

    switch (block.kind) {
      case _BlockKind.h1:
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text(
            block.text,
            style: TextStyle(
              fontSize: 24,
              height: 1.2,
              fontWeight: FontWeight.w900,
              color: ink,
            ),
          ),
        );
      case _BlockKind.h2:
        return Padding(
          padding: const EdgeInsets.only(top: 22, bottom: 8),
          child: Text(
            block.text,
            style: TextStyle(
              fontSize: 17,
              height: 1.3,
              fontWeight: FontWeight.w800,
              color: ink,
            ),
          ),
        );
      case _BlockKind.h3:
        return Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 6),
          child: Text(
            block.text,
            style: TextStyle(
              fontSize: 15,
              height: 1.3,
              fontWeight: FontWeight.w800,
              color: ink,
            ),
          ),
        );
      case _BlockKind.rule:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Divider(height: 1, color: ink.withOpacity(0.12)),
        );
      case _BlockKind.paragraph:
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _InlineText(source: block.text),
        );
      case _BlockKind.bullet:
        return Padding(
          padding: const EdgeInsets.only(bottom: 8, left: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                // Optically aligns the dot with the cap height of the first
                // line rather than with the line box, which sits it high.
                padding: const EdgeInsets.only(top: 7, right: 10),
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: VentlyColors.berryMagenta.withOpacity(0.75),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Expanded(child: _InlineText(source: block.text)),
            ],
          ),
        );
    }
  }
}

/// Resolves `**bold**` and `_italic_` inside one block of text.
class _InlineText extends StatelessWidget {
  const _InlineText({required this.source});
  final String source;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(
      fontSize: 15,
      height: 1.55,
      color: context.ink.withOpacity(0.86),
    );
    return Text.rich(TextSpan(children: _spans(source, base)), style: base);
  }

  static List<InlineSpan> _spans(String source, TextStyle base) {
    // One pass, one pattern, so `**bold**` cannot be mistaken for two
    // `_italic_` runs and the emphasis markers never survive into the output.
    final pattern = RegExp(r'\*\*(.+?)\*\*|_(.+?)_');
    final spans = <InlineSpan>[];
    var cursor = 0;

    for (final match in pattern.allMatches(source)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: source.substring(cursor, match.start)));
      }
      final bold = match.group(1);
      if (bold != null) {
        spans.add(
          TextSpan(
            text: bold,
            style: base.copyWith(fontWeight: FontWeight.w800),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: match.group(2),
            style: base.copyWith(fontStyle: FontStyle.italic),
          ),
        );
      }
      cursor = match.end;
    }
    if (cursor < source.length) {
      spans.add(TextSpan(text: source.substring(cursor)));
    }
    return spans;
  }
}
