import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/image_magic_bytes.dart';
import 'package:vently_app/data/services/tribe_image_picker.dart';

/// A minimal but genuinely valid JPEG header, so `assertSupportedImage` sees
/// real magic bytes rather than a string that happens to be long enough.
Uint8List _jpeg({int padTo = 64}) {
  final bytes = <int>[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01];
  while (bytes.length < padTo) {
    bytes.add(0x20);
  }
  return Uint8List.fromList(bytes);
}

void main() {
  group('TribeImageKind', () {
    test('avatar and banner differ in every dimension rule', () {
      // The old code used one `uploadTribeAvatar` for both, so neither had
      // rules of its own — a rectangular photo became a squashed avatar.
      expect(TribeImageKind.avatar.ratio, (1, 1));
      expect(TribeImageKind.banner.ratio, (16, 9));
      expect(
        TribeImageKind.banner.maxEdge,
        greaterThan(TribeImageKind.avatar.maxEdge),
        reason: 'a banner spans the screen; an avatar is drawn at 46pt',
      );
      expect(TribeImageKind.banner.isBanner, isTrue);
      expect(TribeImageKind.avatar.isBanner, isFalse);
    });

    test('the labels read naturally in a sentence', () {
      // These land inside "Remove this …?" and "Crop …", so a label like
      // "avatar" would read as jargon to a member.
      expect(TribeImageKind.avatar.label, 'picture');
      expect(TribeImageKind.banner.label, 'banner');
    });
  });

  group('the upload ceiling', () {
    test('sits below the bucket limit, not at it', () {
      // The bucket allows 20 MB. A client that only relied on that would make
      // somebody wait for a 20 MB upload before being told no.
      expect(TribeImagePicker.maxUploadBytes, 6 * 1024 * 1024);
      expect(TribeImagePicker.maxUploadBytes, lessThan(20 * 1024 * 1024));
    });
  });

  group('bytes are trusted over filenames', () {
    test('a real JPEG passes the magic-byte check', () {
      expect(() => assertSupportedImage(_jpeg()), returnsNormally);
    });

    test('a renamed non-image is refused however it is named', () {
      // The bucket's MIME allowlist is a courtesy the client can be told to
      // skip; this is the check that actually holds.
      final pdf = Uint8List.fromList([
        0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37,
        ...List<int>.filled(56, 0x20),
      ]);
      expect(
        () => assertSupportedImage(pdf),
        throwsA(isA<UnsupportedImageFormatException>()),
      );
    });

    test('a file too small to be an image is refused', () {
      expect(
        () => assertSupportedImage(Uint8List.fromList([0xFF, 0xD8, 0xFF])),
        throwsA(isA<UnsupportedImageFormatException>()),
      );
    });
  });

  group('the path shape the client builds', () {
    // These have to agree with `private.is_tribe_image_path` in
    // 20261016090000. A path the policy rejects produces an opaque 403 that
    // looks exactly like an authorization failure, which is how the original
    // bug was misdiagnosed for two sessions.
    final backend = File(
      'lib/data/services/supabase_backend.dart',
    ).readAsStringSync();

    test('the stable path is tribes/<id>/avatar|banner', () {
      expect(
        backend,
        contains(r"final stablePath = 'tribes/$tribeId/$kind.$safeExt';"),
      );
      expect(backend, contains("final kind = banner ? 'banner' : 'avatar';"));
    });

    test('the extension allowlist matches the policy regex', () {
      // The policy accepts exactly these. Anything else is normalised to jpg
      // here rather than discovered as a 403 at the server.
      for (final ext in const [
        'jpg',
        'jpeg',
        'png',
        'webp',
        'heic',
        'heif',
        'gif',
      ]) {
        expect(
          backend,
          contains("'$ext'"),
          reason: '$ext is in the policy regex and must be accepted here',
        );
      }
      expect(
        backend,
        contains("if (!_tribeImageExtensions.contains(safeExt)) safeExt = 'jpg';"),
      );
    });

    test('replacement upserts, because the key is fixed', () {
      // A stable key means the second upload is an UPDATE. Without upsert it
      // would collide; without the policy's UPDATE arm it would 403.
      expect(backend, contains('upsert: true'));
    });

    test('the returned URL is cache-busted', () {
      // The consequence of a stable path: the public URL no longer changes
      // when the image does, so without a version the CDN keeps serving the
      // old picture and the change looks like it silently failed.
      expect(backend, contains('_bustedPublicUrl'));
      expect(backend, contains(r"'$base&v=$stamp' : '$base?v=$stamp'"));
    });

    test('the legacy fallback is present, scoped, and labelled removable', () {
      // It exists only because 20261016090000 is past the production
      // migration boundary. It must fire on a policy refusal and nothing
      // else, or a network blip would silently downgrade the path.
      expect(backend, contains('_looksLikePolicyRefusal'));
      expect(backend, contains('tribe.media_stable_path_refused'));
      expect(
        backend,
        contains('Delete this branch'),
        reason: 'the fallback has to say when it stops being needed',
      );
    });
  });

  group('removal takes the file down, not just the reference', () {
    final backend = File(
      'lib/data/services/supabase_backend.dart',
    ).readAsStringSync();
    final editScreen = File(
      'lib/presentation/screens/tribes/edit_tribe_screen.dart',
    ).readAsStringSync();

    test('every candidate extension is removed', () {
      // The column holds a URL, not an extension, so the object could have
      // been stored under any of the accepted ones.
      expect(backend, contains('removeTribeImage'));
      expect(
        backend,
        contains("for (final ext in _tribeImageExtensions) 'tribes/\$tribeId/\$kind.\$ext'"),
      );
    });

    test('the column is cleared with an empty string, not null', () {
      // update_tribe_configuration treats null as "leave unchanged" and ''
      // as "clear". Passing null here would make Remove appear to do nothing.
      expect(editScreen, contains("avatarUrl: banner ? null : ''"));
      expect(editScreen, contains("bannerUrl: banner ? '' : null"));
    });

    test('removal is confirmed first', () {
      expect(editScreen, contains('Remove this \${kind.label}?'));
    });

    test('a failed object delete still clears the column', () {
      // The visible outcome the keeper asked for is that the Tribe stops
      // showing the picture. Refusing to clear the column because the file
      // delete failed would leave them unable to take an image down at all.
      expect(backend, contains('tribe.media_remove_failed'));
    });
  });

  group('one pipeline, not three', () {
    test('no tribe screen calls ImagePicker directly any more', () {
      // create_tribe_screen, edit_tribe_screen and tribe_chat_hub_screen each
      // had their own picker call; only two checked the file size at all, and
      // none offered a crop.
      final offenders = <String>[];
      for (final entity in Directory(
        'lib/presentation/screens/tribes',
      ).listSync()) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final src = entity.readAsStringSync();
        // Scoped to files that set a *Tribe image*. tribe_chat_screen picks
        // media for chat messages, which is a different feature, a different
        // bucket, and none of this pipeline's business.
        if (!src.contains('uploadTribeImage')) continue;
        // `TribeImagePicker()` contains this substring, so match the bare
        // constructor only.
        if (RegExp(r'(?<!Tribe)ImagePicker\(\)').hasMatch(src)) {
          offenders.add(entity.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'These pick images without the shared crop/compress/validate '
            'pipeline, so their rules will drift: $offenders',
      );
    });

    test('the content type is derived from bytes, not from a filename', () {
      // Both screens used to guess it from the extension, which is how a HEIC
      // ends up declared as image/jpeg.
      for (final path in const [
        'lib/presentation/screens/tribes/create_tribe_screen.dart',
        'lib/presentation/screens/tribes/edit_tribe_screen.dart',
      ]) {
        final src = File(path).readAsStringSync();
        expect(
          src,
          isNot(contains('String _contentType(String extension)')),
          reason: '$path still guesses a MIME type from a filename',
        );
      }
    });
  });

  group('the Android side of the cropper', () {
    test('UCropActivity is declared', () {
      // Missing, this throws ActivityNotFoundException at runtime rather than
      // failing the build — so it is easy to ship broken.
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(manifest, contains('com.yalantis.ucrop.UCropActivity'));
      expect(manifest, contains('Theme.AppCompat.Light.NoActionBar'));
    });
  });
}
