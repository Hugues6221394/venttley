import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pushing a shell-owned route from a root-navigator screen crashes.
///
/// GoRouter's StatefulShellRoute reserves a navigator key per branch. Entering
/// a shell route while already outside the shell reserves those keys a second
/// time and trips
///
///   'package:flutter/src/widgets/navigator.dart': Failed assertion:
///   '!keyReservation.contains(key)': is not true.
///
/// which a user sees as "This part of Venttly didn't load". It has now been
/// reported three times, as three unrelated-looking bugs: a profile opened
/// from a space chat, an @mention tapped in a conversation, and "Full tribe
/// manage" from a chat hub's info page.
///
/// `go` is exempt and always was: it replaces the stack, so the shell is
/// rebuilt rather than re-entered. Only `push` reserves on top of a live
/// reservation.
///
/// The fix in each case is a root-level twin — /user-preview, /post-preview,
/// /manage-preview, /settings-preview — and this is what stops the fourth
/// report.
const _rootScreens = <String>[
  'lib/presentation/screens/tribes/tribe_chat_screen.dart',
  'lib/presentation/screens/tribes/tribe_chat_hub_screen.dart',
  'lib/presentation/screens/inbox/group_chat_settings_screen.dart',
  'lib/presentation/screens/compose/create_story_screen.dart',
  'lib/presentation/screens/whispers/create_whisper_screen.dart',
  'lib/presentation/screens/feed/story_viewer_screen.dart',
  'lib/presentation/screens/settings/verification_screen.dart',
  'lib/presentation/screens/settings/appeals_screen.dart',
];

/// Prefixes the shell owns. A route under one of these is inside the branch.
const _shellOwned = <String>[
  '/feed', '/friends', '/discover', '/tribes', '/post/', '/plug/',
  '/profile', '/keeper/', '/tribe/', '/questions', '/goals', '/user/',
  '/notifications', '/whispers', '/compose', '/inbox', '/settings',
  '/security-check',
];

/// Routes that live on the root navigator despite the prefix, so they are
/// fine to push from another root route.
///
/// Written with `:x` where the source interpolates, because that is what the
/// normaliser below turns `\${tribe.slug}` into. The chat and its hub are here
/// because both declare parentNavigatorKey: rootNavigatorKey — they look like
/// shell routes from their path alone and are not.
const _actuallyRoot = <String>[
  '/user-preview', '/post-preview', '/manage-preview', '/settings-preview',
  '/compose/story', '/whispers/new', '/settings/verification',
  '/settings/appeals', '/tribes/new',
  '/tribe/:x/chat',
];

/// `/tribe/\${tribe.slug}/chat/hub` -> `/tribe/:x/chat/hub`.
///
/// The first version of this stopped the match at the `\$`, so every
/// interpolated path collapsed to its prefix and the chat hub looked like an
/// ordinary /tribe/ route. It read as a real finding and was not one.
String _normalise(String raw) {
  final buffer = StringBuffer();
  var i = 0;
  while (i < raw.length) {
    if (raw.startsWith(r'${', i)) {
      var depth = 1;
      i += 2;
      while (i < raw.length && depth > 0) {
        if (raw[i] == '{') depth++;
        if (raw[i] == '}') depth--;
        i++;
      }
      buffer.write(':x');
      continue;
    }
    if (raw[i] == r'$') {
      i++;
      while (i < raw.length && RegExp(r'\w').hasMatch(raw[i])) {
        i++;
      }
      buffer.write(':x');
      continue;
    }
    buffer.write(raw[i]);
    i++;
  }
  return buffer.toString();
}

void main() {
  test('no root-navigator screen pushes a shell-owned route', () {
    final offenders = <String>[];
    final push = RegExp(
      r"""(?:context|router|GoRouter\.of\(context\))\s*\.\s*push\(\s*['"]([^'"]*)['"]""",
    );

    for (final path in _rootScreens) {
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: '$path has moved or gone');

      final lines = file.readAsStringSync().split('\n');
      for (var i = 0; i < lines.length; i++) {
        final match = push.firstMatch(lines[i]);
        if (match == null) continue;

        final target = _normalise(match.group(1)!);
        if (_actuallyRoot.any(target.startsWith)) continue;
        if (!_shellOwned.any(target.startsWith)) continue;

        offenders.add('$path:${i + 1}  ${lines[i].trim()}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'these push a shell-owned route from outside the shell, which '
          'reserves the branch navigator keys twice and throws:\n'
          '${offenders.join('\n')}',
    );
  });

  test('the root-level twins exist', () {
    // If one of these is renamed, the call sites above go back to pushing the
    // shell route and the test above starts passing for the wrong reason.
    final router = File(
      'lib/presentation/router/app_router.dart',
    ).readAsStringSync();

    for (final twin in const [
      "path: '/user-preview/:userId'",
      "path: '/post-preview/:id'",
      "path: '/manage-preview/:slug'",
      "path: '/settings-preview'",
    ]) {
      expect(router, contains(twin), reason: '$twin is gone');
    }
  });
}
