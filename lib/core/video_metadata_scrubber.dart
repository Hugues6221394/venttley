import 'dart:typed_data';

/// Taking the location out of a clip before it is uploaded.
///
/// [scrubImageMetadata] exists because a photo straight off a camera carries
/// `GPSLatitude` / `GPSLongitude`, and its own notes call that the most direct
/// de-anonymisation vector in a product whose entire promise is anonymity. An
/// MP4 carries exactly the same thing, in `moov/udta/©xyz` — an iPhone writes
/// an ISO-6709 string there on every recording — and the image scrubber passes
/// a video through untouched, because it recognises JPEG and PNG and nothing
/// else. Shipping video without this would have opened the hole the image path
/// was built to close.
///
/// ## Why it blanks boxes instead of removing them
///
/// The obvious approach — drop the `udta` box and shrink its parents — breaks
/// the file whenever `moov` precedes `mdat`, which is what `+faststart` output
/// and most phone recordings look like. `stco` / `co64` hold absolute byte
/// offsets into `mdat`; move `moov` by a single byte and every one of them
/// points at the wrong place.
///
/// So the box keeps its exact length and is rewritten in place as `free`,
/// which the ISO base media format defines as ignorable padding, with its
/// payload zeroed. Nothing moves, every offset stays valid, and the bytes are
/// gone. The file is a few kilobytes larger than a true strip would leave it,
/// which is a trade worth making for not corrupting anybody's video.
class ScrubbedVideo {
  const ScrubbedVideo({required this.bytes, required this.removedBoxes});

  final Uint8List bytes;

  /// Which box types were blanked. Logged, not shown — useful when somebody
  /// asks whether a particular clip carried a location.
  final List<String> removedBoxes;
}

/// Box types worth removing, and why each one.
///
/// `udta` is where `©xyz` (ISO-6709 latitude/longitude), `©mak`, `©mod` and
/// friends live. `meta` is the iTunes-style metadata box, which on Apple
/// captures duplicates the location and adds the device name. `uuid` is the
/// vendor extension box — Apple and GoPro both use it for maker notes that
/// have carried GPS in the past.
const Set<String> _dropBoxes = {'udta', 'meta', 'uuid'};

/// Blank every location-bearing box, top-level and inside `moov`.
///
/// Anything that is not an MP4 or a QuickTime file comes back untouched, the
/// same way the image scrubber leaves formats it does not know alone.
ScrubbedVideo scrubVideoMetadata(Uint8List bytes) {
  if (!looksLikeMp4(bytes)) {
    return ScrubbedVideo(bytes: bytes, removedBoxes: const []);
  }

  // Copied first: the input may be a view onto a buffer the caller still owns,
  // and this rewrites in place.
  final out = Uint8List.fromList(bytes);
  final removed = <String>[];
  _scrubRange(out, 0, out.length, removed, depth: 0);
  return ScrubbedVideo(bytes: out, removedBoxes: removed);
}

/// Whether these bytes are an ISO base media file (MP4, M4V, MOV).
///
/// Every one of them starts with a box whose type is `ftyp`, at offset 4.
bool looksLikeMp4(Uint8List b) =>
    b.length >= 12 &&
    b[4] == 0x66 && // f
    b[5] == 0x74 && // t
    b[6] == 0x79 && // y
    b[7] == 0x70; // p

void _scrubRange(
  Uint8List bytes,
  int start,
  int end,
  List<String> removed, {
  required int depth,
}) {
  // Two levels is enough: top-level for `uuid` and QuickTime's `meta`, and
  // inside `moov` for `udta`. Recursing further would mean walking into
  // `trak`, which holds nothing worth removing and plenty worth breaking.
  if (depth > 1) return;

  var offset = start;
  while (offset + 8 <= end) {
    final size32 = _readUint32(bytes, offset);
    final type = String.fromCharCodes(bytes, offset + 4, offset + 8);

    int boxSize;
    int headerSize;
    if (size32 == 1) {
      // 64-bit size, in the eight bytes after the type.
      if (offset + 16 > end) return;
      boxSize = _readUint64(bytes, offset + 8);
      headerSize = 16;
    } else if (size32 == 0) {
      // Runs to the end of the file.
      boxSize = end - offset;
      headerSize = 8;
    } else {
      boxSize = size32;
      headerSize = 8;
    }

    // A malformed or truncated box: stop rather than guess. Better to upload
    // something unscrubbed than to hand back a corrupted file — the upload
    // still has to pass the magic-byte check either way.
    if (boxSize < headerSize || offset + boxSize > end) return;

    if (_dropBoxes.contains(type)) {
      removed.add(type);
      // Same length, new type, empty payload. 'free' is defined as ignorable.
      bytes[offset + 4] = 0x66; // f
      bytes[offset + 5] = 0x72; // r
      bytes[offset + 6] = 0x65; // e
      bytes[offset + 7] = 0x65; // e
      bytes.fillRange(offset + headerSize, offset + boxSize, 0);
    } else if (type == 'moov' || type == 'trak') {
      _scrubRange(
        bytes,
        offset + headerSize,
        offset + boxSize,
        removed,
        depth: depth + 1,
      );
    }

    offset += boxSize;
  }
}

int _readUint32(Uint8List b, int i) =>
    (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

int _readUint64(Uint8List b, int i) {
  var value = 0;
  for (var k = 0; k < 8; k++) {
    value = (value << 8) | b[i + k];
  }
  return value;
}
