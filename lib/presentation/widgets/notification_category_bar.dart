import 'package:flutter/material.dart';

import '../../animation/core/motion_tokens.dart';
import '../../core/vently_haptics.dart';
import '../../domain/notifications/notification_category.dart';
import '../theme/colors.dart';

/// The Activity tabs: All, Mentions, Reactions, Comments, Friends, Tribes,
/// System.
///
/// A scrolling row rather than a TabBar, because seven tabs do not fit a phone
/// and an underline indicator shrinks each one to a few illegible pixels. The
/// selected pill fills; the rest stay quiet. Counts appear only where there is
/// something unread, so the row reads as a summary at a glance instead of a
/// wall of zeros.
///
/// The selected pill scrolls itself into view. Tapping "System" at the right
/// edge and having it sit half off-screen is the kind of small wrongness that
/// makes an interface feel unfinished.
class NotificationCategoryBar extends StatefulWidget {
  const NotificationCategoryBar({
    super.key,
    required this.value,
    required this.onChanged,
    this.unreadByCategory = const {},
  });

  final NotificationCategory value;
  final ValueChanged<NotificationCategory> onChanged;

  /// Unread count per tab. Absent or zero hides the badge.
  final Map<NotificationCategory, int> unreadByCategory;

  @override
  State<NotificationCategoryBar> createState() =>
      _NotificationCategoryBarState();
}

class _NotificationCategoryBarState extends State<NotificationCategoryBar> {
  final _controller = ScrollController();
  final _keys = <NotificationCategory, GlobalKey>{
    for (final c in NotificationCategory.tabs) c: GlobalKey(),
  };

  @override
  void didUpdateWidget(covariant NotificationCategoryBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _revealSelected();
  }

  void _revealSelected() {
    final context = _keys[widget.value]?.currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(
      context,
      duration: MotionTokens.medium,
      curve: AppCurves.standard,
      alignment: 0.5,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: ListView.separated(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        physics: const BouncingScrollPhysics(),
        itemCount: NotificationCategory.tabs.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final category = NotificationCategory.tabs[i];
          return _CategoryPill(
            key: _keys[category],
            category: category,
            selected: category == widget.value,
            unread: widget.unreadByCategory[category] ?? 0,
            onTap: () {
              if (category == widget.value) return;
              VentlyHaptics.selection();
              widget.onChanged(category);
            },
          );
        },
      ),
    );
  }
}

class _CategoryPill extends StatefulWidget {
  const _CategoryPill({
    super.key,
    required this.category,
    required this.selected,
    required this.unread,
    required this.onTap,
  });

  final NotificationCategory category;
  final bool selected;
  final int unread;
  final VoidCallback onTap;

  @override
  State<_CategoryPill> createState() => _CategoryPillState();
}

class _CategoryPillState extends State<_CategoryPill> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final selected = widget.selected;

    final foreground = selected
        ? Colors.white
        : (dark ? Colors.white70 : VentlyColors.deepBurgundy);

    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        // A small give under the thumb. Enough to feel answered, not enough to
        // look like the row is bouncing.
        scale: _pressed ? 0.95 : 1,
        duration: MotionTokens.press.duration,
        curve: MotionTokens.press.curve,
        child: AnimatedContainer(
          duration: MotionTokens.feedback.duration,
          curve: MotionTokens.feedback.curve,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: selected
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [VentlyColors.berryMagenta, VentlyColors.roseDeep],
                  )
                : null,
            color: selected
                ? null
                : (dark ? Colors.white10 : Colors.white),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: selected
                  ? Colors.transparent
                  : (dark ? Colors.white24 : VentlyColors.softMauve),
            ),
            boxShadow: selected
                ? [
                    // The rose carries its own glow so the selected tab lifts
                    // off the canvas instead of merely changing colour.
                    BoxShadow(
                      color: VentlyColors.berryMagenta.withOpacity(0.28),
                      blurRadius: 16,
                      spreadRadius: -4,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.category.icon, size: 15, color: foreground),
              const SizedBox(width: 6),
              Text(
                widget.category.label,
                style: TextStyle(
                  color: foreground,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.1,
                ),
              ),
              // Counts grow in rather than popping, and disappear entirely at
              // zero — a row of "0"s reads as noise, not information.
              AnimatedSize(
                duration: MotionTokens.feedback.duration,
                curve: MotionTokens.feedback.curve,
                child: widget.unread == 0
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: selected
                                ? Colors.white.withOpacity(0.24)
                                : VentlyColors.berryMagenta,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            widget.unread > 99 ? '99+' : '${widget.unread}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
