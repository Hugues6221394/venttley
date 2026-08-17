// One-off backfill: remove EXIF/GPS from images already in Supabase Storage.
//
// 76c3c7d fixed uploads going forward. Everything uploaded before it still
// carries whatever the camera wrote, including GPS coordinates — so this walks
// the buckets and rewrites the ones that do.
//
// ## Why a Dart tool and not an Edge Function or SQL
//
// It imports the *same* `scrubImageMetadata` the app uses. A TypeScript
// reimplementation in an Edge Function would be a second copy of security-
// relevant logic that could drift from the tested one, and storage objects are
// opaque binaries so SQL cannot touch them at all.
//
// ## Safety
//
// * **Dry run by default.** Nothing is written without `--apply`.
// * **Originals are copied to disk before any overwrite.** Re-uploading with
//   upsert replaces the object with no server-side undo, so the local backup is
//   the rollback path. `--apply` refuses to run if the backup directory cannot
//   be created.
// * **Only rewrites objects whose bytes actually change.** A clean photo is
//   never touched, so the vast majority of objects are read-only.
// * **Never deletes anything.**
// * Credentials come from the environment. The service-role key must never be
//   pasted into a file, a commit, or a chat transcript.
//
// ## Usage
//
//   export SUPABASE_URL='https://<project>.supabase.co'
//   export SUPABASE_SERVICE_ROLE_KEY='<service role key>'
//
//   # 1. See what it would do. Reads only.
//   dart run tool/scrub_uploaded_image_metadata.dart
//
//   # 2. Do it, keeping originals under ./exif-backfill-backup/
//   dart run tool/scrub_uploaded_image_metadata.dart --apply
//
//   # Optional: one bucket at a time
//   dart run tool/scrub_uploaded_image_metadata.dart --apply --bucket=post-media

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:vently_app/core/image_metadata_scrubber.dart';

/// Every bucket the app uploads binaries to (audited from
/// supabase_backend.dart's `storage.from(...)` call sites). Tribe avatars and
/// banners live in post-media, which is why there is no tribe-media entry.
const _buckets = <String>[
  'post-media',
  'profile-photos',
  'chat-media',
  'tribe-chat-media',
  'whispers-media',
];

const _listPageSize = 100;

late final String _baseUrl;
late final String _serviceKey;

Future<void> main(List<String> args) async {
  final apply = args.contains('--apply');
  final onlyBucket = args
      .firstWhere((a) => a.startsWith('--bucket='), orElse: () => '')
      .replaceFirst('--bucket=', '');
  final backupDir = Directory(
    args
            .firstWhere((a) => a.startsWith('--backup='), orElse: () => '')
            .replaceFirst('--backup=', '')
            .trim()
            .isEmpty
        ? 'exif-backfill-backup'
        : args
              .firstWhere((a) => a.startsWith('--backup='))
              .replaceFirst('--backup=', ''),
  );

  final url = Platform.environment['SUPABASE_URL']?.trim();
  final key = Platform.environment['SUPABASE_SERVICE_ROLE_KEY']?.trim();
  if (url == null || url.isEmpty || key == null || key.isEmpty) {
    stderr.writeln(
      'Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in the environment.\n'
      'The service-role key bypasses RLS — do not put it in a file or a commit.',
    );
    exitCode = 64;
    return;
  }
  _baseUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  _serviceKey = key;

  if (apply) {
    try {
      backupDir.createSync(recursive: true);
    } catch (e) {
      stderr.writeln('Cannot create backup directory ${backupDir.path}: $e');
      stderr.writeln('Refusing to overwrite anything without a rollback path.');
      exitCode = 73;
      return;
    }
  }

  final targets = onlyBucket.isEmpty ? _buckets : [onlyBucket];
  stdout.writeln(
    apply
        ? 'APPLY — rewriting objects that carry metadata. '
              'Originals copied to ${backupDir.path}/'
        : 'DRY RUN — reading only. Re-run with --apply to write.',
  );
  stdout.writeln('Buckets: ${targets.join(', ')}\n');

  var scanned = 0;
  var carried = 0;
  var rewritten = 0;
  var failed = 0;
  var skippedNonImage = 0;

  for (final bucket in targets) {
    stdout.writeln('── $bucket');
    final paths = await _listAll(bucket);
    stdout.writeln('   ${paths.length} object(s)');

    for (final path in paths) {
      scanned++;
      try {
        final got = await _download(bucket, path);
        if (got == null) {
          failed++;
          stdout.writeln('   ?? $path — could not download');
          continue;
        }
        final scrubbed = scrubImageMetadata(got.bytes);
        if (!scrubbed.wasScrubbed) {
          // Either already clean or not a JPEG/PNG. Not touched either way.
          if (!_looksLikeImage(got.contentType, path)) skippedNonImage++;
          continue;
        }

        carried++;
        final saved = got.bytes.length - scrubbed.bytes.length;
        stdout.writeln(
          '   ${apply ? '->' : '  '} $path '
          '[${scrubbed.removedSegments.join(', ')}] -$saved bytes',
        );

        if (!apply) continue;

        // Back up the original *before* the overwrite. This is the only undo.
        final backupFile = File('${backupDir.path}/$bucket/$path');
        backupFile.parent.createSync(recursive: true);
        backupFile.writeAsBytesSync(got.bytes);

        final ok = await _overwrite(
          bucket,
          path,
          scrubbed.bytes,
          got.contentType,
        );
        if (ok) {
          rewritten++;
        } else {
          failed++;
          stdout.writeln('   !! $path — upload failed, original kept');
        }
      } catch (e) {
        failed++;
        stdout.writeln('   !! $path — $e');
      }
    }
  }

  stdout.writeln('\n───────────── summary');
  stdout.writeln('scanned            $scanned');
  stdout.writeln('carried metadata   $carried');
  stdout.writeln(
    apply ? 'rewritten          $rewritten' : 'would rewrite      $carried',
  );
  stdout.writeln('non-image objects  $skippedNonImage');
  stdout.writeln('failed             $failed');
  if (apply && rewritten > 0) {
    stdout.writeln(
      '\nOriginals: ${backupDir.path}/  (delete once you are satisfied)',
    );
  }
  if (failed > 0) exitCode = 1;
}

bool _looksLikeImage(String? contentType, String path) {
  final ct = (contentType ?? '').toLowerCase();
  if (ct.startsWith('image/')) return true;
  final p = path.toLowerCase();
  return p.endsWith('.jpg') ||
      p.endsWith('.jpeg') ||
      p.endsWith('.png') ||
      p.endsWith('.webp') ||
      p.endsWith('.gif');
}

Map<String, String> get _headers => {
  'Authorization': 'Bearer $_serviceKey',
  'apikey': _serviceKey,
};

/// Recursively lists every object path in a bucket.
///
/// The Storage list endpoint is one directory level at a time and paginated:
/// entries with a null `id` are prefixes (folders), not objects.
Future<List<String>> _listAll(String bucket, [String prefix = '']) async {
  final found = <String>[];
  var offset = 0;

  while (true) {
    final res = await http.post(
      Uri.parse('$_baseUrl/storage/v1/object/list/$bucket'),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'prefix': prefix,
        'limit': _listPageSize,
        'offset': offset,
        'sortBy': {'column': 'name', 'order': 'asc'},
      }),
    );
    if (res.statusCode != 200) {
      stderr.writeln(
        '  list $bucket/$prefix failed: ${res.statusCode} ${res.body}',
      );
      return found;
    }
    final rows = (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
    if (rows.isEmpty) break;

    for (final row in rows) {
      final name = row['name'] as String?;
      if (name == null || name.isEmpty) continue;
      final full = prefix.isEmpty ? name : '$prefix/$name';
      if (row['id'] == null) {
        found.addAll(await _listAll(bucket, full)); // folder
      } else {
        found.add(full);
      }
    }

    if (rows.length < _listPageSize) break;
    offset += _listPageSize;
  }
  return found;
}

class _Downloaded {
  _Downloaded(this.bytes, this.contentType);
  final Uint8List bytes;
  final String? contentType;
}

Future<_Downloaded?> _download(String bucket, String path) async {
  final res = await http.get(
    Uri.parse('$_baseUrl/storage/v1/object/$bucket/${_encodePath(path)}'),
    headers: _headers,
  );
  if (res.statusCode != 200) return null;
  return _Downloaded(res.bodyBytes, res.headers['content-type']);
}

Future<bool> _overwrite(
  String bucket,
  String path,
  List<int> bytes,
  String? contentType,
) async {
  final res = await http.put(
    Uri.parse('$_baseUrl/storage/v1/object/$bucket/${_encodePath(path)}'),
    headers: {
      ..._headers,
      'Content-Type': contentType ?? 'application/octet-stream',
      // Replace in place; the object's public URL must not change or every
      // post, profile and chat message referencing it would break.
      'x-upsert': 'true',
      'cache-control': '3600',
    },
    body: bytes,
  );
  return res.statusCode >= 200 && res.statusCode < 300;
}

String _encodePath(String path) =>
    path.split('/').map(Uri.encodeComponent).join('/');
