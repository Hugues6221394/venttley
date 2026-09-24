import 'dart:typed_data';

/// Raised when upload bytes are not a real image, regardless of the
/// filename or Content-Type the client claimed.
class UnsupportedImageFormatException implements Exception {
  const UnsupportedImageFormatException(this.reason);
  final String reason;

  @override
  String toString() => 'UnsupportedImageFormatException: $reason';
}

/// What the first bytes of a file actually are, not what the picker named it.
enum DetectedImageKind { jpeg, png, gif, webp, heic }

/// Identifies an image from its magic bytes.
///
/// Storage MIME allowlists are a courtesy. A renamed `.exe` or a PDF with a
/// `.jpg` extension still has to be refused here, or the allowlist is theatre.
DetectedImageKind? detectImageKind(Uint8List bytes) {
  if (bytes.length < 12) return null;
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return DetectedImageKind.jpeg;
  }
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A) {
    return DetectedImageKind.png;
  }
  if (bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return DetectedImageKind.gif;
  }
  if (bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return DetectedImageKind.webp;
  }
  // HEIC/HEIF: ISO-BMFF with a brand at offset 8.
  if (bytes[4] == 0x66 &&
      bytes[5] == 0x74 &&
      bytes[6] == 0x79 &&
      bytes[7] == 0x70) {
    final brand = String.fromCharCodes(bytes.sublist(8, 12));
    if (brand.startsWith('heic') ||
        brand.startsWith('heix') ||
        brand.startsWith('mif1') ||
        brand.startsWith('msf1') ||
        brand.startsWith('heif')) {
      return DetectedImageKind.heic;
    }
  }
  return null;
}

/// Rejects a payload that is not a supported image, or that is too small
/// to be one. Size caps stay on the bucket; this is the type check.
void assertSupportedImage(Uint8List bytes) {
  if (bytes.length < 32) {
    throw const UnsupportedImageFormatException(
      'That file is too small to be an image.',
    );
  }
  if (detectImageKind(bytes) == null) {
    throw const UnsupportedImageFormatException(
      'That file is not a JPEG, PNG, GIF, WebP or HEIC image.',
    );
  }
}

/// Raised when upload bytes are not a real video.
class UnsupportedVideoFormatException implements Exception {
  const UnsupportedVideoFormatException(this.reason);
  final String reason;

  @override
  String toString() => 'UnsupportedVideoFormatException: $reason';
}

/// Rejects a payload that is not an MP4 or QuickTime file.
///
/// Deliberately separate from [assertSupportedImage] rather than folded into
/// it. An `ftyp` box with brand `isom` or `qt  ` is not a HEIC, so a clip
/// would be refused by the image check — and letting the two share a function
/// would mean an image upload silently starting to accept videos.
void assertSupportedVideo(Uint8List bytes) {
  if (bytes.length < 32) {
    throw const UnsupportedVideoFormatException(
      'That file is too small to be a video.',
    );
  }
  // Every ISO base media file — MP4, M4V, MOV — opens with an `ftyp` box, so
  // the type sits at offset 4 rather than at 0.
  final isIsoBmff =
      bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70;
  if (!isIsoBmff) {
    throw const UnsupportedVideoFormatException(
      'That file is not an MP4 or QuickTime video.',
    );
  }
}
