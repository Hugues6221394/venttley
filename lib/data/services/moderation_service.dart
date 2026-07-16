/// Context-aware safety moderation pipeline.
///
/// Implements the tiered cascade from the PRD:
///   1. Fast local keyword dictionary (self-harm, doxxing PII, hate, harassment,
///      sexual content). Runs in-process — single-digit ms latency.
///   2. Server-side Llama Guard — escalates ambiguous content through the
///      authenticated `moderate` Edge Function. No provider key ships in app.
///
/// Public surface: [ModerationService.review] returns a [ModerationResult]
/// with a [SafetyVerdict], human-readable reasons, and a [surfaceCrisisHelpline]
/// flag that the UI uses to nudge crisis resources without breaking flow.
library;

import 'dart:async';
import 'dart:math';

import '../../domain/entities/entities.dart';

enum SafetyVerdict { safe, warn, block }

/// LlamaGuard 3 hazard taxonomy — we map its S* codes back to UI categories.
enum HazardCategory {
  selfHarm,
  hate,
  harassment,
  sexualContent,
  violence,
  privacy,
  other,
}

class ModerationResult {
  final SafetyVerdict verdict;
  final List<String> reasons;
  final Set<HazardCategory> categories;
  final bool surfaceCrisisHelpline;

  const ModerationResult({
    required this.verdict,
    required this.reasons,
    required this.categories,
    required this.surfaceCrisisHelpline,
  });

  bool get isBlocked => verdict == SafetyVerdict.block;
  bool get isWarn => verdict == SafetyVerdict.warn;
}

class ModerationService {
  ModerationService({this.remoteGuard});

  /// When set, Tier-2 classification is delegated to this callback — the
  /// server-side `moderate` edge function — instead of calling Groq directly.
  /// Keeps the API key off-device and enables the trusted verdict cache.
  /// Returns the raw verdict map {verdict, categories, reason}, or null on
  /// failure (treated as safe; Tier-1 still applies).
  final Future<Map<String, dynamic>?> Function(String text)? remoteGuard;

  // Staff-managed automod rules (migration 0085), loaded from the backend and
  // applied on top of the built-in dictionaries. Updated at runtime as the
  // rules provider resolves.
  List<AutomodRule> _dynamicRules = const [];
  void setDynamicRules(List<AutomodRule> rules) => _dynamicRules = rules;

  // --- Tier-2 cost gate ---------------------------------------------------
  final _rng = Random();

  /// Fraction of clearly-benign messages still sent to the LLM, so we keep
  /// coverage on novel harmful phrasing and can monitor classifier drift.
  static const double _llmSampleRate = 0.05;

  /// Minimum length below which a signal-free message is treated as benign
  /// (a 3-word "i feel sad" doesn't need a Llama Guard round-trip).
  static const int _llmMinLength = 24;

  /// Coarse risk-adjacent tokens. If none of these appear AND Tier 1 found
  /// nothing, the content is almost certainly benign venting — the LLM's job
  /// is nuance around these themes, so its absence means low value / high cost.
  static final RegExp _riskHints = RegExp(
    r'\b('
    r'die|dead|death|kill|hurt|harm|blood|cut|pills|overdose|suicide|'
    r'hate|kys|ugly|stupid|worthless|loser|freak|'
    r'sex|nude|naked|horny|dick|pussy|porn|'
    r'gun|knife|shoot|stab|bomb|threat|'
    r'address|phone|snap|insta|whatsapp|email|meet\s?up'
    r')\b',
    caseSensitive: false,
  );

  /// Decides whether to spend a Tier-2 LLM call. Escalates on any Tier-1
  /// signal or risk hint; otherwise samples a small fraction.
  bool _shouldRunLlmGuard(String lower, Set<HazardCategory> categories) {
    if (categories.isNotEmpty) return true; // confirm/expand a Tier-1 hit
    if (lower.length < _llmMinLength) return false;
    if (_riskHints.hasMatch(lower)) return true; // nuance worth the call
    return _rng.nextDouble() < _llmSampleRate; // sampled coverage
  }

  bool _ruleMatches(AutomodRule rule, String original, String lower) {
    final p = rule.pattern.trim();
    if (p.isEmpty) return false;
    switch (rule.matchType) {
      case 'regex':
        try {
          return RegExp(p, caseSensitive: false).hasMatch(original);
        } catch (_) {
          return false; // A malformed rule never breaks moderation.
        }
      case 'word':
        return RegExp('\\b${RegExp.escape(p.toLowerCase())}\\b')
            .hasMatch(lower);
      case 'contains':
      default:
        return lower.contains(p.toLowerCase());
    }
  }

  // ---------------------------------------------------------------------
  // TIER 1 — keyword dictionaries
  // ---------------------------------------------------------------------

  // 7+ digits, allowing spaces / dashes / leading + — catches obvious phone
  // numbers without flagging years or street addresses.
  static final RegExp _phoneNumber = RegExp(r'(?:\+?\d[\s\-]?){7,}');

  // Bare email addresses — same rationale.
  static final RegExp _email =
      RegExp(r'[\w.\-]+@[\w\-]+\.[a-zA-Z]{2,}', caseSensitive: false);

  // Imminent-harm phrases. These short-circuit to [SafetyVerdict.warn] and
  // surface crisis resources — never block, so people in crisis can still
  // reach for help in the app.
  static const List<String> _selfHarmKeywords = [
    'kill myself',
    'end it all',
    'suicide',
    "i want to die",
    'self harm',
    'cutting myself',
    'kms',
    "won't be here",
    'overdose',
    'jump off',
    'no reason to live',
  ];

  // Hate speech — small starter set; production loads from a private dict.
  static const List<String> _hateSlurs = [
    'retard',
    'faggot',
    'n word',
  ];

  // Targeted harassment of others.
  static const List<String> _harassment = [
    'kill yourself',
    'kys',
    'go die',
    "nobody loves you",
    'you should die',
  ];

  // Sexual / explicit content — kept short here; LlamaGuard catches nuance.
  static const List<String> _sexualKeywords = [
    'nude pic',
    'send nudes',
  ];

  // ---------------------------------------------------------------------
  // PUBLIC API
  // ---------------------------------------------------------------------

  Future<ModerationResult> review(String text) async {
    final t = text.toLowerCase();
    final reasons = <String>[];
    final categories = <HazardCategory>{};
    bool crisis = false;
    var verdict = SafetyVerdict.safe;

    if (_phoneNumber.hasMatch(text)) {
      reasons.add('Looks like a phone number — Venttly masks contact info.');
      categories.add(HazardCategory.privacy);
      verdict = SafetyVerdict.block;
    }
    if (_email.hasMatch(text)) {
      reasons.add('Email addresses are masked here to keep things anonymous.');
      categories.add(HazardCategory.privacy);
      verdict = SafetyVerdict.block;
    }
    for (final phrase in _harassment) {
      if (t.contains(phrase)) {
        reasons.add('Targeted harassment language detected.');
        categories.add(HazardCategory.harassment);
        verdict = SafetyVerdict.block;
        break;
      }
    }
    for (final slur in _hateSlurs) {
      if (t.contains(slur)) {
        reasons.add('Hate-speech term detected.');
        categories.add(HazardCategory.hate);
        verdict = SafetyVerdict.block;
        break;
      }
    }
    for (final phrase in _sexualKeywords) {
      if (t.contains(phrase)) {
        reasons.add('Sexual solicitation detected.');
        categories.add(HazardCategory.sexualContent);
        verdict = SafetyVerdict.block;
        break;
      }
    }
    for (final phrase in _selfHarmKeywords) {
      if (t.contains(phrase)) {
        crisis = true;
        categories.add(HazardCategory.selfHarm);
        // Never block self-harm language — surface help instead.
        if (verdict == SafetyVerdict.safe) verdict = SafetyVerdict.warn;
        reasons.add('We care about you. Would you like crisis resources?');
        break;
      }
    }

    // Tier 1.5 — staff-managed automod rules (migration 0085). Applied on top
    // of the built-in dictionaries so ops can react to new abuse without a
    // release. 'crisis' never blocks (help stays reachable); 'block' stops the
    // message; 'flag' warns but lets it through.
    for (final rule in _dynamicRules) {
      if (!_ruleMatches(rule, text, t)) continue;
      categories.add(_categoryFromString(rule.category));
      switch (rule.action) {
        case 'crisis':
          crisis = true;
          if (verdict == SafetyVerdict.safe) verdict = SafetyVerdict.warn;
          reasons.add('We care about you. Would you like crisis resources?');
          break;
        case 'flag':
          if (verdict == SafetyVerdict.safe) verdict = SafetyVerdict.warn;
          reasons.add('Flagged by a Venttly safety rule.');
          break;
        case 'block':
        default:
          verdict = SafetyVerdict.block;
          reasons.add('This goes against our community rules.');
          break;
      }
    }

    // Tier 2 — Groq-hosted Llama Guard 3. Skipped when no key is configured,
    // when Tier 1 already blocked, and — at scale — when the content shows no
    // risk signal at all (cost gate, see _shouldRunLlmGuard). This keeps LLM
    // spend/latency proportional to actual risk instead of paying per message.
    if (verdict != SafetyVerdict.block &&
        remoteGuard != null &&
        _shouldRunLlmGuard(t, categories)) {
      try {
        final guard =
            await _llamaGuardReview(text).timeout(const Duration(seconds: 3));
        if (guard.verdict == SafetyVerdict.block) {
          verdict = SafetyVerdict.block;
          reasons.addAll(guard.reasons);
          categories.addAll(guard.categories);
        } else if (guard.verdict == SafetyVerdict.warn &&
            verdict == SafetyVerdict.safe) {
          verdict = SafetyVerdict.warn;
          reasons.addAll(guard.reasons);
          categories.addAll(guard.categories);
        }
        if (guard.categories.contains(HazardCategory.selfHarm)) {
          crisis = true;
        }
      } catch (_) {
        // Network failure / timeout — fail open (don't block on infrastructure
        // outage). Tier-1 still applies.
      }
    }

    return ModerationResult(
      verdict: verdict,
      reasons: reasons,
      categories: categories,
      surfaceCrisisHelpline: crisis,
    );
  }

  // ---------------------------------------------------------------------
  // TIER 2 — authenticated server-side classification.
  // ---------------------------------------------------------------------
  Future<ModerationResult> _llamaGuardReview(String text) async {
    final remote = remoteGuard;
    if (remote == null) return _safeGuardResult;
    final parsed = await remote(text);
    if (parsed == null) return _safeGuardResult;
    return _mapGuardParsed(parsed);
  }

  static const ModerationResult _safeGuardResult = ModerationResult(
    verdict: SafetyVerdict.safe,
    reasons: [],
    categories: {},
    surfaceCrisisHelpline: false,
  );

  /// Maps the raw model verdict shape {verdict, categories, reason} onto a
  /// [ModerationResult] — shared by the remote and direct-Groq paths.
  ModerationResult _mapGuardParsed(Map<String, dynamic> parsed) {
    final verdictStr = (parsed['verdict'] as String?)?.toLowerCase();
    final rawCats = parsed['categories'];
    final reason = parsed['reason'] as String?;
    final cats = <HazardCategory>{};
    if (rawCats is List) {
      for (final c in rawCats) {
        cats.add(_categoryFromString(c.toString()));
      }
    }
    final crisis = cats.contains(HazardCategory.selfHarm);
    final verdict = switch (verdictStr) {
      'block' => SafetyVerdict.block,
      'warn' => SafetyVerdict.warn,
      _ => SafetyVerdict.safe,
    };
    // Self-harm never escalates to block — keep crisis support reachable.
    final effective =
        (verdict == SafetyVerdict.block && crisis && cats.length == 1)
            ? SafetyVerdict.warn
            : verdict;

    return ModerationResult(
      verdict: effective,
      reasons: [
        if (reason != null && reason.isNotEmpty)
          reason
        else if (effective == SafetyVerdict.block)
          'Flagged by Venttly safety AI.',
        if (crisis) 'We care about you. Would you like crisis resources?',
      ],
      categories: cats,
      surfaceCrisisHelpline: crisis,
    );
  }

  static HazardCategory _categoryFromString(String s) {
    switch (s.trim().toLowerCase()) {
      case 'self_harm':
        return HazardCategory.selfHarm;
      case 'hate':
        return HazardCategory.hate;
      case 'harassment':
        return HazardCategory.harassment;
      case 'sexual_content':
        return HazardCategory.sexualContent;
      case 'violence':
        return HazardCategory.violence;
      case 'privacy':
        return HazardCategory.privacy;
      default:
        return HazardCategory.other;
    }
  }

  /// Cascade false-positive rate calculator from the spec.
  static double cascadeError(List<double> epsilons) {
    var keep = 1.0;
    for (final e in epsilons) {
      keep *= (1.0 - e);
    }
    return 1.0 - keep;
  }
}

class CrisisResource {
  final String label;
  final String reach;
  const CrisisResource(this.label, this.reach);
}

const List<CrisisResource> kCrisisResources = [
  CrisisResource('Venttly Care Line', 'Text CARE to 741741 (free, 24/7)'),
  CrisisResource('IsangeOne Stop Centre, Rwanda', 'Call 3029 from any phone'),
  CrisisResource('International Befrienders', 'https://befrienders.org'),
];
