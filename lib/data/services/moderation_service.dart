/// Context-aware safety moderation pipeline.
///
/// Implements the tiered cascade from the spec:
///   1. fast local keyword dictionary (self-harm alerts + phone-number doxx)
///   2. Llama Guard 3 edge call (stubbed locally for offline / mock mode)
///
/// Average end-to-end latency target: < 100 ms.
library;

import 'dart:math';

enum SafetyVerdict { safe, warn, block }

class ModerationResult {
  final SafetyVerdict verdict;
  final List<String> reasons;
  final bool surfaceCrisisHelpline;

  const ModerationResult({
    required this.verdict,
    required this.reasons,
    required this.surfaceCrisisHelpline,
  });

  bool get isBlocked => verdict == SafetyVerdict.block;
  bool get isWarn    => verdict == SafetyVerdict.warn;
}

class ModerationService {
  // Tier 1 — fast local keyword scan. Tuned to catch immediate self-harm
  // language and obvious doxxing patterns without flagging supportive
  // peer comments.
  static final RegExp _phoneNumber = RegExp(r'(?:\+?\d[\s\-]?){7,}');
  static const List<String> _selfHarmKeywords = [
    'kill myself', 'end it all', 'suicide', "i want to die",
    'self harm', 'cutting myself',
  ];
  static const List<String> _hateSlurs = [
    // very small starter set — production would load from a private dict.
    'retard', 'faggot', 'n word',
  ];
  static const List<String> _harassment = [
    'kill yourself', 'kys', 'go die', "nobody loves you", 'you should die',
  ];

  /// Scan a piece of user-generated content and return a verdict.
  Future<ModerationResult> review(String text) async {
    final t = text.toLowerCase();
    final reasons = <String>[];
    bool crisis = false;
    var verdict = SafetyVerdict.safe;

    if (_phoneNumber.hasMatch(text)) {
      reasons.add('Looks like a phone number — Vently masks contact info.');
      verdict = SafetyVerdict.block;
    }
    for (final phrase in _harassment) {
      if (t.contains(phrase)) {
        reasons.add('Targeted harassment language detected.');
        verdict = SafetyVerdict.block;
        break;
      }
    }
    for (final slur in _hateSlurs) {
      if (t.contains(slur)) {
        reasons.add('Hate-speech term detected.');
        verdict = SafetyVerdict.block;
        break;
      }
    }
    for (final phrase in _selfHarmKeywords) {
      if (t.contains(phrase)) {
        crisis = true;
        if (verdict == SafetyVerdict.safe) verdict = SafetyVerdict.warn;
        reasons.add('We care about you. Would you like crisis resources?');
        break;
      }
    }

    // Tier 2 — Llama Guard 3 edge call. Stubbed locally for now; in
    // production this would POST to a private edge endpoint.
    final guardVerdict = await _llamaGuardStub(text);
    if (guardVerdict == SafetyVerdict.block) {
      verdict = SafetyVerdict.block;
      reasons.add('Flagged by Vently safety AI.');
    } else if (guardVerdict == SafetyVerdict.warn && verdict == SafetyVerdict.safe) {
      verdict = SafetyVerdict.warn;
    }

    return ModerationResult(
      verdict: verdict,
      reasons: reasons,
      surfaceCrisisHelpline: crisis,
    );
  }

  Future<SafetyVerdict> _llamaGuardStub(String text) async {
    // Simulate <50ms inference and a tiny false-positive surface.
    await Future<void>.delayed(const Duration(milliseconds: 35));
    final hits = _suspiciousScore(text);
    if (hits > 0.85) return SafetyVerdict.block;
    if (hits > 0.5)  return SafetyVerdict.warn;
    return SafetyVerdict.safe;
  }

  double _suspiciousScore(String text) {
    final lc = text.toLowerCase();
    var score = 0.0;
    if (lc.contains('http') || lc.contains('www.')) score += 0.4;
    if (RegExp(r'[A-Z]{5,}').hasMatch(text)) score += 0.2;
    if (text.length < 4) score += 0.2;
    score += Random(text.hashCode).nextDouble() * 0.05;
    return score;
  }

  /// Cascade false-positive rate calculator from the spec.
  /// `epsilons` is the per-stage FPR; returns the cumulative error after
  /// passing through every stage.
  static double cascadeError(List<double> epsilons) {
    var keep = 1.0;
    for (final e in epsilons) {
      keep *= (1.0 - e);
    }
    return 1.0 - keep;
  }
}

/// Crisis support resources surfaced when self-harm signals fire.
class CrisisResource {
  final String label;
  final String reach;
  const CrisisResource(this.label, this.reach);
}

const List<CrisisResource> kCrisisResources = [
  CrisisResource('Vently Care Line',           'Text CARE to 741741 (free, 24/7)'),
  CrisisResource('IsangeOne Stop Centre, Rwanda', 'Call 3029 from any phone'),
  CrisisResource('International Befrienders',  'https://befrienders.org'),
];
