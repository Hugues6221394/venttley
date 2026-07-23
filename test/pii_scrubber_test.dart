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
