/// Context-aware safety moderation pipeline.
///
/// Implements the tiered cascade from the PRD:
///   1. Fast local keyword dictionary (self-harm, doxxing PII, hate, harassment,
///      sexual content). Runs in-process — single-digit ms latency.
///   2. Groq-hosted Llama Guard 3 — escalates ambiguous content. Skipped when
///      [VentlyConfig.groqApiKey] is empty (safe-fail).
///
/// Public surface: [ModerationService.review] returns a [ModerationResult]
/// with a [SafetyVerdict], human-readable reasons, and a [surfaceCrisisHelpline]
/// flag that the UI uses to nudge crisis resources without breaking flow.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/constants.dart';

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
  bool get isWarn    => verdict == SafetyVerdict.warn;
}

class ModerationService {
  ModerationService({http.Client? httpClient}) : _http = httpClient;

  final http.Client? _http;

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
    'kill myself', 'end it all', 'suicide', "i want to die",
    'self harm', 'cutting myself', 'kms', "won't be here",
    'overdose', 'jump off', 'no reason to live',
  ];

  // Hate speech — small starter set; production loads from a private dict.
  static const List<String> _hateSlurs = [
    'retard', 'faggot', 'n word',
  ];

  // Targeted harassment of others.
  static const List<String> _harassment = [
    'kill yourself', 'kys', 'go die', "nobody loves you", 'you should die',
  ];

  // Sexual / explicit content — kept short here; LlamaGuard catches nuance.
  static const List<String> _sexualKeywords = [
    'nude pic', 'send nudes',
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

    // Tier 2 — Groq-hosted Llama Guard 3. Skipped when no key is configured;
    // skipped when Tier 1 already blocked (no need to spend a call).
    if (verdict != SafetyVerdict.block && VentlyConfig.groqApiKey.isNotEmpty) {
      try {
        final guard = await _llamaGuardReview(text)
            .timeout(const Duration(seconds: 3));
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
  // TIER 2 — Groq llama-guard-3-8b
  //
  // LlamaGuard 3 returns either "safe" or "unsafe\nS<n>,S<m>" where S<n>
  // codes follow MLCommons hazards. We map them back into our taxonomy.
  // ---------------------------------------------------------------------
  Future<ModerationResult> _llamaGuardReview(String text) async {
    final client = _http ?? http.Client();
    final res = await client.post(
      Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
      headers: {
        'Authorization': 'Bearer ${VentlyConfig.groqApiKey}',
        'Content-Type':  'application/json',
      },
      body: jsonEncode({
        'model':       VentlyConfig.groqGuardModel,
        'messages':    [
          {'role': 'user', 'content': text},
        ],
        'temperature': 0,
        'max_tokens':  100,
      }),
    );
    if (res.statusCode >= 400) {
      throw StateError('LlamaGuard HTTP ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final choices = body['choices'] as List?;
    final firstChoice = (choices == null || choices.isEmpty)
        ? null
        : choices.first as Map<String, dynamic>?;
    final message = firstChoice?['message'] as Map<String, dynamic>?;
    final content =
        ((message?['content'] as String?) ?? 'safe').trim().toLowerCase();

    if (content.startsWith('safe')) {
      return const ModerationResult(
        verdict: SafetyVerdict.safe,
        reasons: [],
        categories: {},
        surfaceCrisisHelpline: false,
      );
    }
    final cats = <HazardCategory>{};
    bool crisis = false;
    for (final code in _hazardCodes(content)) {
      final mapped = _mapHazard(code);
      if (mapped == HazardCategory.selfHarm) crisis = true;
      cats.add(mapped);
    }
    // Self-harm only escalates to warn — keep the door open to crisis
    // resources. Anything else blocks.
    final blockOnly = {...cats}..remove(HazardCategory.selfHarm);
    final verdict =
        blockOnly.isEmpty ? SafetyVerdict.warn : SafetyVerdict.block;
    return ModerationResult(
      verdict: verdict,
      reasons: [
        if (verdict == SafetyVerdict.block) 'Flagged by Venttly safety AI.',
        if (crisis) 'We care about you. Would you like crisis resources?',
      ],
      categories: cats,
      surfaceCrisisHelpline: crisis,
    );
  }

  static List<String> _hazardCodes(String content) {
    // LlamaGuard format: "unsafe\nS1,S11"
    return content
        .split(RegExp(r'[\s,]+'))
        .where((p) => p.startsWith('s'))
        .toList();
  }

  static HazardCategory _mapHazard(String code) {
    switch (code) {
      case 's1':  return HazardCategory.violence;
      case 's2':  return HazardCategory.violence;
      case 's3':  return HazardCategory.sexualContent;
      case 's4':  return HazardCategory.sexualContent;
      case 's5':  return HazardCategory.privacy;
      case 's6':  return HazardCategory.harassment;
      case 's7':  return HazardCategory.privacy;
      case 's8':  return HazardCategory.privacy;
      case 's9':  return HazardCategory.violence;
      case 's10': return HazardCategory.hate;
      case 's11': return HazardCategory.selfHarm;
      case 's12': return HazardCategory.sexualContent;
      case 's13': return HazardCategory.harassment;
      default:    return HazardCategory.other;
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
  CrisisResource('Venttly Care Line',           'Text CARE to 741741 (free, 24/7)'),
  CrisisResource('IsangeOne Stop Centre, Rwanda', 'Call 3029 from any phone'),
  CrisisResource('International Befrienders',  'https://befrienders.org'),
];
