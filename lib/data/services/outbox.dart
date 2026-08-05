import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../repositories/vently_repository.dart';
import 'pending_media_store.dart';
import 'sensitive_store.dart';

enum OutboxKind { post, comment, whisperComment, dm, tribeMessage }

class StagedOutboxMedia {
  const StagedOutboxMedia({
    required this.path,
    required this.extension,
    required this.contentType,
    required this.mediaType,
    this.durationSeconds,
  });

  final String path;
  final String extension;
  final String contentType;
  final String mediaType;
  final int? durationSeconds;

  Map<String, dynamic> toPayload() => {
        'localMediaPath': path,
        'localMediaExtension': extension,
        'localMediaContentType': contentType,
        'localMediaType': mediaType,
        'localMediaDurationSeconds': durationSeconds,
      };
}

class OutboxOp {
  OutboxOp({
    required this.id,
    required this.kind,
    required this.payload,
    required this.createdAt,
    this.attempts = 0,
    this.nextRetryAt,
    this.lastError,
    this.failedAt,
    this.actorUserId,
  });

  final String id;
  final OutboxKind kind;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  int attempts;
  DateTime? nextRetryAt;
  String? lastError;
  DateTime? failedAt;
  String? actorUserId;

  bool get isFailed => failedAt != null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'payload': payload,
        'createdAt': createdAt.toIso8601String(),
        'attempts': attempts,
        'nextRetryAt': nextRetryAt?.toIso8601String(),
        'lastError': lastError,
        'failedAt': failedAt?.toIso8601String(),
        'actorUserId': actorUserId,
      };

  static OutboxOp? fromJson(Map<String, dynamic> value) {
    try {
      final id = value['id'];
      final kindName = value['kind'];
      final rawPayload = value['payload'];
      final createdAt = DateTime.tryParse(value['createdAt'] as String? ?? '');
      if (id is! String || id.isEmpty || kindName is! String) return null;
      if (rawPayload is! Map || createdAt == null) return null;

      OutboxKind? kind;
      for (final candidate in OutboxKind.values) {
        if (candidate.name == kindName) {
          kind = candidate;
          break;
        }
      }
      if (kind == null) return null;

      final payload = <String, dynamic>{};
      for (final entry in rawPayload.entries) {
        if (entry.key is String) payload[entry.key as String] = entry.value;
      }
      return OutboxOp(
        id: id,
        kind: kind,
        payload: payload,
        createdAt: createdAt,
        attempts: value['attempts'] is int ? value['attempts'] as int : 0,
        nextRetryAt: value['nextRetryAt'] is String
            ? DateTime.tryParse(value['nextRetryAt'] as String)
            : null,
        lastError: value['lastError'] as String?,
        failedAt: value['failedAt'] is String
            ? DateTime.tryParse(value['failedAt'] as String)
            : null,
        actorUserId: value['actorUserId'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  String get label => switch (kind) {
        OutboxKind.post => 'vent',
        OutboxKind.comment => 'reply',
        OutboxKind.whisperComment => 'whisper reply',
        OutboxKind.dm => 'message',
        OutboxKind.tribeMessage => 'tribe message',
      };
}

typedef OutboxExecutor = Future<void> Function(OutboxOp operation);

/// Encrypted, per-operation retry queue for writes that failed in transit.
///
/// Each operation has its own secure-storage record. Successful sends are
/// tombstoned before deletion so a crash during cleanup does not replay a
/// known-complete write on the next launch.
class OutboxService extends ChangeNotifier {
  OutboxService._(
    this._storage,
    this._executor,
    this._now,
    this._userId,
    this._mediaStore,
    List<OutboxOp> operations,
  ) : _ops = operations {
    if (_ops.any((operation) => !operation.isFailed)) _armTimer();
  }

  static const _legacyKey = 'vently.outbox.v1';
  static const _keyPrefix = 'vently.outbox.v2.';
  static const maxAge = Duration(hours: 24);
  static const _heartbeat = Duration(seconds: 30);

  final SensitiveStore _storage;
  final OutboxExecutor _executor;
  final DateTime Function() _now;
  final String? _userId;
  final PendingMediaStore? _mediaStore;
  final List<OutboxOp> _ops;
  Timer? _timer;
  bool _flushing = false;

  static Future<OutboxService> open(
    VentlyRepository repository, {
    required String? userId,
  }) async {
    final storage = DeviceSensitiveStore();
    await _migrateLegacyPreferences(storage);
    final mediaStore = await PendingMediaStore.open(keyStore: storage);
    late OutboxService service;
    service = await openWithStore(
      storage,
      userId: userId,
      mediaStore: mediaStore,
      executor: (operation) => _executeWithRepository(
        repository,
        operation,
        mediaStore,
        () => service._persist(operation),
      ),
    );
    return service;
  }

  static Future<OutboxService> openWithStore(
    SensitiveStore storage, {
    required OutboxExecutor executor,
    DateTime Function()? now,
    String? userId = 'test-user',
    PendingMediaStore? mediaStore,
  }) async {
    final clock = now ?? DateTime.now;
    final cutoff = clock().subtract(maxAge);
    final operations = <OutboxOp>[];
    final values = await storage.readAll();

    for (final entry in values.entries.where(
      (entry) => entry.key.startsWith(_keyPrefix),
    )) {
      try {
        final decoded = jsonDecode(entry.value);
        if (decoded is Map && decoded['completed'] == true) {
          await storage.delete(entry.key);
          continue;
        }
        final operation =
            decoded is Map<String, dynamic> ? OutboxOp.fromJson(decoded) : null;
        if (operation == null) {
          await storage.delete(entry.key);
          continue;
        }
        if (userId == null) continue;
        if (operation.actorUserId == null) {
          operation.actorUserId = userId;
          await storage.write(entry.key, jsonEncode(operation.toJson()));
        }
        if (operation.actorUserId != userId) continue;
        if (!operation.isFailed && !operation.createdAt.isAfter(cutoff)) {
          operation.failedAt = clock();
          operation.nextRetryAt = null;
          operation.lastError ??= 'Automatic retry window expired';
          await storage.write(entry.key, jsonEncode(operation.toJson()));
        }
        operations.add(operation);
      } catch (_) {
        await storage.delete(entry.key);
      }
    }
    operations.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return OutboxService._(
      storage,
      executor,
      clock,
      userId,
      mediaStore,
      operations,
    );
  }

  List<OutboxOp> get pending =>
      List.unmodifiable(_ops.where((operation) => !operation.isFailed));
  List<OutboxOp> get failed =>
      List.unmodifiable(_ops.where((operation) => operation.isFailed));
  int get pendingCount => pending.length;
  int get failedCount => failed.length;

  /// Create the mutation id before the first network attempt so a lost
  /// response and every later retry identify the same server-side write.
  static String newOperationId() => const Uuid().v4();

  /// Encrypts attachment bytes before the first network attempt. The returned
  /// metadata belongs in the operation payload and is removed only after the
  /// server confirms the idempotent database write.
  Future<StagedOutboxMedia> stageMedia({
    required String operationId,
    required List<int> bytes,
    required String extension,
    required String contentType,
    required String mediaType,
    int? durationSeconds,
  }) async {
    final userId = _userId;
    final mediaStore = _mediaStore;
    if (userId == null) {
      throw StateError('Cannot stage media while signed out');
    }
    if (mediaStore == null) {
      throw StateError('Pending media storage is unavailable');
    }
    final path = await mediaStore.stage(
      userId: userId,
      operationId: operationId,
      bytes: bytes,
      extension: extension,
    );
    return StagedOutboxMedia(
      path: path,
      extension: extension,
      contentType: contentType,
      mediaType: mediaType,
      durationSeconds: durationSeconds,
    );
  }

  Future<void> discardStagedMedia(String? path) =>
      _mediaStore?.delete(path) ?? Future<void>.value();

  Future<OutboxOp> enqueue(
    OutboxKind kind,
    Map<String, dynamic> payload, {
    String? operationId,
  }) async {
    final actorUserId = _userId;
    if (actorUserId == null) {
      throw StateError('Cannot queue a write while signed out');
    }
    final id = operationId ?? newOperationId();
    for (final existing in _ops) {
      if (existing.id == id) return existing;
    }
    final operation = OutboxOp(
      id: id,
      kind: kind,
      payload: Map<String, dynamic>.from(payload),
      createdAt: _now(),
      actorUserId: actorUserId,
    );
    await _storage.write(_storageKey(id), jsonEncode(operation.toJson()));
    _ops.add(operation);
    notifyListeners();
    _armTimer();
    return operation;
  }

  Future<void> remove(String id) async {
    OutboxOp? operation;
    for (final candidate in _ops) {
      if (candidate.id == id) {
        operation = candidate;
        break;
      }
    }
    if (operation != null) await _deleteLocalMedia(operation);
    await _storage.delete(_storageKey(id));
    _ops.removeWhere((operation) => operation.id == id);
    notifyListeners();
    _disarmIfIdle();
  }

  /// Requeue retained failures without changing their mutation ids.
  Future<void> retryFailed() async {
    var changed = false;
    for (var index = 0; index < _ops.length; index += 1) {
      final operation = _ops[index];
      if (!operation.isFailed) continue;
      final retried = OutboxOp(
        id: operation.id,
        kind: operation.kind,
        payload: Map<String, dynamic>.from(operation.payload),
        createdAt: _now(),
        actorUserId: operation.actorUserId,
      );
      await _storage.write(
        _storageKey(retried.id),
        jsonEncode(retried.toJson()),
      );
      _ops[index] = retried;
      changed = true;
    }
    if (!changed) return;
    notifyListeners();
    _armTimer();
  }

  void _armTimer() {
    _timer ??= Timer.periodic(_heartbeat, (_) => unawaited(flush()));
  }

  void _disarmIfIdle() {
    if (!_ops.any((operation) => !operation.isFailed)) {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Attempts every due operation once. Re-entry is intentionally a no-op.
  Future<void> flush() async {
    if (_flushing || pendingCount == 0) return;
    _flushing = true;
    try {
      final now = _now();
      final cutoff = now.subtract(maxAge);
      for (final operation in List<OutboxOp>.of(_ops)) {
        if (operation.isFailed) continue;
        if (!operation.createdAt.isAfter(cutoff)) {
          operation.failedAt = now;
          operation.nextRetryAt = null;
          operation.lastError ??= 'Automatic retry window expired';
          await _storage.write(
            _storageKey(operation.id),
            jsonEncode(operation.toJson()),
          );
          continue;
        }
        final due = operation.nextRetryAt == null ||
            !operation.nextRetryAt!.isAfter(now);
        if (!due) continue;
        try {
          await _executor(operation);
          await _deleteLocalMedia(operation);
          await _markComplete(operation.id);
          _ops.removeWhere((candidate) => candidate.id == operation.id);
        } catch (error) {
          operation.attempts += 1;
          operation.lastError = '$error';
          operation.nextRetryAt =
              _now().add(retryDelayForAttempt(operation.attempts));
          await _storage.write(
            _storageKey(operation.id),
            jsonEncode(operation.toJson()),
          );
        }
      }
      notifyListeners();
    } finally {
      _flushing = false;
      _disarmIfIdle();
    }
  }

  static Duration retryDelayForAttempt(int attempt) {
    final safeAttempt = max(1, attempt);
    return Duration(seconds: min(1 << min(safeAttempt, 7), 120));
  }

  Future<void> _markComplete(String id) async {
    final key = _storageKey(id);
    await _storage.write(
      key,
      jsonEncode({
        'id': id,
        'completed': true,
        'completedAt': _now().toIso8601String()
      }),
    );
    await _storage.delete(key);
  }

  static String _storageKey(String id) => '$_keyPrefix$id';

  Future<void> _persist(OutboxOp operation) => _storage.write(
        _storageKey(operation.id),
        jsonEncode(operation.toJson()),
      );

  Future<void> _deleteLocalMedia(OutboxOp operation) =>
      discardStagedMedia(operation.payload['localMediaPath'] as String?);

  static Future<void> _migrateLegacyPreferences(
    SensitiveStore storage,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_legacyKey);
    if (raw == null) return;
    final existing = await storage.readAll();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final value in decoded) {
          if (value is! Map) continue;
          final operation = OutboxOp.fromJson(
            Map<String, dynamic>.from(value),
          );
          if (operation == null) continue;
          final key = _storageKey(operation.id);
          if (!existing.containsKey(key)) {
            await storage.write(key, jsonEncode(operation.toJson()));
          }
        }
      }
      await prefs.remove(_legacyKey);
    } catch (_) {
      // Leave the legacy value in place so a future version can recover it.
    }
  }

  static Future<void> _executeWithRepository(
    VentlyRepository repository,
    OutboxOp operation,
    PendingMediaStore mediaStore,
    Future<void> Function() persistPayload,
  ) async {
    final actorUserId = operation.actorUserId;
    if (actorUserId == null || repository.currentUser?.userId != actorUserId) {
      throw StateError('Queued write belongs to another signed-in account');
    }
    final payload = operation.payload;
    await _uploadPendingMedia(
      repository,
      operation.kind,
      payload,
      mediaStore,
      persistPayload,
    );
    switch (operation.kind) {
      case OutboxKind.post:
        await repository.createPost(
          content: (payload['content'] as String?) ?? '',
          category: (payload['category'] as String?) ?? 'confessions',
          mood: (payload['mood'] as String?) ?? 'healing',
          tribeId: payload['tribeId'] as String?,
          spaceId: payload['spaceId'] as String?,
          personaId: payload['personaId'] as String?,
          isWhisper: (payload['isWhisper'] as bool?) ?? false,
          isStory: (payload['isStory'] as bool?) ?? false,
          storyAudience:
              (payload['storyAudience'] as String?) ?? 'everyone',
          imagePath: payload['imagePath'] as String?,
          imageUrl: payload['imageUrl'] as String?,
          audioPath: payload['audioPath'] as String?,
          audioUrl: payload['audioUrl'] as String?,
          audioDurationSeconds: payload['audioDurationSeconds'] as int?,
          cardBackgroundColor: payload['cardBackgroundColor'] as String?,
          cardTextColor: payload['cardTextColor'] as String?,
          idempotencyKey: operation.id,
        );
      case OutboxKind.comment:
        await repository.addComment(
          postId: payload['postId'] as String,
          parentId: payload['parentId'] as String?,
          content: payload['content'] as String,
          personaId: payload['personaId'] as String?,
          imageUrl: payload['imageUrl'] as String?,
          imagePath: payload['imagePath'] as String?,
          idempotencyKey: operation.id,
        );
      case OutboxKind.whisperComment:
        await repository.addWhisperComment(
          payload['whisperId'] as String,
          payload['content'] as String,
          personaId: payload['personaId'] as String?,
          parentId: payload['parentId'] as String?,
          idempotencyKey: operation.id,
        );
      case OutboxKind.dm:
        await repository.sendMessage(
          roomId: payload['roomId'] as String,
          plaintext: payload['plaintext'] as String,
          attachedMediaPath: payload['attachedMediaPath'] as String?,
          attachedMediaType: payload['attachedMediaType'] as String?,
          parentMessageId: payload['parentMessageId'] as String?,
          idempotencyKey: operation.id,
        );
      case OutboxKind.tribeMessage:
        await repository.sendTribeMessage(
          tribeId: payload['tribeId'] as String,
          content: payload['content'] as String?,
          personaId: payload['personaId'] as String?,
          imagePath: payload['imagePath'] as String?,
          imageUrl: payload['imageUrl'] as String?,
          audioPath: payload['audioPath'] as String?,
          audioUrl: payload['audioUrl'] as String?,
          audioDurationSeconds: payload['audioDurationSeconds'] as int?,
          replyToMessageId: payload['replyToMessageId'] as String?,
          idempotencyKey: operation.id,
        );
    }
  }

  static Future<void> _uploadPendingMedia(
    VentlyRepository repository,
    OutboxKind kind,
    Map<String, dynamic> payload,
    PendingMediaStore mediaStore,
    Future<void> Function() persistPayload,
  ) async {
    final localPath = payload['localMediaPath'] as String?;
    if (localPath == null) return;
    final mediaType = payload['localMediaType'] as String? ?? 'image';
    final extension = payload['localMediaExtension'] as String? ??
        (mediaType == 'audio' ? 'm4a' : 'jpg');
    final contentType = payload['localMediaContentType'] as String? ??
        (mediaType == 'audio' ? 'audio/mp4' : 'image/jpeg');

    switch (kind) {
      case OutboxKind.post:
      case OutboxKind.comment:
        if (payload['imageUrl'] != null) return;
        final upload = await repository.uploadPostImage(
          bytes: await mediaStore.read(localPath),
          extension: extension,
          contentType: contentType,
        );
        payload['imagePath'] = upload.path;
        payload['imageUrl'] = upload.url;
      case OutboxKind.dm:
        if (payload['attachedMediaPath'] != null) return;
        if (mediaType == 'audio') {
          final upload = await repository.uploadChatAudio(
            roomId: payload['roomId'] as String,
            bytes: await mediaStore.read(localPath),
            durationSeconds:
                (payload['localMediaDurationSeconds'] as int?) ?? 1,
          );
          payload['attachedMediaPath'] = upload.path;
          payload['attachedMediaType'] = 'audio';
        } else {
          final upload = await repository.uploadChatImage(
            roomId: payload['roomId'] as String,
            bytes: await mediaStore.read(localPath),
            extension: extension,
            contentType: contentType,
          );
          payload['attachedMediaPath'] = upload.path;
          payload['attachedMediaType'] = 'image';
        }
      case OutboxKind.tribeMessage:
        if (mediaType == 'audio') {
          if (payload['audioUrl'] != null) return;
          final upload = await repository.uploadTribeChatAudio(
            bytes: await mediaStore.read(localPath),
            extension: extension,
            contentType: contentType,
          );
          payload['audioPath'] = upload.path;
          payload['audioUrl'] = upload.url;
          payload['audioDurationSeconds'] =
              (payload['localMediaDurationSeconds'] as int?) ?? 1;
        } else {
          if (payload['imageUrl'] != null) return;
          final upload = await repository.uploadTribeChatImage(
            bytes: await mediaStore.read(localPath),
            extension: extension,
            contentType: contentType,
          );
          payload['imagePath'] = upload.path;
          payload['imageUrl'] = upload.url;
        }
      case OutboxKind.whisperComment:
        return;
    }
    await persistPayload();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
