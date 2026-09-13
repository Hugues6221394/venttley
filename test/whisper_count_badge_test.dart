// The Whispers rail badge counts Whispers, not plays.
//
// Reported from the device: the badge read "473" beside three Whispers, and
// publishing a new one moved it to 474 — a number that looked invented and
// barely responded.
//
// It was not hardcoded. It was `whispers.fold(0, (sum, w) => sum + w.playsCount)`
// over whatever the rail had loaded, and the seeded demo rows carry inflated
// play counts: 128 + 256 + 89 is exactly 473. A real number, measuring the
// wrong thing, in a place the label implied something else.
//
// Two separate defects, and this pins both:
//
//   1. it summed plays rather than counting Whispers
//   2. it summed only the loaded page, so it could never exceed the rail's
//      own limit no matter how large the library grew

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/presentation/widgets/popular_whispers_rail.dart';

Whisper _whisper(String id, int plays) => Whisper(
  whisperId: id,
  authorPseudonym: 'demo_$id',
  authorAvatarSeed: 'seed-$id',
  audioUrl: 'https://example.test/$id.m4a',
  audioDurationSeconds: 30,
  voiceFilter: 'original',
  category: 'vent_zone',
  playsCount: plays,
  likesCount: 0,
  commentsCount: 0,
  createdAt: DateTime(2026, 9, 13),
);

Future<void> _pump(
  WidgetTester tester, {
  required List<Whisper> whispers,
  required int total,
}) async {
  // A phone-sized surface. The default 800x600 test window makes the carousel
  // tile overflow, which fails the test for a reason unrelated to the badge.
  await tester.binding.setSurfaceSize(const Size(402, 874));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        popularWhispersProvider.overrideWith((ref) async => whispers),
        whisperTotalProvider.overrideWith((ref) async => total),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: PopularWhispersRail()),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('shows the Whisper count, not the sum of plays', (tester) async {
    // The exact numbers from the report: three Whispers whose plays add to 473.
    await _pump(
      tester,
      whispers: [_whisper('a', 128), _whisper('b', 256), _whisper('c', 89)],
      total: 3,
    );

    expect(find.text('3'), findsWidgets, reason: 'the badge shows how many Whispers exist');
    expect(
      find.text('473'),
      findsNothing,
      reason: 'the sum of play counts must not be presented as a Whisper count',
    );
  });

  testWidgets('reports the database total, not the size of the loaded page', (
    tester,
  ) async {
    // The rail loads at most a couple of dozen; the library is larger. Summing
    // or counting what is loaded would report the page size forever.
    await _pump(
      tester,
      whispers: [_whisper('a', 5), _whisper('b', 5)],
      total: 1284,
    );

    expect(find.text('1.3k'), findsWidgets,
        reason: 'the total comes from the database, not from the two rows on screen');
    expect(find.text('2'), findsNothing,
        reason: 'the loaded page size is not the total');
  });

  testWidgets('hides the badge rather than showing a zero or a guess', (
    tester,
  ) async {
    await _pump(tester, whispers: [_whisper('a', 40)], total: 0);
    expect(find.text('0'), findsNothing);
  });
}
