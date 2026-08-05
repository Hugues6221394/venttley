import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/data/services/moderation_service.dart';

void main() {
  group('ModerationService', () {
    test('blocks direct contact details locally', () async {
      final result = await ModerationService().review(
        'Reach me at person@example.com',
      );

      expect(result.verdict, SafetyVerdict.block);
      expect(result.categories, contains(HazardCategory.privacy));
    });

    test('blocks a plausible international phone number locally', () async {
      final result = await ModerationService().review(
        'Call me on +250 788 123 456',
      );

      expect(result.verdict, SafetyVerdict.block);
      expect(result.categories, contains(HazardCategory.privacy));
    });

    test('does not mistake compact or formatted dates for phone numbers',
        () async {
      final service = ModerationService();

      final compact = await service.review('Release check 20260718');
      final formatted = await service.review('The appointment is 2026-07-18');

      expect(compact.verdict, SafetyVerdict.safe);
      expect(formatted.verdict, SafetyVerdict.safe);
    });

    test('warns for self-harm language without blocking help', () async {
      final result = await ModerationService().review('I want to die');

      expect(result.verdict, SafetyVerdict.warn);
      expect(result.surfaceCrisisHelpline, isTrue);
      expect(result.categories, contains(HazardCategory.selfHarm));
    });

    test('maps a server-side guard verdict for risk-adjacent text', () async {
      var calls = 0;
      final service = ModerationService(
        remoteGuard: (text) async {
          calls += 1;
          return {
            'verdict': 'block',
            'categories': ['violence'],
            'reason': 'Credible threat detected.',
          };
        },
      );

      final result = await service.review(
        'I have a knife and this is a credible threat to another person.',
      );

      expect(calls, 1);
      expect(result.verdict, SafetyVerdict.block);
      expect(result.categories, contains(HazardCategory.violence));
    });

    test('does not send short benign content to the remote guard', () async {
      var calls = 0;
      final service = ModerationService(
        remoteGuard: (text) async {
          calls += 1;
          return null;
        },
      );

      final result = await service.review('rough day');

      expect(calls, 0);
      expect(result.verdict, SafetyVerdict.safe);
    });

    test('fallback crisis contacts contain no invented Venttly hotline', () {
      final resources =
          kCrisisResources.map((resource) => resource.reach).join(' ');

      expect(resources, isNot(contains('741741')));
      expect(
        kCrisisResources.map((resource) => resource.label),
        contains('Kigali Mental Health Referral Centre'),
      );
      expect(resources, contains('114 or 912'));
      expect(resources, contains('3029'));
    });

    test('crisis resource migration retires the unsafe global text line', () {
      final migration = File(
        'supabase/migrations/'
        '20260728125529_correct_rwanda_crisis_resources.sql',
      ).readAsStringSync();

      expect(migration, contains("reach ILIKE '%741741%'"));
      expect(migration, contains('SET is_active = false'));
      expect(migration, contains('Kigali Mental Health Referral Centre'));
      expect(migration, contains('Call 114 or 912'));
    });
  });
}
