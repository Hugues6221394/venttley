import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Timestamps rendered in UTC instead of the reader's own time.
///
/// Found on device: a tribe message sent at 09:58 local displayed **7:57 AM**.
/// Postgres `timestamptz` reaches the client as `...+00:00`, `DateTime.parse`
/// returns that as a UTC DateTime, and `DateFormat.format()` renders a value in
/// its own zone — so every server-loaded timestamp was shown two hours behind
/// in Kigali, and further out the further a user is from UTC.
///
/// It hid for two reasons.
///
/// First, the optimistic copy of a just-sent message is built with
/// `DateTime.now()`, which is local, so the time looked right until the list
/// refreshed from the server and the message jumped backwards.
///
/// Second, relative times were never wrong. `Duration difference()` compares
/// absolute instants and ignores the zone flag, so "2h ago" was always correct
/// while "7:57 AM" beside it was not — which reads as a formatting quirk rather
/// than a bug.
///
/// The worse half was the date grouping. The chat divider and the inbox both
/// compared calendar fields — `.day`, `.weekday` — of a *local* `now` against a
/// *UTC* timestamp. At UTC+2 a message from 01:00 today is 23:00 UTC yesterday,
/// so it was filed under the previous day.
///
/// These are source assertions rather than widget tests on purpose: the defect
/// is "somebody formatted a server DateTime without converting it", and the
/// only way to catch the next instance is to check every call site. A widget
/// test would need the host machine to be in a non-UTC zone to fail at all,
/// which is precisely why CI would have stayed green.
void main() {
  final dartFiles = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  test('Dart itself behaves the way the fix assumes', () {
    // The premise, asserted rather than trusted: a timestamptz parses to UTC,
    // toLocal() is safe to apply twice, and difference() ignores the zone.
    final parsed = DateTime.parse('2026-09-06T07:57:12.000+00:00');
    expect(parsed.isUtc, isTrue);

    final now = DateTime.now();
    expect(
      now.difference(now.toUtc()).inSeconds,
      0,
      reason: 'difference() must compare instants, so relative times are fine',
    );
    expect(
      now.toLocal().toLocal(),
      now.toLocal(),
      reason: 'toLocal() must be idempotent, or applying it broadly is unsafe',
    );
  });

  test('no DateFormat formats a DateTime without converting it first', () {
    // `.format(x)` where x carries no `.toLocal()`. A local DateTime passed
    // through toLocal() is unchanged, so there is no cost to being uniform
    // here — and being uniform is what makes the rule checkable.
    final offenders = <String>[];
    final call = RegExp(r'\.format\(\s*([A-Za-z_][\w\.\[\]\x27"$]*)\s*\)');

    for (final file in dartFiles) {
      final lines = file.readAsStringSync().split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        for (final m in call.allMatches(line)) {
          final arg = m.group(1)!;
          // Already converted, or a fresh local now — both fine.
          if (arg.contains('toLocal')) continue;
          if (arg == 'now' || arg == 'DateTime.now()') continue;
          final window = line.substring(
            (m.start - 40).clamp(0, line.length),
            (m.end + 12).clamp(0, line.length),
          );
          if (window.contains('toLocal')) continue;
          // The argument may be a value that was already converted and
          // hoisted, which is the preferred shape wherever a timestamp is used
          // more than once. Accept it only on proof — an assignment of
          // `<arg> = <something>.toLocal()` earlier in the same file — rather
          // than on the variable being named something reassuring.
          final assigned = RegExp(
            '(final|var)\\s+' + RegExp.escape(arg) + r'\s*=\s*[^;]*toLocal\(\)',
          );
          if (lines
              .take(i)
              .any((earlier) => assigned.hasMatch(earlier))) {
            continue;
          }
          // Only DateFormat is in scope; NumberFormat.format(int) is not.
          if (!line.contains('DateFormat') &&
              !(i > 0 && lines[i - 1].contains('DateFormat'))) {
            continue;
          }
          offenders.add('${file.path}:${i + 1}  $arg');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These render a server timestamp in UTC to a reader who is not in '
          'UTC. Add .toLocal() before formatting:\n  ${offenders.join('\n  ')}',
    );
  });

  test('the chat divider and the inbox group dates in one zone', () {
    // The two places that read calendar fields off a server timestamp. Both
    // convert once, up front, and every later comparison uses that value —
    // converting inside the DateFormat call alone would fix the label while
    // leaving the Today/Yesterday decision wrong.
    final divider = File(
      'lib/presentation/screens/tribes/tribe_chat_screen.dart',
    ).readAsStringSync();
    expect(divider, contains('final local = when.toLocal();'));
    expect(
      divider,
      isNot(contains('now.day == when.day')),
      reason: 'comparing a local now against a UTC when is the bug',
    );

    final inbox = File(
      'lib/presentation/screens/inbox/inbox_screen.dart',
    ).readAsStringSync();
    expect(inbox, contains('final local = timestamp.toLocal();'));
    expect(
      inbox,
      isNot(contains('now.day == timestamp.day')),
      reason: 'same comparison, same bug, different screen',
    );
    expect(
      inbox,
      isNot(contains('days[timestamp.weekday - 1]')),
      reason: 'the weekday must come from the local value',
    );
  });

  test('day boundaries are computed in local time, not UTC', () {
    // The instance the first sweep missed, and the reason it missed it: this
    // compares two server timestamps against EACH OTHER. There is no local
    // `now` for a UTC value to disagree with, so two wrong values produce a
    // confidently wrong answer and nothing looks suspicious.
    //
    // Comparing UTC dates puts the divider at UTC midnight — 02:00 for a
    // reader at UTC+2, 14:00 at UTC-10 — so a "Tuesday" divider landed in the
    // middle of Monday night. It also has to agree with _DateDivider, which
    // now picks its label from the local date; a divider that says one day and
    // appears on another is worse than either bug alone.
    final chat = File(
      'lib/presentation/screens/tribes/tribe_chat_screen.dart',
    ).readAsStringSync();

    expect(chat, contains('final left = a.createdAt.toLocal();'));
    expect(chat, contains('final right = b.createdAt.toLocal();'));
    expect(
      chat,
      isNot(contains('a.createdAt.day != b.createdAt.day')),
      reason: 'comparing two UTC dates draws the divider at UTC midnight',
    );
  });

  test('a recording that captured nothing says so', () {
    // `if (result == null || result.bytes.isEmpty) return;` — the recording bar
    // vanished, no message appeared, and nothing was said. Reproduced on a
    // simulator, which has no microphone; the same path runs on a real device
    // when mic permission is denied or the recorder never started.
    final chat = File(
      'lib/presentation/screens/tribes/tribe_chat_screen.dart',
    ).readAsStringSync();

    final silent = RegExp(
      r'result\s*==\s*null\s*\|\|\s*result\.bytes\.isEmpty\)\s*return;',
    );
    expect(
      silent.hasMatch(chat),
      isFalse,
      reason: 'a failed recording must explain itself, not disappear',
    );
    expect(chat, contains("didn't capture any audio"));
  });
}
