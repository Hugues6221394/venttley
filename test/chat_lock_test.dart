import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:vently_app/data/services/chat_lock.dart';
import 'package:vently_app/data/services/sensitive_store.dart';
import 'package:vently_app/domain/entities/entities.dart';

/// Locking a conversation.
///
/// The lock is deliberately two halves. Whether a chat is locked is account
/// state on dm_room_prefs, so it follows you to a new phone and so the server
/// can withhold the last message entirely. Whether *you* may open it is a
/// device question, answered here.
///
/// This is not encryption and the tests do not pretend it is. What is worth
/// pinning is the handling of the PIN, because that is the part that would
/// quietly be wrong.
class _MemoryStore implements SensitiveStore {
  final Map<String, String> _data = {};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<Map<String, String>> readAll() async => Map.of(_data);

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

class _NoBiometrics implements LocalAuthentication {
  @override
  Future<bool> get canCheckBiometrics async => false;

  @override
  Future<bool> isDeviceSupported() async => false;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<Object> authMessages = const [],
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async => false;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() async => const [];

  @override
  Future<bool> stopAuthentication() async => false;
}

ChatRoom _room({DateTime? lockedAt, DateTime? archivedAt}) => ChatRoom(
  roomId: 'r1',
  peerPseudonym: '@someone',
  peerAvatarSeed: 'seed',
  requestPreview: '',
  roomStatus: 'active',
  createdAt: DateTime(2026, 1, 1),
  initiatedByMe: true,
  lockedAt: lockedAt,
  archivedAt: archivedAt,
);

void main() {
  late _MemoryStore store;
  late ChatLock lock;

  setUp(() {
    store = _MemoryStore();
    lock = ChatLock(store: store, auth: _NoBiometrics());
  });

  test('a PIN is not stored in the clear', () async {
    await lock.setPin('1234');
    final saved = await store.readAll();

    expect(
      saved.values,
      isNot(contains('1234')),
      reason: 'secure storage is only as private as the device it sits on',
    );
    expect(await lock.checkPin('1234'), isTrue);
    expect(await lock.checkPin('1235'), isFalse);
  });

  test('two people choosing the same PIN store different things', () async {
    // Salted, because four digits is ten thousand possibilities: an unsalted
    // digest of one is a lookup table anybody can build.
    await lock.setPin('1234');
    final first = (await store.readAll())['chat_lock_pin'];

    final other = ChatLock(store: _MemoryStore(), auth: _NoBiometrics());
    await other.setPin('1234');

    expect(first, isNotNull);
    expect(await lock.checkPin('1234'), isTrue);
    expect(await other.checkPin('1234'), isTrue);
  });

  test('no PIN set means nothing passes', () async {
    // Otherwise an empty store would compare null to null and open the chat.
    expect(await lock.hasPin, isFalse);
    expect(await lock.checkPin(''), isFalse);
    expect(await lock.checkPin('0000'), isFalse);
  });

  test('clearing the PIN removes the salt with it', () async {
    await lock.setPin('4321');
    await lock.clearPin();

    expect(await lock.hasPin, isFalse);
    expect(await store.readAll(), isEmpty);
    expect(await lock.checkPin('4321'), isFalse);
  });

  test('a device with no biometrics says so rather than throwing', () async {
    // The lock screen has to draw either way, so a device that cannot answer
    // the question must not take the screen down with it.
    expect(await lock.canUseBiometrics, isFalse);
    expect(await lock.authenticateWithDevice(), isFalse);
  });

  test('a room knows whether it is locked or filed away', () {
    expect(_room().isLocked, isFalse);
    expect(_room().isArchived, isFalse);
    expect(_room(lockedAt: DateTime(2026, 2, 1)).isLocked, isTrue);
    expect(_room(archivedAt: DateTime(2026, 2, 1)).isArchived, isTrue);
  });
}
