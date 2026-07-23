import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/constants.dart';
import 'package:vently_app/data/services/mock_backend.dart';
import 'package:vently_app/domain/entities/entities.dart';

void main() {
  group('backend configuration', () {
    test('release builds reject the mock backend', () {
      expect(
        () => VentlyConfig.resolveBackendMode(
          release: true,
          forceMock: true,
          url: 'https://project.supabase.co',
          anonKey: 'publishable-key',
        ),
        throwsStateError,
      );
    });

    test('missing live credentials fail closed', () {
      expect(
        () => VentlyConfig.resolveBackendMode(
          release: false,
          forceMock: false,
          url: '',
          anonKey: '',
        ),
        throwsStateError,
      );
    });

    test('development mock mode remains explicit', () {
      expect(
        VentlyConfig.resolveBackendMode(
          release: false,
          forceMock: true,
          url: '',
          anonKey: '',
        ),
        BackendMode.mock,
      );
    });
  });

  test('presentation code cannot depend on MockBackend', () {
    final presentation = Directory('lib/presentation')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));

    final offenders = <String>[];
    for (final file in presentation) {
      final source = file.readAsStringSync();
      if (source.contains('MockBackend') ||
          source.contains("services/mock_backend.dart")) {
        offenders.add(file.path);
      }
    }

    expect(offenders, isEmpty,
        reason: 'UI code must obtain all content through repositories.');
  });

  test('live session state cannot fall through to the mock account', () {
    final source = File(
      'lib/data/repositories/vently_repository.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('_live?.me ?? _mock.me')));
    expect(source, contains('return live != null ? live.me : _mock.me;'));
  });

  test('demo UUID namespaces are absent from production Dart code', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .where((file) => !file.path.endsWith('mock_backend.dart'));
    final demoId = RegExp(r'[a-f]0000000-0000-4000-8000-');
    final offenders = <String>[];

    for (final file in files) {
      if (demoId.hasMatch(file.readAsStringSync())) {
        offenders.add(file.path);
      }
    }

    expect(offenders, isEmpty,
        reason: 'Synthetic database identities belong only in test fixtures.');
  });

  test('historical showcase migration cannot seed runtime tables', () {
    final source = File(
      'supabase/migrations/0070_seed_demo_community.sql',
    ).readAsStringSync();

    expect(source.toUpperCase(), isNot(contains('INSERT INTO')));
    expect(source, isNot(contains('picsum.photos')));
    expect(source, isNot(contains('pravatar.cc')));
  });

  test('keeper schema migration cannot bootstrap development identities', () {
    final source = File(
      'supabase/migrations/0062_keeper_studio_v2.sql',
    ).readAsStringSync();

    expect(source, isNot(contains('tester_keeper')));
    expect(source, isNot(contains('Quiet Mornings')));
    expect(source.toUpperCase(), isNot(contains('INSERT INTO PUBLIC.TRIBES')));
  });

  test('manual cleanup includes exact local development accounts', () {
    final source = File(
      'supabase/maintenance/remove_demo_seed_from_runtime.sql',
    ).readAsStringSync();

    for (final pseudonym in const [
      'tester_user',
      'tester_keeper',
      'tester_admin',
      'demo_alex',
      'demo_sam',
      'demo_riley',
    ]) {
      expect(source, contains("'$pseudonym'"));
    }
    expect(source, contains('DELETE FROM auth.users'));
    expect(source, contains('NEVER RUN DURING A NORMAL DEPLOY'));
  });

  test('mock reply counters match their fixture threads', () {
    int countTree(List<ThreadedComment> comments) {
      return comments.fold<int>(
        0,
        (total, comment) => total + 1 + countTree(comment.children),
      );
    }

    final mock = MockBackend.instance;
    for (final post in mock.feed(limit: 100)) {
      expect(
        post.commentsCount,
        countTree(mock.comments(post.postId)),
        reason: 'Mock post ${post.postId} advertises a false reply total.',
      );
    }
  });
}
