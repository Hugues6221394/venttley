import 'package:flutter/material.dart';

/// Layer 3 — Rich Motion: Rive bridge (interactive UI states).
///
/// The `rive` package is NOT a dependency yet. This bridge keeps call-sites
/// stable: today it renders the [fallback] widget; once `rive` is added to
/// pubspec and assets exist, only this file changes — the app code that uses
/// [RiveStateWidget] does not.
///
/// Contract per the motion spec: Rive drives *interactive component states*
/// (like buttons, toggles, onboarding characters) via state machines with
/// idle / active / success / error inputs.
enum RiveUIState { idle, active, success, error }

class RiveStateWidget extends StatelessWidget {
  const RiveStateWidget({
    super.key,
    required this.asset,
    required this.state,
    required this.fallback,
    this.stateMachine = 'default',
  });

  /// e.g. 'assets/rive/like_button.riv'
  final String asset;
  final RiveUIState state;
  final String stateMachine;

  /// Rendered until the Rive runtime is enabled — never ship a blank box.
  final Widget fallback;

  static bool get enabled => false; // flips true when `rive` is wired in

  @override
  Widget build(BuildContext context) => fallback;
}
