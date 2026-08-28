import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vently_app/data/services/music_preview_cache.dart';
import 'package:vently_app/domain/entities/entities.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('venttly-music-cache-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'authorized preview is cached and reused without another download',
    () async {
      var requests = 0;
      final cache = MusicPreviewCache(
        client: MockClient((_) async {
          requests += 1;
          return http.Response.bytes(
            List<int>.generate(1024, (index) => index % 255),
            200,
            headers: {'content-type': 'audio/mpeg'},
          );
        }),
        directory: () async => directory,
      );
      addTearDown(cache.dispose);

      final first = await cache.resolve(_track(cacheAllowed: true));
      final second = await cache.resolve(_track(cacheAllowed: true));

      expect(first, isNotNull);
      expect(second, first);
      expect(await File(first!).length(), 1024);
      expect(requests, 1);
    },
  );

  test('catalog rights opt-out prevents disk and network access', () async {
    var requests = 0;
    final cache = MusicPreviewCache(
      client: MockClient((_) async {
        requests += 1;
        return http.Response('unexpected', 200);
      }),
      directory: () async => directory,
    );
    addTearDown(cache.dispose);

    expect(await cache.resolve(_track(cacheAllowed: false)), isNull);
    expect(requests, 0);
    expect(await directory.list().toList(), isEmpty);
  });

  test('oversized preview is rejected and partial bytes are removed', () async {
    final cache = MusicPreviewCache(
      client: MockClient(
        (_) async => http.Response.bytes(
          List<int>.filled(2048, 1),
          200,
          headers: {'content-type': 'audio/mpeg'},
        ),
      ),
      directory: () async => directory,
      maxFileBytes: 1024,
    );
    addTearDown(cache.dispose);

    expect(await cache.resolve(_track(cacheAllowed: true)), isNull);
    expect(await directory.list().toList(), isEmpty);
  });
}

MusicTrack _track({required bool cacheAllowed}) => MusicTrack(
  trackId: 'track-a',
  provider: 'licensed_catalog',
  providerTrackId: 'provider-a',
  title: 'Safe preview',
  artist: 'Licensed artist',
  previewUrl: 'https://catalog.example/preview.mp3',
  previewDurationMs: 15000,
  licenseCode: 'COMMERCIAL',
  cacheAllowed: cacheAllowed,
);
