/// Layer 2 — Motion System.
///
/// The standardized timing table for every animation in Venttly.
/// No widget may hardcode a duration; it must pick from this scale.
///
/// | Type               | Duration  |
/// | ------------------ | --------- |
/// | Micro interaction  | 80–150ms  |
/// | UI feedback        | 150–300ms |
/// | Screen transitions | 250–450ms |
/// | Heavy transitions  | 400–700ms |
class MotionDurations {
  MotionDurations._();

  /// Micro interactions — press feedback, chip toggles.
  static const Duration micro = Duration(milliseconds: 120);

  /// UI feedback — selection states, small reveals.
  static const Duration fast = Duration(milliseconds: 220);

  /// Screen transitions, card entrances.
  static const Duration medium = Duration(milliseconds: 350);

  /// Heavy transitions — sheets, hero moments.
  static const Duration slow = Duration(milliseconds: 550);

  /// Ambient motion — background drift; intentionally very slow.
  static const Duration ambient = Duration(seconds: 9);

  /// Stagger gap between sibling entrances.
  static const Duration stagger = Duration(milliseconds: 55);
}
