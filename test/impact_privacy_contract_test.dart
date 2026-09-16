import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('impact and analytics privacy contract', () {
    final analytics = File('lib/data/services/analytics_service.dart').readAsStringSync();
    final repository = File('lib/data/repositories/vently_repository.dart').readAsStringSync();
    final taxonomy = File('lib/core/analytics_events.dart').readAsStringSync();

    test('PostHog identity comes from the server-issued analytics subject', () {
      expect(analytics, contains("rpc('my_analytics_subject')"));
      expect(analytics, contains("'distinct_id': subject"));
      expect(analytics, isNot(contains("'distinct_id': userId")));
      expect(analytics, isNot(contains("props: {'user_id': userId")));
    });

    test('legacy Tribe telemetry does not send resource identifiers', () {
      expect(repository, contains('_telemetry.event(Events.tribeJoined)'));
      expect(repository, contains('_telemetry.event(Events.tribeLeft)'));
      expect(repository, isNot(contains("'tribe_id': tribeId")));
      expect(repository, isNot(contains("_telemetry.event('tribe_join'")));
      expect(repository, isNot(contains("_telemetry.event('tribe_leave'")));
    });

    test('the reviewed taxonomy contains the impact signature events', () {
      expect(taxonomy, contains("'post.created'"));
      expect(taxonomy, contains("'comment.created'"));
      expect(taxonomy, contains("'engagement.self_interaction_rejected'"));
      expect(taxonomy, contains("'music.attached'"));
    });
  });
}
