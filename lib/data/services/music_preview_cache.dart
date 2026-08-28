import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../domain/entities/entities.dart';

typedef MusicCacheDirectory = Future<Directory> Function();

/// Small, rights-aware cache for authorized preview clips only.
///
/// Catalog rows opt in with `cache_allowed`; external streaming providers are
/// never cached by default. Files are content-addressed, bounded by both file
/// and directory size, and live in the OS cache directory so the platform may
/// reclaim them under storage pressure.
class MusicPreviewCache {
  MusicPreviewCache({
    http.Client? client,
    MusicCacheDirectory? directory,
    this.maxBytes = 32 * 1024 * 1024,
    this.maxEntries = 40,
    this.maxFileBytes = 5 * 1024 * 1024,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _directory = directory ?? _defaultDirectory;

  final http.Client _client;
  final bool _ownsClient;
  final MusicCacheDirectory _directory;
  final int maxBytes;
  final int maxEntries;
  final int maxFileBytes;
  final Map<String, Future<String?>> _inFlight = {};

  static Future<Directory> _defaultDirectory() async {
    final root = await getTemporaryDirectory();
    return Directory('${root.path}/venttly_music_previews_v1');
  }

  Future<String?> resolve(MusicTrack track) {
    if (!track.cacheAllowed) return Future<String?>.value();
    final uri = Uri.tryParse(track.previewUrl);
    if (uri == null || uri.scheme != 'https') {
      return Future<String?>.value();
    }
    final key = sha256
        .convert(utf8.encode('${track.trackId}|${track.previewUrl}'))
        .toString();
    return _inFlight.putIfAbsent(key, () async {
      try {
        return await _resolve(key, uri);
      } finally {
        _inFlight.remove(key);
      }
    });
  }

  Future<String?> _resolve(String key, Uri uri) async {
    final directory = await _directory();
    await directory.create(recursive: true);
    final target = File('${directory.path}/$key.preview');
    if (await target.exists()) {
      final length = await target.length();
      if (length > 0 && length <= maxFileBytes) {
        await target.setLastModified(DateTime.now());
        return target.path;
      }
      await target.delete();
    }

    final partial = File('${directory.path}/$key.partial');
    IOSink? sink;
    try {
      final response = await _client
          .send(http.Request('GET', uri))
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != HttpStatus.ok) return null;
      final declared = response.contentLength;
      if (declared != null && declared > maxFileBytes) return null;
      final contentType = response.headers['content-type']?.toLowerCase() ?? '';
      if (contentType.isNotEmpty &&
          !contentType.startsWith('audio/') &&
          contentType != 'application/octet-stream') {
        return null;
      }

      sink = partial.openWrite();
      var received = 0;
      await for (final chunk in response.stream) {
        received += chunk.length;
        if (received > maxFileBytes) {
          throw const FileSystemException('Music preview exceeds cache limit');
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (received == 0) return null;
      await partial.rename(target.path);
      try {
        await _evict(directory, keepPath: target.path);
      } catch (_) {
        // The downloaded preview is still usable when best-effort eviction
        // encounters a transient filesystem race or permission error.
      }
      return target.path;
    } catch (_) {
      return null;
    } finally {
      await sink?.close();
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<void> _evict(Directory directory, {required String keepPath}) async {
    final files = await directory
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.preview'))
        .cast<File>()
        .toList();
    final entries = <({File file, int bytes, DateTime touched})>[];
    for (final file in files) {
      final stat = await file.stat();
      entries.add((file: file, bytes: stat.size, touched: stat.modified));
    }
    entries.sort((a, b) => a.touched.compareTo(b.touched));
    var total = entries.fold<int>(0, (sum, entry) => sum + entry.bytes);
    var count = entries.length;
    for (final entry in entries) {
      if (count <= maxEntries && total <= maxBytes) break;
      if (entry.file.path == keepPath) continue;
      await entry.file.delete();
      total -= entry.bytes;
      count -= 1;
    }
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
