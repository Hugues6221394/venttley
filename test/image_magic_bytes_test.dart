import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/image_magic_bytes.dart';

Uint8List _pad(List<int> head, {int length = 64}) {
  final out = Uint8List(length);
  out.setRange(0, head.length, head);
  return out;
}

void main() {
  test('JPEG / PNG / GIF / WebP / HEIC are recognised from bytes', () {
    expect(
      detectImageKind(_pad([0xFF, 0xD8, 0xFF, 0xE0])),
      DetectedImageKind.jpeg,
    );
    expect(
      detectImageKind(
        _pad([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
      ),
      DetectedImageKind.png,
    );
    expect(
      detectImageKind(_pad([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])),
      DetectedImageKind.gif,
    );
    expect(
      detectImageKind(
        _pad([
          0x52,
          0x49,
          0x46,
          0x46,
          0,
          0,
          0,
          0,
          0x57,
          0x45,
          0x42,
          0x50,
        ]),
      ),
      DetectedImageKind.webp,
    );
    final heic = _pad([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63]);
    expect(detectImageKind(heic), DetectedImageKind.heic);
  });

  test('a renamed executable is not an image', () {
    final exe = _pad([0x4D, 0x5A]); // MZ
    expect(detectImageKind(exe), isNull);
    expect(
      () => assertSupportedImage(exe),
      throwsA(isA<UnsupportedImageFormatException>()),
    );
  });

  test('too-small payloads are rejected before the kind check', () {
    expect(
      () => assertSupportedImage(Uint8List.fromList([0xFF, 0xD8, 0xFF])),
      throwsA(isA<UnsupportedImageFormatException>()),
    );
  });

  test('audio-looking bytes are not treated as images', () {
    final ftyp = _pad([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20]);
    expect(detectImageKind(ftyp), isNull);
  });
}
