import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import '../../domain/avatar/avatar_look.dart';

/// Flattens an [AvatarLook] into one PNG.
///
/// Why bake at all, when the app can draw the layers live: a reader scrolling
/// the feed sees *other people's* avatars, and those arrive as a
/// profile_photo_url on a feed row. Teaching every surface that shows a face —
/// feed, comments, chat, search, tribe members — to fetch and compose a
/// stranger's config would mean reissuing the feed_posts view, which is the
/// one that silently lost `security_invoker` the last time it was reissued and
/// turned row level security off for eight readers. Baking to a URL changes
/// nothing anywhere else.
///
/// Composed with a canvas rather than by screenshotting a RepaintBoundary, so
/// the result does not depend on the widget being laid out, on the device's
/// pixel ratio, or on anything the studio happens to be drawing around it.
class AvatarBaker {
  const AvatarBaker._();

  /// Big enough for a profile header at 3x, small enough to send often.
  static const size = 512;

  /// Bits kept per colour channel before encoding.
  ///
  /// dart:ui will only hand back PNG, and a 512px PNG of this art is 233KB —
  /// heavy for something a feed fetches once per author. The shading is flat
  /// enough that dropping to 4 bits is invisible at the sizes an avatar is
  /// ever drawn, and takes the file to about 90KB. Alpha is left alone; the
  /// edges of a hairstyle are where banding would actually show.
  static const _bitsPerChannel = 4;

  static Future<Uint8List> bake(AvatarLook look) async {
    final recorder = ui.PictureRecorder();
    final rect = Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble());
    final canvas = Canvas(recorder, rect);

    for (final layer in look.layers) {
      final image = await _load(layer.asset);
      final paint = Paint()..filterQuality = FilterQuality.high;
      final tint = layer.tint;
      if (tint != null) paint.colorFilter = AvatarPalettes.multiply(tint);
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        rect,
        paint,
      );
      image.dispose();
    }

    final picture = recorder.endRecording();
    final composed = await picture.toImage(size, size);
    picture.dispose();

    final raw = await composed.toByteData(format: ui.ImageByteFormat.rawRgba);
    composed.dispose();
    if (raw == null) throw StateError('avatar_bake_failed');

    final posterised = await _posterise(raw.buffer.asUint8List());
    final png = await posterised.toByteData(format: ui.ImageByteFormat.png);
    posterised.dispose();
    if (png == null) throw StateError('avatar_encode_failed');
    return png.buffer.asUint8List();
  }

  static Future<ui.Image> _load(String asset) async {
    final data = await rootBundle.load(asset);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  /// Quantise RGB in place, then hand the pixels back to the engine.
  static Future<ui.Image> _posterise(Uint8List rgba) async {
    const levels = 1 << _bitsPerChannel;
    final lut = Uint8List(256);
    for (var i = 0; i < 256; i++) {
      // Round-trip through the level count so 255 survives as 255 — a LUT that
      // lands on 248 puts a grey cast on every white shirt.
      lut[i] = ((i * (levels - 1) / 255).round() * 255 / (levels - 1)).round();
    }
    for (var i = 0; i < rgba.length; i += 4) {
      rgba[i] = lut[rgba[i]];
      rgba[i + 1] = lut[rgba[i + 1]];
      rgba[i + 2] = lut[rgba[i + 2]];
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      size,
      size,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }
}
