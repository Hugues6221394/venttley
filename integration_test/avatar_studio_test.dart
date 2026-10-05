// The avatar studio's save path, end to end, against a real Supabase stack.
//
// What nothing else covers: the studio flattens twenty-odd PNGs into one
// image, uploads it, and writes a config the server shape-checks. Each half is
// unit-tested — the catalogue agrees with the migration, the migration refuses
// what it should — and neither proves the two halves meet. This signs in, bakes
// a look, puts it through the real RPC and the real bucket, and fetches the
// result back over HTTP as a reader would.
//
// Deliberately NOT mock mode. It needs the live local stack:
//
//   supabase start
//   psql "$DB" -f supabase/seed/test_accounts.sql
//   flutter test integration_test/avatar_studio_test.dart -d <simulator-id> \
//     --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
//     --dart-define=SUPABASE_ANON_KEY=<local anon key>

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vently_app/domain/avatar/avatar_look.dart';
import 'package:vently_app/presentation/widgets/avatar_baker.dart';
import 'package:vently_app/presentation/widgets/avatar_look_view.dart';

const _url = String.fromEnvironment('SUPABASE_URL');
const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a look somebody builds becomes an avatar anybody can fetch', (
    tester,
  ) async {
    expect(
      _url.isNotEmpty && _anonKey.isNotEmpty,
      isTrue,
      reason:
          'Pass --dart-define=SUPABASE_URL and --dart-define=SUPABASE_ANON_KEY. '
          'This test talks to a real stack on purpose.',
    );

    await Supabase.initialize(url: _url, anonKey: _anonKey, debug: false);
    final client = Supabase.instance.client;
    await client.auth.signInWithPassword(
      email: 'tester_user@id.venttly.app',
      password: 'TestPass123!',
    );
    final uid = client.auth.currentUser?.id;
    expect(uid, isNotNull, reason: 'signed in');

    const look = AvatarLook(
      skin: 's02',
      hair: 'hair_07',
      hairTint: 'auburn',
      beard: 'beard_10',
      top: 'top_02',
      topTint: 'berry',
    );

    // 1. Flatten it. Done off the widget tree, so this is the same call the
    //    save button makes and not a screenshot of whatever was on screen.
    final png = await AvatarBaker.bake(look);
    expect(
      png.sublist(0, 8),
      [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
      reason: 'a PNG signature',
    );
    // Big enough to be a picture of somebody, small enough to send to a feed.
    expect(png.length, greaterThan(20 * 1024));
    expect(png.length, lessThan(400 * 1024));

    // 2. Upload and record it, the way the repository does.
    final path = '$uid/avatar-studio-test.png';
    await client.storage
        .from('profile-photos')
        .uploadBinary(
          path,
          png,
          fileOptions: const FileOptions(
            contentType: 'image/png',
            upsert: true,
          ),
        );
    final url = client.storage.from('profile-photos').getPublicUrl(path);
    final previous = await client.rpc(
      'set_avatar_config',
      params: {
        'p_config': look.toConfig(),
        'p_photo_url': url,
        'p_persona_id': null,
        'p_avatar_path': path,
      },
    );
    expect(previous, anyOf(isNull, isA<String>()));

    // 3. Read it back the way the studio does when it reopens.
    final row = await client
        .from('users')
        .select('avatar_config, profile_photo_url')
        .eq('user_id', uid!)
        .single();
    expect(AvatarLook.tryParse(row['avatar_config']), look);
    expect(row['profile_photo_url'], url);

    // 4. Fetch it as a stranger would — anonymous, over HTTP, from the public
    //    URL a feed row carries. The avatar being in the database is not the
    //    same as the avatar being visible.
    final stranger = SupabaseClient(_url, _anonKey);
    addTearDown(stranger.dispose);
    final fetched = await stranger.storage
        .from('profile-photos')
        .download(path);
    expect(fetched.length, png.length, reason: 'the bytes a reader gets back');

    // 5. And that the same look draws on screen from the bundled layers.
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: AvatarLookView(look: look, size: 200)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNWidgets(look.layers.length));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the server refuses a look the app would never build', (
    tester,
  ) async {
    await Supabase.initialize(url: _url, anonKey: _anonKey, debug: false);
    final client = Supabase.instance.client;
    await client.auth.signInWithPassword(
      email: 'tester_user@id.venttly.app',
      password: 'TestPass123!',
    );

    Future<void> expectRefused(Map<String, dynamic> config, String code) async {
      try {
        await client.rpc('set_avatar_config', params: {'p_config': config});
        fail('stored $config, which should have been refused');
      } on PostgrestException catch (e) {
        expect(e.message, contains(code));
      }
    }

    await expectRefused({
      'kind': 'custom',
      'skin': 'etc/passwd',
      'top': 'top_01',
      'hair_tint': 'black',
      'top_tint': 'white',
    }, 'invalid_avatar_skin');
    await expectRefused({
      'kind': 'custom',
      'skin': 's01',
      'top': 'top_01',
      'hair': '../../secrets',
      'hair_tint': 'black',
      'top_tint': 'white',
    }, 'invalid_avatar_hair');
    await expectRefused({'kind': 'nonsense'}, 'invalid_avatar_config');
    await expectRefused({
      'kind': 'custom',
      'skin': 's01',
      'top': 'top_01',
      'hair_tint': 'black',
      'top_tint': 'white',
      'junk': base64Encode(List.filled(900, 65)),
    }, 'invalid_avatar_config');
  });
}
