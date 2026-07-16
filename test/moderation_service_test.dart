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
  });
}
