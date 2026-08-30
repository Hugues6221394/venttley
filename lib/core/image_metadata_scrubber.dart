import 'dart:typed_data';

/// Removes location and identifying metadata from image bytes before upload.
///
/// ## Why this exists
///
/// `image_picker` does **not** strip EXIF, and passing `maxWidth`/`maxHeight`/
/// `imageQuality` does not change that. On iOS the plugin reads the original
/// file's full metadata dictionary and copies it back into the rescaled output:
///
/// ```objc
/// metaData = [FLTImagePickerMetaDataUtil getMetaDataFromImageData:originalImageData];
/// // …scale…
/// NSData *updatedData = [FLTImagePickerMetaDataUtil imageFromImage:data withMetaData:metaData];
/// ```
///
/// `requestFullMetadata: false` does not help either: on the PHPicker path
/// (iOS 14+, i.e. every modern gallery pick) `processImage` calls
/// `saveImageWithOriginalImageData:` unconditionally and never consults the
/// flag. So an uploaded photo carries whatever the camera wrote — including
/// `GPSLatitude` / `GPSLongitude`.
///
/// On a platform whose entire promise is anonymity, and whose users include
/// 13–17 year olds, a vent photo that carries the coordinates of the bedroom it
/// was taken in is the most direct de-anonymisation vector in the product.
///
/// ## Why it strips rather than re-encodes
///
/// Decoding and re-encoding would also drop metadata, but it costs image
/// quality, CPU, and either a new dependency or a switch to PNG — and PNG for
/// photographs would multiply upload size on exactly the slow connections this
/// app is built for. EXIF lives in container segments *beside* the compressed
/// image data, so it can be removed by rewriting the container and leaving
/// every pixel byte untouched: lossless, no dependency, and smaller output.
///
/// ## What it keeps
///
/// JPEG APP0 (JFIF) and APP2 (ICC colour profile) survive, because dropping the
/// colour profile visibly shifts colours and neither segment carries anything
/// about the photographer. Everything else in the APPn range goes, which covers
/// EXIF and XMP (APP1) and IPTC/Photoshop blocks (APP13), plus free-text
/// comments (COM).
///
/// Unknown formats are returned unchanged rather than corrupted — the caller
/// gets bytes that still render. [wasScrubbed] reports whether anything was
/// actually removed, so a caller can log coverage instead of assuming it.
class ScrubbedImage {
  const ScrubbedImage({required this.bytes, required this.removedSegments});

  final Uint8List bytes;

  /// Human-readable names of what was dropped, for logging. Empty means the
  /// image carried no metadata worth removing (or is a format we leave alone).
  final List<String> removedSegments;

  bool get wasScrubbed => removedSegments.isNotEmpty;
}

/// JPEG markers that can carry identifying or location data.
///
/// APP1 is EXIF *and* XMP — both can hold GPS. APP13 is the Photoshop/IPTC
/// block, which has its own location fields. COM is a free-text comment some
/// cameras and editors fill with device or owner strings.
const Set<int> _jpegDropMarkers = {
  0xE1, // APP1  — EXIF, XMP
  0xE3, // APP3
  0xE4, // APP4
  0xE5, // APP5
  0xE6, // APP6
  0xE7, // APP7
  0xE8, // APP8
  0xE9, // APP9
  0xEA, // APP10
  0xEB, // APP11
  0xEC, // APP12
  0xED, // APP13 — Photoshop / IPTC
  0xEE, // APP14
  0xEF, // APP15
  0xFE, // COM   — free-text comment
};

/// PNG ancillary chunks that can carry metadata. `eXIf` is a full EXIF block;
/// the text chunks are commonly used for camera and software strings.
const Set<String> _pngDropChunks = {'eXIf', 'tEXt', 'iTXt', 'zTXt', 'tIME'};

ScrubbedImage scrubImageMetadata(Uint8List bytes) {
  if (_looksLikeJpeg(bytes)) return _scrubJpeg(bytes);
  if (_looksLikePng(bytes)) return _scrubPng(bytes);
  return ScrubbedImage(bytes: bytes, removedSegments: const []);
}

bool _looksLikeJpeg(Uint8List b) =>
    b.length > 3 && b[0] == 0xFF && b[1] == 0xD8;

bool _looksLikePng(Uint8List b) =>
    b.length > 8 &&
    b[0] == 0x89 &&
    b[1] == 0x50 &&
    b[2] == 0x4E &&
    b[3] == 0x47;

ScrubbedImage _scrubJpeg(Uint8List bytes) {
  final out = BytesBuilder(copy: false);
  final removed = <String>[];
  // SOI.
  out.add(bytes.sublist(0, 2));
  var i = 2;

  while (i + 3 < bytes.length) {
    if (bytes[i] != 0xFF) {
      // Not at a marker boundary — the file is malformed or we lost sync. Copy
      // the remainder verbatim rather than risk truncating image data.
      out.add(bytes.sublist(i));
      return ScrubbedImage(bytes: out.toBytes(), removedSegments: removed);
    }
    final marker = bytes[i + 1];

    // Start of Scan: everything after this is entropy-coded image data, which
    // contains no metadata and must not be parsed as segments.
    if (marker == 0xDA) {
      out.add(bytes.sublist(i));
      return ScrubbedImage(bytes: out.toBytes(), removedSegments: removed);
    }

    // Standalone markers carry no length field.
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD9)) {
      out.add(bytes.sublist(i, i + 2));
      i += 2;
      continue;
    }

    final length = (bytes[i + 2] << 8) | bytes[i + 3];
    if (length < 2 || i + 2 + length > bytes.length) {
      // Truncated segment. Copy what is left and stop.
      out.add(bytes.sublist(i));
      return ScrubbedImage(bytes: out.toBytes(), removedSegments: removed);
    }

    if (_jpegDropMarkers.contains(marker)) {
      removed.add(_jpegMarkerName(marker));
    } else {
      out.add(bytes.sublist(i, i + 2 + length));
    }
    i += 2 + length;
  }

  if (i < bytes.length) out.add(bytes.sublist(i));
  return ScrubbedImage(bytes: out.toBytes(), removedSegments: removed);
}

String _jpegMarkerName(int marker) {
  if (marker == 0xFE) return 'COM';
  if (marker == 0xE1) return 'APP1(EXIF/XMP)';
  if (marker == 0xED) return 'APP13(IPTC)';
  return 'APP${marker - 0xE0}';
}

ScrubbedImage _scrubPng(Uint8List bytes) {
  final out = BytesBuilder(copy: false);
  final removed = <String>[];
  out.add(bytes.sublist(0, 8)); // signature
  var i = 8;

  while (i + 8 <= bytes.length) {
    final length =
        (bytes[i] << 24) |
        (bytes[i + 1] << 16) |
        (bytes[i + 2] << 8) |
        bytes[i + 3];
    if (length < 0 || i + 12 + length > bytes.length) {
      out.add(bytes.sublist(i));
      return ScrubbedImage(bytes: out.toBytes(), removedSegments: removed);
    }
    final type = String.fromCharCodes(bytes.sublist(i + 4, i + 8));
    final chunkEnd = i + 12 + length; // length + type + data + CRC

    if (_pngDropChunks.contains(type)) {
      removed.add(type);
    } else {
      out.add(bytes.sublist(i, chunkEnd));
    }
    i = chunkEnd;
    if (type == 'IEND') break;
  }

  return ScrubbedImage(bytes: out.toBytes(), removedSegments: removed);
}
