import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';

import 'sensitive_store.dart';

/// Encrypted, app-private storage for media that has not reached Postgres yet.
///
/// The outbox stores only the managed file path and upload metadata. Bytes stay
/// outside Keychain/Keystore, where large images and voice notes do not belong.
class PendingMediaStore {
  PendingMediaStore._(this._root, this._keys);

  static const _keyName = 'vently.pending-media.key.v1';
  static const _magic = <int>[0x56, 0x50, 0x4d, 0x31]; // VPM1
  static const maxAttachmentBytes = 25 * 1024 * 1024;

  final Directory _root;
  final SensitiveStore _keys;
  final AesGcm _cipher = AesGcm.with256bits();
  Future<SecretKey>? _loadedKey;

  static Future<PendingMediaStore> open({SensitiveStore? keyStore}) async {
    final support = await getApplicationSupportDirectory();
    return PendingMediaStore._(
      Directory('${support.path}${Platform.pathSeparator}pending-media-v1'),
      keyStore ?? DeviceSensitiveStore(),
    );
  }

  /// Test-only construction that still uses the production encryption format.
  static PendingMediaStore forDirectory(
    Directory root, {
    required SensitiveStore keyStore,
  }) => PendingMediaStore._(root, keyStore);

  Future<String> stage({
    required String userId,
    required String operationId,
    required List<int> bytes,
    required String extension,
  }) async {
    if (bytes.isEmpty) throw ArgumentError.value(bytes, 'bytes', 'is empty');
    if (bytes.length > maxAttachmentBytes) {
      throw ArgumentError.value(
        bytes.length,
        'bytes',
        'attachment exceeds $maxAttachmentBytes bytes',
      );
    }

    final safeUser = _safeSegment(userId, fallback: 'account');
    final safeOperation = _safeSegment(operationId, fallback: 'operation');
    final safeExtension = _safeSegment(extension, fallback: 'bin');
    final directory = Directory(
      '${_root.path}${Platform.pathSeparator}$safeUser',
    );
    await directory.create(recursive: true);

    final secretBox = await _cipher.encrypt(
      bytes,
      secretKey: await _secretKey(),
    );
    final sealed = Uint8List.fromList([
      ..._magic,
      secretBox.nonce.length,
      secretBox.mac.bytes.length,
      ...secretBox.nonce,
      ...secretBox.mac.bytes,
      ...secretBox.cipherText,
    ]);
    final destination = File(
      '${directory.path}${Platform.pathSeparator}'
      '$safeOperation.$safeExtension.vpm',
    );
    final temporary = File('${destination.path}.tmp');
    await temporary.writeAsBytes(sealed, flush: true);
    if (await destination.exists()) await destination.delete();
    await temporary.rename(destination.path);
    return destination.path;
  }

  Future<Uint8List> read(String path) async {
    final file = _managedFile(path);
    final sealed = await file.readAsBytes();
    if (sealed.length < 6 || !_startsWith(sealed, _magic)) {
      throw const FormatException('Invalid pending media envelope');
    }
    final nonceLength = sealed[4];
    final macLength = sealed[5];
    final cipherOffset = 6 + nonceLength + macLength;
    if (nonceLength == 0 || macLength == 0 || cipherOffset > sealed.length) {
      throw const FormatException('Invalid pending media envelope');
    }
    final box = SecretBox(
      sealed.sublist(cipherOffset),
      nonce: sealed.sublist(6, 6 + nonceLength),
      mac: Mac(sealed.sublist(6 + nonceLength, cipherOffset)),
    );
    return Uint8List.fromList(
      await _cipher.decrypt(box, secretKey: await _secretKey()),
    );
  }

  Future<void> delete(String? path) async {
    if (path == null || path.isEmpty) return;
    final file = _managedFile(path);
    if (await file.exists()) await file.delete();
    final parent = file.parent;
    if (await parent.exists() && await parent.list().isEmpty) {
      await parent.delete();
    }
  }

  File _managedFile(String path) {
    final root = _normalizePath(_root.absolute.path);
    final candidate = _normalizePath(File(path).absolute.path);
    final prefix = '$root${Platform.pathSeparator}';
    if (!candidate.startsWith(prefix)) {
      throw StateError('Pending media path is outside the managed directory');
    }
    return File(candidate);
  }

  static String _normalizePath(String path) =>
      Uri.file(path).normalizePath().toFilePath();

  Future<SecretKey> _secretKey() => _loadedKey ??= _loadOrCreateSecretKey();

  Future<SecretKey> _loadOrCreateSecretKey() async {
    final existing = await _keys.read(_keyName);
    if (existing != null) {
      try {
        final bytes = base64Url.decode(existing);
        if (bytes.length == 32) return SecretKey(bytes);
      } catch (_) {
        // Replace malformed key material. Existing files will fail closed.
      }
    }
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    await _keys.write(_keyName, base64Url.encode(bytes));
    return SecretKey(bytes);
  }

  static String _safeSegment(String value, {required String fallback}) {
    final safe = value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '');
    if (safe.isEmpty) return fallback;
    return safe.substring(0, min(80, safe.length));
  }

  static bool _startsWith(List<int> value, List<int> prefix) {
    if (value.length < prefix.length) return false;
    for (var index = 0; index < prefix.length; index += 1) {
      if (value[index] != prefix[index]) return false;
    }
    return true;
  }
}
