import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../domain/entities/entities.dart';
import '../theme/colors.dart';
import 'profile_avatar.dart';

/// Instagram-style tag rendering: any `@handle` inside [text] renders as a
/// tappable rose token. Tapping resolves the handle server-side (users win
/// over tribes) and deep-links to the profile or tribe.
///
/// Drop-in replacement for a `Text(content)` — pass the same [style].
class TaggedText extends ConsumerStatefulWidget {
  const TaggedText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  static final RegExp tagPattern = RegExp(r'@([A-Za-z0-9_.-]{2,32})');

  @override
  ConsumerState<TaggedText> createState() => _TaggedTextState();
}

class _TaggedTextState extends ConsumerState<TaggedText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _open(String handle) async {
    final repo = ref.read(repositoryProvider);
    final router = GoRouter.of(context);
    final resolved = await repo.resolveTag(handle);
    if (!mounted || resolved == null) return;
    if (resolved.kind == 'user') {
      router.push('/user/${resolved.id}');
    } else if (resolved.kind == 'tribe' && resolved.slug != null) {
      router.push('/tribe/${resolved.slug}');
    }
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final base = widget.style ?? DefaultTextStyle.of(context).style;
    final tagStyle = base.copyWith(
      color: VentlyColors.berryMagenta,
      fontWeight: FontWeight.w800,
    );

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final m in TaggedText.tagPattern.allMatches(widget.text)) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: widget.text.substring(cursor, m.start)));
      }
      final handle = m.group(1)!;
      final recognizer = TapGestureRecognizer()
        ..onTap = () => unawaited(_open(handle));
      _recognizers.add(recognizer);
      spans.add(TextSpan(
        text: m.group(0),
        style: tagStyle,
        recognizer: recognizer,
      ));
      cursor = m.end;
    }
    if (cursor < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(cursor)));
    }

    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      textAlign: widget.textAlign,
    );
  }
}

/// Wraps any text input with an Instagram-style @-mention suggestion strip.
/// Watches [controller]; while the word under the caret starts with `@`,
/// shows matching friends → users → tribes above [child]. Selecting a
/// candidate replaces the token and re-focuses the field.
class TagAutocomplete extends ConsumerStatefulWidget {
  const TagAutocomplete({
    super.key,
    required this.controller,
    required this.child,
    this.fill = false,
  });

  final TextEditingController controller;
  final Widget child;

  /// When true the column takes all available height and [child] expands
  /// to fill it — for full-height composers. Default hugs the input.
  final bool fill;

  @override
  ConsumerState<TagAutocomplete> createState() => _TagAutocompleteState();
}

class _TagAutocompleteState extends ConsumerState<TagAutocomplete> {
  String _query = '';
  int _tokenStart = -1;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_recompute);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_recompute);
    super.dispose();
  }

  void _recompute() {
    final sel = widget.controller.selection;
    final text = widget.controller.text;
    if (!sel.isValid || !sel.isCollapsed) {
      _clear();
      return;
    }
    final caret = sel.baseOffset;
    var start = caret - 1;
    while (start >= 0 && !_isBoundary(text[start])) {
      start--;
    }
    start++;
    if (start < caret && start < text.length && text[start] == '@') {
      final q = text.substring(start + 1, caret);
      if (q.isNotEmpty && !q.contains('@')) {
        setState(() {
          _query = q;
          _tokenStart = start;
        });
        return;
      }
    }
    _clear();
  }

  bool _isBoundary(String c) => c == ' ' || c == '\n' || c == '\t';

  void _clear() {
    if (_query.isNotEmpty || _tokenStart != -1) {
      setState(() {
        _query = '';
        _tokenStart = -1;
      });
    }
  }

  void _select(TagCandidate c) {
    final text = widget.controller.text;
    final caret = widget.controller.selection.baseOffset;
    final replaced =
        '${text.substring(0, _tokenStart)}@${c.handle} ${text.substring(caret)}';
    final newCaret = _tokenStart + c.handle.length + 2;
    widget.controller.value = TextEditingValue(
      text: replaced,
      selection: TextSelection.collapsed(offset: newCaret),
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = _query.isNotEmpty;
    final candidates = active
        ? (ref.watch(tagCandidatesProvider(_query)).valueOrNull ??
            const <TagCandidate>[])
        : const <TagCandidate>[];

    return Column(
      mainAxisSize: widget.fill ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (candidates.isNotEmpty)
          Container(
            constraints: const BoxConstraints(maxHeight: 216),
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              color: context.isDark
                  ? Theme.of(context).colorScheme.surface
                  : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: context.glassBorder),
            ),
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: candidates.length,
              itemBuilder: (context, i) {
                final c = candidates[i];
                return InkWell(
                  onTap: () => _select(c),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        if (c.kind == 'tribe')
                          Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color:
                                  VentlyColors.berryMagenta.withOpacity(0.14),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.groups_rounded,
                                size: 18, color: VentlyColors.berryMagenta),
                          )
                        else
                          ProfileAvatar(
                            avatarSeed: c.avatarSeed ?? 'default-orb',
                            label: c.handle,
                            size: 32,
                          ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '@${c.handle}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                  color: context.ink,
                                ),
                              ),
                              if (c.kind == 'tribe' || c.display != c.handle)
                                Text(
                                  c.kind == 'tribe'
                                      ? '${c.display} · Tribe'
                                      : c.display,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: context.inkMuted,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (c.isFriend)
                          Text(
                            'Friend',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: VentlyColors.berryMagenta.withOpacity(0.8),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        if (widget.fill) Expanded(child: widget.child) else widget.child,
      ],
    );
  }
}
