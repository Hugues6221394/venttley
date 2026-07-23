import 'package:flutter/cupertino.dart';

/// Venttly's single notification-bell glyph.
///
/// Cupertino's thin outline matches the app's premium visual language while
/// keeping every bell backed by the same lightweight icon font.
class VentlyNotificationBell extends StatelessWidget {
  const VentlyNotificationBell({
    super.key,
    this.size = 24,
    this.color,
    this.muted = false,
    this.semanticLabel,
  });

  static const IconData iconData = CupertinoIcons.bell;
  static const IconData mutedIconData = CupertinoIcons.bell_slash;

  final double size;
  final Color? color;
  final bool muted;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Icon(
      muted ? mutedIconData : iconData,
      size: size,
      color: color,
      semanticLabel: semanticLabel,
    );
  }
}
