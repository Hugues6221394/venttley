import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/pii_scrubber.dart';

void main() {
  group('PiiScrubber', () {
    test('drops sensitive keys recursively without mutating input', () {
      final input = <String, Object?>{
        'screen': 'feed',
        'user_email': 'person@example.com',
        'nested': <String, Object?>{
          'message_body': 'please keep this private',
          'count': 2,
        },
      };

      final output = PiiScrubber.scrub(input);

      expect(output, {
        'screen': 'feed',
        'nested': {'count': 2},
      });
      expect(input['user_email'], 'person@example.com');
    });

    test('redacts inline identifiers and credentials', () {
      const jwt = 'aaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbb.cccccccccccccccc';
      final scrubbed = PiiScrubber.scrubText(
        'contact person@example.com with Bearer abcdefghijklmnop or $jwt',
      );

      expect(scrubbed, isNot(contains('person@example.com')));
      expect(scrubbed, isNot(contains('abcdefghijklmnop')));
      expect(scrubbed, isNot(contains(jwt)));
      expect(scrubbed, contains('<scrubbed:email>'));
      expect(scrubbed, contains('<scrubbed:bearer>'));
      expect(scrubbed, contains('<scrubbed:jwt>'));
    });

    test('keeps opaque identifiers readable without sparing phone numbers', () {
      // A UUID's digit runs joined by hyphens look exactly like a phone
      // number. Mangling them cost us breadcrumb-to-account traceability.
      const userId = '4f8a2c31-9b6e-4d17-8a05-a1b22d98064d';
      expect(PiiScrubber.scrubText(userId), userId);

      // ...but only when the value is *entirely* an identifier. Real numbers,
      // alone or embedded in a sentence, must still be redacted.
      expect(PiiScrubber.scrubText('+15551234567'), contains('<scrubbed:phone>'));
      final sentence = PiiScrubber.scrubText('call me on 555 123 4567 tonight');
      expect(sentence, contains('<scrubbed:phone>'));
      expect(sentence, isNot(contains('4567')));
    });

    test('wraps errors without retaining their sensitive message', () {
      final error = PiiScrubber.scrubError(
        StateError('account person@example.com could not authenticate'),
      );

      expect(error.type, 'StateError');
      expect(error.toString(), isNot(contains('person@example.com')));
    });

    test('scrubs long free-form strings completely', () {
      final privateText = List.filled(50, 'private').join(' ');
      expect(
        PiiScrubber.scrubText(privateText),
        '<scrubbed:length=${privateText.length}>',
      );
    });
  });
}
