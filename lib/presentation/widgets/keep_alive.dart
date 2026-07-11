import 'package:flutter/material.dart';

/// Wraps [child] in an AutomaticKeepAliveClientMixin so it survives
/// tab switches in the bottom-nav shell. Use sparingly — only on
/// screens whose state is expensive to recreate (heavy scroll feeds,
/// realtime streams, audio players).
class KeepAliveWrapper extends StatefulWidget {
  const KeepAliveWrapper({super.key, required this.child});
  final Widget child;
  @override
  State<KeepAliveWrapper> createState() => _KeepAliveWrapperState();
}

class _KeepAliveWrapperState extends State<KeepAliveWrapper>
    with AutomaticKeepAliveClientMixin<KeepAliveWrapper> {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
