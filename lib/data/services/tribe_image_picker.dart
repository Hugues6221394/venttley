import 'dart:typed_data';

import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/image_magic_bytes.dart';
import '../../core/logger.dart';

/// What a Tribe image is for. Avatars are square, banners are wide, and the
/// two differ in every dimension rule below — which is why the old code,
/// which used one `uploadTribeAvatar` for both, could not enforce either.
enum TribeImageKind {
  avatar,
  banner;

  bool get isBanner => this == TribeImageKind.banner;

  String get label => isBanner ? 'banner' : 'picture';

  /// Enforced by cropping to it, not by rejecting the source.
  ///
  /// Rejecting "wrong aspect ratio" would mean telling somebody their photo is
  /// unacceptable when what we actually need is a decision about framing —
  /// which is the crop step's whole job.
  (int x, int y) get ratio => isBanner ? (16, 9) : (1, 1);

  /// The longest edge kept. Past this a Tribe picture is paying for pixels
  /// nothing renders: the avatar is drawn at 46pt and the banner at screen
  /// width.
  int get maxEdge => isBanner ? 1920 : 1024;
}

/// A picked, cropped, compressed Tribe image, ready to upload.
class PreparedTribeImage {
  const PreparedTribeImage({
    required this.bytes,
    required this.extension,
    required this.contentType,
  });

  final Uint8List bytes;
  final String extension;
  final String contentType;

  int get sizeBytes => bytes.length;
}

/// Raised when a chosen file cannot be used, with a reason worth showing.
class TribeImageRejected implements Exception {
  const TribeImageRejected(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Pick → crop → compress → validate, in one place.
///
/// This existed three times before, inconsistently: `create_tribe_screen`,
/// `edit_tribe_screen` and `tribe_chat_hub_screen` each had their own picker
/// call, and only two of the three checked the file size at all. None of them
/// offered a crop, so a keeper's rectangular photo became a squashed avatar,
/// and none validated that the bytes were actually an image beyond what the
/// upload path happened to do.
///
/// The order matters. Cropping *before* compressing means the compressor is
/// sizing the pixels that will actually be shown, and validating *after* both
/// means the bytes checked are the bytes uploaded — a check on the source file
/// would say nothing about what the cropper handed back.
class TribeImagePicker {
  TribeImagePicker({ImagePicker? picker, ImageCropper? cropper})
    : _picker = picker ?? ImagePicker(),
      _cropper = cropper ?? ImageCropper();

  final ImagePicker _picker;
  final ImageCropper _cropper;

  /// Hard ceiling on what leaves the device.
  ///
  /// Below the bucket's own 20 MB limit on purpose: the bucket cap is the last
  /// line, and a client that only relies on it makes the user wait for a
  /// 20 MB upload before being told no.
  static const int maxUploadBytes = 6 * 1024 * 1024;

  /// Returns null when the person backs out of either the picker or the crop.
  ///
  /// Cancelling the crop is a cancel, not a fall-through to the uncropped
  /// original: they were asked to choose a framing and declined.
  Future<PreparedTribeImage?> pick(TribeImageKind kind) async {
    final XFile? picked;
    try {
      picked = await _picker.pickImage(
        source: ImageSource.gallery,
        // A first pass at the source, so a 48-megapixel photo is not decoded
        // at full size just to be cropped down. The crop step re-encodes
        // anyway; this only bounds the intermediate.
        imageQuality: 90,
        maxWidth: kind.maxEdge.toDouble() * 2,
        maxHeight: kind.maxEdge.toDouble() * 2,
      );
    } catch (error) {
      throw const TribeImageRejected("Couldn't open that image.");
    }
    if (picked == null) return null;

    final cropped = await _crop(picked.path, kind);
    if (cropped == null) return null;

    final bytes = await cropped.readAsBytes();

    // Magic bytes, not the extension. The picker reports whatever the file was
    // named; this is the only thing that knows what it actually is. A renamed
    // PDF or executable dies here rather than at the bucket's MIME allowlist,
    // which is a courtesy check the client can be told to skip.
    try {
      assertSupportedImage(bytes);
    } on UnsupportedImageFormatException catch (error) {
      throw TribeImageRejected(error.reason);
    }

    if (bytes.length > maxUploadBytes) {
      throw TribeImageRejected(
        'That ${kind.label} is still ${_mb(bytes.length)} after compression. '
        'Try a smaller image.',
      );
    }

    final detected = detectImageKind(bytes);
    return PreparedTribeImage(
      bytes: bytes,
      // Derived from the bytes, so the path we build and the Content-Type we
      // declare both describe the real payload.
      extension: _extensionFor(detected),
      contentType: _contentTypeFor(detected),
    );
  }

  Future<CroppedFile?> _crop(String sourcePath, TribeImageKind kind) async {
    final (rx, ry) = kind.ratio;
    try {
      return await _cropper.cropImage(
        sourcePath: sourcePath,
        // Locked, not merely suggested. A Tribe avatar is rendered in a circle
        // and a banner in a fixed-height band, so a free-form crop would just
        // be cropped again by the layout, off-centre.
        aspectRatio: CropAspectRatio(ratioX: rx.toDouble(), ratioY: ry.toDouble()),
        maxWidth: kind.maxEdge,
        maxHeight: kind.isBanner
            ? (kind.maxEdge * ry / rx).round()
            : kind.maxEdge,
        // This is the compression step. uCrop and TOCropViewController both
        // re-encode, so a separate compressor package would be a third
        // re-encode for no gain.
        compressFormat: ImageCompressFormat.jpg,
        compressQuality: 88,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'Crop ${kind.label}',
            lockAspectRatio: true,
            hideBottomControls: false,
          ),
          IOSUiSettings(
            title: 'Crop ${kind.label}',
            aspectRatioLockEnabled: true,
            resetAspectRatioEnabled: false,
          ),
        ],
      );
    } catch (error) {
      // A missing UCropActivity declaration surfaces here as a platform
      // exception at runtime rather than at build time, so it is named.
      log.warn('tribe.crop_failed', props: {'error': error.toString()});
      throw const TribeImageRejected(
        "Couldn't open the cropper. Try a different image.",
      );
    }
  }

  static String _extensionFor(DetectedImageKind? kind) => switch (kind) {
    DetectedImageKind.png => 'png',
    DetectedImageKind.webp => 'webp',
    DetectedImageKind.gif => 'gif',
    DetectedImageKind.heic => 'heic',
    // The cropper re-encodes to JPEG, so this is the usual answer.
    _ => 'jpg',
  };

  static String _contentTypeFor(DetectedImageKind? kind) => switch (kind) {
    DetectedImageKind.png => 'image/png',
    DetectedImageKind.webp => 'image/webp',
    DetectedImageKind.gif => 'image/gif',
    DetectedImageKind.heic => 'image/heic',
    _ => 'image/jpeg',
  };

  static String _mb(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
