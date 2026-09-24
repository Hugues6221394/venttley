import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/image_magic_bytes.dart';
import 'package:vently_app/core/video_metadata_scrubber.dart';

/// Taking the location out of a clip.
///
/// The image scrubber's own notes call a photo's GPS tag the most direct
/// de-anonymisation vector in the product. An MP4 carries the same thing in
/// moov/udta/©xyz — an iPhone writes an ISO-6709 string there on every
/// recording — and the image scrubber passes video through untouched, because
/// it recognises JPEG and PNG and nothing else. Shipping video without this
/// would have reopened the hole the image path exists to close.

/// One ISO base media box: [4-byte size][4-byte type][payload].
Uint8List _box(String type, List<int> payload) {
  final size = 8 + payload.length;
  return Uint8List.fromList([
    (size >> 24) & 0xFF,
    (size >> 16) & 0xFF,
    (size >> 8) & 0xFF,
    size & 0xFF,
    ...type.codeUnits,
    ...payload,
  ]);
}

String _typeAt(Uint8List bytes, int offset) =>
    String.fromCharCodes(bytes, offset + 4, offset + 8);

void main() {
  final ftyp = _box('ftyp', 'isom'.codeUnits + List.filled(8, 0));

  test('a clip carrying a location loses it', () {
    // ©xyz is the box an iPhone writes the coordinates into.
    final gps = _box('©xyz', '+51.5074-000.1278/'.codeUnits);
    final udta = _box('udta', gps);
    final moov = _box('moov', udta);
    final input = Uint8List.fromList([...ftyp, ...moov]);

    final out = scrubVideoMetadata(input);

    expect(out.removedBoxes, contains('udta'));
    expect(
      String.fromCharCodes(out.bytes),
      isNot(contains('+51.5074')),
      reason: 'the coordinates have to actually be gone, not just unreferenced',
    );
  });

  test('the file does not change length', () {
    // The obvious fix — drop the box and shrink its parents — corrupts any
    // file where moov precedes mdat, because stco/co64 hold absolute offsets
    // into mdat and every one of them would then point at the wrong place.
    // So the box keeps its length and becomes `free`, which the format
    // defines as ignorable padding.
    final udta = _box('udta', List.filled(40, 7));
    final moov = _box('moov', udta);
    final mdat = _box('mdat', List.filled(64, 3));
    final input = Uint8List.fromList([...ftyp, ...moov, ...mdat]);

    final out = scrubVideoMetadata(input);

    expect(out.bytes.length, input.length);
    expect(_typeAt(out.bytes, ftyp.length + 8), 'free');
  });

  test('the video data itself is untouched', () {
    final udta = _box('udta', List.filled(16, 9));
    final moov = _box('moov', udta);
    final payload = List.generate(96, (i) => (i * 7) % 256);
    final mdat = _box('mdat', payload);
    final input = Uint8List.fromList([...ftyp, ...moov, ...mdat]);

    final out = scrubVideoMetadata(input);

    final start = ftyp.length + moov.length + 8;
    expect(out.bytes.sublist(start, start + payload.length), payload);
    expect(_typeAt(out.bytes, ftyp.length + moov.length), 'mdat');
  });

  test('a top-level uuid box goes too', () {
    // Apple and GoPro both use uuid for maker notes, which have carried GPS.
    final input = Uint8List.fromList([
      ...ftyp,
      ..._box('uuid', List.filled(24, 1)),
    ]);

    final out = scrubVideoMetadata(input);

    expect(out.removedBoxes, contains('uuid'));
    expect(out.bytes.length, input.length);
  });

  test('something that is not a video comes back untouched', () {
    // Same contract as the image scrubber: formats it does not know are left
    // alone rather than mangled.
    final notVideo = Uint8List.fromList(List.generate(64, (i) => i));
    final out = scrubVideoMetadata(notVideo);

    expect(out.bytes, notVideo);
    expect(out.removedBoxes, isEmpty);
  });

  test('a truncated file is left alone rather than mangled', () {
    // A box claiming more bytes than exist. Better to upload something
    // unscrubbed than to hand back a corrupted file — the magic-byte check
    // still has to pass either way.
    final input = Uint8List.fromList([
      ...ftyp,
      0x00, 0x00, 0xFF, 0xFF, // a box claiming 65535 bytes
      ...'udta'.codeUnits,
      1, 2, 3, 4,
    ]);

    final out = scrubVideoMetadata(input);

    expect(out.removedBoxes, isEmpty);
    expect(out.bytes.length, input.length);
  });

  group('the type check', () {
    test('accepts an MP4 and a MOV', () {
      expect(
        () => assertSupportedVideo(
          Uint8List.fromList([...ftyp, ...List.filled(32, 0)]),
        ),
        returnsNormally,
      );
    });

    test('refuses a JPEG renamed to mp4', () {
      // Filename and Content-Type are claims. An allowlist that trusts them is
      // theatre — the same reasoning as assertSupportedImage.
      final jpeg = Uint8List.fromList([
        0xFF, 0xD8, 0xFF, 0xE0,
        ...List.filled(40, 0),
      ]);
      expect(
        () => assertSupportedVideo(jpeg),
        throwsA(isA<UnsupportedVideoFormatException>()),
      );
    });

    test('refuses something too small to be anything', () {
      expect(
        () => assertSupportedVideo(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<UnsupportedVideoFormatException>()),
      );
    });

    test('and the image check still refuses a video', () {
      // The two are separate functions on purpose: folding them together
      // would mean an image upload quietly starting to accept clips.
      expect(
        () => assertSupportedImage(
          Uint8List.fromList([...ftyp, ...List.filled(32, 0)]),
        ),
        throwsA(isA<UnsupportedImageFormatException>()),
      );
    });
  });
}
