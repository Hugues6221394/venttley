import 'package:flutter/material.dart';

import '../../core/vently_haptics.dart';
import '../theme/colors.dart';
import '../theme/motion.dart';

/// How far the face sits above the extrusion when idle.
const double _kLift = 5;

/// Primary action that looks like a glossy button bolted onto the canvas.
///
/// The darker slab behind the face is the "wall mount". On press the face
/// slides down onto it instead of merely scaling, which is what makes it
/// feel physical rather than like a flat Material pill.
class WallButton extends StatefulWidget {
  const WallButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.tone = WallButtonTone.brand,
    this.expanded = true,
    this.compact = false,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final WallButtonTone tone;
  final bool expanded;
  final bool compact;
  final bool busy;

  @override
  State<WallButton> createState() => _WallButtonState();
}

enum WallButtonTone { brand, danger, quiet }

class _WallButtonState extends State<WallButton> {
  bool _pressed = false;

  bool get _enabled => widget.onPressed != null && !widget.busy;

  void _set(bool v) {
    if (_pressed != v && mounted) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final colors = _WallPalette.of(context, widget.tone);
    final radius = widget.compact ? 16.0 : 22.0;
    final pad = widget.compact
        ? const EdgeInsets.symmetric(horizontal: 16, vertical: 8)
        : const EdgeInsets.symmetric(horizontal: 22, vertical: 14);
    final lift = _pressed || !_enabled ? 1.0 : _kLift;

    final labelColor = widget.tone == WallButtonTone.quiet
        ? context.ink
        : Colors.white;

    final child = widget.busy
        ? SizedBox(
            width: widget.compact ? 16 : 20,
            height: widget.compact ? 16 : 20,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: labelColor,
            ),
          )
        : Row(
            mainAxisSize: widget.expanded ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.icon != null) ...[
                Icon(
                  widget.icon,
                  color: labelColor,
                  size: widget.compact ? 15 : 18,
                ),
                SizedBox(width: widget.compact ? 6 : 8),
              ],
              if (widget.expanded)
                Flexible(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: labelColor,
                      fontWeight: FontWeight.w800,
                      fontSize: widget.compact ? 13 : 15,
                      letterSpacing: 0.1,
                      height: 1,
                    ),
                  ),
                )
              else
                Text(
                  widget.label,
                  style: TextStyle(
                    color: labelColor,
                    fontWeight: FontWeight.w800,
                    fontSize: widget.compact ? 13 : 15,
                    letterSpacing: 0.1,
                    height: 1,
                  ),
                ),
            ],
          );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _enabled ? (_) => _set(true) : null,
      onTapCancel: () => _set(false),
      onTapUp: (_) => _set(false),
      onTap: _enabled
          ? () {
              VentlyHaptics.light();
              widget.onPressed!();
            }
          : null,
      child: AnimatedOpacity(
        duration: VentlyMotion.fast,
        opacity: widget.onPressed == null ? 0.55 : 1,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.only(top: _kLift),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(radius),
                      color: colors.extrusion,
                      boxShadow: [
                        BoxShadow(
                          color: colors.wallShadow,
                          blurRadius: _pressed ? 6 : 14,
                          offset: Offset(0, _pressed ? 3 : 8),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              AnimatedPadding(
                duration: const Duration(milliseconds: 90),
                curve: Curves.easeOut,
                padding: EdgeInsets.only(bottom: lift),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(radius),
                    gradient: colors.face,
                    border: Border.all(color: colors.gloss, width: 1),
                  ),
                  child: Padding(
                    padding: pad,
                    child: SizedBox(
                      width: widget.expanded ? double.infinity : null,
                      child: Center(child: child),
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

class _WallPalette {
  const _WallPalette({
    required this.face,
    required this.extrusion,
    required this.gloss,
    required this.wallShadow,
  });

  final Gradient face;
  final Color extrusion;
  final Color gloss;
  final Color wallShadow;

  static _WallPalette of(BuildContext context, WallButtonTone tone) {
    final dark = context.isDark;
    switch (tone) {
      case WallButtonTone.brand:
        return _WallPalette(
          face: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFFF6BA3), Color(0xFFE0245E), Color(0xFFC2185B)],
            stops: [0.0, 0.55, 1.0],
          ),
          extrusion: const Color(0xFF8A1038),
          gloss: Colors.white.withValues(alpha: 0.42),
          wallShadow: const Color(
            0xFFC01A5B,
          ).withValues(alpha: dark ? 0.28 : 0.32),
        );
      case WallButtonTone.danger:
        return _WallPalette(
          face: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFFF7A7A), Color(0xFFE05C5C), Color(0xFFC44747)],
          ),
          extrusion: const Color(0xFF8A2A2A),
          gloss: Colors.white.withValues(alpha: 0.38),
          wallShadow: const Color(0xFFE05C5C).withValues(alpha: 0.28),
        );
      case WallButtonTone.quiet:
        return _WallPalette(
          face: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark
                ? const [Color(0xFF2A1C20), Color(0xFF1E1316)]
                : const [Color(0xFFFFFFFF), Color(0xFFF7EEF2)],
          ),
          extrusion: dark ? const Color(0xFF0C0709) : const Color(0xFFDCC8D0),
          gloss: Colors.white.withValues(alpha: dark ? 0.12 : 0.85),
          wallShadow: Colors.black.withValues(alpha: dark ? 0.35 : 0.10),
        );
    }
  }
}

/// Raised plate mounted on the canvas. Settings rows, checkup cards, tribe
/// tiles — anything that should feel like a physical panel, not a flat list.
class WallPanel extends StatefulWidget {
  const WallPanel({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.tint,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final Color? tint;

  @override
  State<WallPanel> createState() => _WallPanelState();
}

class _WallPanelState extends State<WallPanel> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final dark = context.isDark;
    final lift = _pressed && widget.onTap != null ? 1.0 : 4.0;
    final face = widget.tint ?? (dark ? const Color(0xFF22151A) : Colors.white);
    final extrusion = dark ? const Color(0xFF0A0608) : const Color(0xFFE4D0D8);

    final plate = AnimatedPadding(
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: lift),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: face,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: Colors.white.withValues(alpha: dark ? 0.12 : 0.85),
            width: 1,
          ),
        ),
        child: Padding(padding: widget.padding, child: widget.child),
      ),
    );

    final stack = Padding(
      padding: widget.margin,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: extrusion,
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: dark ? 0.40 : 0.08),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
              ),
            ),
          ),
          plate,
        ],
      ),
    );

    if (widget.onTap == null) return stack;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: () {
        VentlyHaptics.light();
        widget.onTap!();
      },
      child: stack,
    );
  }
}
