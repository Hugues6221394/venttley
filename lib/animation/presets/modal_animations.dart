import 'package:flutter/material.dart';

import '../../presentation/widgets/glass_surfaces.dart';

/// The standard Venttly modal: frosted [GlassSheet] surface, transparent
/// barrier styling, and the framework's spring-settle sheet physics.
///
/// Every bottom sheet in the app should go through this so modals feel
/// identical everywhere.
Future<T?> showGlassSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool isScrollControlled = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: isScrollControlled,
    barrierColor: Colors.black.withOpacity(0.32),
    builder: (ctx) =>
        GlassSheet(child: SafeArea(top: false, child: builder(ctx))),
  );
}

/// Drag-handle pill for glass sheets.
class SheetGrabber extends StatelessWidget {
  const SheetGrabber({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFE5A1B4).withOpacity(0.6),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
