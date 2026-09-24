import 'dart:async';
import 'dart:io';

import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Putting a photo or a clip somebody was sent into their camera roll.
///
/// The app has never written to the photo library. The closest thing is the
/// "Download Image" button on the share card, which screenshots to a temp file
/// and hands it to the system share sheet — so saving takes two taps and a
/// menu somebody has to know to look in.
///
/// gal rather than permission_handler, deliberately: it asks for add-only
/// access to the photo library, which is the narrowest permission iOS offers,
/// and the Podfile compiles PERMISSION_PHOTOS out on purpose. Nothing here
/// ever reads the library.
class MediaSaver {
  MediaSaver({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Download from a signed URL and hand the bytes to the gallery.
  ///
  /// Via a temp file rather than [Gal.putImageBytes] for video: the platform
  /// APIs for saving a movie take a file path, and writing one is cheaper than
  /// holding a 20 MB clip in memory twice.
  Future<MediaSaveResult> saveFromUrl(
    String url, {
    required bool isVideo,
    required String fileName,
  }) async {
    try {
      if (!await Gal.hasAccess(toAlbum: false)) {
        final granted = await Gal.requestAccess(toAlbum: false);
        if (!granted) return MediaSaveResult.denied;
      }

      final response = await _client.get(Uri.parse(url));
      if (response.statusCode != 200) return MediaSaveResult.failed;

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(response.bodyBytes);

      if (isVideo) {
        await Gal.putVideo(file.path);
      } else {
        await Gal.putImage(file.path);
      }

      // The gallery has its own copy now; leaving this behind would grow the
      // cache by the size of every photo anybody ever saved.
      unawaited(file.delete());
      return MediaSaveResult.saved;
    } on GalException catch (e) {
      return e.type == GalExceptionType.accessDenied
          ? MediaSaveResult.denied
          : MediaSaveResult.failed;
    } catch (_) {
      return MediaSaveResult.failed;
    }
  }
}

/// Said three ways because the answer to each is different: nothing, open
/// Settings, or try again.
enum MediaSaveResult { saved, denied, failed }
