import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android release builds require private production signing', () {
    final gradle = File('android/app/build.gradle').readAsStringSync();
    final gitignore = File('.gitignore').readAsStringSync();
    final example = File('android/key.properties.example');

    expect(gradle, contains('releaseTaskRequested'));
    expect(gradle, contains('missingReleaseSigningKeys'));
    expect(gradle, contains('signingConfig = signingConfigs.release'));
    expect(gradle, isNot(contains('signingConfig = signingConfigs.debug')));
    expect(gitignore, contains('/android/key.properties'));
    expect(gitignore, contains('*.jks'));
    expect(example.existsSync(), isTrue);
  });
}
