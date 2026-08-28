import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('discover search hides backend exception details and offers retry', () {
    final source = File(
      'lib/presentation/screens/discover/discover_screen.dart',
    ).readAsStringSync();

    expect(
      source,
      contains("Search isn\\'t available right now. Please try again."),
    );
    expect(source, contains("const Text('Retry')"));
    expect(source, isNot(contains(r'Search failed: $e')));
  });
}
