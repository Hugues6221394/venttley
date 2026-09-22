import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Screens written light-first, found one at a time.
//
/// The shape is always identical: a hardcoded white surface — `Colors.white`
/// as a BoxDecoration fill, a Material colour, or an input fillColor — with
/// `context.ink` drawn on it. `context.ink` is an off-white on the dark
/// themes, so the card comes out white-on-white: perfect in light, invisible
/// in dark.
//
/// It was the welcome trust panel, then the story composer, then Discover and
/// the whisper composer. Each was reported separately as "this looks faint",
/// and each needed the same one-line answer, because nobody was checking.
//
/// This checks. It is scoped to the screens that have been swept rather than
/// to all of lib/presentation, because a hardcoded white is *correct* in
/// plenty of places — on artwork, on a black scrim, on a berry fill, and
/// throughout the immersive whisper player, where the surface is the same
/// colour whatever theme the app is in. A blanket ban would be wrong and
/// would get switched off. This list grows as the sweep does.
const _swept = <String>[
  'lib/presentation/screens/compose/compose_screen.dart',
  'lib/presentation/screens/compose/create_story_screen.dart',
  'lib/presentation/screens/discover/discover_screen.dart',
  'lib/presentation/screens/feed/story_viewer_screen.dart',
  'lib/presentation/screens/friends/friend_profile_screen.dart',
  'lib/presentation/screens/onboarding/welcome_screen.dart',
  'lib/presentation/screens/plugz/plug_dashboard_screen.dart',
  'lib/presentation/screens/plugz/plug_profile_screen.dart',
  'lib/presentation/screens/profile/active_devices_screen.dart',
  'lib/presentation/screens/profile/password_security_screen.dart',
  'lib/presentation/screens/profile/profile_overview.dart',
  'lib/presentation/screens/profile/security_check_screen.dart',
  'lib/presentation/screens/profile/security_screen.dart',
  'lib/presentation/screens/tribes/space_home_screen.dart',
  'lib/presentation/screens/tribes/tribe_chat_hub_screen.dart',
  'lib/presentation/screens/tribes/tribe_chat_screen.dart',
  'lib/presentation/screens/tribes/tribe_detail_screen.dart',
  'lib/presentation/screens/tribes/tribe_moderation_screen.dart',
  'lib/presentation/screens/whispers/create_whisper_screen.dart',
  'lib/presentation/widgets/compact_kpi_strip.dart',
  'lib/presentation/widgets/daily_prompt_card.dart',
  'lib/presentation/widgets/keeper_action_center.dart',
  'lib/presentation/widgets/quick_create_sheet.dart',
  'lib/presentation/widgets/vently_empty_state.dart',
];

// Reviewed and deliberately left alone, with the reason, so the next person
// through does not "finish" the sweep by breaking them.
//
//   app_theme.dart        the light theme's own definition of white
//   skeleton.dart         shimmer masks — Shimmer.fromColors paints them,
//                         and its base and highlight are already theme-aware
//   friends_screen        the QR plate; a code needs a light quiet zone or it
//                         does not scan
//   profile_overview      the disc carrying the Venttly mark, and the badge
//                         medallion behind an emoji — plates for artwork
//   story_viewer          six overlays on somebody's photo or video
//   whispers_screen       the immersive player: 54 of its 55 whites, three
//                         of them opaque play buttons. Its one real card —
//                         the reaction sheet — is fixed, but the file cannot
//                         join the list above without exempting the player
//   popular_whispers_rail, whisper_carousel_tile — overlays on artwork
//   compose_screen        the LIVE PREVIEW disc, on the coloured preview


void main() {
  test('swept screens do not paint surfaces white by hand', () {
    final offenders = <String>[];

    for (final path in _swept) {
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: '$path has moved or gone');
      final lines = file.readAsStringSync().split('\n');

      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();

        // A fill, not a foreground: the line that opens a decoration, or an
        // input's fill. Text and icons name their colour inside TextStyle(…)
        // and Icon(…), which this deliberately does not match.
        final isFill =
            line == 'color: Colors.white,' &&
            _previousCode(lines, i).endsWith('BoxDecoration(');
        final isInputFill = line.startsWith('fillColor: Colors.white');
        final isMaterial = line.startsWith('color: Colors.white') &&
            _previousCode(lines, i).endsWith('Material(');

        if (isFill || isInputFill || isMaterial) {
          offenders.add('$path:${i + 1}  ${lines[i].trim()}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'these paint a surface white regardless of theme, and the ink drawn '
          'on them comes from the theme — which is white-on-white in dark:\n'
          '${offenders.join('\n')}',
    );
  });
}

/// The last line above [i] that is not blank and not a comment.
String _previousCode(List<String> lines, int i) {
  for (var j = i - 1; j >= 0; j--) {
    final line = lines[j].trim();
    if (line.isEmpty || line.startsWith('//')) continue;
    return line;
  }
  return '';
}
