import 'package:flutter/material.dart';

typedef ModalTextControllerBuilder = Widget Function(
  BuildContext context,
  List<TextEditingController> controllers,
);

/// Owns text controllers for a dialog or sheet until its route is fully
/// removed. Disposing controllers immediately after `showDialog` or
/// `showModalBottomSheet` completes can race the route's exit animation.
class ModalTextControllerScope extends StatefulWidget {
  const ModalTextControllerScope({
    super.key,
    required this.initialValues,
    required this.builder,
  });

  final List<String> initialValues;
  final ModalTextControllerBuilder builder;

  @override
  State<ModalTextControllerScope> createState() =>
      _ModalTextControllerScopeState();
}

class _ModalTextControllerScopeState extends State<ModalTextControllerScope> {
  late final List<TextEditingController> _controllers;

  @override
  void initState() {
    super.initState();
    _controllers = widget.initialValues
        .map((text) => TextEditingController(text: text))
        .toList(growable: false);
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _controllers);
  }
}
